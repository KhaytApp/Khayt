'use strict';
/**
 * The same product added to the calculator twice is ONE line of 2 (Turki,
 * Nov 19): its labour is prep once + post × 2 and its packaging
 * ceil(2 / perBox) boxes, exactly what productJobParts says for units 2. A
 * group whose parts the shop has edited is never overwritten: the product then
 * goes in as a group of its own. The real renderer functions run here.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'print-rates', 'calculator-cost', 'product-price', 'product-pricing', 'order-new']) require('../lib/' + f + '.js');
const PP = globalThis.KhaytProductPricing;

const read = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
const fnIn = (src, name) => { const at = src.indexOf('function ' + name + '('); assert.ok(at !== -1, name); return src.slice(at, src.indexOf('\n}\n', at) + 3); };
const inv = read('inventory.js'), build = read('build.js');

const rates = { laborRate: 90, prepTime: 0.25, postTime: 0.5, wearRate: 0, powerDraw: 0, elecRate: 0, failureRate: 10 };
const settings = { defaultMargin: 30, currency: 'SAR', defaultPackagingCost: 5 };
const product = (extra) => Object.assign({ id: 'P', rates, parts: [
  { name: 'a', printWeight: 100, printTime: 0, spoolCost: 90, spoolWeight: 1000, qty: 1 },
  { name: 'b', printWeight: 0, printTime: 0, qty: 2 },
] }, extra || {});

function cart() {
  let n = 0;
  const box = {
    console, Math, JSON, Number, String, Object, Array, Set,
    window: { KhaytProductPricing: PP }, settings, inventory: [], consumables: [],
    uid: (p) => p + (++n), partTotalCost: () => 0,
    currentBuild: [], currentFixedCosts: { labourCost: 0, packagingCost: 0 },
  };
  vm.createContext(box);
  vm.runInContext([fnIn(inv, 'appendProductParts'), fnIn(inv, 'mergeProductAgain'), fnIn(build, 'syncFixedCosts'), fnIn(build, 'onceFixedCost')].join('\n')
    + '\nthis.api = { add: appendProductParts };', box);
  return box;
}
const r2 = (v) => Math.round(v * 100) / 100;

test('a product added twice is one group of 2: labour (0.25 + 0.5 x 2) x 90 x 1.1 = 123.75, two boxes 11.00', () => {
  const box = cart();
  box.api.add(product()); box.api.add(product());
  const keys = Object.keys(box.currentFixedCosts.groups);
  assert.equal(keys.length, 1);
  assert.equal(box.currentFixedCosts.groups[keys[0]].units, 2);
  assert.deepEqual(box.currentBuild.map((p) => p.qty), [2, 4]);
  assert.deepEqual(box.currentBuild.map((p) => p.id), ['PRT2', 'PRT3'], 'the parts keep their ids');
  assert.equal(r2(box.currentFixedCosts.labourCost), 123.75);
  assert.equal(r2(box.currentFixedCosts.packagingCost), 11);
  const jp = PP.productJobParts(product(), { inventory: [], settings, units: 2 });
  assert.deepEqual(box.currentBuild.map((p) => p.baseCost), jp.parts.map((p) => p.baseCost));
});

test('ten times with perBox 4: prep once + post x 10 = 519.75, ceil(10 / 4) = 3 boxes 16.50', () => {
  const box = cart();
  for (let i = 0; i < 10; i++) box.api.add(product({ perBox: 4 }));
  assert.equal(Object.keys(box.currentFixedCosts.groups).length, 1);
  assert.equal(r2(box.currentFixedCosts.labourCost), 519.75);
  assert.equal(r2(box.currentFixedCosts.packagingCost), 16.5);
});

test('a group whose part the shop edited is left alone: the product goes in as its own group', () => {
  const box = cart();
  box.api.add(product());
  box.currentBuild[0] = Object.assign({}, box.currentBuild[0], { qty: 5 });
  box.api.add(product());
  assert.equal(Object.keys(box.currentFixedCosts.groups).length, 2);
  assert.equal(box.currentBuild[0].qty, 5, 'the edit is kept');
  assert.equal(r2(box.currentFixedCosts.labourCost), 148.5, 'two products, each its own line');
});

test('two different products stay two groups', () => {
  const box = cart();
  box.api.add(product()); box.api.add(product({ id: 'Q' }));
  assert.equal(Object.keys(box.currentFixedCosts.groups).length, 2);
});

for (const [what, change] of [['an agreed price', { agreedPrice: 40 }], ['a colour', { colour: 'Red' }], ['a note', { note: 'gift wrap' }]]) {
  test(`a group with ${what} on a part is not rebuilt: the product goes in as its own group (money review of #2586, MED 4)`, () => {
    const box = cart();
    box.api.add(product());
    box.currentBuild[0] = Object.assign({}, box.currentBuild[0], change);
    box.api.add(product());
    assert.equal(Object.keys(box.currentFixedCosts.groups).length, 2);
    for (const [k, v] of Object.entries(change)) assert.equal(box.currentBuild[0][k], v, 'kept');
  });
}
