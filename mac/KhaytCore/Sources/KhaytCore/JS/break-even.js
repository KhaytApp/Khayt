'use strict';
(function (global) {
/**
 * What a shop has to bill in a month to cover the costs it pays anyway.
 *
 * Rent, a subscription, the accountant — the money that goes out whether or not
 * a single print is sold. Break-even revenue is that total divided by the share
 * of each riyal billed that is left after the work itself is paid for.
 *
 * ── THE CORRECTION THIS LIFT CARRIES ──────────────────────────────────────
 *
 * The version this replaces, inline in the other app's analytics screen, costed
 * a job by looking up each part's spool and pricing its grams — and SKIPPED any
 * part with no `filamentId`. A part not linked to a spool therefore cost
 * nothing, so the margin came out too high and the break-even target too LOW.
 * A shop was told it needed to bill less than it does, which is the wrong
 * direction for a figure whose whole job is to be a floor.
 *
 * `partCostOf` is `calculator-cost`'s `partTotalCost` here — the same function
 * the machine P&L and the quote already use, which knows about resin, blended
 * multicolour, per-unit cost and quantity. One opinion about what a part costs.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** A `YYYY-MM-DD` day, from whatever was stored. */
function day(v) { return String(v == null ? '' : v).slice(0, 10); }

/**
 * @param {object} input
 *   fixedCosts  [{ name, amount }] — what goes out every month regardless
 *   completed   finished, non-voided, business orders; the window is the
 *               caller's to choose and `since` says where it starts
 *   since       `YYYY-MM-DD`; orders before it do not inform the margin
 *   month       `YYYY-MM` — which month "so far" means
 * @param {object} deps
 *   revenueOf   (order) => net revenue in the shop's base currency
 *   partCostOf  (part)  => what that part cost to make
 * @returns {{
 *   totalFixed: number, breakEvenRevenue: number|null, marginPct: number|null,
 *   avgRevenuePerJob: number|null, jobsCounted: number,
 *   billedThisMonth: number, surplus: number|null, progressPct: number|null,
 *   costs: Array<{name: string, amount: number}>
 * }}
 */
function breakEven(input, deps) {
  const i = input || {};
  const d = deps || {};
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : () => 0;
  const partCostOf = typeof d.partCostOf === 'function' ? d.partCostOf : () => 0;

  const costs = (Array.isArray(i.fixedCosts) ? i.fixedCosts : [])
    .filter((c) => c && (c.name || c.amount))
    .map((c) => ({ name: String(c.name || ''), amount: num(c.amount) }));
  const totalFixed = costs.reduce((s, c) => s + c.amount, 0);

  const orders = Array.isArray(i.completed) ? i.completed : [];
  const since = day(i.since);
  const month = String(i.month || '').slice(0, 7);

  const billedThisMonth = month
    ? orders.filter((o) => day(o && o.date).startsWith(month))
        .reduce((s, o) => s + num(revenueOf(o)), 0)
    : 0;

  const recent = since ? orders.filter((o) => day(o && o.date) >= since) : orders;

  // NULL, NOT ZERO, for a shop with no finished work in the window. Zero margin
  // would render as "you can never break even", which is a statement about the
  // shop rather than about the absence of data.
  if (recent.length === 0) {
    return {
      totalFixed, breakEvenRevenue: null, marginPct: null, avgRevenuePerJob: null,
      jobsCounted: 0, billedThisMonth, surplus: null, progressPct: null, costs,
    };
  }

  let revenue = 0;
  let cost = 0;
  for (const order of recent) {
    revenue += num(revenueOf(order));
    for (const part of (order && Array.isArray(order.parts) ? order.parts : [])) {
      cost += num(partCostOf(part));
    }
  }

  const avgRevenuePerJob = revenue / recent.length;
  // Clamped at zero: a window where the work cost more than it earned has no
  // break-even point, and a negative margin would produce a negative target —
  // a number that reads as "bill less to break even".
  const marginPct = revenue > 0 ? Math.max(0, (revenue - cost) / revenue) : 0;
  const breakEvenRevenue = marginPct > 0 && totalFixed > 0 ? totalFixed / marginPct : null;

  const surplus = breakEvenRevenue == null ? null : billedThisMonth - breakEvenRevenue;
  const progressPct = breakEvenRevenue == null || breakEvenRevenue <= 0
    ? null
    : Math.max(0, Math.min(100, (billedThisMonth / breakEvenRevenue) * 100));

  return {
    totalFixed, breakEvenRevenue, marginPct, avgRevenuePerJob,
    jobsCounted: recent.length, billedThisMonth, surplus, progressPct, costs,
  };
}

const api = { breakEven };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytBreakEven = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
