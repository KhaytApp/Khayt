'use strict';
/**
 * What each of the shop's sites earned, and what it cost (KhaytLocationPl).
 *
 * A shop with two branches asks the P&L's question once per branch: which one
 * is paying for the other. The answer has to be the SAME P&L split in two —
 * not a second opinion about money — so this does no money arithmetic of its
 * own. It sorts the book into one pile per location and hands each pile to
 * `KhaytPnl.pnlByPeriod`, the rule the shop's own P&L runs. The piles add up
 * to the shop's figures because they are the shop's figures.
 *
 * ── WHAT THE VERSION THIS REPLACES GOT WRONG ──────────────────────────────
 *
 * `renderLocationPL` in renderer/analytics.js did its own sums, and they
 * disagreed with the P&L two screens away:
 *
 * 1. IT COSTED A JOB TWICE OVER. It took `partTotalCost(p)` for every part —
 *    the PRICING cost, re-priced at today's spool prices, with the estimates
 *    of electricity, machine wear, labour and the failure buffer folded in —
 *    and then also took off the shop's real electricity and maintenance
 *    bills as expenses. The P&L counts only what was stocked, from the cost
 *    frozen on the job (`stockShare` × `costBasis`, lib/pnl-report.js), and
 *    lets the bills be the bills. A branch's net came out lower than the
 *    shop's net for the same jobs.
 * 2. TAX. Expenses went in at what was paid, VAT and all, where the P&L takes
 *    off what a registered shop reclaims. Revenue was already net.
 * 3. IT IGNORED A JOB'S OWN LOCATION. `order.locationId` is honoured by the
 *    board filter and by the stock deduction (`orderLocationId`,
 *    lib/order-deduction.js); this read only the machine's. A job moved to
 *    the other branch was still counted at the first.
 * 4. A DELETED LOCATION BECAME A ROW NAMED `LOC-ms2t9…`. Deleting a location
 *    never cleared the machines and expenses pointing at it, so their raw id
 *    turned up as a branch. An id that names no location is unassigned.
 * 5. WASTE was placed only through `machineId`. An entry recorded against a
 *    job with no machine fell to "unassigned" even when its job had a site.
 * 6. A SITE THAT EARNED NOTHING WAS LEFT OFF. "Site 2: 0" is the answer to the
 *    question, not the absence of one.
 *
 * ── WHAT IS NOT SPLIT ─────────────────────────────────────────────────────
 *
 * Fixed overhead — rent, wages, `settings.fixedCosts` — belongs to the shop,
 * and any split of it between branches is a choice the shop has not made. It
 * is left out of every row (as it always was here) and the screen says so.
 * Machine depreciation IS split: a machine is somewhere, and its wear is that
 * branch's cost.
 *
 * Pure; no DOM, no I/O. Shared by the desktop and, bundled, the Mac.
 */
