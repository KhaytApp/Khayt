'use strict';
/**
 * Lot tracing: which jobs a manufacturer's lot went into, and back.
 *
 * ── WHY ───────────────────────────────────────────────────────────────────
 *
 * A filament maker recalls a lot ("brittle, do not ship parts printed from
 * lot 2406-A"), or a customer brings back a part that cracked and the shop
 * wants every other job printed off the same filament. The book already says
 * which spool every gram came off; this joins that to the lot.
 *
 * ── WHERE THE ANSWER COMES FROM, BEST FIRST ───────────────────────────────
 *
 *   1. `printLog[].materialDrawn.spools` — what a COMPLETION took, spool by
 *      spool. Since lot tracing, each draw carries the lot the spool had at
 *      that moment (`lib/order-deduction.js` `lotStamp`): RECORDED.
 *   2. `wasteLog[].drawn` — what a FAILED attempt burned through, the same
 *      shape. Failed prints are in a recall too: the part may have been
 *      handed over anyway, or the failure may BE the defect.
 *   3. `inventory[].usageHistory` job rows that neither of the above already
 *      accounts for — every job deducted before `materialDrawn` existed. A
 *      row written since lot tracing carries its lot; an older one does not.
 *
 * A draw with no lot of its own takes the spool's CURRENT lot and is marked
 * `inferred`: the shop may have typed the lot after the job, or edited it
 * since, and the screen says so rather than claiming a certainty the book
 * does not have. The one exception is a draw dated BEFORE the receipt that
 * brought the current lot in (an empty spool refilled with a new lot keeps
 * its id): that draw takes the lot of the receipt then in force, or none.
 *
 * Lots are free text typed by hand, so matching trims and ignores case.
 *
 * PURE: nothing here is mutated. Loaded in Node, in the renderer and in the
 * Mac app's JavaScriptCore — which has no `global`, hence `globalThis`.
 */
