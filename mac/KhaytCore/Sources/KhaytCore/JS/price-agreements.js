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
 * ── WHERE THE FIGURE LANDS, AND WHY THAT IS SAID OUT LOUD ────────────────
 *
 * The agreed figure is written as the part's unit COST (`unitCost`, and
 * `baseCost` = cost × qty), which is what `renderer/wire-events.js` has always
 * done — and the job is then priced by the ordinary rule, cost plus the job's
 * margin. So a part agreed at 50 on a job quoted at 30% margin comes to 65
 * before discount. The shop sees that total on the form before saving and can
 * set the margin; nothing is hidden. But it means "price agreement" is, as
 * the book stores it, an agreed COST. Whether the rule ought to replace
 * cost-plus-margin for that part instead is a pricing question with a data
 * migration behind it (`lib/pricing.js` prices a cart, not a part), and this
 * module does not decide it — it makes both apps give the same answer, and
 * names the question in its test so it is not forgotten.
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
   * so a host can say "price agreement applied" only when one was.
   */
  function apply(parts, priceList) {
    let applied = 0;
    for (const part of listOf(parts)) {
      const entry = find(priceList, part && part.name);
      if (!entry) continue;
      part.unitCost = +entry.price;
      part.baseCost = +entry.price * (+part.qty || 1);
      applied++;
    }
    return applied;
  }

  const api = { find, apply };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPriceAgreements = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
