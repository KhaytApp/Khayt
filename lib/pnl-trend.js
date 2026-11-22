'use strict';
(function (global) {

/**
 * Six months of the P&L, as the two trend charts read it.
 *
 * `renderer/analytics.js` drew "Monthly revenue vs expenses" and "Profit
 * margin by month" from `KhaytPnl.pnlByPeriod(…, { granularity: 'month' })`,
 * and picked the figures off the rows inline. The Mac draws the same two
 * charts, so the picking is here: which lines make up the expense bar, and
 * what a month with no row reads as.
 *
 * Revenue is the P&L's — net of tax, in the shop's currency. The expense bar
 * is what the shop paid (net of reclaimable tax) plus waste, depreciation and
 * logged labour, WITHOUT the fixed overhead the P&L charges a period: the bar
 * is spending, not the P&L's expense line.
 *
 * PURE: the rows and the month keys come in; nothing is read from a clock.
 */

const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };

function byPeriod(rows) {
  const out = {};
  for (const r of (Array.isArray(rows) ? rows : [])) if (r && r.period != null) out[r.period] = r;
  return out;
}

/**
 * Revenue against spending, a row per month key, oldest first as given.
 * @returns {Array<{month, revenue, expenses, profit}>}
 */
function monthlyTrend(rows, monthKeys) {
  const byKey = byPeriod(rows);
  return (Array.isArray(monthKeys) ? monthKeys : []).map((m) => {
    const r = byKey[m];
    const revenue = r ? r.revenue : 0;
    const expenses = r ? r.expenses + (r.waste || 0) + (r.depreciation || 0) + (r.labour || 0) : 0;
    return { month: String(m), revenue: num(revenue), expenses: num(expenses), profit: num(revenue) - num(expenses) };
  });
}

/**
 * The P&L's own blended margin per month — money accumulated and divided
 * once — or null for a month the P&L has no margin for.
 * @returns {Array<{month, marginPct: number|null}>}
 */
function marginTrend(rows, monthKeys) {
  const byKey = byPeriod(rows);
  return (Array.isArray(monthKeys) ? monthKeys : []).map((m) => ({
    month: String(m),
    marginPct: (byKey[m] && byKey[m].marginPct != null) ? byKey[m].marginPct : null,
  }));
}

/** The colour band a margin reads in: 40% and up, 20% and up, below. */
function marginBand(pct) {
  return pct >= 40 ? 'good' : pct >= 20 ? 'fair' : 'poor';
}

const api = { monthlyTrend, marginTrend, marginBand };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytPnlTrend = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
