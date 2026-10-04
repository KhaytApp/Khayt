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
    if (!o || o.voidedAt || o.status === 'quote') return false;
    /* A CANCELLED JOB IS NOT AN ORDER. It never reached revenue (it is not
     * done), but `orderCount` is every row and `outstanding` is summed over
     * every row — so a cancelled 400 SAR job counted as an order and as 400
     * owed, money nobody will ever be asked for. */
    if (o.status === 'cancelled') return false;
    /* NOR IS WORK THAT IS NOT THE SHOP'S TRADE. The P&L and product profit
     * already leave out a job marked Not business (lib/business-scope.js),
     * and these tiles did not: a shop that marked its nineteen test prints
     * saw the P&L go to 28% while the dashboard kept its cost, its count and
     * a −495% margin. Read through the global so a host that has not loaded
     * business-scope counts as before rather than failing. */
    const scope = global.KhaytBusinessScope;
    if (scope && typeof scope.countsForBusiness === 'function' && !scope.countsForBusiness(o)) return false;
    return true;
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
    const raw = String((o && (o.completedAt || o.deliveredAt || o.date)) || '');
    return localDayOf(raw);
  }

  /**
   * The LOCAL day a stamp falls on. `completedAt` is an ISO instant, and its
   * first ten characters are the UTC day — in Riyadh, yesterday until 03:00.
   * A job finished at 01:30 on the 6th and due on the 5th was counted on time
   * here and late on the On-time card, which reads the local day. A bare
   * `YYYY-MM-DD` is already the shop's day and is read as written.
   */
  function localDayOf(raw) {
    const s = String(raw || '');
    if (s.length > 10 && /^\d{4}-\d{2}-\d{2}T/.test(s)) {
      const d = new Date(s);
      if (!isNaN(d.getTime())) return ymd(d);
    }
    return s.slice(0, 10);
  }

  /** Load a sibling module the way the host has it: a global, else require. */
  function sibling(name, file) {
    if (global[name]) return global[name];
    try { return require(file); } catch (_) { return null; }
  }

  /**
   * What a job cost to make, for the dashboard's cost and margin — ONE rule.
   *
   * The two apps had two: Khayt summed each part's computed cost
   * (`partTotalCost`) and added shipping; the Mac summed `unitCost × qty`,
   * which only a line priced from a product carries, and left shipping out.
   * So the same book showed two different margins.
   *
   * Per part: its cost as costed (`lib/calculator-cost.js`), or — a line with
   * no costing inputs, priced from a product's unit cost — `unitCost` (else the
   * frozen `baseCost`) × qty. Then the P&L's stocked share
   * (`lib/pnl-report.js stockShare`), then shipping in the base currency.
   *
   * `ctx`: `{ settings, inventory, clients, known, consumables }`.
   * `consumables` is the shelf a part's own consumables (magnets, inserts) are
   * priced from; a host without one in reach leaves it out and each line is
   * priced at the `unitCost` written on it (`calculator-cost`). The Mac hands
   * its shelf over, so the two apps cost the same job the same.
   *
   * NOT `order.componentsCost`. This is the dashboard's cost of goods, and a
   * product's components are bought as an EXPENSE (`lib/purchase-orders.js`
   * books a consumable purchase under `other`, not as stock) — so they reach
   * the P&L once, as what was paid, exactly as `pnl-report` counts them.
   */
  function orderCost(o, ctx) {
    const c = ctx || {};
    const order = o || {};
    const CC = sibling('KhaytCalculatorCost', './calculator-cost.js');
    const P = sibling('KhaytPnl', './pnl-report.js');
    const M = sibling('KhaytOrderMoney', './order-money.js');
    const costCtx = { inventory: c.inventory || [], settings: c.settings || {} };
    if (Array.isArray(c.consumables)) costCtx.consumables = c.consumables;
    let parts = 0;
    for (const p of Array.isArray(order.parts) ? order.parts : []) {
      if (!p) continue;
      const qty = Math.max(1, +p.qty || 1);
      let each = 0;
      if (CC && typeof CC.partTotalCost === 'function') {
        try { each = CC.partTotalCost(p, costCtx) / qty; } catch (_) { each = 0; }
      }
      // Packaging alone is not a costing: a product line has no inputs and
      // would otherwise read as a few halalas.
      const hasInputs = (+p.spoolCost || 0) > 0 || (+p.printTime || 0) > 0
        || (+p.prepTime || 0) > 0 || (+p.postTime || 0) > 0
        || (Array.isArray(p.extraMaterials) && p.extraMaterials.length > 0);
      if (!hasInputs || !(each > 0)) each = (+p.unitCost || 0) > 0 ? +p.unitCost : Math.max(0, +p.baseCost || 0);
      parts += each * qty;
    }
    const share = (P && typeof P.stockShare === 'function') ? P.stockShare(order, costCtx) : 1;
    const moneyCtx = { settings: c.settings || {}, clients: c.clients || [] };
    const shipping = M
      ? M.convertToBase(+order.shippingCost || 0, M.orderCurrency(order, moneyCtx, c.known), moneyCtx)
      : (+order.shippingCost || 0);
    return parts * share + shipping;
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

  const api = { bounds, inRange, counts, isDone, doneOn, localDayOf, onTime, orderCost, kpiRows };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytKpiRows = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
