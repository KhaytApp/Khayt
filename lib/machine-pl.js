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
  for (const m of Array.isArray(i.machines) ? i.machines : []) {
    if (!m || !m.id) continue;
    byId.set(String(m.id), {
      machineId: String(m.id), name: String(m.name || ''), color: m.color || '#888888',
      jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0,
      hours: 0, measured: 0, targetHoursPerDay: num(m.targetHoursPerDay) || null,
    });
  }
  byId.set(NONE, {
    machineId: NONE, name: String(i.unassigned || ''), color: '#888888',
    jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0,
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
    row.revenue += num(revenueOf(o));
    for (const p of Array.isArray(o.parts) ? o.parts : []) row.materialCost += num(partCostOf(p));
    row.linkedExpenses += linked.get(String(o.id)) || 0;
  }

  const rows = [];
  for (const row of byId.values()) {
    // A machine that finished nothing in this range has no P&L. A row of
    // zeroes reads as a machine that lost nothing, which is a different claim.
    if (row.jobs === 0) continue;
    const net = row.revenue - row.materialCost - row.linkedExpenses - row.maintenance;
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
    net: t.net + r.net,
    hours: t.hours + r.hours,
    measured: t.measured + r.measured,
  }), { jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0,
        net: 0, hours: 0, measured: 0 });

  return { rows, totals };
}

const api = { machineProfit, hoursOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachinePL = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
