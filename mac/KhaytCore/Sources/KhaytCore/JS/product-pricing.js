'use strict';
(function (global) {

/**
 * What a catalogue product costs the shop, and what it is therefore worth.
 *
 * ── WHY THIS IS A FILE AND NOT A FUNCTION IN A SCREEN ─────────────────────
 *
 * It was `productDefaultPricing` in `renderer/inventory.js`, which was fine
 * while one app had a product editor. The Mac grew one, and the hole showed
 * immediately: a product written down there came back priced 0.00 with no
 * hours and no grams, because nothing on that side summed its parts.
 *
 * A product's price is not typed. It is COMPUTED — the calculator's per-part
 * cost summed over the parts, plus any bought-in components, plus the shop's
 * margin, then whatever rounding the shop has asked for. Two apps computing
 * that separately is two prices for one product, and the one the customer sees
 * depends on which app last saved it.
 *
 * Pure: no DOM, no fs. The two things it cannot do itself — cost one part, and
 * round a final price — are `KhaytCalculatorCost` and `KhaytProductPrice`,
 * reached through globals the way every module in this folder reaches another.
 */

const num = (v, fallback) => {
  const n = +v;
  return Number.isFinite(n) ? n : fallback;
};

/**
 * Price one product.
 *
 * @param {object} product   the record, with `parts` and `defaultMargin`
 * @param {object} opts      `inventory` and `settings` for the cost context
 *                           (NOT optional in practice — see below) and
 *                           `consumables` for the BOM
 * @returns {{cost:number, basePrice:number, price:number, priceSource:string,
 *            parts:number, hours:number, grams:number}}
 */
function priceProduct(product, opts) {
  const d = product || {};
  opts = opts || {};
  const list = Array.isArray(d.parts) ? d.parts : [];

  const CC = (typeof global !== 'undefined' && global.KhaytCalculatorCost) || null;

  /* ── THE CONTEXT IS NOT OPTIONAL, WHATEVER THE SIGNATURE SAYS ─────────────
   *
   * `computePartBaseCost(part, ctx)` falls back to `global.inventory` and
   * `global.settings` when ctx is absent. Those exist in the RENDERER and in no
   * other host — under JavaScriptCore they are undefined, so the fallback is an
   * empty shelf and empty settings.
   *
   * That is not a missing number, it is a WRONG one. The resin branch is chosen
   * by looking the part's filament up in the inventory, and the two branches are
   * different formulas — resin is `cost/1000 x grams`, filament is
   * `cost/spoolWeight x grams`. Measured: a 120 g resin part off a 500 g bottle
   * at 220 costs 105.85 with the shelf and 134.89 without it. The direction
   * depends on the recorded weight and the two agree only at exactly 1000 g,
   * which is why this looks correct in a casual test. The renderer never saw
   * any of it, because its globals happened to be there.
   *
   * ── AND NO RATES ARE INJECTED, DELIBERATELY ─────────────────────────────
   *
   * A first draft merged `print-rates` defaults under each part, the way
   * `costPart` does for a JOB's part. That is a behaviour change wearing a
   * refactor's clothes: `productDefaultPricing` never did it, so every
   * catalogue product in every existing shop would have gained labour, power
   * and wear it was not priced with, and every price would have moved on the
   * next save. A lift must return what it replaced.
   *
   * A product's part is costed with whatever rates it carries. Where it carries
   * none, those terms are zero — which is what the shop has been charging.
   */
  const ctx = { inventory: opts.inventory || [], settings: opts.settings || {} };

  const partsCost = list.reduce((sum, p) => {
    if (CC && typeof CC.computePartBaseCost === 'function') {
      return sum + (+CC.computePartBaseCost(p, ctx) || 0);
    }
    return sum + (+p.baseCost || 0);
  }, 0);

  // Non-printed components folded into the unit cost, for a product that is an
  // assembly rather than a single print. Same module as the per-part cost —
  // `computeComponentsCost` lives in `calculator-cost`, not in `assembly`,
  // which is where I looked first and would have silently costed every BOM
  // product at its printed parts alone.
  const compCost = (CC && typeof CC.computeComponentsCost === 'function')
    ? (+CC.computeComponentsCost(d.components, opts.consumables || []) || 0)
    : 0;

  const cost = partsCost + compCost;
  const margin = Math.max(0, num(d.defaultMargin, 30));
  const basePrice = +(cost * (1 + margin / 100)).toFixed(2);

  // `basePrice` is cost plus margin and stays that. `price` is what the shop
  // CHARGES, after its own rounding. Keeping both is the point: a shop that can
  // only see its rounded price cannot tell a healthy margin from a rounding
  // accident.
  const PP = (typeof global !== 'undefined' && global.KhaytProductPrice) || null;
  const fp = (PP && typeof PP.finalPrice === 'function')
    ? PP.finalPrice(d, basePrice)
    : { final: basePrice, source: 'base' };

  // The specs a catalogue row shows, from the same parts the cost came from —
  // so a product can never show a price without the work behind it, or hours
  // without a price.
  let hours = 0, grams = 0;
  for (const p of list) {
    const qty = Math.max(1, num(p.qty, 1));
    hours += num(p.printTime, 0) * qty;
    grams += (num(p.printWeight, 0) + num(p.supportWeight, 0)) * qty;
  }

  return {
    cost: +cost.toFixed(2),
    basePrice,
    price: fp.final,
    priceSource: fp.source,
    parts: list.length,
    hours: +hours.toFixed(2),
    grams: +grams.toFixed(2),
  };
}

/**
 * The fields `priceProduct` owns on a product record.
 *
 * Returned separately so a caller writes exactly these and nothing else — a
 * save that spread the whole answer onto the record would put `parts` (a
 * count) over `parts` (the list), which is the shape of bug that eats data.
 */
function pricingFields(product, opts) {
  const p = priceProduct(product, opts);
  return { baseCost: p.cost, basePrice: p.basePrice, price: p.price };
}

const api = { priceProduct, pricingFields };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytProductPricing = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
