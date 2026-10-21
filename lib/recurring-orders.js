'use strict';

/**
 * A customer's standing order, and the job it produces when the day comes.
 *
 * A shop that prints the same thing for the same customer every month keeps a
 * schedule on the customer — an interval, the next date, a pause, an end date,
 * how many days early to start — and expects a job to appear in the queue on
 * time without anyone remembering. This is the rule that decides WHICH
 * schedules are due and WHAT the job they produce looks like: a copy of a
 * template order (the one the shop chose, else the last completed job for that
 * customer), with everything that belonged to the previous run reset — payment,
 * photos, actuals, quote dates — and the cycle it stands for written on it so
 * the same cycle can never be created twice.
 *
 * ── WHY IT IS HERE ────────────────────────────────────────────────────────
 *
 * It was written twice in `renderer/clients.js`: `checkRecurringOrders`, which
 * fired on the due day itself, and `patchRecurringOrdersWithLeadDays`, which
 * fired up to `leadDays` early — and both ran at every boot and every six
 * hours, each guarding against the other. They did not produce the same job.
 * The due-day copy had NO due date, was always `pending`, and ignored the
 * template the shop had chosen; the early copy carried the cycle date as its
 * due date, honoured `cloneStatus` and `templateOrderId`, and started with an
 * empty comments list. So the job a customer got depended on whether the app
 * happened to be opened the day before or the day of. That is the divergence
 * this lift found, and the test that proves it is in
 * `test/recurring-orders.test.js`. THE RICHER SHAPE IS THE RULE NOW, on both
 * days: a standing order is a job with a due date, always.
 *
 * And the native Mac app had no rule at all, so a schedule set on the Windows
 * PC produced nothing on a Mac. Both apps run this now.
 *
 * ── THE SHAPE ─────────────────────────────────────────────────────────────
 *
 * PURE, with the same two exceptions `lib/order-new.js` makes and for the same
 * reasons: `ctx.settings` is mutated to allocate each invoice number (an
 * allocation nobody writes down is a number handed out twice), and
 * `clients` and `orders` are mutated IN PLACE — the schedule advances on the
 * client record the caller handed in, and the new job is put at the front of
 * the caller's own `orders`, because in the Electron window `printLog` is the
 * very array every open screen holds. The caller saves all three together.
 *
 * `run()` returns what it did — the orders it created — so a host can say so.
 * Message CODES are the host's to turn into a sentence in its own language.
 */
