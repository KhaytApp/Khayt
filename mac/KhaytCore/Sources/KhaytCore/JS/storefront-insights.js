'use strict';
/**
 * What the web store's visitors did, and what its customers said — read for
 * the storefront screen.
 *
 * Khayt Cloud answers two owner-only questions about a shop's public pages:
 *
 *   - `GET /v1/shops/{id}/sfstats` → `{ views, carts, orders, items: [{ id,
 *     name, views?, carts, orders }] }`, the storefront funnel;
 *   - `GET /v1/shops/{id}/reviews/all` → `{ reviews: [{ id, rating, comment,
 *     name, createdAt, verified }] }`, every review, with the ids a delete
 *     needs.
 *
 * Both were read inline in the desktop's Storefront dialog, so the Mac could
 * show neither without a second copy of the arithmetic. They are here now,
 * and both apps draw from them.
 *
 * PURE: no DOM, no network, no clock.
 */
(function (global) {

  /** How many products the "top products" list names. */
  const TOP_LIMIT = 5;

  const count = (v) => { const n = +v; return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0; };

  /**
   * The funnel as the screen shows it, or `{ empty: true }` when nobody has
   * looked at the store yet.
   *
   * `conversionPct` is orders over views, to one decimal; zero with no views.
   * `top` is the products that were carted or ordered, in the cloud's order
   * (it ranks them), at most five.
   */
  function insights(stats) {
    const s = stats && typeof stats === 'object' ? stats : {};
    const views = count(s.views);
    const carts = count(s.carts);
    const orders = count(s.orders);
    if (!views && !carts && !orders) return { empty: true, views: 0, carts: 0, orders: 0, conversionPct: 0, top: [] };
    const conversionPct = views > 0 ? Math.round((orders / views) * 1000) / 10 : 0;
    const top = (Array.isArray(s.items) ? s.items : [])
      .filter((it) => it && typeof it === 'object' && (count(it.orders) || count(it.carts)))
      .slice(0, TOP_LIMIT)
      .map((it) => ({
        id: String(it.id == null ? '' : it.id),
        name: String(it.name || it.id || ''),
        orders: count(it.orders),
        carts: count(it.carts),
      }));
    return { empty: false, views, carts, orders, conversionPct, top };
  }

  /** A review's stars, whole and between none and five. */
  function stars(rating) {
    const n = Math.round(+rating);
    return Number.isFinite(n) ? Math.max(0, Math.min(5, n)) : 0;
  }

  /**
   * The reviews as the list shows them: whole stars, the day it was left
   * (`YYYY-MM-DD`, as the cloud stamped it), and whether the reviewer was a
   * customer the shop actually served. Anything that is not a review with an
   * id is left out — a row with no id is a row that cannot be deleted.
   */
  function reviewRows(reviews) {
    return (Array.isArray(reviews) ? reviews : [])
      .filter((r) => r && typeof r === 'object' && r.id != null && String(r.id) !== '')
      .map((r) => ({
        id: String(r.id),
        stars: stars(r.rating),
        comment: String(r.comment == null ? '' : r.comment),
        name: String(r.name == null ? '' : r.name).trim(),
        day: String(r.createdAt == null ? '' : r.createdAt).slice(0, 10),
        verified: !!r.verified,
      }));
  }

  /**
   * The public page a shop sends a customer to rate it:
   * `{cloud}/review/{shopId}`. The average shows on the storefront.
   */
  function reviewLink(baseUrl, shopId) {
    const base = String(baseUrl || '').replace(/\/+$/, '');
    const id = String(shopId || '');
    if (!base || !id) return '';
    return base + '/review/' + encodeURIComponent(id);
  }

  const api = { TOP_LIMIT, insights, stars, reviewRows, reviewLink };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStorefrontInsights = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
