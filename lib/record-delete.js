'use strict';

/**
 * Which jobs and customers may be DELETED, and what a delete tidies up.
 *
 * ── A JOB WITH AN INVOICE NUMBER IS NEVER DELETED ─────────────────────────
 *
 * An invoice number is a promise to the tax authority that the sequence has
 * no gaps. Deleting a job that carries one leaves a hole a ZATCA audit asks
 * about, and deleting one that took money removes the only record that the
 * money came in. So a job may be deleted only when it has neither:
 *
 *   - no invoice number (`invoiceNum` / `invoiceNumber`), no ZATCA
 *     submission, no credit note and no void — all of which say an invoice
 *     existed; and
 *   - no payment of any kind: cash recorded (`paidAmount`), a deposit taken,
 *     a gift card spent on it, a paid instalment or plan entry, a payment row.
 *
 * In practice that is a quote nobody accepted, or an old record that was
 * never numbered. `newOrder` numbers every job that is not a quote the moment
 * it is created, so a job taken as a job is CANCELLED, not deleted — the
 * status path both apps already have, which keeps its number in the sequence.
 *
 * ── A DELETE TAKES THE JOB AND NOTHING ELSE ───────────────────────────────
 *
 * Money spent and filament used are real whether or not the job survives.
 * The desktop's delete used to remove the expenses booked to the job and the
 * spool usage rows that named it — which raised the P&L's net by costs the
 * shop really paid, and erased the record of grams really drawn. Now every
 * row that pointed at the job STAYS, with `orderId` set to null: expenses,
 * spool usage rows, waste, time and loyalty entries. Their figures are
 * untouched. Payments are never touched either, because a job that has any
 * cannot be deleted. Print runs and photos are fields ON the job, so they go
 * with it.
 *
 * A spool's remaining filament is its stored `weight`, drawn down by the
 * deduction (`lib/order-deduction.js drawFrom`); the usage rows are a log of
 * those draws. Neither changes here.
 *
 * Every change is handed back (`deleted`) so a host can offer Undo through
 * `restoreOrders`, which puts the job back and relinks its rows.
 *
 * ── CUSTOMERS ─────────────────────────────────────────────────────────────
 *
 * A customer may be deleted only when nothing in the book is theirs: no job
 * in any status (linked by `clientId`, or unlinked and carrying one of their
 * names — the way both apps already attribute old jobs), and no gift card
 * issued to them. Credit notes live on jobs, so a customer with none of those
 * has none either; they are counted anyway so the refusal can say so.
 *
 * Pure, with one declared exception: `deleteOrders`, `restoreOrders`,
 * `deleteClients` and `restoreClients` change the `book` they are handed, in
 * place, and return it — the host writes the collections back in the same
 * store write. No clock, no randomness, no I/O.
 */
