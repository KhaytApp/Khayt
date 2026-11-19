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

/** lib/print-rates.js, by whichever route this host loads modules. */
const printRates = () => {
  if (typeof global !== 'undefined' && global.KhaytPrintRates) return global.KhaytPrintRates;
  if (typeof require === 'function') {
    try { return require('./print-rates.js'); } catch (e) { return null; }
  }
  return null;
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
const RATE_KEYS = ['laborRate', 'prepTime', 'postTime', 'wearRate', 'powerDraw', 'elecRate', 'failureRate'];
/** A rate field the product or part actually says (a number), not blank. */
const said = (v) => v !== undefined && v !== null && v !== '' && Number.isFinite(+v);
/** Whether the product is costed the new way: it carries its own `rates`. */
function usesProductRates(product) {
  const r = product && product.rates;
  return !!(r && typeof r === 'object' && !Array.isArray(r));
}
/** The product's own rates, the fields it says. */
function productRateDefaults(product) {
  const r = (product && product.rates) || {};
  const out = {};
  for (const k of RATE_KEYS) if (said(r[k])) out[k] = +r[k];
  return out;
}
/** A part without its blank rate fields, so the product's rate shows through. */
function stripUnset(part) {
  const p = Object.assign({}, part || {});
  for (const k of RATE_KEYS) if (!said(p[k])) delete p[k];
  return p;
}
/**
 * The labour a product with its own rates carries ONCE:
 * (prepTime + postTime) × laborRate × (1 + failureRate / 100), from the
 * product's rates with the shop's defaults under them (KhaytPrintRates).
 * 0 for a product without rates, or with `labourPerPart` (its labour is in
 * each part then).
 *
 * The product's prep and post hours are its own (`rates.prepTime`,
 * `rates.postTime`): a PART's own prep or post is not used under once-labour
 * (money review of #2575, finding 4), as the Mac sheet says. Under
 * `labourPerPart` each part's own hours count, as before.
 */
/** How many of a product: `opts.units`, a whole number ≥ 1 (1 when unsaid). */
function unitsOf(opts) {
  const n = Math.floor(+(opts && opts.units) || 1);
  return n >= 1 ? n : 1;
}

function moneyRules() {
  const g = (typeof global !== 'undefined' && global.KhaytOrderMoney) || null;
  const Mo = g || (typeof require === 'function' ? (() => { try { return require('./order-money.js'); } catch (_) { return null; } })() : null);
  if (!Mo || typeof Mo.lineLabour !== 'function') throw new Error('KhaytOrderMoney.lineLabour is not loaded');
  return Mo;
}

function productLabourCost(product, opts) {
  if (!usesProductRates(product) || product.labourPerPart === true) return 0;
  const PRt = printRates();
  const settings = (opts && opts.settings) || {};
  const r = PRt ? PRt.withRates(productRateDefaults(product), { settings }) : productRateDefaults(product);
  // The product is the LINE: prep once, post/assembly per finished product
  // (`opts.units`, how many of it; 1 by default). The parts' own qty do not
  // multiply post (Turki, Nov 19). KhaytOrderMoney.lineLabour is the rule.
  const Mo = moneyRules();
  const line = Mo.lineLabour({ prepTime: r.prepTime, postTime: r.postTime, laborRate: r.laborRate, qty: unitsOf(opts) });
  return line * (1 + Math.max(0, +r.failureRate || 0) / 100);
}

/**
 * What a product with its own rates carries ONCE: its labour and the shop's
 * packaging (one box per product), each with the product's failure buffer, as
 * the calculator charges them on a single item. 0 for a product without
 * rates or with `labourPerPart` (both are in each part then).
 */
function productOnceCost(product, opts) {
  return productLabourCost(product, opts) + productPackagingCost(product, opts);
}

/** The shop's packaging, once for a product with its own rates, with its failure buffer; 0 otherwise. */
function productPackagingCost(product, opts) {
  if (!usesProductRates(product) || product.labourPerPart === true) return 0;
  const PRt = printRates();
  const settings = (opts && opts.settings) || {};
  const r = PRt ? PRt.withRates(productRateDefaults(product), { settings }) : productRateDefaults(product);
  // One box per finished product: N of it are N boxes, as the Mac charges a
  // store line of N today.
  return Math.max(0, +settings.defaultPackagingCost || 0) * (1 + Math.max(0, +r.failureRate || 0) / 100) * unitsOf(opts);
}

/** A product part with its rates merged as priceProduct costs it (part > product > shop). */
function ratedPart(product, raw, settings) {
  const PRt = printRates();
  const merged = usesProductRates(product) ? Object.assign({}, productRateDefaults(product), stripUnset(raw)) : raw;
  return PRt ? PRt.withRates(merged, { settings }) : merged;
}

/**
 * What a JOB taken from the product starts with, so that lib/order-new.js
 * newOrder prices it exactly as the catalogue prices the product (money
 * review of #2575). Returns { parts, labourCost, packagingCost }:
 *   parts          each part rated (part > product > shop) and costed WITHOUT
 *                  labour and packaging for a product with its own rates
 *                  (`unitCost` a piece, `baseCost` the line, to 4 places);
 *                  as it always was for one without (or with labourPerPart);
 *   labourCost,    the product's labour and packaging, ONCE: ORDER-level
 *   packagingCost  costs (Dev Hub, Nov 19), not a part. A "labour" part
 *                  broke every part walker (assembly completion, reprints,
 *                  file links). 0 for a product without rates.
 * Pass all three to newOrder.
 */
function productJobParts(product, opts) {
  // `opts.units`: how many of the product the job makes (1 by default): each
  // part's qty × units, and the once-costs for that many (productLabourCost).
  const units = unitsOf(opts);
  const d = product || {};
  const CC = (typeof global !== 'undefined' && global.KhaytCalculatorCost) || null;
  const ctx = { inventory: (opts && opts.inventory) || [], settings: (opts && opts.settings) || {}, consumables: (opts && opts.consumables) || [], units };
  const once = usesProductRates(d) && d.labourPerPart !== true;
  const o = once ? { labour: false, packaging: false } : undefined;
  const parts = (Array.isArray(d.parts) ? d.parts : []).filter(Boolean).map((raw) => {
    const p = Object.assign({}, ratedPart(d, raw, ctx.settings));   // never the product's own part
    // Costed at the line's real qty: a per-piece share (packaging, and under
    // labourPerPart its labour) depends on it.
    p.qty = Math.max(1, +p.qty || 1) * units;
    const unit = CC ? +CC.computePartBaseCost(p, ctx, o) || 0 : +p.unitCost || 0;
    const qty = p.qty;
    // To 4 places, not 2: newOrder sums the lines, and 15 lines each rounded
    // to the halala came to 0.01 more than the catalogue's one rounding.
    // `orderLevelCosts`: this part's labour and packaging are on the order, so
    // anything that costs it again leaves them out (lib/calculator-cost.js).
    return Object.assign({}, p, { unitCost: +unit.toFixed(4), baseCost: +(unit * qty).toFixed(4) }, once ? { orderLevelCosts: true } : {});
  });
  return {
    parts,
    labourCost: once ? +productLabourCost(d, ctx).toFixed(4) : 0,
    packagingCost: once ? +productPackagingCost(d, ctx).toFixed(4) : 0,
  };
}

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
   * ── A RATE THE PART NEVER SAID IS KHAYT'S DEFAULT, AS IN A JOB ──────────
   *
   * A part is costed through `KhaytPrintRates.withRates` with the shop's
   * settings: every rate it carries wins, and one it does not carry (no
   * labour, no wear) is the shop's default — Khayt's figures with the shop's
   * own tariff over them, the ones a new part starts at on either app's sheet.
   * That is the same merge the Mac's `costPart` makes for a job, so a job
   * taken from the product costs what the catalogue says.
   *
   * It did not used to: an earlier draft held these at zero so that no stored
   * price would move on the next save. The Mac then filled the defaults in on
   * the job and the catalogue did not, so a part with no labour saved on it
   * listed at its material cost and opened a job at material plus 90 an hour.
   * Stored prices still do not move: a product is priced again only when
   * somebody edits it and saves, on a sheet that shows the figure it will
   * write and says when the saved price is kept.
   */
  const ctx = { inventory: opts.inventory || [], settings: opts.settings || {}, consumables: opts.consumables || [] };

  // ── EACH PART TIMES ITS QUANTITY, AS A JOB COUNTS IT ────────────────────
  //
  // `computePartBaseCost` is ONE piece. This summed it once per part, so a
  // product made of three of the same part was costed as one: a stand ×3 at
  // 19.80 a piece listed at cost 19.80 / price 25.74, while a job taken from
  // the same product (`partTotalCost`, which every cart line is costed with)
  // came to 59.40 / 77.22. The catalogue was selling it at a loss and saying
  // it made 30%. `partTotalCost` is the same function the job uses, so the
  // two cannot drift again: piece cost × `qty` (1 when absent), with the
  // shop's packaging spread across the line once, not once a piece.
  //
  // This moves no stored price. A product carries the price it was saved
  // with; it is priced again only when somebody opens and saves it, on a
  // sheet that shows the figure it will save.
  const PRt = printRates();
  // ── LABOUR ONCE PER PRODUCT (Turki, Nov 19; data model: Mac Figma p.18) ──
  //
  // A product WITH its own `rates` ({ laborRate, prepTime, postTime, wearRate,
  // powerDraw, elecRate, failureRate }) is costed the new way: each part's
  // material, wear and power by its own print time (a part's own rate wins,
  // then the product's, then the shop's), and the labour, prep and assembly,
  // ONCE for the product: (prep + post) × rate × (1 + failure / 100). With
  // `labourPerPart: true` each part carries its labour again, as before.
  // A 6-part product at 0.75 h × 90 cost 6 × 67.50 = 405; the work is 67.50.
  //
  // A product with NO `rates` (every product saved before this) is costed
  // exactly as it was, labour in every part, until the shop presses "Use the
  // new cost" (which gives it rates): nothing re-prices silently.
  const own = usesProductRates(d);
  const once = own && d.labourPerPart !== true;
  const onceOpts = once ? { labour: false, packaging: false } : undefined;
  const partsCost = list.reduce((sum, raw) => {
    const p = ratedPart(d, raw, ctx.settings);
    if (CC && typeof CC.partTotalCost === 'function') {
      return sum + (+CC.partTotalCost(p, ctx, onceOpts) || 0);
    }
    if (CC && typeof CC.computePartBaseCost === 'function') {
      return sum + (+CC.computePartBaseCost(p, ctx, onceOpts) || 0) * Math.max(1, +(p && p.qty) || 1);
    }
    return sum + (+(p && p.baseCost) || 0);
  }, 0) + productOnceCost(d, ctx);

  // Non-printed components folded into the unit cost, for a product that is an
  // assembly rather than a single print. Same module as the per-part cost —
  // `computeComponentsCost` lives in `calculator-cost`, not in `assembly`,
  // which is where I looked first and would have silently costed every BOM
  // product at its printed parts alone.
  //
  // Times the product's `assemblyQty`, as `lib/order-new.js` costs a job from
  // it (`componentsCost`: one set per assembly, absent or not positive is 1) —
  // a job taken from the product starts at that count, and the catalogue
  // pricing anything else is two prices for one product.
  const assemblyQty = num(d.assemblyQty, 0) > 0 ? num(d.assemblyQty, 1) : 1;
  const compCost = (CC && typeof CC.computeComponentsCost === 'function')
    ? (+CC.computeComponentsCost(d.components, opts.consumables || []) || 0) * assemblyQty
    : 0;

  const cost = partsCost + compCost;
  // A product with no margin of its own is priced at the SHOP's default
  // (`settings.defaultMargin`, else 30) — the figure a job taken from it, a
  // counter sale and the LAN library quote all use. This read 30 whatever the
  // shop had set, so a shop at 50 listed a product at cost × 1.3 in the
  // catalogue and the storefront and recorded cost × 1.5 when it sold one.
  const shopMargin = (ctx.settings && typeof ctx.settings.defaultMargin === 'number'
    && Number.isFinite(ctx.settings.defaultMargin)) ? ctx.settings.defaultMargin : 30;
  const margin = Math.max(0, num(d.defaultMargin, shopMargin));
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

const api = { priceProduct, pricingFields, usesProductRates, productLabourCost, productPackagingCost, productOnceCost, productJobParts };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytProductPricing = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
