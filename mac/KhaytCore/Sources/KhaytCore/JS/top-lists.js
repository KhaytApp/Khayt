'use strict';
/**
 * Who the shop's best customers are, and what it sells most of.
 *
 * Two aggregations that were written out FOUR times in renderer/analytics.js —
 * the same client rollup at line 216 and again at 376, each with its own slice
 * and its own extra fields, and the product rollup beside them. Lifted so the
 * Mac app can show the same lists rather than form a second opinion about who
 * the shop's biggest customer is, which is the kind of disagreement nobody
 * notices until two people are looking at two screens.
 *
 * ## The two are NOT the same shape, and that is deliberate
 *
 * `topClients` is fed orders that have already been narrowed to completed,
 * un-voided, in-range trade, and counts every one of them. It answers "what has
 * this customer actually paid us", so it is sorted by revenue.
 *
 * `topProducts` is fed EVERY in-range order whatever its status, counts them
 * all, and adds revenue only for the ones that completed. It answers "what do
 * people ask us for", so it is sorted by count — a product quoted twenty times
 * and made twice is a fact about the shop worth seeing, and one sorted by
 * revenue would hide it.
 *
 * Both take the orders already filtered rather than doing it themselves: the
 * range and the business-scope rules belong to the screen asking, and a module
 * that re-derived them would be a second place for "which orders count" to
 * drift.
 */
(function (global) {

  /** `orderNetRevenueBase` through the same guard the renderer uses. */
  function money() {
    if (typeof require === 'function') {
      try { return require('./order-money.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytOrderMoney || null;
  }

  function languages() {
    if (typeof require === 'function') {
      try { return require('./content-languages.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytContentLanguages || null;
  }

  function scope() {
    if (typeof require === 'function') {
      try { return require('./business-scope.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytBusinessScope || null;
  }

  /**
   * A record's name in the shop's language — `localName` from the renderer,
   * which is `KhaytContentLanguages.read` with the same fallback chain, and the
   * id when there is no such record at all.
   *
   * A record that exists but has NO name filled in reads as an empty string,
   * not as its id. That is the behaviour these lists have always had; it is not
   * quietly changed here, because a blank row in a top-five list is a visible
   * prompt to go and name the thing, and a row labelled `PRD-0041` is not.
   */
  function nameOf(record, id, ctx) {
    if (!record) return String(id);
    const L = languages();
    // NO EN→AR FALLBACK HERE, not even for the module-absent case. Two
    // hard-coded languages is the shape that mailed a German shop's client list
    // a message opening "Hi ," — `content-languages` is the answer, it is a
    // hard dependency of this module (listed before it in every host), and if
    // it is somehow missing the id is an honest label where a guess is not.
    if (!L || typeof L.read !== 'function') return String(id);
    return L.read(record, 'name', ctx && ctx.language, (ctx && ctx.settings) || null);
  }

  function revenueOf(order, ctx) {
    const M = money();
    if (!M || typeof M.orderNetRevenueBase !== 'function') return 0;
    const settings = (ctx && ctx.settings) || {};
    const value = M.orderNetRevenueBase(order, {
      settings,
      clients: (ctx && ctx.clients) || [],
    }, (ctx && ctx.currencies) || null);
    const charged = Number.isFinite(+value) ? +value : 0;
    // NET OF TAX, like every other place that says "revenue". Tax collected on
    // a sale belongs to the government, so a list of best customers ranked and
    // TOTALLED by revenue must not count it. The order of the list barely moves
    // — one rate divides everything alike — but the figures beside the names
    // are money, and they have to be the same money the P&L and the dashboard
    // report. `netOfTax` leaves an exclusive-VAT shop's prices alone.
    const T = (typeof global !== 'undefined' && global.KhaytTax) || null;
    if (!T || typeof T.netOfTax !== 'function') return charged;
    return T.netOfTax(charged, T.profileFromSettings(settings));
  }

  /** Does this order count as trade? Everything counts when the module is absent. */
  function countsForBusiness(order) {
    const S = scope();
    return !S || typeof S.countsForBusiness !== 'function' ? true : !!S.countsForBusiness(order);
  }

  /**
   * How many rows the caller wants. Five, which is what the simple screen
   * shows; the executive overview asks for eight, and asking for none means
   * none — `|| 5` read a zero as "unspecified" and handed back five.
   */
  function howMany(options) {
    const wanted = options && options.limit;
    const n = Number(wanted);
    if (wanted === undefined || wanted === null || !Number.isFinite(n)) return 5;
    return Math.max(0, Math.floor(n));
  }

  function rollUp(orders, key) {
    const agg = new Map();
    for (const order of Array.isArray(orders) ? orders : []) {
      const id = order && order[key];
      if (!id) continue;
      if (!agg.has(id)) agg.set(id, { id, count: 0, revenue: 0 });
      agg.get(id).count += 1;
    }
    return agg;
  }

  /**
   * The shop's best customers by what they have paid.
   *
   * @param {object[]} completed orders already narrowed to completed, un-voided,
   *                             in-range trade — the screen's filter, not this
   *                             module's.
   * @param {{settings?:object, clients?:object[], currencies?:object, language?:string}} ctx
   * @param {{limit?:number}} [options]
   */
  function topClients(completed, ctx, options) {
    const limit = howMany(options);
    const agg = rollUp(completed, 'clientId');
    for (const order of Array.isArray(completed) ? completed : []) {
      if (!order || !order.clientId) continue;
      agg.get(order.clientId).revenue += revenueOf(order, ctx);
    }
    const clients = (ctx && ctx.clients) || [];
    return [...agg.values()]
      .map((row) => ({
        ...row,
        name: nameOf(clients.find((c) => c && c.id === row.id), row.id, ctx),
      }))
      // Ties keep the order they were first seen in, which is what a stable
      // sort over `Object.entries` gave the two screens this was lifted from.
      .sort((a, b) => b.revenue - a.revenue)
      .slice(0, limit);
  }

  /**
   * What the shop is asked for most.
   *
   * @param {object[]} orders every in-range order, whatever its status.
   * @param {{settings?:object, products?:object[], clients?:object[], currencies?:object, language?:string}} ctx
   * @param {{limit?:number}} [options]
   */
  function topProducts(orders, ctx, options) {
    const limit = howMany(options);
    const agg = rollUp(orders, 'productId');
    for (const order of Array.isArray(orders) ? orders : []) {
      if (!order || !order.productId) continue;
      // Revenue only from what was actually made and billed. The COUNT is every
      // order — see the note at the top.
      if (order.status !== 'completed' || order.voidedAt || !countsForBusiness(order)) continue;
      agg.get(order.productId).revenue += revenueOf(order, ctx);
    }
    const products = (ctx && ctx.products) || [];
    return [...agg.values()]
      .map((row) => ({
        ...row,
        name: nameOf(products.find((p) => p && p.id === row.id), row.id, ctx),
      }))
      .sort((a, b) => b.count - a.count)
      .slice(0, limit);
  }

  const api = { topClients, topProducts };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytTopLists = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
