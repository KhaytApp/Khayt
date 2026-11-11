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
  /** order-new reads its pricing siblings as globals: under Node, load them first. */
  const OrderNew = () => {
    if (!global.KhaytOrderNew && typeof require === 'function') {
      for (const f of ['./pricing.js', './calculator-cost.js', './working-week.js']) { try { require(f); } catch (_) { /* absent: order-new says so */ } }
    }
    return req('KhaytOrderNew', './order-new.js');
  };
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
  /** The top-level fields of `after` that differ from `before`. */
  const changedKeys = (before, after) => {
    const out = {};
    for (const k of Object.keys(after || {})) if (JSON.stringify(after[k]) !== JSON.stringify((before || {})[k])) out[k] = after[k];
    return out;
  };

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
   * The record is `lib/order-new.js newOrder`'s — the one the desk's
   * calculator, a reprint and the Mac's own new-job sheet all make — so a job
   * taken over the LAN is numbered from the shop's counter (`invPrefix-YYYY-
   * NNNN`, and its invoice number with it), gets a due date estimated from the
   * queue, a quote its validity, and every field a job has. The counters it
   * advances are in `settings`, written back in the same write. What the LAN
   * sends that the calculator does not (a typed customer name with no record,
   * the material, a due date it already knows) is laid over the record.
   *
   * Everything is read off `cur`, the book inside the write. `ctx.tokens`
   * (`{ tracking, quoteApproval, id }`, random bytes) is the host's to give;
   * without it the job has no tracking token and its id tag is Math.random's.
   */
  function orderCreate(cur, raw, ctx) {
    const parsed = cleanBody(raw) || {};
    const project = str(parsed.project, 200);
    if (!project) return err(400, 'project is required');
    const asQuote = parsed.status === 'quote';
    const nowMs = nowOf(ctx);
    const settings = deepCopy((cur && cur.settings) || {});
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
    const priceIn = parsed.price != null ? +parsed.price : null;
    const price = priceIn != null && Number.isFinite(priceIn) ? Math.max(0, priceIn) : null;
    const dueDate = typeof parsed.dueDate === 'string' && parsed.dueDate.trim() ? parsed.dueDate.trim().slice(0, 32) : null;
    const N = OrderNew();
    if (!N || typeof N.newOrder !== 'function') return err(500, 'The order rules could not be loaded');
    const order = N.newOrder({
      parts: [],
      project,
      clientId,
      machineId,
      notes: str(parsed.notes, 500) || '',
      priceOverride: price,
      asQuote,
    }, {
      settings,
      orders: list(cur, 'printLog'),
      clients: list(cur, 'clients'),
      now: nowMs,
      tokens: (ctx && ctx.tokens) || {},
    });
    // A host that hands in `rand` and no id bytes (the Mac's LAN server) gets
    // the tag it gave, as before — `jobNumber-rand`, still unique per job.
    const tok = (ctx && ctx.tokens) || {};
    if (!tok.id && ctx && typeof ctx.rand === 'string' && /^[0-9a-z]{4}$/.test(ctx.rand)) order.id = `${order.jobNumber}-${ctx.rand}`;
    order.client = clientName;
    order.machine = machineName;
    const material = str(parsed.material, 120);
    if (material) order.material = material;
    if (dueDate && !asQuote) order.dueDate = dueDate;
    return {
      status: 201,
      body: {
        ok: true,
        order: {
          id: order.id, project: order.project, client: order.client,
          status: order.status, price: order.price, material: order.material || null,
          dueDate: order.dueDate, quoteExpiresAt: order.quoteExpiresAt,
        },
      },
      store: { ...cur, settings, printLog: [order, ...list(cur, 'printLog')] },
      // The counters it advanced travel with the job: a window holding its own
      // copy of settings would otherwise save the old ones back.
      emit: { channel: 'lan-order-created', payload: { order, settingsChanged: changedKeys((cur && cur.settings) || {}, settings) } },
    };
  }

  const ORDER_STATUSES = ['pending', 'printing', 'post', 'qc', 'completed', 'on_hold'];

  /**
   * What a status move over the LAN hands its host to perform. The rule's
   * money and messaging effects, without the ones that only make sense to a
   * person at the desk (the toasts, the Undo — the caller is not looking at a
   * board) or that the write itself already is (save).
   */
  const LAN_SKIPPED_EFFECTS = new Set(['toast_updated', 'toast_updated_undoable', 'toast_delivered', 'toast_shipped', 'save']);

  /**
   * `PATCH /api/orders/:id` — `{ status?, machineId? }`, nothing else.
   *
   * A status change goes through `lib/order-status.js`, exactly as a move on
   * the board does: `gate()` first (a paused shop, a hard WIP limit, an
   * unfinished assembly are each a 409 with the rule's code), then `apply()`
   * on a COPY — statusHistory, completedAt, the timer, quoteAcceptedAt. The
   * effects it asks for (deduct the filament, the webhooks, the customer's
   * message) are returned in `emit.payload.effects` for the host to run; the
   * rule cannot run them, and neither can this file. A move to the status the
   * job already has changes nothing and asks for nothing.
   */
  function orderPatch(cur, orderId, raw, ctx) {
    const parsed = cleanBody(raw) || {};
    const { status } = parsed;
    const machineIn = parsed.machineId;
    if (!status && machineIn === undefined) return err(400, 'status or machineId required');
    if (status && !ORDER_STATUSES.includes(status)) return err(400, 'Invalid status');
    const log = [...list(cur, 'printLog')];
    const idx = log.findIndex((o) => o && o.id === orderId);
    if (idx === -1) return err(404, 'Order not found');
    const updated = deepCopy(log[idx]);
    let effects = [];
    let settingsOut = null;
    if (status && status !== updated.status) {
      const S = OrderStatus();
      const ruleCtx = { now: nowOf(ctx), settings: (cur && cur.settings) || {}, orders: log, inventory: list(cur, 'inventory') };
      const g = S.gate(updated, status, ruleCtx);
      if (!g.ok) return { status: 409, body: { error: 'Move refused', code: g.block && g.block.code, params: (g.block && g.block.params) || {} } };
      // A QUOTE THAT LEAVES THE QUOTE COLUMN IS AN ORDER, and an order's
      // invoice carries a number — given here, inside the write and on the
      // newest book, as the board gives it (renderer/invoicing.js
      // ensureOrderInvoiceNumber). Not for a cancelled quote, and never a
      // second number for a job that has one (either spelling).
      if (updated.status === 'quote' && status !== 'cancelled' && !(updated.invoiceNum || updated.invoiceNumber)) {
        const N = OrderNew();
        if (N && typeof N.allocateInvoiceNumber === 'function') {
          settingsOut = deepCopy((cur && cur.settings) || {});
          const n = N.allocateInvoiceNumber(settingsOut, new Date(nowOf(ctx)).getFullYear(), log);
          updated.invoiceNum = n;
          updated.invoiceNumber = n;
        }
      } else if (updated.status === 'quote' && (updated.invoiceNum || updated.invoiceNumber)) {
        const had = updated.invoiceNum || updated.invoiceNumber;
        updated.invoiceNum = had;
        updated.invoiceNumber = had;
      }
      const r = S.apply(updated, status, ruleCtx) || {};
      effects = (r.effects || []).filter((e) => e && !LAN_SKIPPED_EFFECTS.has(e.type));
    }
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
    // What the move changed, field by field, so a host holding its own copy
    // of the job (the desktop window) takes those and nothing else — an edit
    // it has not saved yet is not put back by the disk's older copy.
    const before = log[idx];
    const changed = {};
    for (const k of Object.keys(updated)) if (JSON.stringify(updated[k]) !== JSON.stringify(before[k])) changed[k] = updated[k];
    const removed = Object.keys(before).filter((k) => !(k in updated));
    log[idx] = updated;
    return {
      status: 200,
      body: { ok: true, order: { id: updated.id, status: updated.status, machineId: updated.machineId, machine: updated.machine } },
      store: settingsOut ? { ...cur, settings: settingsOut, printLog: log } : { ...cur, printLog: log },
      // `changed`, `removed` and `effects` are additions: a host reading only the first
      // four fields sees what it always saw.
      emit: { channel: 'lan-order-updated', payload: { id: orderId, status: updated.status, machineId: updated.machineId, machine: updated.machine, changed, removed, effects, settingsChanged: settingsOut ? changedKeys((cur && cur.settings) || {}, settingsOut) : {} } },
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
    // `entry` (as it now stands) and `declined` let a host holding its own
    // copy of the list take the change rather than save over it.
    const entry = status === 'declined'
      ? next.waitingListHistory[next.waitingListHistory.length - 1]
      : next.waitingList[i];
    return { status: 200, body: { ok: true }, store: next, emit: { channel: 'lan-waiting-updated', payload: { id: itemId, status, entry, declined: status === 'declined' } } };
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

  /**
   * `POST /api/quote` — cost one part from the phone, with the shop's own
   * maths (`calculator-cost.js`, `pricing.js`) against the live book, so the
   * phone can never quote a different number from the computer it is paired
   * to. Cost, the price tier that applies, and cost → price by the same
   * function the calculator screen calls. Reads only.
   *
   * The desktop's server has carried this inline since the phone could ask;
   * the Mac did not serve it at all, so the phone's "ask the Mac" calculator
   * always failed there (the Nov 10 2026 review). This is that route's rule,
   * for both to call.
   *
   * `ctx.overheadPerHour` is the shop's fixed costs per print hour when the
   * caller has already worked it out; otherwise `public-quote.js` resolves it
   * from the book for `ctx.today`.
   */
  function quotePart(store, raw, ctx) {
    const part = cleanBody(raw);
    if (!part) return err(400, 'Invalid part payload');
    const Cost = req('KhaytCalculatorCost', './calculator-cost.js');
    const Pricing = req('KhaytPricing', './pricing.js');
    if (!Cost || !Pricing) return err(500, 'Could not cost this part');
    try {
      const book = store || {};
      const c = ctx || {};
      const settings = book.settings || {};
      const costCtx = { inventory: book.inventory || [], settings };
      const qty = Math.max(1, Math.min(100000, +part.qty || 1));
      const unitCost = Cost.computePartBaseCost(Object.assign({}, part, { qty }), costCtx);
      const breakdown = Cost.computePartBreakdown(Object.assign({}, part, { qty }), costCtx);
      const tier = Pricing.activePriceTier(part.priceTiers, qty);
      let overheadPerHour = 0;
      if (!tier) {
        if (Number.isFinite(+c.overheadPerHour) && c.overheadPerHour != null) overheadPerHour = Math.max(0, +c.overheadPerHour);
        else {
          const PQ = req('KhaytPublicQuote', './public-quote.js');
          if (PQ && PQ.overheadPerHourFor) overheadPerHour = PQ.overheadPerHourFor(book, c.today || localDay());
        }
      }
      const price = Pricing.quoteTotal({
        baseCost: unitCost * qty,
        qty,
        margin: part.margin,
        overheadPerHour,
        printHours: tier ? 0 : Math.max(0, +part.printTime || 0) * qty,
        priceTier: tier,
        discountPct: part.discountPct,
        rushEnabled: !!part.rush,
        rushPct: settings.rushFeePct == null ? 25 : settings.rushFeePct,
        shippingCost: part.shippingCost,
        extraLines: part.extraLines,
      });
      const round = (n) => Math.round((Number.isFinite(n) ? n : 0) * 10000) / 10000;
      return { status: 200, body: {
        ok: true,
        qty,
        unitCost: round(unitCost),
        totalCost: round(unitCost * qty),
        breakdown: {
          material: round(breakdown.material), machine: round(breakdown.machine),
          labor: round(breakdown.labor), buffer: round(breakdown.buffer),
        },
        priceTier: tier ? { minQty: +tier.minQty, pricePerUnit: +tier.pricePerUnit } : null,
        price: {
          beforeDiscount: round(price.priceBeforeDiscount), discount: round(price.discountAmount),
          subtotal: round(price.subtotal), rushFee: round(price.rushFee), shipping: round(price.shipping),
          extras: round(price.extras), overhead: round(price.overhead), total: round(price.total),
        },
        currency: settings.currency || null,
      } };
    } catch (_) {
      return err(400, 'Could not cost this part');
    }
  }

  /** Every collection a rule here reads or writes. */
  const BOOK_KEYS = ['printLog', 'waitingList', 'waitingListHistory', 'settings', 'machines',
    'clients', 'inventory', 'wasteLog'];

  const api = {
    BOOK_KEYS,
    LAN_SPOOL_FIELDS, LAN_SPOOL_READ_FIELDS, pickLanSpoolFields, pickLanSpoolRead,
    ORDER_STATUSES, WAITING_STATUSES,
    ordersList, machinesList, inventoryList, waitingList, clientsList, orderQuoteUrl, quotePart,
    orderCreate, orderPatch, orderApprove,
    inventoryCreate, inventoryPatch, inventoryDelete,
    waitingListPatch, wasteCreate,
    normalizePrinterEvent, printerEvent,
    localDay,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLanRest = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