(function (global) {

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});
  const arrayOf = (v) => (Array.isArray(v) ? v : []);

  /** The day-count fallback the renderer used when the calendar rule was absent. */
  const INTERVAL_DAYS = { weekly: 7, biweekly: 14, monthly: 30, quarterly: 91 };
  /** What `KhaytSubscriptions.nextRunDate` accepts. Anything else falls back. */
  const CALENDAR_INTERVALS = ['daily', 'weekly', 'biweekly', 'monthly', 'quarterly', 'yearly'];

  const subscriptions = () => (typeof globalThis !== 'undefined' ? globalThis.KhaytSubscriptions : undefined);
  const orderNew = () => (typeof globalThis !== 'undefined' ? globalThis.KhaytOrderNew : undefined);
  const recordDuplicate = () => (typeof globalThis !== 'undefined' && globalThis.KhaytRecordDuplicate)
    || (typeof require === 'function' ? (() => { try { return require('./record-duplicate.js'); } catch (_) { return null; } })() : null);

  /** `YYYY-MM-DD` in the shop's own timezone — a due date is a local day. */
  function localDateStr(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  /**
   * The date one cycle after `nextDue`.
   *
   * Calendar-safe through `KhaytSubscriptions` (the 31st of January advances
   * to the 28th of February, not the 3rd of March); a schedule with an
   * interval that rule does not know, or a date it cannot read, advances by a
   * fixed number of days rather than throwing — a schedule that throws is a
   * schedule that never advances and creates the same job at every boot.
   */
  function advance(nextDue, interval) {
    const S = subscriptions();
    if (S && CALENDAR_INTERVALS.includes(interval)) {
      try { return S.nextRunDate(nextDue, interval); } catch (e) { /* fall through */ }
    }
    const next = new Date(nextDue + 'T00:00:00');
    next.setDate(next.getDate() + (INTERVAL_DAYS[interval] || 30));
    return localDateStr(next);
  }

  /** The day a schedule fires: `leadDays` before the cycle date. */
  function triggerDay(rec) {
    const lead = Math.max(0, Math.floor(+rec.leadDays || 0));
    if (!lead) return rec.nextDue;
    const d = new Date(rec.nextDue + 'T00:00:00');
    d.setDate(d.getDate() - lead);
    return localDateStr(d);
  }

  /**
   * The order a schedule stands in for.
   *
   * The one the shop pointed at, else the most recent completed job for this
   * customer — `orders` are newest first, so the first match is the latest.
   * A customer with a schedule and no finished job yet has nothing to copy,
   * and gets nothing rather than a blank.
   */
  function templateFor(client, rec, orders) {
    if (rec.templateOrderId) {
      const chosen = orders.find(o => o && o.id === rec.templateOrderId);
      if (chosen) return chosen;
    }
    return orders.find(o => o && o.clientId === client.id && o.status === 'completed') || null;
  }

  /**
   * What each schedule wants done today. READ-ONLY: nothing is advanced or
   * created here, so a host can ask what would happen before it happens.
   *
   * Effects, in the order they should be performed:
   *   `{ kind: 'stop',   client }`                       — past its end date
   *   `{ kind: 'create', client, template, cycle }`      — a job is due
   *
   * A schedule whose cycle already has a job — any status, because a cycle
   * cancelled by hand is still that cycle — asks for nothing. That is the
   * whole guard against duplicates, and it is why the cycle is written on
   * the job.
   */
  function due(clients, orders, ctx) {
    const c = ctxOf(ctx);
    const now = c.now instanceof Date ? c.now : new Date(typeof c.now === 'number' ? c.now : Date.now());
    const today = c.today || localDateStr(now);
    const list = arrayOf(orders);
    const effects = [];
    for (const client of arrayOf(clients)) {
      const rec = client && client.recurring;
      if (!rec || !rec.enabled || rec.paused || !rec.nextDue) continue;
      if (rec.endDate && rec.nextDue > rec.endDate) { effects.push({ kind: 'stop', client }); continue; }
      if (triggerDay(rec) > today) continue;
      if (list.some(o => o && o.clientId === client.id && o.recurringCycle === rec.nextDue)) continue;
      const template = templateFor(client, rec, list);
      if (!template) continue;
      effects.push({ kind: 'create', client, template, cycle: rec.nextDue });
    }
    return { effects };
  }

  /**
   * What a repeat order carries over from the job it copies: the standing
   * order itself — what is made, for whom, on which machine, at what price
   * and how that price was reached. NOTHING ELSE.
   *
   * An ALLOWLIST, not a list of fields to reset. The copy used to be the
   * whole template with ~20 fields reset, so everything added to a job since
   * rode along: the last run's credit note and gift-card discount (the new
   * job owed less and the credit counted twice), its instalments, its survey
   * token (the old rating landed on the new job), its tracking and shipping
   * (it read Shipped), its web-store order id (two jobs fought over one
   * order's status). A field a later feature adds to a job is now left
   * behind until someone decides a repeat order should have it.
   */
  const CARRIED = [
    'project', 'client', 'clientId', 'productId', 'currency', 'machineId',
    'material', 'colors', 'colours', 'printTime', 'printTimeMins', 'printFileId',
    'price', 'priceBeforeDiscount', 'discountPct', 'agreedAmount', 'computedPrice',
    'priceSource', 'priceRound', 'priceOverride', 'costBasis', 'shippingCost',
    'extraLines', 'components', 'assemblyQty', 'componentsCost', 'overheadCost',
    'rushFee', 'rushFeeAmount', 'fromStock', 'internalNotes', 'invoiceNotes', 'tags',
    // Not business revenue, the customer's own reference, and the site that
    // makes it (stock is drawn and P&L counted per location): all standing.
    'nonBusiness', 'clientRef', 'locationId',
  ];

  /** `srv`-style hex from the bytes the caller supplies, as `lib/order-new.js` writes it. */
  function hex(bytes) {
    return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  }

  /** A copy deep enough that the new job shares no array or object with the old one. */
  const copy = (v) => (v && typeof v === 'object' ? JSON.parse(JSON.stringify(v)) : v);

  /**
   * A part as the new run starts it: the last run's history taken off —
   * `PART_RUN_KEYS` in `lib/record-duplicate.js`, the list a ⌘D copy uses, so
   * the two can never disagree about what a part's history is — and its own
   * id from the host (`ctx.uid`), because two jobs must not share a part id.
   * Without `uid` the part has no id, as a part typed in fresh may not.
   */
  function freshPart(p, runKeys, uid) {
    const out = {};
    for (const k of Object.keys(p || {})) if (!runKeys.includes(k)) out[k] = copy(p[k]);
    if (typeof uid === 'function') out.id = uid('PRT');
    return out;
  }

  /**
   * The job a cycle produces: the standing order (`CARRIED`) from the
   * template, and the rest as a new job starts — unpaid, unshipped, unrated,
   * its parts not yet printed (`freshPart`; `ctx.uid(prefix)` mints their ids).
   *
   * `ctx.tokens.tracking` (random bytes, as `lib/order-new.js` takes them)
   * mints the job its OWN tracking token; without it the job has none and the
   * host's `ensureTrackingToken` makes one when it is first needed. Never the
   * template's: a shared token opens the old job's page.
   * `ctx.settings` IS MUTATED to take the invoice number.
   */
  function clone(template, ctx) {
    const c = ctxOf(ctx);
    const settings = c.settings || {};
    const now = c.now instanceof Date ? c.now : new Date(typeof c.now === 'number' ? c.now : Date.now());
    const rec = ctxOf(c.recurring);
    const cycle = c.cycle || rec.nextDue || null;
    const tokens = ctxOf(c.tokens);
    const N = orderNew();
    if (!N) throw new Error('KhaytRecurringOrders needs KhaytOrderNew');
    const D = recordDuplicate();
    if (!D || !Array.isArray(D.PART_RUN_KEYS)) throw new Error('KhaytRecurringOrders needs KhaytRecordDuplicate');
    const year = now.getFullYear();
    const invoiceNum = N.allocateInvoiceNumber(settings, year);
    const seq = String(settings.invNumNext - 1).padStart(4, '0');
    const job = {};
    // Only keys the template HAS: a key present and undefined is a different
    // record shape from one without it.
    for (const k of CARRIED) if (Object.prototype.hasOwnProperty.call(template, k)) job[k] = copy(template[k]);
    return Object.assign(job, {
      parts: Array.isArray(template.parts) ? template.parts.map(p => freshPart(p, D.PART_RUN_KEYS, c.uid)) : [],
      id: `${settings.invPrefix || 'INV'}-${year}-${seq}`,
      invoiceNum,
      invoiceNumber: invoiceNum,
      date: localDateStr(now),
      timestamp: now.toISOString(),
      status: rec.cloneStatus || 'pending',
      paymentStatus: 'unpaid',
      paidAmount: 0,
      paymentMethod: null,
      paidAt: null,
      printPhotos: [],
      notes: '',
      dueDate: cycle,
      priority: false,
      materialDeducted: false,
      actualPrintTime: null,
      actualWeight: null,
      quoteSentAt: null,
      quoteExpiresAt: null,
      quoteAcceptedAt: null,
      deliveredAt: null,
      attachedFiles: [],
      comments: [],
      recurringCycle: cycle,
    }, tokens.tracking ? { trackingToken: hex(tokens.tracking) } : {});
  }

  /**
   * Do today's work: create every job that is due and move each schedule on
   * one cycle. One job per schedule per run — a shop that was closed for three
   * months gets one catch-up job now and the next at the next run, which is
   * what it always got, rather than three at once.
   *
   * Mutates `clients[i].recurring`, `orders` (new jobs go to the front) and
   * `ctx.settings`. `ctx.tokens`, when given, is a list of `{ tracking }`
   * random bytes, one taken per job made, and `ctx.uid(prefix)` mints part
   * ids (see `clone`). Returns
   * `{ created, notices }`.
   */
  function run(clients, orders, ctx) {
    const c = ctxOf(ctx);
    const settings = c.settings || {};
    const now = c.now instanceof Date ? c.now : new Date(typeof c.now === 'number' ? c.now : Date.now());
    const list = arrayOf(orders);
    const tokens = arrayOf(c.tokens).slice();
    const created = [];
    for (const effect of due(clients, list, { now, today: c.today }).effects) {
      const rec = effect.client.recurring;
      if (effect.kind === 'stop') { rec.enabled = false; continue; }
      const order = clone(effect.template, { settings, now, recurring: rec, cycle: effect.cycle, tokens: tokens.shift(), uid: c.uid });
      list.unshift(order);
      created.push(order);
      rec.nextDue = advance(rec.nextDue, rec.interval);
      if (rec.endDate && rec.nextDue > rec.endDate) rec.enabled = false;
    }
    return { created, notices: created.length ? [{ code: 'rec.created', n: created.length }] : [] };
  }

  const api = { INTERVAL_DAYS, advance, triggerDay, templateFor, due, clone, run };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytRecurringOrders = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
