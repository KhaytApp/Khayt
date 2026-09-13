'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');

// Loaded for their globals, the way every host loads them.
require('../lib/calculator-cost.js');
require('../lib/product-price.js');
const pricing = require('../lib/product-pricing.js');

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
                 spoolCost: 220, spoolWeight: 500 };
  const withShelf = pricing.priceProduct({ defaultMargin: 0, parts: [part] }, { inventory: shelf });
  const without = pricing.priceProduct({ defaultMargin: 0, parts: [part] }, {});
  // 220/1000 x 120 = 26.40 as resin; 220/500 x 120 = 52.80 as filament. Both
  // material only — no rates are injected here, see the module's note.
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
