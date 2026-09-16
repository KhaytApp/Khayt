'use strict';

/**
 * Cost → price. The one place that decides what a customer is asked to pay.
 *
 * This arithmetic lived inside `renderer/build.js`, interleaved with reading
 * `<input>` values and writing `textContent`. That made it unreachable from
 * anywhere else: the LAN quote endpoint can cost a part with the desktop's own
 * maths (`lib/calculator-cost.js`) but could not turn that cost into a
 * price without reimplementing this — and a second implementation means two
 * prices for one job, with the wrong one being whichever the shop happens to be
 * looking at.
 *
 * Extracted verbatim, not redesigned. The order of operations is load-bearing
 * and is preserved exactly:
 *
 *     priceBeforeDiscount = tier ? tier.pricePerUnit × qty : baseCost × (1 + margin%)
 *     discount            = priceBeforeDiscount × discount%
 *     subtotal            = priceBeforeDiscount − discount
 *     rushFee             = subtotal × rush%          ← after the discount, not before
 *     total               = subtotal + rushFee + shipping + extras
 *
 * Rush is charged on the discounted subtotal, and shipping and extras are added
 * after it, so neither is discounted or rushed. Those are business decisions
 * already baked into shipped quotes; changing them here would silently reprice
 * every future job.
 *
 * PERCENTAGE EXTRAS (added 2026-08-09). An extra line may carry `pct` instead of
 * `amount` — a marketplace fee is a percentage, not a number the shop can know
 * before the price exists. Two decisions, both load-bearing:
 *
 *   The base is `subtotal + rushFee + shipping` — everything the buyer pays
 *   before extras. That is what Etsy and Shopify actually charge against: their
 *   fee includes the shipping the buyer was charged. Taking a percentage of the
 *   subtotal alone would under-state every quote that ships.
 *
 *   Percentages never compound. Every percentage line uses that same base, so
 *   two lines of 5% are 10%, not 10.25%, and REORDERING THE LINES CANNOT CHANGE
 *   THE TOTAL. A quote whose total depends on the order rows were typed in is
 *   indefensible when a customer asks why.
 *
 * A line is a percentage if and only if it carries a positive `pct`; otherwise
 * it is `amount`, exactly as before. Existing quotes have no `pct` and are
 * arithmetically untouched — test/pricing.test.js pins that against the original
 * formula over the same 4,000 randomised cases.
 *
 * VAT is deliberately absent — it is applied at invoicing, not in the
 * calculator, so a quote total is pre-VAT and stays that way.
 *
 * AGREED PRICES, ROUNDING AND A TYPED PRICE (added 2026-09-16). Three inputs,
 * each absent on every quote already sent and arithmetically inert when absent:
 *
 *   `agreedAmount` — the sum of the parts a CUSTOMER has agreed a price for
 *   (`agreedPrice × qty`, resolved by the caller from `lib/price-agreements.js`).
 *   A negotiated price is the price: it joins the subtotal AFTER the discount,
 *   so a customer's standing discount does not quietly cut a figure that was
 *   already negotiated, and it is not marked up. The rush fee, shipping and
 *   extras apply to it as to everything else — a surcharge for priority is not
 *   part of the price of a bracket.
 *
 *   `priceRound: { step, mode }` — the total is rounded to a multiple of `step`
 *   (nearest / up / down), the same rule and the same steps a product's price
 *   uses (`lib/product-price.js`). A shop that quotes 1,847.36 does not want to
 *   say 1,847.36; it wants to say 1,850 and know it did.
 *
 *   `priceOverride` — a typed total, used as is. A shop that has just agreed
 *   1,800 on the phone types 1,800.
 *
 * `total` is what the customer pays. `computedTotal` is what the arithmetic
 * said before rounding or the typed figure, kept so a screen can show
 * "Calculated 1,847.36" beside "1,850" and the shop can tell a healthy margin
 * from a rounding accident. `priceSource` says which: base / rounded / override.
 */

