'use strict';
(function (global) {

/**
 * What each filament earned, and how much of each material the shop used.
 *
 * ── WHY IT IS HERE AND NOT IN A SCREEN ───────────────────────────────────
 *
 * Both were inline in `renderer/dashboard.js` (`renderFilamentAnalytics`,
 * `renderMaterialUsageChart`). The Mac's Reports needed the same two answers,
 * and two copies of "which material earns" is how the two apps come to
 * disagree about it. The screens keep the drawing; the arithmetic is here.
 *
 * ── REVENUE IS WHAT THE CALLER SAYS AN ORDER EARNED ───────────────────────
 *
 * The inline version read `+o.price`: the gross price, VAT included for a
 * tax-inclusive shop, in the order's own currency. Every other money screen
 * reads revenue NET of tax in the shop's currency (`orderEarnedBase`), so the
 * caller passes `revenueOf`. Left out, it is `+o.price`, which is exactly what
 * the old screen computed — `test/filament-report.test.js` holds that.
 *
 * PURE: no DOM, no clock, no collections of its own.
 */

function finishedRule(opts) {
  if (opts && typeof opts.isFinished === 'function') return opts.isFinished;
  const S = (typeof global !== 'undefined' && global.KhaytOrderStatus) || (() => {
    try { return require('./order-status.js'); } catch (e) { return null; }
  })();
  return S ? (o) => S.isFinished(o) : (o) => !!o && (o.status === 'completed' || o.status === 'delivered');
}

/**
 * Revenue, material cost and margin per filament, best earner first.
 *
 * One row per `filamentId` (or material name where a part names no spool).
 * An order's revenue is split across its parts by their share of its base
 * cost — evenly when no part carries one.
 *
 * @returns {Array<{key, label, color, orders, revenue, matCost, marginPct, avgTimePerGram}>}
 *   `marginPct` is 0 for a filament that earned nothing (as the screen showed
 *   it); `avgTimePerGram` is hours per gram from measured prints, or null.
 */
function profitByFilament(orders, inventory, opts) {
  const o2 = opts || {};
  const isFinished = finishedRule(o2);
  const revenueOf = typeof o2.revenueOf === 'function' ? o2.revenueOf : (o) => +o.price;
  const shelf = Array.isArray(inventory) ? inventory : [];
  const agg = {};
  (Array.isArray(orders) ? orders : [])
    .filter((o) => o && isFinished(o))
    .forEach((o) => {
      const parts = o.parts || [];
      if (parts.length === 0) return;
      const price = revenueOf(o);
      const totalBase = parts.reduce((s, p) => s + (+p.baseCost || 0), 0);
      parts.forEach((p) => {
        const key = p.filamentId || p.material || 'unknown';
        const filItem = shelf.find((i) => i && i.id === p.filamentId);
        const label = p.material || (filItem && filItem.material) || key;
        if (!agg[key]) {
          agg[key] = { key, label, color: (filItem && filItem.color) || '#888',
            orderIds: new Set(), revenue: 0, matCost: 0, timePerGrams: [] };
        }
        agg[key].orderIds.add(o.id);

        const revShare = totalBase > 0 ? (+p.baseCost / totalBase) * +price : +price / parts.length;
        agg[key].revenue += revShare;

        const spoolC = +p.spoolCost || 0;
        const spoolW = Math.max(1, +p.spoolWeight || 1000);
        const pw = +p.printWeight || 0;
        agg[key].matCost += (spoolC / spoolW) * pw;

        if (o.actualPrintTime != null && o.actualWeight != null && o.actualWeight > 0 && o.printTime > 0) {
          const timeShare = (p.printTime / o.printTime) * o.actualPrintTime;
          const weightShare = pw > 0 ? pw : o.actualWeight / parts.length;
          if (weightShare > 0) agg[key].timePerGrams.push(timeShare / weightShare);
        }
      });
    });

  return Object.values(agg).sort((a, b) => b.revenue - a.revenue).map((r) => ({
    key: String(r.key),
    label: String(r.label),
    color: String(r.color),
    orders: r.orderIds.size,
    revenue: r.revenue,
    matCost: r.matCost,
    marginPct: r.revenue > 0 ? ((r.revenue - r.matCost) / r.revenue * 100) : 0,
    avgTimePerGram: r.timePerGrams.length > 0
      ? r.timePerGrams.reduce((s, v) => s + v, 0) / r.timePerGrams.length
      : null,
  }));
}

/**
 * `YYYY-MM` for the `count` months ending with the one `now` is in, oldest
 * first, in the calendar of the Date given (local, as the screens draw it).
 */
function lastMonths(now, count) {
  const d0 = now instanceof Date ? now : new Date(now);
  const n = Math.max(1, Math.floor(+count || 6));
  const out = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(d0.getFullYear(), d0.getMonth() - i, 1);
    out.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
  }
  return out;
}

/**
 * Grams used per material per month, from each spool's `usageHistory`.
 *
 * At most `limit` materials (6, for a chart that can still be read), in the
 * order the shelf first names them; a material with nothing in the window is
 * left out. Each material's colour is the first spool of it on the shelf.
 *
 * @returns {{materials: string[], colors: Object<string,string>,
 *            grams: Object<string, Object<string, number>>,
 *            monthTotals: number[], maxGrams: number}}
 */
function materialUsage(inventory, monthKeys, opts) {
  const shelf = Array.isArray(inventory) ? inventory : [];
  const months = Array.isArray(monthKeys) ? monthKeys.map(String) : [];
  const limit = (opts && opts.limit != null) ? +opts.limit : 6;
  const materialData = {};
  for (const item of shelf) {
    if (!item || !item.usageHistory || item.usageHistory.length === 0) continue;
    const mat = item.material || 'Unknown';
    if (!materialData[mat]) materialData[mat] = {};
    for (const h of item.usageHistory) {
      const mk = ((h && h.date) || '').slice(0, 7);
      if (!months.includes(mk)) continue;
      materialData[mat][mk] = (materialData[mat][mk] || 0) + (+h.weightUsed || 0);
    }
  }
  const materials = Object.keys(materialData).filter((mat) =>
    Object.values(materialData[mat]).some((v) => v > 0),
  ).slice(0, limit);

  const colors = {};
  const grams = {};
  for (const mat of materials) {
    const invItem = shelf.find((i) => i && i.material === mat);
    colors[mat] = (invItem && invItem.color) || '#5b9cf0';
    grams[mat] = {};
    for (const mk of months) grams[mat][mk] = materialData[mat][mk] || 0;
  }
  const monthTotals = months.map((mk) => materials.reduce((s, mat) => s + (materialData[mat][mk] || 0), 0));
  return { materials, colors, grams, monthTotals, maxGrams: Math.max(...monthTotals, 1) };
}

const api = { profitByFilament, materialUsage, lastMonths };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytFilamentReport = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
