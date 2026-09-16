'use strict';

/**
 * What a customer has agreed to pay for a thing, applied to the cart.
 *
 * A customer's record can carry a price list — "brackets: 12.50", "any
 * keychain: 8" — and when that customer is chosen for a job, each part whose
 * name contains one of those products takes the agreed figure. The match is
 * by name, case-insensitively, and the FIRST entry whose product the part's
 * name contains is the one that counts, even when its price is zero: a shop
 * that wrote a product down with no price has said "this one is not agreed",
 * and a later entry must not quietly stand in for it.
 *
 * ── WHERE THE FIGURE LANDS ────────────────────────────────────────────────
 *
 * On the part as `agreedPrice`, per unit — and nowhere else. The part's cost
 * (`unitCost`, `baseCost`) stays what it cost, and the pricing rule
 * (`lib/pricing.js`, through `lib/order-new.js`) charges the agreed figure for
 * that part instead of cost plus margin. Until 2026-09-16 the renderer wrote
 * the agreed figure INTO the cost, so the job's margin went on top of it: a
 * part agreed at 50 on a 30% job billed 65, and the profit report then showed
 * the part sold at cost. Both were wrong, and the shop had to notice the total.
 * The price is the price now, in both apps.
 *
 * PURE apart from the parts it is handed, which it mutates in place — the
 * cart in the Electron window is the array the form is drawn from.
 */
(function (global) {

  const listOf = (v) => (Array.isArray(v) ? v : []);

  /**
   * The agreement that covers a part with this name, or null.
   *
   * Null for a nameless part, for an entry with no product, and — see above —
   * when the first entry whose product the name contains has no price.
   */
  function find(priceList, name) {
    const wanted = String(name || '').toLowerCase();
    if (!wanted) return null;
    const entry = listOf(priceList).find(p => p && p.product
      && wanted.includes(String(p.product).toLowerCase()));
    return entry && +entry.price > 0 ? entry : null;
  }

  /**
   * Apply a customer's agreements to a cart. Returns how many parts took one,
   * so a host can say "price agreement applied" only when one was. A part with
   * no agreement is left exactly as it was — including an `agreedPrice` a
   * previous customer left on it, which is cleared, because the cart now
   * belongs to this customer.
   */
  function apply(parts, priceList) {
    let applied = 0;
    for (const part of listOf(parts)) {
      if (!part) continue;
      const entry = find(priceList, part.name);
      if (!entry) { delete part.agreedPrice; continue; }
      part.agreedPrice = +entry.price;
      applied++;
    }
    return applied;
  }

  const api = { find, apply };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPriceAgreements = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
