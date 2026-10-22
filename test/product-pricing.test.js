'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');

// Loaded for their globals, the way every host loads them.
require('../lib/calculator-cost.js');
require('../lib/product-price.js');
const pricing = require('../lib/product-pricing.js');

// Every rate SAID, and said zero, so a figure below is the filament alone. A
// rate a part does not carry is the shop's default (see the last tests here).
const NO_RATES = Object.freeze({ wearRate: 0, powerDraw: 0, elecRate: 0, prepTime: 0, postTime: 0,
                                 laborRate: 0, failureRate: 0 });

const PART = {
  name: 'Stand', material: 'PETG', printWeight: 180, supportWeight: 0,
  printTime: 4.5, qty: 1, spoolCost: 85, spoolWeight: 1000,
};

test('a product is priced from its parts, its margin and its rounding', () => {
  const out = pricing.priceProduct({ defaultMargin: 35, parts: [PART] }, { inventory: [], settings: {} });
  assert.ok(out.cost > 0, 'a product with a part costs something');
  // Within a halalah of cost plus margin, not exactly equal to it: the module
  // applies the margin to the UNROUNDED cost and rounds once at the end, which
  // is right. Recomputing from the rounded `cost` here gave 128.15 against its
  // 128.16 — the test was wrong, not the arithmetic.
  assert.ok(Math.abs(out.basePrice - out.cost * 1.35) <= 0.01,
    `basePrice ${out.basePrice} is not cost ${out.cost} plus 35%`);
  assert.equal(out.parts, 1);
  assert.equal(out.hours, 4.5);
  assert.equal(out.grams, 180);
});

test('a product with NO parts is zero, and says so by its count', () => {
  // THE BUG THIS FILE WAS WRITTEN FOR. A product added on the Mac came back
  // priced 0.00 with no hours and no grams and nothing saying why — because
  // that side had no way to give it parts, and a product's price is entirely
  // made of them. `parts: 0` is what lets a screen say so instead of showing a
  // confident zero.
  const out = pricing.priceProduct({ defaultMargin: 35, parts: [] }, {});
  assert.equal(out.parts, 0);
  assert.equal(out.price, 0);
  assert.equal(out.hours, 0);
  assert.equal(out.grams, 0);
});

test('quantities multiply the specs, not just the cost', () => {
  const out = pricing.priceProduct(
    { defaultMargin: 0, parts: [Object.assign({}, PART, { qty: 3 })] }, {});
  assert.equal(out.hours, 13.5, '4.5 hours x 3');
  assert.equal(out.grams, 540, '180 g x 3');
});

test('the cost CONTEXT changes the answer, so it is not optional', () => {
  // `computePartBaseCost(part, ctx)` falls back to `global.inventory` and
  // `global.settings`. Those exist in the renderer and in no other host, so
  // under JavaScriptCore the fallback is an empty shelf — and the resin branch
  // is chosen by looking the part's filament up in that shelf.
  //
  // The two branches are different formulas: resin is cost/1000 x grams,
  // filament is cost/spoolWeight x grams. They agree only at exactly 1000 g,
  // which is why this looks fine in a casual test.
  const shelf = [{ id: 'R1', materialType: 'resin' }];
  const part = { filamentId: 'R1', printWeight: 120, printTime: 3, qty: 1,
                 spoolCost: 220, spoolWeight: 500, ...NO_RATES };
  const withShelf = pricing.priceProduct({ defaultMargin: 0, parts: [part] }, { inventory: shelf });
  const without = pricing.priceProduct({ defaultMargin: 0, parts: [part] }, {});
  // 220/1000 x 120 = 26.40 as resin; 220/500 x 120 = 52.80 as filament. Both
  // material only — the part says every rate is zero.
  assert.equal(withShelf.cost, 26.4, 'resin is priced per litre');
  assert.equal(without.cost, 52.8, 'without the shelf it takes the filament formula');
  assert.notEqual(without.cost, withShelf.cost, 'the shelf made no difference — is the ctx reaching through?');
});