(function (global) {
  const req = (name, file) => (global && global[name])
    || (typeof require === 'function' ? (() => { try { return require(file); } catch (e) { return null; } })() : null);
  const Pnl = () => req('KhaytPnl', './pnl-report.js');
  const Deduction = () => req('KhaytOrderDeduction', './order-deduction.js');

  const arr = (v) => (Array.isArray(v) ? v : []);
  const str = (v) => (v == null ? '' : String(v));
  const round2 = (n) => Math.round((+n || 0) * 100) / 100;

  /** The key of the pile that is not a location. */
  const UNASSIGNED = '';

  /**
   * Which branch a job belongs to: its own, else its machine's — the board's
   * and the deduction's rule, `KhaytOrderDeduction.orderLocationId`.
   */
  function orderLocationId(order, machines) {
    const D = Deduction();
    if (D && typeof D.orderLocationId === 'function') return D.orderLocationId(order, machines) || null;
    return null;
  }

  /**
   * @param {object} input
   *   orders, expenses, wasteLog, machines, locations — the book
   *   settings, clients, currencies, inventory, now, recentMonthlyHours — what
   *     `pnlByPeriod` is handed by the shop's own P&L, passed through unchanged
   *   inRange  optional `(isoDate) => boolean`. Absent, the whole book. A host
   *     that has already filtered its rows to a period passes none.
   * @returns {{ rows: Array<{locationId, orders, revenue, cogs, expenses,
   *   waste, depreciation, costs, net, marginPct}>, located: boolean }}
   *   One row per location in the book, in the book's order of revenue, then
   *   the unassigned row — present only when something is unassigned.
   */
  function locationPl(input) {
    const c = input || {};
    const P = Pnl();
    const locations = arr(c.locations).filter((l) => l && l.id);
    if (!P || !locations.length) return { rows: [], located: false };
    const known = new Set(locations.map((l) => str(l.id)));
    const machines = arr(c.machines);
    const inRange = typeof c.inRange === 'function' ? c.inRange : () => true;
    // An id that names no location is not a branch: a location deleted before
    // deletes cleared what pointed at it leaves exactly that behind.
    const site = (id) => (id && known.has(str(id)) ? str(id) : UNASSIGNED);

    const piles = new Map();
    const pile = (key) => {
      if (!piles.has(key)) piles.set(key, { orders: [], expenses: [], waste: [], machines: [] });
      return piles.get(key);
    };
    for (const l of locations) pile(str(l.id));

    const orders = arr(c.orders);
    const byId = new Map(orders.filter((o) => o && o.id).map((o) => [o.id, o]));
    for (const o of orders) {
      if (!o || !inRange(str(o.date || str(o.timestamp).slice(0, 10)))) continue;
      pile(site(orderLocationId(o, machines))).orders.push(o);
    }
    for (const e of arr(c.expenses)) {
      if (!e || !inRange(str(e.date))) continue;
      pile(site(e.locationId)).expenses.push(e);
    }
    const machineById = new Map(machines.filter((m) => m && m.id).map((m) => [m.id, m]));
    for (const w of arr(c.wasteLog)) {
      if (!w || !inRange(str(w.date))) continue;
      const m = w.machineId ? machineById.get(w.machineId) : null;
      const job = w.orderId ? byId.get(w.orderId) : null;
      const at = (m && m.locationId) || (job ? orderLocationId(job, machines) : null);
      pile(site(at)).waste.push(w);
    }
    for (const m of machines) {
      if (m && m.locationId && known.has(str(m.locationId))) pile(str(m.locationId)).machines.push(m);
    }

    // Overhead stays with the shop — see the header.
    const settings = Object.assign({}, c.settings || {}, { fixedCosts: [] });
    const rows = [];
    for (const [locationId, p] of piles) {
      const periods = P.pnlByPeriod(p.orders, p.expenses, {
        settings, clients: c.clients || [], currencies: c.currencies || null,
        inventory: c.inventory || [], consumables: c.consumables,
        now: c.now instanceof Date ? c.now : (c.now != null ? new Date(c.now) : new Date()),
        granularity: 'month', wasteLog: p.waste, machines: p.machines,
        recentMonthlyHours: c.recentMonthlyHours,
      });
      const sum = (k) => periods.reduce((s, r) => s + (+r[k] || 0), 0);
      const revenue = sum('revenue'), cogs = sum('cogs'), expenses = sum('expenses');
      const waste = sum('waste'), depreciation = sum('depreciation');
      const costs = cogs + expenses + waste + depreciation;
      const row = {
        locationId,
        orders: sum('orders'),
        revenue: round2(revenue),
        cogs: round2(cogs),
        expenses: round2(expenses),
        waste: round2(waste),
        depreciation: round2(depreciation),
        costs: round2(costs),
        net: round2(revenue - costs),
        // On what was kept, like the P&L's — and none where nothing was billed,
        // rather than a 0% that reads as "broke even".
        marginPct: revenue > 0 ? Math.round(((revenue - costs) / revenue) * 1000) / 10 : null,
      };
      const empty = !row.orders && !row.revenue && !row.costs;
      if (locationId === UNASSIGNED && empty) continue;
      rows.push(row);
    }
    const order = new Map(locations.map((l, i) => [str(l.id), i]));
    rows.sort((a, b) => {
      if (a.locationId === UNASSIGNED) return 1;
      if (b.locationId === UNASSIGNED) return -1;
      return (b.revenue - a.revenue) || (order.get(a.locationId) - order.get(b.locationId));
    });
    return { rows, located: true };
  }

  /**
   * Everything that names a location, for a delete to clear: which records in
   * which collections point at `id`. The desktop's delete dropped the location
   * and left these pointing at nothing (see 4. above); both apps now clear
   * them. Machines and expenses spell "none" as '' (lib/machine-edit.js,
   * lib/expense-book.js), so that is what is written.
   */
  const POINTERS = ['machines', 'inventory', 'expenses', 'printLog'];
  function unpoint(book, id) {
    const changed = [];
    if (!book || !id) return changed;
    for (const k of POINTERS) {
      for (const r of arr(book[k])) {
        if (r && r.locationId === id) { changed.push({ collection: k, id: r.id }); r.locationId = ''; }
      }
    }
    return changed;
  }

  const api = { locationPl, orderLocationId, unpoint, POINTERS, UNASSIGNED };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytLocationPl = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