(function (global) {

  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  const present = (v) => v !== undefined && v !== null && String(v).trim() !== '';
  const idOf = (r) => (isObj(r) && present(r.id) ? String(r.id) : '');
  const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

  /** The collections a job's delete reads and changes. */
  const ORDER_COLLECTIONS = ['printLog', 'inventory', 'expenses', 'wasteLog', 'timeEntries', 'loyaltyLedger'];
  /** Rows that keep their figures and lose only the pointer. */
  const UNLINKED = ['expenses', 'wasteLog', 'timeEntries', 'loyaltyLedger'];

  // ── JOBS ────────────────────────────────────────────────────────────────

  /** Whether an invoice was ever issued for this job. */
  function invoiced(order) {
    if (present(order.invoiceNum) || present(order.invoiceNumber)) return true;
    if (present(order.zatcaUuid) || isObj(order.zatcaSubmission)) return true;
    if (arrayOf(order.creditNotes).length > 0) return true;
    if (present(order.voidedAt) || present(order.creditedAt)) return true;
    return false;
  }

  /** Whether any money was ever recorded against this job. */
  function paid(order) {
    if (num(order.paidAmount) > 0) return true;
    if (num(order.depositAmount) > 0) return true;
    if (num(order.giftCardDiscount) > 0) return true;
    if (arrayOf(order.payments).some((p) => isObj(p) && num(p.amount) > 0)) return true;
    if (arrayOf(order.instalments).some((i) => isObj(i) && (i.paid === true || present(i.paidAt)))) return true;
    const plan = isObj(order.paymentPlan) ? order.paymentPlan : null;
    if (plan && arrayOf(plan.schedule).some((e) => isObj(e) && present(e.paidAt))) return true;
    return false;
  }

  /**
   * May this job be deleted?
   *
   * `{ ok: true, reason: null }`, or `{ ok: false, reason }` where reason is
   * `missing` (no such job), `invoiced` (cancel it instead) or `paid` (cancel
   * it instead). Invoiced is answered first: it is the reason the shop has to
   * act on, and a paid job almost always has a number too.
   */
  function canDeleteOrder(order) {
    if (!isObj(order)) return { ok: false, reason: 'missing' };
    if (invoiced(order)) return { ok: false, reason: 'invoiced' };
    if (paid(order)) return { ok: false, reason: 'paid' };
    return { ok: true, reason: null };
  }

  /** The same row, by everything but its link — a usage row has no id. */
  const sameButLink = (a, b) => {
    const strip = (r) => { const c = Object.assign({}, r); delete c.orderId; return JSON.stringify(c); };
    return isObj(a) && isObj(b) && strip(a) === strip(b);
  };

  /**
   * Delete each job in `ids` that the rule allows, and unlink what pointed at it.
   *
   * `book`: `{ printLog, inventory, expenses, wasteLog, timeEntries,
   * loyaltyLedger }` — any may be absent. Changed in place: the jobs leave
   * `printLog`; every other row that named one stays, with `orderId: null`.
   *
   * Returns `{ book, deleted, skipped }`. `skipped` is `[{ id, reason }]`, one
   * per id the rule refused (or that was not there). `deleted` is what
   * `restoreOrders` needs to put each one back and relink its rows.
   */
  function deleteOrders(book, ids) {
    const b = isObj(book) ? book : {};
    for (const c of ORDER_COLLECTIONS) if (!Array.isArray(b[c])) b[c] = arrayOf(b[c]);
    const deleted = [];
    const skipped = [];
    const seen = new Set();
    for (const raw of arrayOf(ids)) {
      const id = present(raw) ? String(raw) : '';
      if (!id || seen.has(id)) continue;
      seen.add(id);
      const index = b.printLog.findIndex((o) => idOf(o) === id);
      const order = index >= 0 ? b.printLog[index] : null;
      const verdict = canDeleteOrder(order);
      if (!verdict.ok) { skipped.push({ id, reason: verdict.reason }); continue; }

      b.printLog.splice(index, 1);

      // Filament the spools gave it: the grams were used, and the row is the
      // record of it. Only the link goes. (A spool's remaining is its stored
      // `weight`, drawn down at deduction; the rows are its history.)
      const usage = [];
      for (const spool of b.inventory) {
        if (!isObj(spool) || !Array.isArray(spool.usageHistory)) continue;
        for (const h of spool.usageHistory) {
          if (isObj(h) && present(h.orderId) && String(h.orderId) === id) {
            h.orderId = null;
            usage.push({ spoolId: idOf(spool), entry: clone(h) });
          }
        }
      }

      // Money spent and real events: they stay in the books, unlinked.
      const unlinked = {};
      for (const c of UNLINKED) {
        const touched = [];
        b[c].forEach((r, at) => {
          if (isObj(r) && present(r.orderId) && String(r.orderId) === id) {
            r.orderId = null;
            touched.push(idOf(r) || at);
          }
        });
        if (touched.length) unlinked[c] = touched;
      }

      deleted.push({ id, index, order, usage, unlinked });
    }
    return { book: b, deleted, skipped };
  }

  /**
   * Put back what `deleteOrders` took, newest first: each job at the place it
   * left, and its rows linked to it again. A row pointed at another job since
   * is left where it is.
   */
  function restoreOrders(book, deleted) {
    const b = isObj(book) ? book : {};
    for (const c of ORDER_COLLECTIONS) if (!Array.isArray(b[c])) b[c] = arrayOf(b[c]);
    const items = arrayOf(deleted).slice().reverse();
    for (const d of items) {
      if (!isObj(d) || !isObj(d.order)) continue;
      const id = String(d.id || idOf(d.order));
      if (!b.printLog.some((o) => idOf(o) === id)) {
        const at = Math.max(0, Math.min(num(d.index), b.printLog.length));
        b.printLog.splice(at, 0, clone(d.order));
      }
      for (const u of arrayOf(d.usage)) {
        const spool = b.inventory.find((s) => idOf(s) === String(u.spoolId));
        if (!spool || !Array.isArray(spool.usageHistory)) continue;
        const row = spool.usageHistory.find((h) => isObj(h) && !present(h.orderId) && sameButLink(h, u.entry));
        if (row) row.orderId = id;
      }
      const unlinked = isObj(d.unlinked) ? d.unlinked : {};
      for (const c of UNLINKED) {
        for (const key of arrayOf(unlinked[c])) {
          const row = typeof key === 'number' ? b[c][key] : b[c].find((r) => idOf(r) === String(key));
          if (isObj(row) && !present(row.orderId)) row.orderId = id;
        }
      }
    }
    return b;
  }

  // ── CUSTOMERS ───────────────────────────────────────────────────────────

  const fold = (s) => String(s == null ? '' : s).trim().replace(/\s+/g, ' ').toLowerCase();

  /** Every name the shop has written this customer down under. */
  function namesOf(client) {
    return ['name', 'nameEn', 'nameAr'].map((k) => fold(client[k])).filter((n) => n !== '');
  }

  /** The jobs that are this customer's — by link, or by name on an unlinked job. */
  function jobsOf(client, orders) {
    const id = idOf(client);
    const names = namesOf(client);
    return arrayOf(orders).filter((o) => {
      if (!isObj(o)) return false;
      if (present(o.clientId)) return String(o.clientId) === id;
      return names.length > 0 && names.includes(fold(o.client));
    });
  }

  /**
   * May this customer be deleted?
   *
   * `ctx`: `{ orders, giftCards }`. Returns `{ ok, reason, jobs, giftCards,
   * creditNotes }`; reason is `missing`, `has_jobs`, `has_gift_cards` or null.
   * The counts are always filled in, so a refusal can say how many.
   */
  function canDeleteClient(client, ctx) {
    const c = isObj(ctx) ? ctx : {};
    if (!isObj(client) || !idOf(client)) {
      return { ok: false, reason: 'missing', jobs: 0, giftCards: 0, creditNotes: 0 };
    }
    const jobs = jobsOf(client, c.orders);
    const creditNotes = jobs.reduce((s, o) => s + arrayOf(o.creditNotes).length, 0);
    const cards = arrayOf(c.giftCards).filter((g) => isObj(g) && present(g.issuedTo)
      && String(g.issuedTo) === idOf(client)).length;
    const counts = { jobs: jobs.length, giftCards: cards, creditNotes };
    if (jobs.length > 0) return Object.assign({ ok: false, reason: 'has_jobs' }, counts);
    if (cards > 0) return Object.assign({ ok: false, reason: 'has_gift_cards' }, counts);
    return Object.assign({ ok: true, reason: null }, counts);
  }

  /**
   * Delete each customer in `ids` the rule allows. `book`: `{ clients,
   * printLog, giftCards }`, changed in place. Returns `{ book, deleted,
   * skipped }`; `skipped` carries the counts the refusal names.
   */
  function deleteClients(book, ids) {
    const b = isObj(book) ? book : {};
    for (const c of ['clients', 'printLog', 'giftCards']) if (!Array.isArray(b[c])) b[c] = arrayOf(b[c]);
    const deleted = [];
    const skipped = [];
    const seen = new Set();
    for (const raw of arrayOf(ids)) {
      const id = present(raw) ? String(raw) : '';
      if (!id || seen.has(id)) continue;
      seen.add(id);
      const index = b.clients.findIndex((x) => idOf(x) === id);
      const client = index >= 0 ? b.clients[index] : null;
      const verdict = canDeleteClient(client, { orders: b.printLog, giftCards: b.giftCards });
      if (!verdict.ok) {
        skipped.push({ id, reason: verdict.reason, jobs: verdict.jobs, giftCards: verdict.giftCards });
        continue;
      }
      b.clients.splice(index, 1);
      deleted.push({ id, index, client });
    }
    return { book: b, deleted, skipped };
  }

  /** Put back what `deleteClients` took, each at the place it left. */
  function restoreClients(book, deleted) {
    const b = isObj(book) ? book : {};
    if (!Array.isArray(b.clients)) b.clients = arrayOf(b.clients);
    for (const d of arrayOf(deleted).slice().reverse()) {
      if (!isObj(d) || !isObj(d.client)) continue;
      const id = String(d.id || idOf(d.client));
      if (b.clients.some((x) => idOf(x) === id)) continue;
      const at = Math.max(0, Math.min(num(d.index), b.clients.length));
      b.clients.splice(at, 0, clone(d.client));
    }
    return b;
  }

  /**
   * Every refusal in a book at once, for a host that greys its menus before
   * anybody asks: `{ orders: { id: reason }, clients: { id: { reason, jobs,
   * giftCards, creditNotes } } }`. Only the refused are listed.
   */
  function verdicts(book) {
    const b = isObj(book) ? book : {};
    const orders = {};
    for (const o of arrayOf(b.printLog)) {
      const id = idOf(o);
      if (!id) continue;
      const v = canDeleteOrder(o);
      if (!v.ok) orders[id] = v.reason;
    }
    const clients = {};
    for (const cl of arrayOf(b.clients)) {
      const id = idOf(cl);
      if (!id) continue;
      const v = canDeleteClient(cl, { orders: b.printLog, giftCards: b.giftCards });
      if (!v.ok) clients[id] = { reason: v.reason, jobs: v.jobs, giftCards: v.giftCards, creditNotes: v.creditNotes };
    }
    return { orders, clients };
  }

  const api = {
    ORDER_COLLECTIONS,
    canDeleteOrder, deleteOrders, restoreOrders,
    canDeleteClient, deleteClients, restoreClients,
    verdicts,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytRecordDelete = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
