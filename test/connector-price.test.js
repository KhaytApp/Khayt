'use strict';
/**
 * test/fixtures/connector-price-vectors.json through lib/connector-price.js
 * priceSlice: the shop's price for a plate sliced in OrcaSlicer. The Mac runs
 * the same file through its engine (JSC). Plus what the route relies on:
 * nothing from the facts but numbers comes back, and the answer is pure.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'print-rates', 'calculator-cost', 'spool-edit', 'loaded-colours', 'spool-match', 'connector-price']) require('../lib/' + f + '.js');
const CP = globalThis.KhaytConnectorPrice, CC = globalThis.KhaytCalculatorCost;
const V = require('./fixtures/connector-price-vectors.json');
const ctxOf = (c) => ({ ...V.shop, ...c.ctx, settings: { ...V.shop.settings, ...((c.ctx && c.ctx.settings) || {}) } });

for (const c of V.cases) {
  test(c.why, () => assert.deepEqual(CP.priceSlice(c.facts, ctxOf(c)), c.want));
}

test('qty 10 is cheaper a piece than qty 1 by exactly the prep shared: (0.25 x 60 x 1.05) x 9 / 10', () => {
  const one = CP.priceSlice(V.cases[0].facts, ctxOf(V.cases[0]));
  const ten = CP.priceSlice(V.cases[1].facts, ctxOf(V.cases[1]));
  // prep 15.75 and packaging 5.25 (with the failure buffer) are once a line
  assert.ok(Math.abs((one.cost.unit - ten.cost.unit) - (15.75 + 5.25) * 0.9) < 1e-9, String(one.cost.unit - ten.cost.unit));
});

test('the cost is the calculator\'s own: computePartBaseCost of the same part', () => {
  const c = V.cases[0];
  const part = Object.assign(globalThis.KhaytPrintRates.withRates({ qty: 1, printWeight: 272.4, printTime: 53640 / 3600, spoolCost: 272.4 * 0.08, spoolWeight: 272.4, labourPerLine: true },
    { settings: V.shop.settings, preset: V.shop.printers[0] }));
  assert.equal(Math.round(CC.computePartBaseCost(part, { inventory: [], settings: V.shop.settings }) * 1e4) / 1e4, CP.priceSlice(c.facts, ctxOf(c)).cost.unit);
});

test('the answer carries no names, ids or presets from the facts or the book', () => {
  const s = JSON.stringify(CP.priceSlice(V.cases[3].facts, ctxOf(V.cases[3])));
  for (const leak of ['S1', 'S2', 'S5', 'P1', 'Snapmaker', 'PLA', 'PETG', '#']) assert.ok(!s.includes(leak), leak);
});

test('pure: the facts and the shop are not changed', () => {
  const c = V.cases[3];
  const facts = JSON.parse(JSON.stringify(c.facts)), ctx = JSON.parse(JSON.stringify(ctxOf(c)));
  CP.priceSlice(facts, ctx);
  assert.deepEqual(facts, c.facts); assert.deepEqual(ctx, JSON.parse(JSON.stringify(ctxOf(c))));
});

test('bad facts are refused, not priced', () => {
  const f = V.cases[0].facts;
  for (const bad of [null, {}, { ...f, qty: 1000 }, { ...f, qty: 1.5 }, { ...f, timeSec: -1 }, { ...f, timeSec: Infinity },
    { ...f, filaments: [{ type: 'PLA', grams: -1 }] }, { ...f, filaments: Array.from({ length: 17 }, () => ({ type: 'PLA', grams: 1 })) }]) {
    assert.deepEqual(CP.priceSlice(bad, ctxOf(V.cases[0])), { unpriced: 'bad-facts' });
  }
});