test('bought-in components fold into the unit cost', () => {
  const cons = [{ id: 'c1', cost: 0.5 }, { id: 'c2', cost: 0.2 }];
  const out = pricing.priceProduct({
    defaultMargin: 0, parts: [],
    components: [{ consumableId: 'c1', qtyPerUnit: 4 }, { consumableId: 'c2', qtyPerUnit: 6 }],
  }, { consumables: cons });
  assert.equal(out.cost, 3.2, 'a BOM product with no printed parts still costs its components');
});

test('pricingFields writes the three fields it owns and no others', () => {
  // Spreading the whole answer onto a record would put `parts` (a count) over
  // `parts` (the list), which is the shape of bug that eats data.
  const fields = pricing.pricingFields({ defaultMargin: 35, parts: [PART] }, {});
  assert.deepEqual(Object.keys(fields).sort(), ['basePrice', 'baseCost', 'price'].sort());
});

test('a product with no margin of its own is priced at the shop default, as a sale from it is', () => {
  const part = { name: 'P', printWeight: 1000, spoolCost: 100, spoolWeight: 1000, qty: 1, ...NO_RATES };
  // The shop quotes at 50: the catalogue said cost × 1.3, the counter sale cost × 1.5.
  assert.equal(pricing.priceProduct({ parts: [part] }, { settings: { defaultMargin: 50 } }).basePrice, 150);
  assert.equal(pricing.priceProduct({ parts: [part] }, { settings: {} }).basePrice, 130, 'no shop default: 30');
  assert.equal(pricing.priceProduct({ parts: [part], defaultMargin: 20 }, { settings: { defaultMargin: 50 } }).basePrice, 120,
    "the product's own margin still wins");
  assert.equal(pricing.priceProduct({ parts: [part], defaultMargin: 0 }, { settings: { defaultMargin: 50 } }).basePrice, 100,
    'a margin of 0 is a margin, not a blank');
});

/* ── The catalogue and a job taken from the product are one price ────────── */

// The owner's case: a stand at 19.80 a piece, three to a product, 30% on cost.
// The catalogue costed the part ONCE (19.80, priced 25.74); a job from the
// same product counts all three (59.40, priced 77.22).
const STAND = { name: 'Stand', material: 'PLA', printWeight: 180, printTime: 2,
                spoolCost: 110, spoolWeight: 1000, qty: 3, ...NO_RATES };

test('a part ×3 is costed three times, as a job from the product costs it', () => {
  const out = pricing.priceProduct({ defaultMargin: 30, parts: [STAND] }, {});
  assert.equal(out.cost, 59.4, 'three pieces at 19.80');
  assert.equal(out.basePrice, 77.22);
  const one = pricing.priceProduct({ defaultMargin: 30, parts: [Object.assign({}, STAND, { qty: 1 })] }, {});
  assert.equal(one.cost, 19.8);
  assert.equal(one.basePrice, 25.74);
  const blank = pricing.priceProduct({ defaultMargin: 30, parts: [Object.assign({}, STAND, { qty: undefined })] }, {});
  assert.equal(blank.cost, 19.8, 'no qty is one piece, as the job reads it');
});

// A job taken from a product the way both apps take one: each part costed as a
// LINE (`partTotalCost`, renderer/inventory.js `appendProductParts`; the Mac's
// `Shop.partRows` writes piece cost × qty), the product's components and
// `assemblyQty`, and its margin.
function jobFrom(product, ctx) {
  const CC = require('../lib/calculator-cost.js');
  const PR = require('../lib/print-rates.js');
  require('../lib/pricing.js');
  const N = require('../lib/order-new.js');
  // At the part's own rates and the shop's default for any it never carried
  // (`withRates`), as `appendProductParts` and the Mac's `costPart` take it.
  const parts = (product.parts || []).map((p) => {
    const rated = PR.withRates(p, { settings: ctx.settings });
    return Object.assign({}, rated, { baseCost: CC.partTotalCost(rated, ctx) });
  });
  return N.newOrder({
    parts, project: 'From the catalogue', margin: product.defaultMargin,
    components: product.components, assemblyQty: product.assemblyQty,
  }, {
    settings: ctx.settings || {}, orders: [], now: new Date(2026, 9, 1),
    tokens: { tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16) },
    consumables: ctx.consumables || [],
  });
}

