'use strict';
(function (global) {

/**
 * What each machine earned, and what it cost to keep earning it.
 *
 * ── THE QUESTION AN OWNER ASKS AFTER BUYING A PRINTER ─────────────────────
 *
 * "Was it worth it." A shop's P&L answers that for the shop; nothing answered
 * it for the MACHINE, which is the unit the money was spent on. A printer that
 * takes a quarter of the work and half the maintenance is a printer to think
 * about, and the figures to see that with were spread across four collections.
 *
 * ── WHY IT IS HERE AND NOT IN A SCREEN ───────────────────────────────────
 *
 * It was in one — `renderMachinePL` in `renderer/analytics.js` computed it
 * inline, which is fine until a second app wants the same answer. Then there
 * are two implementations of "what did this machine earn" and the one a shop
 * happens to be looking at decides. That is the failure the shared rules exist
 * to prevent, and it is worse here than most: this is the number an owner uses
 * to decide whether to RETIRE a machine.
 *
 * ── EVERY COST RESPECTS THE RANGE, WHICH IS NOT FREE ─────────────────────
 *
 * Maintenance used to be filtered by calendar year while revenue and material
 * were filtered by the chosen range, so picking "This month" charged January's
 * belt overhaul against July's revenue and a profitable printer read as
 * loss-making. The caller filters ALL FOUR the same way and passes what is in
 * range; this module does not know what a range is.
 *
 * PURE: no DOM, no clock, no collections of its own.
 */

const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };

/**
 * How long a job actually occupied its machine.
 *
 * ── WHY NOT `printTime`, WHICH IS WHAT THE SCREEN USED ───────────────────
 *
 * `printTime` is the ESTIMATE the job was quoted at. `actualPrintTime` is what
 * it took. A shop whose prints routinely run over reads as under-worked on the
 * estimate, and one whose estimates are padded reads as busier than it is —
 * from the same book, on the same day.
 *
 * This deliberately accepts a TYPED actual as well as a printer-measured one,
 * which `machine-accuracy.js` refuses. The two modules are asking different
 * questions. Accuracy compares the estimate against reality, so an actual that
 * is just the estimate confirmed would compare an estimate to itself and
 * report a machine as perfectly calibrated — it has to know where the figure
 * came from. "How many hours was this machine busy" does not: a typed actual
 * is still the shop's best account of the time, and falling back to the
 * estimate for those jobs would mix two measures in one total.
 */
function hoursOf(order) {
  const actual = num(order && order.actualPrintTime);
  return actual > 0 ? actual : num(order && order.printTime);
}

/**
 * @param {object} input
 *   machines   [{ id, name, color }]
 *   completed  finished orders ALREADY filtered to the range
 *   expenses   expenses already filtered to the range; linked by `orderId`
 *   maintenance machine maintenance entries already filtered, `{ machineId, cost }`
 *   unassigned what to call work that names no machine
 *   days       how long the range is, for utilisation; omit and it is null
 *   range      `{ from, to }` YYYY-MM-DD, the range the four were filtered to
 *              (`to` cut to today for one still running) — what a
 *              straight-line machine's depreciation is pro-rated over. Omit
 *              it and only perHour machines, charged on their hours, have one.
 *   recentMonthlyHours  `{ [machineId]: hours }`, for a straight-line machine
 *              whose hourly figure depends on it
 *   orders     optional, the WHOLE book unfiltered. With it a perHour
 *              machine's depreciation is exactly the shop P&L's
 *              (`periodCharges` over `range`): hours before its purchase date
 *              are ignored and hours already printed count against its life.
 * @param {object} deps
 *   revenueOf  (order) => net revenue in the shop's base currency
 *   partCostOf (part)  => what that part's material cost
 * @returns {{rows: Array, totals: object}} rows worst-margin last, machines
 *   with no finished work omitted — a printer that did nothing this month has
 *   no P&L, and a row of zeroes reads as one that lost nothing.
 */
function machineProfit(input, deps) {
  const i = input || {};
  const d = deps || {};
  // How long the range is, in days. Utilisation is hours run against hours
  // wanted, and hours wanted is a rate — without the length of the range there
  // is no denominator, so the figure is withheld rather than guessed.
  const days = num(i.days);
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : () => 0;
  const partCostOf = typeof d.partCostOf === 'function' ? d.partCostOf : () => 0;

  const NONE = '__none__';
  const byId = new Map();
  const records = new Map();
  for (const m of Array.isArray(i.machines) ? i.machines : []) {
    if (!m || !m.id) continue;
    records.set(String(m.id), m);
    byId.set(String(m.id), {
      machineId: String(m.id), name: String(m.name || ''), color: m.color || '#888888',
      jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0, depreciation: 0,
      hours: 0, measured: 0, targetHoursPerDay: num(m.targetHoursPerDay) || null,
    });
  }
  byId.set(NONE, {
    machineId: NONE, name: String(i.unassigned || ''), color: '#888888',
    jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0, depreciation: 0,
    // Work naming no machine has no machine to be a target of.
    hours: 0, measured: 0, targetHoursPerDay: null,
  });

  // Maintenance BEFORE the jobs, because a machine can have been serviced in a
  // range it took no work in — and that is a fact worth seeing, not a row to
  // drop. Whether it is shown is decided at the end, on `jobs`.
  for (const e of Array.isArray(i.maintenance) ? i.maintenance : []) {
    const row = byId.get(String((e && e.machineId) || ''));
    if (row) row.maintenance += num(e && e.cost);
  }

  const linked = new Map();
  for (const e of Array.isArray(i.expenses) ? i.expenses : []) {
    const id = String((e && e.orderId) || '');
    if (!id) continue;
    linked.set(id, (linked.get(id) || 0) + num(e && e.amount));
  }

  for (const o of Array.isArray(i.completed) ? i.completed : []) {
    if (!o) continue;
    const key = o.machineId && byId.has(String(o.machineId)) ? String(o.machineId) : NONE;
    const row = byId.get(key);
    row.jobs += 1;
    row.hours += hoursOf(o);
    if (num(o.actualPrintTime) > 0) row.measured += 1;
    /* A job marked Not business still took the machine's time, which is what
     * a machine's hours are for, but it is not the shop's trade: its plastic
     * is not a cost of sales and it earned nothing. The P&L leaves it out
     * (lib/business-scope.js), and a machine's P&L that kept it showed the
     * U1 losing 262 SAR on nineteen test prints the shop had set aside. */
    const scope = global.KhaytBusinessScope;
    if (scope && typeof scope.countsForBusiness === 'function' && !scope.countsForBusiness(o)) continue;
    row.revenue += num(revenueOf(o));
    for (const p of Array.isArray(o.parts) ? o.parts : []) row.materialCost += num(partCostOf(p));
    row.linkedExpenses += linked.get(String(o.id)) || 0;
  }

  /* ── WHAT THE MACHINE LOST IN VALUE OVER THE RANGE ──────────────────────
   *
   * The one place its wear is counted (the maintainer's decision, 2026-09-28,
   * and the same line the shop's P&L carries): perHour on the hours it ran in
   * the range, straightLine as its monthly amount pro-rated over the range.
   * A machine without depreciation set has none, and its net is unchanged. */
  const D = global.KhaytDepreciation
    || (typeof require === 'function'
      ? (() => { try { return require('./depreciation.js'); } catch (e) { return null; } })()
      : null);
  const range = i.range || {};
  const recentBy = i.recentMonthlyHours || {};

  /* ── perHour: THE SAME CHARGE THE SHOP'S P&L MAKES ─────────────────────
   *
   * This charged `rate × the hours in range`, while the shop's P&L
   * (`periodCharges`) charges only hours printed SINCE THE MACHINE WAS
   * BOUGHT and never past its life. A printer already 100 h into a 100 h life
   * read 50 of depreciation here and 0 there; a job dated before the machine
   * was bought was charged to it here and not there. One machine, two figures,
   * on the report an owner retires a printer on.
   *
   * With `orders` (the whole book) it routes through `periodCharges` over the
   * range as one period, so the two cannot disagree. Without it (an older
   * caller) the hours before the range are unknown and taken as none, but a
   * job dated before the purchase is still left out. */
  const book = Array.isArray(i.orders) ? i.orders : null;
  const dayOf = (v) => {
    const m = /^\d{4}-\d{2}-\d{2}/.exec(String(v == null ? '' : v).trim());
    return m ? m[0] : '';
  };
  function perHourCharge(Dep, m, s, id) {
    if (book) {
      const recent = {};
      recent[id] = recentBy[id];
      const out = Dep.periodCharges([m], book,
        [{ key: 'range', from: dayOf(range.from) || '1970-01-01', to: dayOf(range.to) || '9999-12-31' }],
        { recentMonthlyHours: recent });
      return (out.range && out.range.byMachine[id]) || 0;
    }
    let hours = 0;
    for (const o of Array.isArray(i.completed) ? i.completed : []) {
      if (!o || String(o.machineId || '') !== id) continue;
      if (s.purchaseDate) {
        const day = dayOf(o.date);
        if (!day || day < s.purchaseDate) continue;
      }
      hours += hoursOf(o);
    }
    return Dep.periodCharge(m, { hours }, { recentMonthlyHours: recentBy[id] });
  }

  if (D) {
    for (const [id, m] of records) {
      const row = byId.get(id);
      if (!row || !D.settingsOf(m)) continue;
      const opts = { recentMonthlyHours: recentBy[id] };
      const s = D.settingsOf(m);
      row.depreciation = s.method === 'perHour'
        ? perHourCharge(D, m, s, id)
        : D.periodCharge(m, { from: range.from, to: range.to }, opts);
    }
  }

  const rows = [];
  for (const row of byId.values()) {
    // A machine that finished nothing in this range has no P&L. A row of
    // zeroes reads as a machine that lost nothing, which is a different claim.
    if (row.jobs === 0) continue;
    const net = row.revenue - row.materialCost - row.linkedExpenses - row.maintenance - row.depreciation;
    rows.push({
      ...row,
      net,
      // Null rather than zero on no revenue: a machine that earned nothing has
      // no margin, and 0% reads as "broke even".
      //
      // ROUNDED HERE, not by each screen. `550 / 1000 * 100` is
      // 55.00000000000001 in binary floating point, and a rule that hands that
      // out makes every consumer round it — which is how two screens come to
      // show the same machine at 55% and 55.0000000001%. Two decimals is what
      // `printer-actuals` uses for the same reason.
      marginPct: row.revenue > 0 ? Math.round((net / row.revenue) * 10000) / 100 : null,
      // ── HOW HARD IT WORKED, AND NEVER CAPPED ──────────────────────────
      //
      // `Math.min(100, …)` is what the screen did, and it destroys the only
      // reading anybody needs this for: a printer running half as much again
      // as it is meant to and one hitting its target exactly came out
      // identical, so the machine to buy a second of was invisible. Clamp the
      // BAR, never the number — the same rule `lib/capacity.js` states about
      // its own gauge.
      //
      // Null, not zero, when there is no target or no days: a machine nobody
      // has set a target for has no utilisation, and 0% reads as idle.
      utilisationPct: (row.targetHoursPerDay > 0 && days > 0)
        ? Math.round((row.hours / (row.targetHoursPerDay * days)) * 10000) / 100
        : null,
    });
  }
  // Best earner first — the order an owner reads it in.
  rows.sort((a, b) => b.net - a.net);

  const totals = rows.reduce((t, r) => ({
    jobs: t.jobs + r.jobs,
    revenue: t.revenue + r.revenue,
    materialCost: t.materialCost + r.materialCost,
    linkedExpenses: t.linkedExpenses + r.linkedExpenses,
    maintenance: t.maintenance + r.maintenance,
    depreciation: t.depreciation + r.depreciation,
    net: t.net + r.net,
    hours: t.hours + r.hours,
    measured: t.measured + r.measured,
  }), { jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0,
        depreciation: 0, net: 0, hours: 0, measured: 0 });

  return { rows, totals };
}

const api = { machineProfit, hoursOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachinePL = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