// Wrapped, like every other lib/ module the renderer loads. Plain <script> tags
// share one global scope, so a top-level `const api` here collides with the same
// name in another module and the whole file fails to parse with
// "Identifier 'api' has already been declared" — taking its exports with it.
// Caught by scripts/e2e-populated-screens-smoke.mjs, which is the only check
// that loads every script together the way the app does.
(function () {

/** `num()` from renderer/format.js, duplicated so this file has no DOM lineage. */
function num(v, fallback = 0) {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : fallback;
}
const clampPositive = (v) => Math.max(0, num(v, 0));

/**
 * @param {object} input
 * @param {number} input.baseCost      Total COST of the line or cart (already × qty).
 * @param {number} [input.qty=1]       Units — only used when a price tier applies.
 * @param {number} [input.margin=0]    Percent markup on cost. Ignored when a tier applies.
 * @param {{pricePerUnit:number}|null} [input.priceTier]  Fixed per-unit price that
 *        REPLACES cost-plus-margin. The caller decides whether it applies: in the
 *        desktop a tier is honoured only for a single live part, never for a
 *        multi-line cart, and that rule stays with the caller that knows it.
 * @param {number} [input.discountPct=0]
 * @param {boolean} [input.rushEnabled=false]
 * @param {number} [input.rushPct=0]
 * @param {number} [input.shippingCost=0]
 * @param {Array<{amount:number}>} [input.extraLines=[]]
 * @param {boolean} [input.business=true] False for the commerce-free (hobbyist)
 *        experience, which prices nothing: no margin, discount, fees or extras,
 *        so the "total" is pure cost. Zeroing here rather than at each call site
 *        is what stops a business surface leaking into that build.
 * @returns {{priceBeforeDiscount:number, discountAmount:number, subtotal:number,
 *            rushFee:number, shipping:number, extras:number, total:number}}
 */
/**
 * A line is a percentage only when it says so with a positive `pct`.
 *
 * Absence is what every existing quote has, so absence must keep meaning
 * "fixed". A zero or negative pct is not a percentage line either — it would
 * contribute nothing and hide an `amount` that was meant to apply.
 */
function isPercentLine(l) {
  return !!l && num(l.pct) > 0;
}

function quoteTotal(input) {
  const i = input || {};
  const business = i.business !== false;
  const qty = Math.max(1, Math.round(num(i.qty, 1)));
  const baseCost = clampPositive(i.baseCost);

  const margin = business ? clampPositive(i.margin) : 0;
  const discountPct = business ? Math.min(100, clampPositive(i.discountPct)) : 0;
  const rushPct = business && i.rushEnabled ? clampPositive(i.rushPct) : 0;
  const shipping = business ? clampPositive(i.shippingCost) : 0;
  const lines = business && Array.isArray(i.extraLines) ? i.extraLines : [];
  // Fixed lines total as they always have. Percentage lines are resolved below,
  // once there is a base to take a percentage OF.
  const extrasFixed = lines.reduce(
    (s, l) => s + (isPercentLine(l) ? 0 : clampPositive(l && l.amount)), 0);

  const tier = i.priceTier;
  const priceBeforeDiscount = tier
    ? clampPositive(tier.pricePerUnit) * qty
    : baseCost * (1 + margin / 100);

  const discountAmount = priceBeforeDiscount * discountPct / 100;
  // What the customer has already agreed is not discounted again — see above.
  const agreed = business ? clampPositive(i.agreedAmount) : 0;
  const subtotal = priceBeforeDiscount - discountAmount + agreed;
  const rushFee = subtotal * rushPct / 100;

  // What the buyer pays before extras — the base every percentage line uses.
  // Fixed extras are NOT in it, or a percentage would depend on how many fixed
  // lines happened to be above it.
  const extrasBase = subtotal + rushFee + shipping;
  const extrasPercent = lines.reduce(
    (s, l) => s + (isPercentLine(l) ? extrasBase * clampPositive(l.pct) / 100 : 0), 0);
  const extras = extrasFixed + extrasPercent;
  const computedTotal = subtotal + rushFee + shipping + extras;

  // The last word: a typed figure, else the rounding rule, else the arithmetic.
  // Neither in the hobbyist build, which prices nothing to round.
  let total = computedTotal;
  let priceSource = 'base';
  const override = business ? optional(i.priceOverride) : null;
  const round = business && i.priceRound ? i.priceRound : null;
  if (override !== null && override >= 0) {
    total = Math.round(override * 100) / 100;
    priceSource = 'override';
  } else if (round && clampPositive(round.step) > 0) {
    total = roundToStep(computedTotal, clampPositive(round.step), round.mode);
    priceSource = 'rounded';
  }

  return {
    priceBeforeDiscount,
    discountAmount,
    agreedAmount: agreed,
    subtotal,
    rushFee,
    shipping,
    extras,
    // Broken out so a screen can show "6.5% (SAR 12.50)" the way the rush chip
    // already does, without recomputing the base and risking a different answer.
    extrasFixed,
    extrasPercent,
    extrasBase,
    computedTotal,
    priceSource,
    total,
  };
}

/** null, undefined and '' are ABSENT, not zero — a cleared box is not a free job. */
function optional(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * Round to a multiple of `step`, the way a product's price is rounded.
 *
 * The product rule is the authority and is used when it is loaded; the copy
 * below is the same arithmetic for a build that has this module alone, and
 * `test/pricing.test.js` holds the two to the same answers. The epsilon is the
 * part that matters: 45 / 5 is 9.000000000000002 for plenty of real prices,
 * and without it a total already on a multiple rounds UP to the next one.
 */
function roundToStep(value, step, mode) {
  const P = typeof globalThis !== 'undefined' ? globalThis.KhaytProductPrice : undefined;
  if (P && typeof P.roundToStep === 'function') return P.roundToStep(value, step, mode);
  const q = value / step;
  const EPS = 1e-9;
  const nearWhole = Math.abs(q - Math.round(q)) < EPS;
  const raw = nearWhole ? Math.round(q)
    : (mode === 'up' ? Math.ceil(q) : mode === 'down' ? Math.floor(q) : Math.round(q));
  return Math.round(raw * step * 100) / 100;
}

/**
 * Resolve each line to money, for rendering.
 *
 * Returns the SAME numbers quoteTotal used — a second computation in the view is
 * how a breakdown ends up not adding up to the total above it.
 */
function resolveExtraLines(lines, extrasBase) {
  const base = clampPositive(extrasBase);
  return (Array.isArray(lines) ? lines : []).map((l) => (isPercentLine(l)
    ? { label: (l && l.label) || '', pct: clampPositive(l.pct), amount: base * clampPositive(l.pct) / 100 }
    : { label: (l && l.label) || '', pct: null, amount: clampPositive(l && l.amount) }));
}

/**
 * The tier that applies at this quantity, or null.
 *
 * Tiers with a zero or missing minQty/pricePerUnit are ignored — a half-filled
 * tier row in the UI must not silently price a job at zero.
 */
function activePriceTier(tiers, qty) {
  const usable = (Array.isArray(tiers) ? tiers : [])
    .filter((t) => t && num(t.minQty) > 0 && num(t.pricePerUnit) > 0);
  if (!usable.length) return null;
  const q = Math.max(1, Math.round(num(qty, 1)));
  return [...usable].sort((a, b) => num(b.minQty) - num(a.minQty))
    .find((t) => q >= num(t.minQty)) || null;
}

const pricingApi = { quoteTotal, activePriceTier, resolveExtraLines, isPercentLine, roundToStep };
if (typeof module !== 'undefined' && module.exports) module.exports = pricingApi;
if (typeof globalThis !== 'undefined') globalThis.KhaytPricing = pricingApi;

})();
