'use strict';
/**
 * The LAN REST API's rules: what `/api/orders`, `/api/clients`,
 * `/api/inventory`, `/api/waste`, `/api/waiting-list`, `/api/machines` and the
 * printer webhook READ out of a book and WRITE into one.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * These lived inline in `lib/lan-server.js`, which cannot run on the Mac (it
 * wants `node:http` at module scope), so the native Mac answered every one of
 * them 404 and a script or a phone pointed at a shop running the Mac app had
 * nothing to talk to. What is a RULE moved here — the projection a GET sends,
 * the record a POST makes, what a PATCH may change and the refusals in
 * between. What is PLUMBING stayed with each server: reading the body, the
 * size cap, the PIN and API-token gate, the lockout, and the write chain. The
 * same split as `lib/carrier-webhook.js` and `lib/storefront-webhook.js`.
 *
 * ── HOW A WRITE IS SHAPED ─────────────────────────────────────────────────
 *
 * Every write is `fn(cur, input, ctx)` → `{ status, body, store?, emit? }`:
 *
 *   status, body  the HTTP answer, exactly as the Node route wrote it
 *   store         the WHOLE book to write, present only when something changed
 *   emit          `{ channel, payload }` for the desktop's renderer, which
 *                 learns of a LAN write over IPC; the Mac reloads from disk
 *
 * A server calls it TWICE: once on the book it holds, to answer a refusal
 * without a write, and again INSIDE the write on the book as it is then, so a
 * change computed from a stale copy can never put the stale copy back (see the
 * store write chain). The answer sent is the one from inside the write.
 *
 * Pure: no clock, no random, no disk. `ctx.nowMs` and `ctx.rand` (and the ids
 * built from them) are the caller's, so both servers and a test can say
 * exactly what they were.
 */