(function (root) {
  const arr = (v) => (Array.isArray(v) ? v : []);
  const str = (v) => (typeof v === 'string' ? v : (v == null ? '' : String(v)));
  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
  const r2 = (n) => Math.round(num(n) * 100) / 100;

  /** A lot as it is compared: trimmed, case folded. Empty is no lot. */
  function lotKey(lot) {
    return str(lot).trim().toLowerCase();
  }

  /** Do two lots name the same thing? Two blanks do NOT. */
  function sameLot(a, b) {
    const x = lotKey(a);
    return !!x && x === lotKey(b);
  }

  function dayOf(v) {
    const s = str(v);
    return /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : '';
  }

  /** The book's three lists, however little of it was handed in. */
  function partsOf(book) {
    const b = book && typeof book === 'object' ? book : {};
    return { orders: arr(b.printLog), waste: arr(b.wasteLog), inventory: arr(b.inventory) };
  }

  function spoolMap(inventory) {
    const m = new Map();
    for (const s of arr(inventory)) if (s && s.id != null) m.set(str(s.id), s);
    return m;
  }

  /**
   * The lot (and order) a spool is presumed to have held on `date`.
   *
   * Its CURRENT lot, unless the receipts on its history say that lot arrived
   * after `date`: an empty spool refilled with a new lot is the same record,
   * relabelled, and without this every job it printed before the refill
   * would turn up in a recall of the new lot. Then the lot of the newest
   * receipt on or before `date` — or none, when no receipt says.
   *
   * `usageHistory` is newest first. The current lot arrived with the OLDEST
   * of the unbroken run of receipts at the top that name it; a newest receipt
   * naming some other lot (or none) means the lot was typed by hand, and the
   * current one is presumed throughout, as before.
   */
  function presumedLot(spool, date) {
    const current = { lot: str(spool && spool.lot).trim(), poId: str(spool && spool.poId) };
    if (!spool || !date || !current.lot) return current;
    const receipts = arr(spool.usageHistory)
      .filter((h) => h && h.type === 'received' && dayOf(h.date));
    let since = '';
    for (const h of receipts) {
      if (!sameLot(h.lot, current.lot)) break;
      since = dayOf(h.date);
    }
    if (!since || date >= since) return current;
    const then = receipts.find((h) => dayOf(h.date) <= date);
    return { lot: then ? str(then.lot).trim() : '', poId: then ? str(then.poId) : '' };
  }

  /** One draw, with the lot it is known or presumed to be from. */
  function drawRow(d, spools, extra) {
    const spoolId = str(d && d.spoolId);
    const spool = spools.get(spoolId);
    const own = str(d && d.lot).trim();
    const presumed = own ? null : presumedLot(spool, extra && extra.date);
    const row = {
      spoolId,
      grams: r2(d && (d.grams != null ? d.grams : d.weightUsed)),
      lot: own || presumed.lot,
      inferred: !own,
      poId: str((d && d.poId) || (presumed && presumed.poId) || ''),
    };
    return Object.assign(row, extra);
  }

  /**
   * Every draw the book knows of, normalised:
   * `{ orderId, project, date, spoolId, grams, lot, inferred, poId, source }`
   * where `source` is `completed`, `failed` or `history`.
   */
  function allDraws(book) {
    const { orders, waste, inventory } = partsOf(book);
    const spools = spoolMap(inventory);
    const byId = new Map();
    for (const o of orders) if (o && o.id != null) byId.set(str(o.id), o);
    const out = [];
    // What the structured records account for, so the same grams are not
    // found a second time in the spool's own history. Kept as a TOTAL per job
    // and spool, not row by row: a failed print that took twice off one spool
    // (two parts on it) has ONE 50 g row in `drawn` — `deductActual` merges
    // per spool — but two history rows of 30 g and 20 g, and a gram-for-gram
    // match would cover neither and count the job twice.
    const covered = new Map();
    const cover = (orderId, spoolId, grams) => {
      const k = orderId + '|' + spoolId;
      covered.set(k, r2((covered.get(k) || 0) + grams));
    };

    for (const o of orders) {
      const drawn = o && o.materialDrawn && arr(o.materialDrawn.spools);
      if (!drawn || !drawn.length) continue;
      const orderId = str(o.id);
      for (const d of drawn) {
        if (!d || !(num(d.grams) > 0)) continue;
        const row = drawRow(d, spools, {
          orderId, project: str(o.project),
          date: dayOf(o.completedAt) || dayOf(o.date), source: 'completed',
        });
        out.push(row);
        cover(orderId, row.spoolId, row.grams);
      }
    }

    for (const w of waste) {
      if (!w) continue;
      const orderId = str(w.orderId);
      const o = byId.get(orderId);
      const list = arr(w.drawn).length ? arr(w.drawn)
        : (w.spoolId && num(w.weight) > 0 ? [{ spoolId: w.spoolId, grams: w.weight }] : []);
      for (const d of list) {
        if (!d || !(num(d.grams) > 0)) continue;
        const row = drawRow(d, spools, {
          orderId, project: str((o && o.project) || ''),
          date: dayOf(w.date), source: 'failed',
        });
        out.push(row);
        if (orderId) cover(orderId, row.spoolId, row.grams);
      }
    }

    for (const s of inventory) {
      if (!s) continue;
      for (const h of arr(s.usageHistory)) {
        if (!h || h.type === 'received' || !(num(h.weightUsed) > 0) || !h.orderId) continue;
        const orderId = str(h.orderId);
        const k = orderId + '|' + str(s.id);
        const left = covered.get(k) || 0;
        // Whatever of this row the records already hold is not counted again;
        // only the rest, if any, is a draw they never saw.
        const grams = r2(num(h.weightUsed) - left);
        covered.set(k, Math.max(0, r2(left - num(h.weightUsed))));
        if (!(grams > 0)) continue;
        const o = byId.get(orderId);
        out.push(drawRow({ spoolId: s.id, grams, lot: h.lot, poId: h.poId }, spools, {
          orderId, project: str(h.project || (o && o.project) || ''),
          date: dayOf(h.date), source: 'history',
        }));
      }
    }
    return out;
  }

  /** Draws gathered into one row per job, newest first. */
  function groupByJob(draws, book) {
    const { orders } = partsOf(book);
    const byId = new Map();
    for (const o of orders) if (o && o.id != null) byId.set(str(o.id), o);
    const jobs = new Map();
    for (const d of draws) {
      const key = d.orderId || ('?' + d.spoolId + d.date);
      let j = jobs.get(key);
      if (!j) {
        const o = byId.get(d.orderId);
        j = {
          orderId: d.orderId,
          project: d.project || str(o && o.project),
          client: str(o && (o.client || o.clientName)),
          date: d.date,
          grams: 0,
          lots: [],
          spoolIds: [],
          failed: false,
          completed: false,
          inferred: false,
          draws: [],
        };
        jobs.set(key, j);
      }
      j.grams = r2(j.grams + d.grams);
      if (d.date > j.date) j.date = d.date;
      if (d.lot && !j.lots.some((l) => sameLot(l, d.lot))) j.lots.push(d.lot);
      if (d.spoolId && !j.spoolIds.includes(d.spoolId)) j.spoolIds.push(d.spoolId);
      if (d.source === 'failed') j.failed = true;
      else j.completed = true;
      if (d.inferred) j.inferred = true;
      j.draws.push(d);
    }
    return Array.from(jobs.values())
      .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));
  }

  /**
   * Every job that drew filament from `lot`, newest first.
   * `book`: `{ printLog, wasteLog, inventory }`.
   * Each row: `{ orderId, project, client, date, grams, lots, spoolIds,
   * failed, completed, inferred, draws }` — `grams` is what came from THIS lot.
   */
  function jobsForLot(book, lot) {
    if (!lotKey(lot)) return [];
    return groupByJob(allDraws(book).filter((d) => sameLot(d.lot, lot)), book);
  }

  /** Every job that drew from one spool, newest first. Same rows. */
  function jobsForSpool(book, spoolId) {
    const id = str(spoolId);
    if (!id) return [];
    return groupByJob(allDraws(book).filter((d) => d.spoolId === id), book);
  }

  /**
   * What one job drew, draw by draw, with the lot and the spool's description:
   * `[{ spoolId, grams, lot, inferred, poId, source, material, colourVariant,
   * color, spoolGone }]`.
   *
   * `materialDrawn` first. A job with none — finished before the record, or
   * never finished — falls back to the spool histories that name it.
   * `wasteLog` is optional: when handed in, failed attempts are included.
   */
  function lotsForJob(order, inventory, wasteLog) {
    if (!order || order.id == null) return [];
    const book = {
      printLog: [order],
      inventory: arr(inventory),
      wasteLog: arr(wasteLog).filter((w) => w && str(w.orderId) === str(order.id)),
    };
    const spools = spoolMap(inventory);
    return allDraws(book)
      .filter((d) => d.orderId === str(order.id))
      .map((d) => {
        const s = spools.get(d.spoolId);
        return Object.assign({}, d, {
          material: str(s && s.material),
          colourVariant: str(s && s.colourVariant),
          color: str(s && s.color),
          spoolGone: !s,
        });
      });
  }

  /** Every distinct lot the book has seen, as first written. */
  function knownLots(book) {
    const seen = new Map();
    const add = (l) => { const k = lotKey(l); if (k && !seen.has(k)) seen.set(k, str(l).trim()); };
    for (const s of partsOf(book).inventory) add(s && s.lot);
    for (const d of allDraws(book)) add(d.lot);
    return Array.from(seen.values());
  }

  /**
   * Comma-separated values for a recall list. Quotes what needs quoting, and
   * a text cell starting with = + - @ (a client name, a title, a lot) gets a
   * leading ' so Excel or Sheets opens it as text, never as a formula — the
   * same rule as csv-bundle's `neutralize`.
   */
  function csvForJobs(jobs, headers) {
    const q = (v) => {
      let s = str(v);
      if (typeof v !== 'number' && /^[=+\-@\t\r]/.test(s)) s = "'" + s;
      return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    };
    const h = Array.isArray(headers) && headers.length === 7 ? headers
      : ['Job', 'Project', 'Client', 'Date', 'Grams', 'Lots', 'Status'];
    const lines = [h.map(q).join(',')];
    for (const j of arr(jobs)) {
      const status = (j.failed && !j.completed ? 'failed' : 'completed')
        + (j.inferred ? ' (inferred)' : '');
      lines.push([j.orderId, j.project, j.client, j.date, r2(j.grams),
        arr(j.lots).join(' / '), status].map(q).join(','));
    }
    return lines.join('\n') + '\n';
  }

  const api = { lotKey, sameLot, allDraws, jobsForLot, jobsForSpool, lotsForJob, knownLots, csvForJobs };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.KhaytLotTrace = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