// A part saved with none of its rates — an older Mac build's save, an
// import, the Mac's sample book — and only some of the others.
const RATELESS = { name: 'Bracket', material: 'PETG', printWeight: 180, printTime: 4.5,
                   spoolCost: 85, spoolWeight: 1000, qty: 2, prepTime: 0.1 };

test('the catalogue prices a product exactly as a job from it does, on every shape', () => {
  const consumables = [{ id: 'mag', cost: 0.35 }, { id: 'box', cost: 2.1 }];
  const settings = { defaultPackagingCost: 1.5 };
  const comps = [{ consumableId: 'mag', qtyPerUnit: 4 }, { consumableId: 'box', qtyPerUnit: 1 }];
  const second = { name: 'Lid', material: 'PETG', printWeight: 42.5, supportWeight: 3, printTime: 0.75,
                   spoolCost: 95, spoolWeight: 750, qty: 2, laborRate: 20, postTime: 0.1, failureRate: 5 };
  const shapes = {
    'one piece': { defaultMargin: 30, parts: [Object.assign({}, STAND, { qty: 1 })] },
    'one part ×3': { defaultMargin: 30, parts: [STAND] },
    'two parts, ×3 and ×2': { defaultMargin: 45, parts: [STAND, second] },
    'components': { defaultMargin: 30, parts: [STAND], components: comps },
    'components, assemblyQty 2': { defaultMargin: 30, parts: [STAND, second], components: comps, assemblyQty: 2 },
    'assemblyQty with no components': { defaultMargin: 25, parts: [STAND], assemblyQty: 3 },
    'a part with no labour or wear': { defaultMargin: 30, parts: [RATELESS] },
    'rate-less beside a rated part': { defaultMargin: 35, parts: [RATELESS, second], components: comps },
  };
  for (const [name, product] of Object.entries(shapes)) {
    const ctx = { inventory: [], settings, consumables };
    const listed = pricing.priceProduct(product, ctx);
    const job = jobFrom(product, ctx);
    const jobCost = job.parts.reduce((s, p) => s + p.baseCost, 0) + (job.componentsCost || 0);
    assert.equal(listed.price, job.price, `${name}: catalogue ${listed.price} vs job ${job.price}`);
    assert.equal(listed.cost, +jobCost.toFixed(2), `${name}: catalogue cost ${listed.cost} vs job ${jobCost}`);
  }
});

/* ── A rate the part never carried is the shop's default ─────────────────── */

test('a part with no labour or wear is costed at the shop defaults, as the job path costs it', () => {
  const CC = require('../lib/calculator-cost.js');
  const PR = require('../lib/print-rates.js');
  const settings = { elecRate: 0.3 };
  const out = pricing.priceProduct({ defaultMargin: 30, parts: [RATELESS] }, { inventory: [], settings });
  // One piece: 180 g at 0.085 = 15.30; wear 0.75 x 4.5 = 3.375; power 150 W x
  // 4.5 h at the shop's 0.30 = 0.2025; labour (0.1 its own + 0.5 default) x 90
  // = 54; +10 % = 80.164. Two of them: 160.33.
  assert.equal(out.cost, 160.33);
  // The very merge the Mac's `costPart` makes for a job's part.
  const merged = Object.assign({}, PR.ratesFor({ settings }), RATELESS);
  assert.equal(out.cost, +CC.partTotalCost(merged, { inventory: [], settings }).toFixed(2));
  assert.deepEqual(PR.withRates(RATELESS, { settings }), merged);
});

test('a rate the part DID carry wins, zero included', () => {
  const said = Object.assign({}, RATELESS, NO_RATES, { prepTime: 0.1 });
  const out = pricing.priceProduct({ defaultMargin: 0, parts: [said] }, { settings: {} });
  assert.equal(out.cost, 30.6, '180 g at 0.085, twice: a zero rate is a rate, not a blank');
  const withLabour = Object.assign({}, RATELESS, { laborRate: 40 });
  const a = pricing.priceProduct({ defaultMargin: 0, parts: [withLabour] }, { settings: {} });
  const b = pricing.priceProduct({ defaultMargin: 0, parts: [RATELESS] }, { settings: {} });
  assert.ok(a.cost < b.cost, "the part's own 40 an hour beat the default 90");
});
