'use strict';

/**
 * Which orders count towards a period's figures, and what "completed" and
 * "on time" mean.
 *
 * `lib/kpi.js` adds the numbers up. It takes rows that have already been scoped
 * to a date range, converted to one currency and marked completed and on-time —
 * and that scoping and marking lived inside `openExecutiveSummary` in
 * `renderer/analytics.js`, where nothing else could reach it.
 *
 * That mattered the moment a second app existed. The Mac app called
 * `computeKpis({orders, settings})`, which is not its signature, and got every
 * figure back as ZERO — a dashboard reading "0 SAR revenue" beside a toolbar
 * reading 52,691.57. The alternative to sharing this was a second Swift opinion
 * about what counts as revenue, which is how two apps come to disagree about a
 * shop's year.
 *
 * ── WHAT IS HERE AND WHAT IS NOT ───────────────────────────────────────────
 * Here: the date bounds, the exclusions, and the completed/on-time rules. Those
 * are the parts a second implementation gets subtly wrong.
 *
 * Not here: money. Converting an order to the shop's base currency needs the
 * rates in `settings` and the client's own currency, and that lives in
 * `renderer/currency.js` with the rest of the multi-currency machinery. So the
 * caller passes a function per order. PURE: no globals, no clock of its own —
 * `bounds` takes the day it should treat as today.
 */
(function (global) {

  /** `YYYY-MM-DD` in LOCAL time, matching renderer/util.js localDateStr. */
  function ymd(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  /**
   * The first and last day of a named range, inclusive.
   *
   * Local months, not UTC: a shop closing its books on the 31st means its own
   * 31st. `all` is two empty strings rather than impossible dates, because the
   * filter below reads "no bound" from emptiness.
   *
   * @param {string} range  month | last_month | quarter | year | all
   * @param {Date} [now]    the day to treat as today
   * @returns {[string, string]}
   */
  function bounds(range, now) {
    const d = now instanceof Date ? now : new Date();
    const y = d.getFullYear();
    const m = d.getMonth();
    if (range === 'month') return [ymd(new Date(y, m, 1)), ymd(new Date(y, m + 1, 0))];
    if (range === 'last_month') return [ymd(new Date(y, m - 1, 1)), ymd(new Date(y, m, 0))];
    if (range === 'quarter') {
      const q = Math.floor(m / 3);
      return [ymd(new Date(y, q * 3, 1)), ymd(new Date(y, q * 3 + 3, 0))];
    }
    if (range === 'year') return [ymd(new Date(y, 0, 1)), ymd(new Date(y, 11, 31))];
    return ['', ''];
  }

  /** A date is in range when both open bounds allow it. Empty means unbounded. */
  function inRange(date, from, to) {
    const x = String(date || '').slice(0, 10);
    if (!x) return !from && !to;   // an undated order belongs only to "all"
    return (!from || x >= from) && (!to || x <= to);
  }

  /**
   * Does this order count at all?
   *
   * Voided orders are not revenue that later went away — they are entries that
   * should never have been counted. Quotes are not sales; a shop with a hundred
   * open quotes has not earned anything.
   */
  function counts(o) {
    return !!o && !o.voidedAt && o.status !== 'quote';
  }

  /** Completed means the work is out of the shop, by either route. */
  function isDone(o) {
    return !!o && (o.status === 'completed' || o.status === 'delivered');
  }

  /**
   * The day the work left, for judging lateness.
   *
   * `completedAt` then `deliveredAt` then the order's own date. The fallback
   * chain matters: an order marked delivered without a delivery stamp still has
   * a day, and dropping it would count as "no due-date comparison possible"
   * rather than as late or on time.
   */
  function doneOn(o) {
    return String((o && (o.completedAt || o.deliveredAt || o.date)) || '').slice(0, 10);
  }

  /**
   * Was it on time? `null` — not `false` — when there is nothing to judge
   * against, so `computeKpis` leaves it out of the percentage instead of
   * counting it as a miss.
   */
  function onTime(o) {
    if (!isDone(o) || !o.dueDate) return null;
    const on = doneOn(o);
    return !!on && on <= o.dueDate;
  }

  /**
   * The rows `KhaytKpi.computeKpis` wants.
   *
   * @param {object} input
   * @param {object[]} input.orders
   * @param {string} [input.from] `YYYY-MM-DD`, inclusive; empty for unbounded
   * @param {string} [input.to]
   * @param {string} [input.locationId]  '' for every location
   * @param {(o: object) => string} [input.locationOf]  required to filter by location
   * @param {(o: object) => {revenue: number, cost: number, outstanding: number}} input.money
   *        per order, already in the shop's base currency
   * @param {(o: object) => string} [input.clientName]
   * @param {string} [input.unassigned]  what to call an order with no client
   */
  function kpiRows(input) {
    const inp = input || {};
    const orders = Array.isArray(inp.orders) ? inp.orders : [];
    const from = inp.from || '';
    const to = inp.to || '';
    const locId = inp.locationId || '';
    const locationOf = typeof inp.locationOf === 'function' ? inp.locationOf : null;
    const money = typeof inp.money === 'function' ? inp.money : () => ({});
    const clientName = typeof inp.clientName === 'function' ? inp.clientName : () => '';
    const unassigned = inp.unassigned || '—';
    // The shop's tax profile, when the host knows it. Given one, the revenue a
    // row carries is NET OF TAX — see the note on `revenue` below. Resolved
    // here rather than by each host so the dashboard, the P&L and the best
    // lists cannot come to different answers about what revenue means.
    const tax = inp.tax || (typeof global !== 'undefined' ? global.KhaytTax : null);
    const profile = inp.taxProfile
      || (tax && inp.settings ? tax.profileFromSettings(inp.settings) : null);

    return orders.filter((o) => {
      if (!counts(o)) return false;
      if (!inRange(o.date, from, to)) return false;
      // A location filter with no way to read an order's location matches
      // everything, rather than silently hiding the whole book.
      if (locId && locationOf && locationOf(o) !== locId) return false;
      return true;
    }).map((o) => {
      const m = money(o) || {};
      return {
        // NET OF TAX. Tax collected on a sale is money held for the government
        // — a liability until it is remitted, never income — so it has no place
        // in revenue, a margin, or an average order value. ZATCA and IFRS 15
        // both say so and Khayt's own accountant export has always split it.
        //
        // `netOfTax` is mode-aware: an exclusive-VAT shop's price IS the net
        // figure and comes back unchanged. `outstanding` below stays GROSS on
        // purpose — what a customer owes is what they were charged, tax and all.
        revenue: (tax && profile) ? tax.netOfTax(+m.revenue || 0, profile) : (+m.revenue || 0),
        cost: +m.cost || 0,
        completed: isDone(o),
        onTime: onTime(o),
        outstanding: +m.outstanding || 0,
        clientName: clientName(o) || unassigned,
        productName: o.project || o.id,
      };
    });
  }

  const api = { bounds, inRange, counts, isDone, doneOn, onTime, kpiRows };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytKpiRows = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
