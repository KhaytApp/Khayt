'use strict';
(function (global) {
/**
 * The shop's staff: who did the work, how long it took them, and what it
 * earned (KhaytOperators).
 *
 * `store.operators = [{ id: 'OP-…', name, role, roleKey, hourlyRate, active,
 * pinHash? }]`, `order.operatorId`, and `store.timeEntries = [{ id: 'TE-…',
 * orderId, operatorId, operatorName, hours, hourlyRate, cost, date, notes,
 * createdAt }]` — `cost` is `hours × hourlyRate` frozen when the time was
 * logged, so a raise does not reprice last year's work.
 *
 * Three things live here, each used by both apps:
 *
 * ── performance(): THE PER-OPERATOR TABLE ────────────────────────────────
 *
 * It lived inline in `renderOperatorAnalytics` (renderer/analytics.js). What
 * that version got wrong:
 *
 * 1. ACCURACY WENT NEGATIVE. Each job scored `(1 − |actual − estimate| /
 *    estimate) × 100`, so a print that took three times its estimate scored
 *    −100%, and one such job cancelled out two perfect ones. A job's score is
 *    now floored at 0: "nothing like the estimate" is as wrong as a print can
 *    be, and accuracy below none is not a quantity.
 * 2. IT SCORED TYPED TIMES. An actual somebody typed in is usually the
 *    estimate confirmed, so it scored 100% and made an operator look perfect
 *    for not measuring anything. Only a time a printer reported is scored
 *    (`timeWasMeasured`, the rule `machine-accuracy.js` uses), and how many
 *    jobs were scored is reported beside it.
 * 3. WASTE WAS A COUNT OF ENTRIES, and only on jobs that FINISHED. One gram
 *    and one ruined kilogram were one entry each, and a job that failed and
 *    was cancelled — the job most likely to have waste — was not "finished",
 *    so its waste was nobody's. Waste is now grams and cost, from every job
 *    the operator was on.
 * 4. It counted voided, archived and not-business jobs.
 * 5. A job whose operator had been deleted vanished from the table: the rows
 *    were built from the operator list, so the work went with the name. It is
 *    now a row of its own, marked as an operator no longer on the list.
 *
 * ── timeTracking(): THE LABOUR TABLE ─────────────────────────────────────
 *
 * The time-entry half of `renderTimeAnalytics`. What it got wrong:
 *
 * 1. EVERY OPERATOR ON A JOB WAS CREDITED WITH ALL OF ITS REVENUE. Two people
 *    each logging an hour on a 1,000 job both showed 1,000 earned, so the
 *    operators' revenue added up to more than the shop took. A job's revenue
 *    is now shared by the hours each person put into it.
 * 2. REVENUE WAS `order.price`: the typed price, before discounts, with tax
 *    and in whatever currency the order was in — from any order, including
 *    quotes, open jobs and voided ones. It is now the order's earned revenue
 *    (the caller's `revenueOf`, `order-money`'s rule) and only from work that
 *    reached the customer.
 * 3. REVENUE PER HOUR DIVIDED BY HOURS THAT HAD EARNED NOTHING YET. Hours on
 *    a job still printing were in the denominator while its revenue was not,
 *    so a busy week read as a bad one. Revenue per hour is now over the hours
 *    on jobs that have earned.
 * 4. AVERAGE HOURS PER ORDER divided ALL hours — including time logged
 *    against no job at all — by the number of jobs, inflating it.
 * 5. A RENAMED OPERATOR KEPT THEIR OLD NAME. The row was labelled from the
 *    first entry's frozen `operatorName`. The current name is used now, and
 *    the frozen one only for somebody no longer on the list.
 * 6. The top jobs had no tie-break, and every label on the card was English.
 *
 * ── references(): WHAT A DELETE WOULD STRAND ─────────────────────────────
 *
 * Both apps' delete used to drop the operator and nothing else, leaving every
 * job and time entry pointing at an id that named nobody. Who printed a job is
 * history, not a setting, so it is not cleared the way a deleted location is:
 * an operator with work on record is made INACTIVE instead (gone from every
 * picker, still the name on their work), and only one with no work is removed.
 *
 * Pure: no DOM, no clock.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
function str(v) { return v == null ? '' : String(v); }

function defaultsOf(deps) {
  const d = deps || {};
  return {
    isFinished: typeof d.isFinished === 'function'
      ? d.isFinished : (o) => !!o && (o.status === 'completed' || o.status === 'delivered'),
    countsForBusiness: typeof d.countsForBusiness === 'function'
      ? d.countsForBusiness : (o) => !!o && o.nonBusiness !== true,
    timeWasMeasured: typeof d.timeWasMeasured === 'function'
      ? d.timeWasMeasured
      : (o) => !!(o && o.actualsSource && o.actualsSource.time && o.actualsSource.time !== 'manual'),
    revenueOf: typeof d.revenueOf === 'function' ? d.revenueOf : (o) => num(o && o.price),
  };
}

/** Is this the shop's own finished, standing work? */
function earned(o, d) {
  return !!o && !o.voidedAt && !o.archived && d.isFinished(o) && d.countsForBusiness(o);
}

/** The operators, keyed by id, in the book's order. */
function index(operators) {
  const byId = new Map();
  for (const op of Array.isArray(operators) ? operators : []) {
    if (op && op.id != null && str(op.id) !== '' && !byId.has(str(op.id))) byId.set(str(op.id), op);
  }
  return byId;
}

/** One job's accuracy, 0–100. Null when it cannot be scored. */
function jobAccuracy(o) {
  const est = num(o.printTime);
  const act = num(o.actualPrintTime);
  if (!(est > 0) || !(act > 0)) return null;
  return Math.max(0, 1 - Math.abs(act - est) / est) * 100;
}

/**
 * @param {object} input
 *   operators  store.operators
 *   orders     every order in the book
 *   wasteLog   store.wasteLog
 * @param {object} deps  isFinished, countsForBusiness, timeWasMeasured
 * @returns {{
 *   hasOperators: boolean,
 *   rows: {operatorId: string, name: string, role: string, active: boolean,
 *          known: boolean, jobs: number, wasteEntries: number,
 *          wasteGrams: number, wasteCost: number,
 *          accuracyPct: number|null, scored: number}[]
 * }}
 */
function performance(input, deps) {
  const i = input || {};
  const d = defaultsOf(deps);
  const ops = index(i.operators);
  const orders = Array.isArray(i.orders) ? i.orders : [];

  // Every job an operator was on, finished or not — waste happens on the jobs
  // that did not finish.
  const onJob = new Map();     // orderId → operatorId
  const stats = new Map();     // operatorId → row under construction
  const row = (id) => {
    if (!stats.has(id)) {
      stats.set(id, { jobs: 0, wasteEntries: 0, wasteGrams: 0, wasteCost: 0, scores: [] });
    }
    return stats.get(id);
  };
  for (const o of orders) {
    if (!o || o.id == null || !o.operatorId) continue;
    const opId = str(o.operatorId);
    onJob.set(str(o.id), opId);
    if (!earned(o, d)) continue;
    const r = row(opId);
    r.jobs += 1;
    if (d.timeWasMeasured(o)) {
      const s = jobAccuracy(o);
      if (s != null) r.scores.push(s);
    }
  }
  for (const w of Array.isArray(i.wasteLog) ? i.wasteLog : []) {
    if (!w || w.orderId == null) continue;
    const opId = onJob.get(str(w.orderId));
    if (!opId) continue;
    const r = row(opId);
    r.wasteEntries += 1;
    r.wasteGrams += Math.max(0, num(w.weight));
    r.wasteCost += Math.max(0, num(w.costFull != null ? w.costFull : w.cost));
  }

  const out = [];
  const finish = (id, op) => {
    const s = stats.get(id);
    if (!s || (s.jobs === 0 && s.wasteEntries === 0)) return;
    out.push({
      operatorId: id,
      name: op ? str(op.name) : '',
      role: op ? str(op.role) : '',
      active: op ? op.active !== false : false,
      known: !!op,
      jobs: s.jobs,
      wasteEntries: s.wasteEntries,
      wasteGrams: s.wasteGrams,
      wasteCost: s.wasteCost,
      accuracyPct: s.scores.length ? s.scores.reduce((a, b) => a + b, 0) / s.scores.length : null,
      scored: s.scores.length,
    });
  };
  for (const [id, op] of ops) finish(id, op);
  // Work by somebody no longer on the list, after everyone who is.
  [...stats.keys()].filter((id) => !ops.has(id)).sort().forEach((id) => finish(id, null));
  return { hasOperators: ops.size > 0, rows: out };
}

/**
 * @param {object} input
 *   timeEntries  store.timeEntries
 *   orders       every order in the book
 *   operators    store.operators
 *   top          how many jobs to list, default 3
 * @param {object} deps  revenueOf, isFinished, countsForBusiness
 * @returns {{
 *   entries: number,
 *   totals: {hours: number, cost: number, orders: number,
 *            avgHoursPerOrder: number|null},
 *   operators: {operatorId: string, name: string, known: boolean,
 *               active: boolean, hours: number, cost: number, orders: number,
 *               avgHoursPerOrder: number|null, revenue: number,
 *               earningHours: number, revenuePerHour: number|null}[],
 *   topOrders: {orderId: string, project: string, hours: number,
 *               operators: string[]}[]
 * }}
 */
function timeTracking(input, deps) {
  const i = input || {};
  const d = defaultsOf(deps);
  const ops = index(i.operators);
  const topN = Number.isFinite(i.top) ? Math.max(0, i.top) : 3;
  const orderById = new Map();
  for (const o of Array.isArray(i.orders) ? i.orders : []) {
    if (o && o.id != null && !orderById.has(str(o.id))) orderById.set(str(o.id), o);
  }

  const entries = [];
  for (const e of Array.isArray(i.timeEntries) ? i.timeEntries : []) {
    if (!e || typeof e !== 'object') continue;
    const hours = num(e.hours);
    if (!(hours > 0)) continue;
    const cost = e.cost != null && Number.isFinite(Number(e.cost))
      ? Math.max(0, Number(e.cost)) : hours * Math.max(0, num(e.hourlyRate));
    entries.push({
      opId: str(e.operatorId),
      frozenName: str(e.operatorName),
      orderId: e.orderId == null ? '' : str(e.orderId),
      hours, cost,
    });
  }

  const nameOf = (opId, frozen) => {
    const op = ops.get(opId);
    return op ? str(op.name) : frozen;
  };

  // Hours per order, and each operator's share of them.
  const perOrder = new Map(); // orderId → { hours, byOp: Map(opId → hours) }
  for (const e of entries) {
    if (!e.orderId) continue;
    if (!perOrder.has(e.orderId)) perOrder.set(e.orderId, { hours: 0, byOp: new Map() });
    const p = perOrder.get(e.orderId);
    p.hours += e.hours;
    p.byOp.set(e.opId, (p.byOp.get(e.opId) || 0) + e.hours);
  }

  const perOp = new Map();
  const opRow = (e) => {
    if (!perOp.has(e.opId)) {
      perOp.set(e.opId, { frozenName: e.frozenName, hours: 0, cost: 0, orders: new Set(),
                          hoursOnOrders: 0, revenue: 0, earningHours: 0 });
    }
    return perOp.get(e.opId);
  };
  for (const e of entries) {
    const r = opRow(e);
    r.hours += e.hours;
    r.cost += e.cost;
    if (e.orderId) { r.orders.add(e.orderId); r.hoursOnOrders += e.hours; }
  }
  // Revenue, shared by hours, only from work that reached the customer.
  for (const [orderId, p] of perOrder) {
    const o = orderById.get(orderId);
    if (!earned(o, d) || !(p.hours > 0)) continue;
    const revenue = num(d.revenueOf(o));
    for (const [opId, h] of p.byOp) {
      const r = perOp.get(opId);
      r.revenue += revenue * (h / p.hours);
      r.earningHours += h;
    }
  }

  const rows = [];
  const push = (opId, r) => {
    const op = ops.get(opId);
    rows.push({
      operatorId: opId,
      name: nameOf(opId, r.frozenName),
      known: !!op,
      active: op ? op.active !== false : false,
      hours: r.hours,
      cost: r.cost,
      orders: r.orders.size,
      avgHoursPerOrder: r.orders.size ? r.hoursOnOrders / r.orders.size : null,
      revenue: r.revenue,
      earningHours: r.earningHours,
      revenuePerHour: r.earningHours > 0 ? r.revenue / r.earningHours : null,
    });
  };
  for (const opId of ops.keys()) if (perOp.has(opId)) push(opId, perOp.get(opId));
  [...perOp.keys()].filter((id) => !ops.has(id)).sort().forEach((id) => push(id, perOp.get(id)));

  const hoursOnOrders = entries.reduce((s, e) => s + (e.orderId ? e.hours : 0), 0);
  const topOrders = [...perOrder.entries()]
    .sort((a, b) => (b[1].hours - a[1].hours) || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .slice(0, topN)
    .map(([orderId, p]) => {
      const o = orderById.get(orderId);
      const names = [];
      for (const opId of p.byOp.keys()) {
        const frozen = (entries.find((e) => e.orderId === orderId && e.opId === opId) || {}).frozenName || '';
        const n = nameOf(opId, frozen);
        if (n && !names.includes(n)) names.push(n);
      }
      return { orderId, project: o ? str(o.project) : '', hours: p.hours, operators: names };
    });

  return {
    entries: entries.length,
    totals: {
      hours: entries.reduce((s, e) => s + e.hours, 0),
      cost: entries.reduce((s, e) => s + e.cost, 0),
      orders: perOrder.size,
      avgHoursPerOrder: perOrder.size ? hoursOnOrders / perOrder.size : null,
    },
    operators: rows,
    topOrders,
  };
}

/**
 * What a delete of this operator would leave pointing at nobody.
 *
 * @returns {{jobs: number, timeEntries: number}}
 */
function references(book, operatorId) {
  const b = book || {};
  const id = str(operatorId);
  if (!id) return { jobs: 0, timeEntries: 0 };
  const jobs = (Array.isArray(b.printLog) ? b.printLog : [])
    .filter((o) => o && str(o.operatorId) === id).length;
  const timeEntries = (Array.isArray(b.timeEntries) ? b.timeEntries : [])
    .filter((e) => e && str(e.operatorId) === id).length;
  return { jobs, timeEntries };
}

/**
 * Delete an operator the way both apps do: removed when nothing names them,
 * made inactive when their name is on work. Returns the new operators list and
 * which of the two happened; the record itself — `pinHash`, `roleKey`,
 * anything this does not know — is otherwise left exactly as it was.
 *
 * @returns {{operators: object[], outcome: 'removed'|'deactivated'|'missing'}}
 */
function remove(book, operatorId) {
  const b = book || {};
  const list = Array.isArray(b.operators) ? b.operators : [];
  const id = str(operatorId);
  const at = list.findIndex((op) => op && str(op.id) === id);
  if (at < 0) return { operators: list, outcome: 'missing' };
  const refs = references(b, id);
  if (refs.jobs + refs.timeEntries === 0) {
    return { operators: list.filter((_, k) => k !== at), outcome: 'removed' };
  }
  const next = list.slice();
  next[at] = { ...list[at], active: false };
  return { operators: next, outcome: 'deactivated' };
}

const api = { performance, timeTracking, references, remove, jobAccuracy };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytOperators = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