(function (global) {
  // Siblings, reached at CALL time: in the Mac's one JavaScriptCore context
  // they are globals loaded in whatever order the bundle lists them, so a
  // lookup at load time would find nothing for a module listed after this one.
  const req = (name, path) => global[name] || (typeof require === 'function' ? require(path) : null);
  const ContentLanguages = () => req('KhaytContentLanguages', './content-languages.js');
  const SpoolEdit = () => req('KhaytSpoolEdit', './spool-edit.js');
  const OrderStatus = () => req('KhaytOrderStatus', './order-status.js');
  const StoreValidate = () => req('KhaytStoreValidate', './store-validate.js');
  const QuotePage = () => req('KhaytLanQuotePage', './lan-quote-page.js');

  /** The shop's calendar day for a moment — never UTC's. */
  function localDay(ms) {
    const d = new Date(ms);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }
  const nowOf = (ctx) => (ctx && typeof ctx.nowMs === 'number' ? ctx.nowMs : Date.now());
  const isoOf = (ctx) => new Date(nowOf(ctx)).toISOString();
  const todayOf = (ctx) => (ctx && ctx.today) || localDay(nowOf(ctx));
  /** `${prefix}-${nowMs}-${hex}` — the Node server's `uniqueLanId`, with the random part handed in. */
  const lanId = (prefix, ctx) => `${prefix}-${nowOf(ctx)}-${String((ctx && ctx.rand) || '0000')}`;

  /** A JSON body, with no prototype keys in it; `null` for anything that is not an object. */
  function cleanBody(raw) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    const V = StoreValidate();
    return V && V.sanitisePlainObject ? V.sanitisePlainObject(raw) : raw;
  }
  /** An id off the wire: a non-empty string or number, as a string, capped — or null. */
  function wireId(v, max = 128) {
    if (typeof v === 'number' && Number.isFinite(v)) return String(v);
    if (typeof v !== 'string') return null;
    const s = v.trim().slice(0, max);
    return s || null;
  }
  const str = (v, max = 500) => String(v || '').trim().slice(0, max);
  const pos = (v) => Math.max(0, Number.isFinite(+v) ? +v : 0);
  const list = (store, key) => (store && Array.isArray(store[key]) ? store[key] : []);
  const err = (status, error) => ({ status, body: { error } });
  /**
   * A record about to be changed by a rule that MUTATES (`order-status.apply`
   * pushes onto `statusHistory`, `spool-edit.applyEdit` onto `priceHistory`).
   * A spread copies the top level only, so the push landed on the array the
   * caller's book still held — and a server that asks twice (once to answer,
   * once inside the write) pushed twice. Every decision here must leave the
   * book it was handed exactly as it was. JSON, because a record is JSON.
   */
  const deepCopy = (record) => JSON.parse(JSON.stringify(record));

  // ── Spools on the wire ──────────────────────────────────────────────────

  /**
   * What the write path TAKES OFF THE WIRE. Not the same list as the fields a
   * spool ends up with: `id` and `purchasedAt` are the server's to decide, not
   * the caller's — the shop's clock outranks the phone's.
   */
  const LAN_SPOOL_FIELDS = new Set([
    'material', 'brand', 'color', 'colour', 'cost', 'weight', 'weightTotal', 'weightRemaining',
    'vendor', 'notes', 'materialType', 'lot', 'filament', 'reorderPoint', 'colourVariant',
    // Off the label or the NFC tag. The companion has a camera and a tag reader
    // largely to read these three, sent them from the first version, and had them
    // dropped every time because this list never named them.
    'sku', 'printTemp', 'bedTemp',
    // The product barcode (UPC/EAN) off the box. The companion scans it and looks
    // the filament up — first on this shop's own shelf, by this field — so a
    // roll booked in without it is a roll the next identical box cannot find.
    'barcode',
  ]);

  function pickLanSpoolFields(raw) {
    const spool = {};
    for (const key of LAN_SPOOL_FIELDS) {
      const v = raw[key];
      if (v === undefined || v === null) continue;
      if (typeof v === 'string') spool[key] = v.trim().slice(0, 500);
      else if (typeof v === 'number' && Number.isFinite(v)) spool[key] = v;
    }
    // A GTIN is 8 to 14 digits and nothing else. Anything else stored here would
    // be matched against every future scan, so it is dropped rather than kept.
    if (spool.barcode !== undefined && !/^\d{8,14}$/.test(String(spool.barcode))) delete spool.barcode;
    return spool;
  }

  /**
   * What a spool looks like on the way OUT: what the API accepts, plus the few
   * extra fields the companion reads. A field the API never accepted is not
   * something a caller can be relying on having written, and "whatever happens
   * to be on the record" is the wrong default for a route behind one PIN.
   */
  const LAN_SPOOL_READ_FIELDS = new Set([
    ...LAN_SPOOL_FIELDS,
    'id', 'remaining', 'purchasedAt', 'spoolWeight', 'addedAt',
  ]);

  function pickLanSpoolRead(raw) {
    if (!raw || typeof raw !== 'object') return null;
    const out = {};
    for (const key of LAN_SPOOL_READ_FIELDS) {
      const v = raw[key];
      if (v === undefined) continue;
      out[key] = v;
    }
    return out;
  }

  // ── Reads ───────────────────────────────────────────────────────────────

  /** `GET /api/orders` — `query`: `{ limit, status }` as strings off the address. */
  function ordersList(store, query) {
    const q = query || {};
    const limit = Math.min(parseInt(q.limit || '50', 10), 200);
    let orders = list(store, 'printLog');
    if (q.status) orders = orders.filter((o) => o && o.status === q.status);
    orders = orders.slice(0, limit);
    return orders.filter((o) => o && typeof o === 'object').map((o) => ({
      id: o.id, project: o.project, client: o.client, status: o.status,
      material: o.material, price: o.price, dueDate: o.dueDate, date: o.date,
      paymentStatus: o.paymentStatus,
      quoteExpiresAt: o.quoteExpiresAt,
      quoteAcceptedAt: o.quoteAcceptedAt,
      // The reference a person reads (lib/order-new.js `jobRef`), only on jobs
      // that have one, as /api/queue sends it.
      ...(o.jobNumber ? { jobNumber: o.jobNumber } : {}),
      // The currency `price` is in, when the job names one.
      ...(o.currency ? { currency: o.currency } : {}),
    }));
  }

  /** `GET /api/machines`. */
  function machinesList(store) {
    return list(store, 'machines').filter((m) => m && typeof m === 'object').map((m) => ({
      id: m.id, name: m.name, type: m.type, status: m.status,
      hasPrinterApi: !!(m.printerApi && m.printerApi.type && m.printerApi.type !== 'none'),
    }));
  }

  /** `GET /api/inventory` — projected, not dumped (see `pickLanSpoolRead`). */
  function inventoryList(store) {
    return list(store, 'inventory').map(pickLanSpoolRead).filter(Boolean);
  }

  /** `GET /api/waiting-list` — a declined entry is history, not the list. */
  function waitingList(store) {
    return list(store, 'waitingList').filter((w) => w && w.status !== 'declined').map((w) => ({
      id: w.id,
      project: w.project,
      clientName: w.clientName,
      notes: w.notes,
      email: w.email,
      phone: w.phone,
      material: w.material,
      priority: w.priority || 'normal',
      status: w.status || 'active',
      estValue: w.estValue ?? w.estimatedValue ?? 0,
      reminderDate: w.reminderDate,
      source: w.source,
      submittedAt: w.submittedAt || w.addedAt || w.createdAt,
    }));
  }

  /**
   * `GET /api/clients`. `name` is the canonical one, resolved through the
   * shop's own content languages. nameEn/nameAr stay because the shipped
   * companion decodes those two; where the shop writes NEITHER, the resolved
   * name goes in nameEn so that build shows something.
   */
  function clientsList(store) {
    const settings = (store && store.settings) || {};
    const lang = settings.lang || 'en';
    const nameOf = (c) => ContentLanguages().read(c, 'name', lang, settings);
    return list(store, 'clients').filter((c) => c && typeof c === 'object').map((c) => {
      // Whether the shop wrote either of the two the shipped companion reads.
      const hasEnAr = Boolean(c.nameEn) || Boolean(c.nameAr);
      return {
        id: c.id,
        name: nameOf(c),
        nameEn: hasEnAr ? c.nameEn : nameOf(c),
        nameAr: c.nameAr,
        phone: c.phone,
        email: c.email,
      };
    });
  }

  /** `GET /api/orders/:id/quote-url`. `base` is `http://<the Host header>`. */
  function orderQuoteUrl(store, orderId, base, ctx) {
    const order = list(store, 'printLog').find((o) => o && o.id === orderId);
    if (!order) return err(404, 'Order not found');
    const expired = QuotePage().isQuoteExpired(order, ctx && ctx.today);
    const canApprove = order.status === 'quote' || (order.status === 'on_hold' && order.hasQuote);
    return {
      status: 200,
      body: {
        quoteUrl: `${base}/order/${encodeURIComponent(orderId)}/quote`,
        statusUrl: `${base}/order/${encodeURIComponent(orderId)}/status`,
        canApprove: canApprove && !expired,
        expired,
        quoteExpiresAt: order.quoteExpiresAt || null,
        alreadyApproved: order.status !== 'quote' && !!(order.quoteAcceptedAt || order.clientApprovedAt),
      },
    };
  }

  // ── Writes ──────────────────────────────────────────────────────────────

  /**
   * `POST /api/orders` — a job or a quote raised from outside the desk.
   *
   * Numbered with the SAME prefix the desktop uses — `invPrefix`, or
   * `quotePrefix` for a quote — never a key nothing writes. Everything the
   * record is built from is read off `cur`, the book inside the write: the
   * client's name, the machine and the queue position.
   */
  function orderCreate(cur, raw, ctx) {
    const parsed = cleanBody(raw) || {};
    const project = str(parsed.project, 200);
    if (!project) return err(400, 'project is required');
    const asQuote = parsed.status === 'quote';
    const status = asQuote ? 'quote' : 'pending';
    const nowMs = nowOf(ctx);
    const now = new Date(nowMs);
    const settings = (cur && cur.settings) || {};
    const prefix = asQuote ? (settings.quotePrefix || 'QUO') : (settings.invPrefix || 'INV');
    const id = `${prefix}-${now.getFullYear()}-${nowMs}-${String((ctx && ctx.rand) || '0000')}`;
    let clientName = str(parsed.client, 200) || null;
    const clientId = wireId(parsed.clientId);
    if (clientId) {
      const cl = list(cur, 'clients').find((c) => c && c.id === clientId);
      if (cl) clientName = ContentLanguages().read(cl, 'name', settings.lang || 'en', settings) || clientName;
    }
    const machineId = wireId(parsed.machineId);
    let machineName = null;
    if (machineId) {
      const m = list(cur, 'machines').find((x) => x && x.id === machineId);
      if (!m) return err(404, 'Machine not found');
      machineName = m.name;
    }
    const priceIn = parsed.price != null ? +parsed.price : 0;
    const price = Number.isFinite(priceIn) ? Math.max(0, priceIn) : 0;
    const dueDate = typeof parsed.dueDate === 'string' && parsed.dueDate.trim() ? parsed.dueDate.trim().slice(0, 32) : null;
    const order = {
      id,
      date: localDay(nowMs),
      timestamp: now.toISOString(),
      project,
      client: clientName,
      clientId,
      material: str(parsed.material, 120) || null,
      price: +price.toFixed(2),
      status,
      statusHistory: [{ status, at: now.toISOString() }],
      queuePos: list(cur, 'printLog').filter((o) => o && o.status === 'pending').length + 1,
      machineId,
      machine: machineName,
      notes: str(parsed.notes, 500) || '',
      dueDate,
      paymentStatus: 'unpaid',
      parts: [],
    };
    if (asQuote) {
      const validityDays = settings.quoteValidityDays || 7;
      order.quoteSentAt = order.date;
      order.quoteExpiresAt = localDay(nowMs + validityDays * 86400000);
      order.quoteVersion = 1;
    }
    return {
      status: 201,
      body: {
        ok: true,
        order: {
          id: order.id, project: order.project, client: order.client,
          status: order.status, price: order.price, material: order.material,
          dueDate: order.dueDate, quoteExpiresAt: order.quoteExpiresAt,
        },
      },
      store: { ...cur, printLog: [order, ...list(cur, 'printLog')] },
      emit: { channel: 'lan-order-created', payload: order },
    };
  }

  const ORDER_STATUSES = ['pending', 'printing', 'post', 'qc', 'completed', 'on_hold'];

  /** `PATCH /api/orders/:id` — `{ status?, machineId? }`, nothing else. */
  function orderPatch(cur, orderId, raw) {
    const parsed = cleanBody(raw) || {};
    const { status } = parsed;
    const machineIn = parsed.machineId;
    if (!status && machineIn === undefined) return err(400, 'status or machineId required');
    if (status && !ORDER_STATUSES.includes(status)) return err(400, 'Invalid status');
    const log = [...list(cur, 'printLog')];
    const idx = log.findIndex((o) => o && o.id === orderId);
    if (idx === -1) return err(404, 'Order not found');
    const updated = { ...log[idx] };
    if (status) updated.status = status;
    // null (what the phone sends) or an empty string unassigns; anything that
    // is not a string or a number is refused rather than read as "unassign".
    if (machineIn !== undefined && machineIn !== null && typeof machineIn !== 'string'
        && !(typeof machineIn === 'number' && Number.isFinite(machineIn))) {
      return err(400, 'Invalid machineId');
    }
    if (machineIn !== undefined) {
      const machineId = machineIn === null ? null : wireId(machineIn);
      if (!machineId) {
        updated.machineId = null;
        updated.machine = null;
      } else {
        const machine = list(cur, 'machines').find((m) => m && m.id === machineId);
        if (!machine) return err(404, 'Machine not found');
        updated.machineId = machineId;
        updated.machine = machine.name;
      }
    }
    log[idx] = updated;
    return {
      status: 200,
      body: { ok: true, order: { id: updated.id, status: updated.status, machineId: updated.machineId, machine: updated.machine } },
      store: { ...cur, printLog: log },
      emit: { channel: 'lan-order-updated', payload: { id: orderId, status: updated.status, machineId: updated.machineId, machine: updated.machine } },
    };
  }

  /**
   * `POST /api/orders/:id/approve` — the owner (or a token holding
   * `orders:write`) approves a quote, by the customer page's own rule.
   *
   * AN EXPIRED QUOTE IS 410. The route used to fall through for one: it
   * answered 200 `ok` with the quote unchanged, because the write refused it
   * and the answer did not look.
   */
  function orderApprove(cur, orderId, ctx) {
    const probe = { ...cur, printLog: [...list(cur, 'printLog')] };
    const result = QuotePage().applyQuoteApprovalToStore(probe, orderId, ctx && ctx.nowIso);
    if (!result) return err(404, 'Order not found');
    if (result.error === 'expired') return err(410, 'Quote has expired');
    if (result.error === 'cannot_approve') return err(409, 'Quote cannot be approved in its current state');
    const approved = result.order;
    return {
      status: 200,
      body: { ok: true, order: { id: approved.id, status: approved.status, quoteAcceptedAt: approved.quoteAcceptedAt } },
      store: probe,
      order: approved,
      emit: {
        channel: 'lan-order-updated',
        payload: {
          id: orderId, status: approved.status, clientApprovedAt: approved.clientApprovedAt,
          quoteAcceptedAt: approved.quoteAcceptedAt, quoteApproved: true,
        },
      },
    };
  }

  /**
   * `POST /api/inventory` — a roll booked in at the shelf, made by the shelf's
   * own rule (`lib/spool-edit.js`) so it is the same object as one typed at
   * the desk. `ctx`: `{ id, today, nowMs }`.
   */
  function inventoryCreate(cur, raw, ctx) {
    const rawSpool = cleanBody(raw);
    if (!rawSpool) return err(400, 'Invalid inventory payload');
    const wire = pickLanSpoolFields(rawSpool);
    const settingsNow = (cur && cur.settings) || {};
    const today = todayOf(ctx);
    // A full roll arrives with one weight sent three times; a part-used one
    // with two. `weightTotal` is what it weighed on arrival; `weightRemaining`
    // is what is left.
    const arrived = wire.weightTotal ?? wire.weight ?? wire.weightRemaining;
    const left = wire.weightRemaining ?? wire.weightTotal ?? wire.weight;
    const made = SpoolEdit().newSpool({
      material: wire.material, cost: wire.cost, weight: arrived,
      color: wire.color || wire.colour, materialType: wire.materialType, lot: wire.lot,
    }, { id: (ctx && ctx.id) || lanId('spool', ctx), today, activeLocation: settingsNow.activeLocationId });
    if (made.refused) return err(400, 'A spool needs a material');
    const spool = made.spool;
    // A scratch settings object: `applyEdit` teaches the colour library by
    // MUTATING what it is handed, and the library is merged below.
    const { colourAdded } = SpoolEdit().applyEdit(spool, {
      weight: left, printTemp: wire.printTemp, bedTemp: wire.bedTemp,
      colourVariant: wire.colourVariant, reorderPoint: wire.reorderPoint,
    }, { today, settings: {} });
    for (const key of ['brand', 'vendor', 'notes', 'filament', 'sku', 'barcode']) {
      if (wire[key] !== undefined) spool[key] = wire[key];
    }
    // `weight` is the store's word for what is left; `remaining` and
    // `weightRemaining` are the companion's. All three say the same thing.
    spool.remaining = spool.weight;
    spool.weightRemaining = spool.weight;
    spool.spoolWeight = Math.max(spool.spoolWeight, spool.weight);
    spool.weightTotal = spool.spoolWeight;
    spool.addedAt = isoOf(ctx);
    const next = { ...cur, inventory: [...list(cur, 'inventory'), spool] };
    if (colourAdded) {
      const settings = { ...settingsNow };
      const library = { ...(settings.filamentColours || {}) };
      const known = library[spool.material] || [];
      if (!known.includes(colourAdded)) {
        library[spool.material] = [...known, colourAdded];
        settings.filamentColours = library;
        next.settings = settings;
      }
    }
    return { status: 201, body: { ok: true, spool }, store: next, emit: { channel: 'lan-spool-added', payload: spool } };
  }

  /** `PATCH /api/inventory/:id` — a spool reweighed: `{ remaining }` or `{ weightRemaining }`. */
  function inventoryPatch(cur, spoolId, raw, ctx) {
    if (!spoolId || String(spoolId).includes('..')) return err(400, 'Invalid spool ID');
    const parsed = cleanBody(raw) || {};
    const remaining = parsed.remaining ?? parsed.weightRemaining;
    if (remaining === undefined || remaining === null || Number.isNaN(Number(remaining))) return err(400, 'remaining is required');
    const grams = Math.max(0, Math.min(50000, Math.round(Number(remaining))));
    const inv = [...list(cur, 'inventory')];
    const i = inv.findIndex((s) => s && s.id === spoolId);
    if (i === -1) return err(404, 'Spool not found');
    // What is LEFT, in all three of its names — `weight` is what every piece
    // of arithmetic reads, and the one this endpoint once forgot to write.
    const next = deepCopy(inv[i]);
    SpoolEdit().applyEdit(next, { weight: grams }, { today: todayOf(ctx) });
    next.remaining = next.weight;
    next.weightRemaining = next.weight;
    inv[i] = next;
    return { status: 200, body: { ok: true, spool: next }, store: { ...cur, inventory: inv }, emit: { channel: 'lan-spool-updated', payload: next } };
  }

  /** `DELETE /api/inventory/:id`. */
  function inventoryDelete(cur, spoolId) {
    if (!spoolId || String(spoolId).includes('..')) return err(400, 'Invalid spool ID');
    const inv = list(cur, 'inventory');
    const removed = inv.find((s) => s && s.id === spoolId);
    if (!removed) return err(404, 'Spool not found');
    return {
      status: 200,
      body: { ok: true, id: spoolId, spool: removed },
      store: { ...cur, inventory: inv.filter((s) => !(s && s.id === spoolId)) },
      emit: { channel: 'lan-spool-deleted', payload: { id: spoolId } },
    };
  }

  const WAITING_STATUSES = ['active', 'reminded', 'declined'];

  /** `YYYY-MM-DD`, and a day the calendar has (no 2026-02-30). */
  function isCalendarDay(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (!m) return false;
    const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
    return d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3];
  }

  /**
   * `PATCH /api/waiting-list/:id` — `{ status }`. A DECLINED entry leaves the
   * list for `waitingListHistory`, stamped `declinedAt`; every reader handles
   * both shapes (`lib/intake-view.js`). The entry leaving `waitingList` is a
   * delete as far as sync is concerned, and each app's write path tombstones
   * it, so a stale copy on another device cannot bring it back.
   */
  function waitingListPatch(cur, itemId, raw, ctx) {
    const parsed = cleanBody(raw) || {};
    const { status } = parsed;
    if (!WAITING_STATUSES.includes(status)) return err(400, 'Invalid status');
    // When to remind the customer — the field the desktop's own editor writes
    // (renderer/waiting-list.js, lib/intake-queue.js saveItem): a calendar day,
    // `YYYY-MM-DD`, or '' to clear it. Absent leaves it alone.
    const hasReminder = Object.prototype.hasOwnProperty.call(parsed, 'reminderDate');
    let reminderDate;
    if (hasReminder) {
      const r = parsed.reminderDate;
      if (r === null || r === '') reminderDate = '';
      else if (typeof r === 'string' && isCalendarDay(r.trim())) reminderDate = r.trim();
      else return err(400, 'Invalid reminderDate');
    }
    const entries = [...list(cur, 'waitingList')];
    const i = entries.findIndex((w) => w && w.id === itemId);
    if (i === -1) return err(404, 'Waiting list item not found');
    let next;
    if (status === 'declined') {
      next = {
        ...cur,
        waitingListHistory: [...list(cur, 'waitingListHistory'), { ...entries[i], status: 'declined', declinedAt: isoOf(ctx) }],
        waitingList: entries.filter((w) => !(w && w.id === itemId)),
      };
    } else {
      entries[i] = { ...entries[i], status };
      if (hasReminder) entries[i].reminderDate = reminderDate;
      next = { ...cur, waitingList: entries };
    }
    return { status: 200, body: { ok: true }, store: next, emit: { channel: 'lan-waiting-updated', payload: { id: itemId, status } } };
  }

  /**
   * `POST /api/waste` — a failed print, logged at the machine. With
   * `deduct`, the grams come off the first spool of that material, computed
   * on `cur` so a second deduction never undoes the first.
   */
  function wasteCreate(cur, raw, ctx) {
    const body = cleanBody(raw);
    if (!body) return err(400, 'Invalid waste payload');
    const material = str(body.material, 200);
    if (!material) return err(400, 'Material is required');
    const entry = {
      id: (ctx && ctx.id) || lanId('w', ctx),
      date: todayOf(ctx),
      material,
      failureType: str(body.failureType, 60) || 'other',
      weight: pos(body.weight),
      cost: pos(body.cost),
      reason: str(body.reason),
      notes: str(body.notes),
      orderId: str(body.orderId, 128) || null,
      machineId: str(body.machineId, 128) || null,
    };
    const next = { ...cur, wasteLog: [entry, ...list(cur, 'wasteLog')] };
    let deducted = null;
    if (body.deduct && entry.weight > 0) {
      const inv = [...list(cur, 'inventory')];
      const i = inv.findIndex((f) => f && f.material === material);
      if (i !== -1) {
        inv[i] = { ...inv[i], weight: Math.max(0, (+inv[i].weight || 0) - entry.weight) };
        next.inventory = inv;
        deducted = { id: inv[i].id, weight: inv[i].weight };
      }
    }
    return { status: 201, body: { ok: true, entry, deducted }, store: next, emit: { channel: 'lan-waste-logged', payload: { entry, deducted } } };
  }

  // ── The printer webhook ─────────────────────────────────────────────────

  /** What a printer (OctoPrint, Moonraker, a plugin) says happened, as one of three events. */
  function normalizePrinterEvent(body) {
    const b = body || {};
    if (typeof b.topic === 'string') {
      const t = b.topic.toLowerCase();
      if (t.includes('done') || t.includes('finished') || t.includes('complete')) return 'print_done';
      if (t.includes('started') || t.includes('start')) return 'print_started';
      if (t.includes('cancel') || t.includes('fail') || t.includes('error')) return 'print_cancelled';
    }
    if (typeof b.event === 'string') {
      const e = b.event.toLowerCase();
      if (e.includes('done') || e.includes('complete') || e.includes('finish')) return 'print_done';
      if (e.includes('start')) return 'print_started';
      if (e.includes('cancel') || e.includes('fail') || e.includes('error')) return 'print_cancelled';
      return b.event;
    }
    if (typeof b.state === 'string') {
      const s = b.state.toLowerCase();
      if (s === 'complete' || s === 'completed' || s === 'standby') return 'print_done';
      if (s === 'printing') return 'print_started';
      if (s === 'cancelled' || s === 'error') return 'print_cancelled';
    }
    return null;
  }

  /**
   * `POST /api/webhook/printer/:machineId` — moves the job on that machine
   * through the status rule, as a move on the board does (timer, history).
   * Always 200 `{ ok, event, advanced }`; `store` only when a job moved.
   */
  function printerEvent(cur, machineId, raw, ctx) {
    const parsed = cleanBody(raw) || {};
    const event = normalizePrinterEvent(parsed);
    const machine = list(cur, 'machines').find((m) => m && m.id === machineId);
    const machineName = (machine && machine.name) || machineId;
    let advanced = null;
    let store;
    if (event === 'print_done' || event === 'print_started' || event === 'print_cancelled') {
      const from = event === 'print_started' ? 'pending' : 'printing';
      const to = event === 'print_done' ? 'post' : event === 'print_started' ? 'printing' : 'on_hold';
      const log = [...list(cur, 'printLog')];
      const i = log.findIndex((o) => o && o.status === from && (o.machine === machineName || o.machineId === machineId));
      if (i !== -1) {
        const moved = deepCopy(log[i]);
        OrderStatus().apply(moved, to, { now: nowOf(ctx) });
        log[i] = moved;
        store = { ...cur, printLog: log };
        advanced = { id: moved.id, from, to, project: moved.project };
      }
    }
    const out = { status: 200, body: { ok: true, event, advanced } };
    if (store) { out.store = store; out.emit = { channel: 'lan-kanban-advanced', payload: advanced }; }
    return out;
  }

  /** Every collection a rule here reads or writes. */
  const BOOK_KEYS = ['printLog', 'waitingList', 'waitingListHistory', 'settings', 'machines',
    'clients', 'inventory', 'wasteLog'];

  const api = {
    BOOK_KEYS,
    LAN_SPOOL_FIELDS, LAN_SPOOL_READ_FIELDS, pickLanSpoolFields, pickLanSpoolRead,
    ORDER_STATUSES, WAITING_STATUSES,
    ordersList, machinesList, inventoryList, waitingList, clientsList, orderQuoteUrl,
    orderCreate, orderPatch, orderApprove,
    inventoryCreate, inventoryPatch, inventoryDelete,
    waitingListPatch, wasteCreate,
    normalizePrinterEvent, printerEvent,
    localDay,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLanRest = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
