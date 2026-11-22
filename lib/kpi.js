/**
 * Executive KPI summary — collapse a period's orders into the headline numbers
 * an owner wants at a glance: revenue, margin, on-time delivery, cash
 * outstanding, average order value, and the top clients / products.
 *
 * Pure (no DOM, no currency lookups, no clock): the renderer scopes orders to a
 * date range, converts to base currency, and computes per-order on-time/cost,
 * then hands plain normalized rows in here. Deterministic + unit-testable.
 */
(function (global) {
  const round2 = (n) => Math.round((+n || 0) * 100) / 100;

  /**
   * @param {Array<{revenue:number, cost:number, completed:boolean,
   *   onTime?:boolean|null, outstanding?:number, clientName?:string,
   *   productName?:string}>} rows  one per order, already in base currency
   * @returns {object} KPI summary
   */
  function computeKpis(rows) {
    rows = Array.isArray(rows) ? rows : [];
    let revenue = 0, cost = 0, outstanding = 0, completedCount = 0;
    let onTimeHit = 0, onTimeTotal = 0;
    const byClient = {}, byProduct = {};

    for (const r of rows) {
      const rev = +r.revenue || 0;
      outstanding += +r.outstanding || 0;
      if (r.completed) {
        completedCount++;
        revenue += rev;
        cost += +r.cost || 0;
        if (r.onTime === true || r.onTime === false) { onTimeTotal++; if (r.onTime) onTimeHit++; }
        if (r.clientName) {
          const c = byClient[r.clientName] || (byClient[r.clientName] = { name: r.clientName, revenue: 0, count: 0 });
          c.revenue += rev; c.count++;
        }
        if (r.productName) {
          const p = byProduct[r.productName] || (byProduct[r.productName] = { name: r.productName, revenue: 0, count: 0 });
          p.revenue += rev; p.count++;
        }
      }
    }
    const grossProfit = revenue - cost;
    const topN = (map) => Object.values(map)
      .sort((a, b) => b.revenue - a.revenue)
      .slice(0, 5)
      .map((x) => ({ name: x.name, revenue: round2(x.revenue), count: x.count }));

    return {
      orderCount: rows.length,
      completedCount,
      revenue: round2(revenue),
      cost: round2(cost),
      grossProfit: round2(grossProfit),
      grossMargin: revenue > 0 ? Math.round((grossProfit / revenue) * 1000) / 10 : 0,
      avgOrderValue: completedCount > 0 ? round2(revenue / completedCount) : 0,
      onTimePct: onTimeTotal > 0 ? Math.round((onTimeHit / onTimeTotal) * 1000) / 10 : null,
      onTimeTotal,
      outstanding: round2(outstanding),
      topClients: topN(byClient),
      topProducts: topN(byProduct),
    };
  }

  const api = { computeKpis };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytKpi = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
