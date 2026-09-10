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
 * @param {object} input
 *   machines   [{ id, name, color }]
 *   completed  finished orders ALREADY filtered to the range
 *   expenses   expenses already filtered to the range; linked by `orderId`
 *   maintenance machine maintenance entries already filtered, `{ machineId, cost }`
 *   unassigned what to call work that names no machine
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
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : () => 0;
  const partCostOf = typeof d.partCostOf === 'function' ? d.partCostOf : () => 0;

  const NONE = '__none__';
  const byId = new Map();
  for (const m of Array.isArray(i.machines) ? i.machines : []) {
    if (!m || !m.id) continue;
    byId.set(String(m.id), {
      machineId: String(m.id), name: String(m.name || ''), color: m.color || '#888888',
      jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0,
    });
  }
  byId.set(NONE, {
    machineId: NONE, name: String(i.unassigned || ''), color: '#888888',
    jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0,
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
  }), { jobs: 0, revenue: 0, materialCost: 0, linkedExpenses: 0, maintenance: 0, net: 0 });

  return { rows, totals };
}

const api = { machineProfit };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachinePL = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
