'use strict';
const test = require('node:test');
const assert = require('node:assert');
// The neighbours, loaded the way a host loads them: onto globalThis.
require('../lib/product-price.js');
require('../lib/product-specs.js');
require('../lib/product-profit.js');
require('../lib/printer-actuals.js');
require('../lib/estimate-variance.js');
require('../lib/business-scope.js');
const { productRates, storeHints, jobHours } = require('../lib/profit-per-hour.js');

const deps = { partCostOf: (p) => p.cost || 0 };
const product = (id, name, basePrice, baseCost, hours, extra = {}) => ({
  id, name, basePrice, baseCost,
  parts: hours === null ? [] : [{ printTime: hours, qty: 1 }],
  ...extra,
});
const of = (r, id) => r.rows.find((x) => x.productId === id);

// Two products that make the same profit per sale. One takes 2 hours, the
// other 20. Per sale they tie; per printer hour one is ten times the other.
const slow = product('slow', 'Slow bust', 100, 60, 20);
const quick = product('quick', 'Quick keyring', 100, 60, 2);
const mid = product('mid', 'Mid vase', 90, 40, 5);

test('ranks by profit per machine hour, not by profit per sale', () => {
  const r = productRates({ products: [slow, quick, mid] }, deps);
  assert.deepStrictEqual(r.rows.map((x) => x.productId), ['quick', 'mid', 'slow']);
  assert.equal(of(r, 'quick').profit, 40);
  assert.equal(of(r, 'slow').profit, 40);
  assert.equal(of(r, 'quick').perHour, 20);
  assert.equal(of(r, 'slow').perHour, 2);
  assert.equal(of(r, 'mid').perHour, 10);
  assert.equal(r.totals.best, 'quick');
});

test('the price is the one the shop charges: an override or rounding wins', () => {
  const rounded = product('r', 'Rounded', 43.71, 20, 1, { priceRound: { step: 5, mode: 'up' } });
  const typed = product('t', 'Typed', 43.71, 20, 1, { priceOverride: 60 });
  const r = productRates({ products: [rounded, typed] }, deps);
  assert.equal(of(r, 'r').price, 45);
  assert.equal(of(r, 't').price, 60);
  assert.equal(of(r, 't').perHour, 40);
});

test('no hours: shown last with a dash reason, never divided by zero', () => {
  const none = product('none', 'Assembly', 50, 10, null);
  const r = productRates({ products: [none, quick] }, deps);
  const row = of(r, 'none');
  assert.equal(row.hours, null);
  assert.equal(row.perHour, null);
  assert.equal(row.missing, 'hours');
  assert.equal(row.profit, 40, 'the profit per sale is still known');
  assert.equal(r.rows[r.rows.length - 1].productId, 'none');
  assert.equal(r.totals.noHours, 1);
  assert.ok(r.rows.every((x) => x.perHour === null || Number.isFinite(x.perHour)));
});

test('no price: no profit rather than a zero that reads as break-even', () => {
  const unpriced = { id: 'u', name: 'New thing', parts: [{ printTime: 3 }] };
  const zero = product('z', 'Zero calc', 0, 0, 3);
  const r = productRates({ products: [unpriced, zero, quick] }, deps);
  for (const id of ['u', 'z']) {
    assert.equal(of(r, id).price, null, id);
    assert.equal(of(r, id).profit, null, id);
    assert.equal(of(r, id).perHour, null, id);
    assert.equal(of(r, id).missing, 'price', id);
  }
  assert.equal(r.totals.noPrice, 2);
});

test('a typed price of zero is a giveaway, and a real (negative) rate', () => {
  const free = product('f', 'Sample', 30, 10, 2, { priceOverride: 0 });
  const r = productRates({ products: [free] }, deps);
  assert.equal(of(r, 'f').price, 0);
  assert.equal(of(r, 'f').perHour, -5);
});

test('flags a product earning well under the shop average per hour, with a price that fixes it', () => {
  const r = productRates({ products: [slow, quick, mid] }, deps);
  // (40 + 40 + 50) profit over (20 + 2 + 5) hours
  assert.equal(r.totals.averagePerHour, Math.round((130 / 27) * 100) / 100);
  assert.equal(of(r, 'slow').underpriced, true);
  assert.equal(of(r, 'quick').underpriced, false);
  assert.equal(of(r, 'mid').underpriced, false);
  // cost + average × hours
  assert.equal(of(r, 'slow').suggestedPrice, Math.round((60 + r.totals.averagePerHour * 20) * 100) / 100);
  assert.equal(r.totals.underpriced, 1);
});

test('the suggestion is rounded UP to the shop\'s own step', () => {
  const stepped = { ...slow, priceRound: { step: 5, mode: 'nearest' } };
  const r = productRates({ products: [stepped, quick, mid] }, deps);
  const s = of(r, 'slow').suggestedPrice;
  assert.equal(s % 5, 0);
  assert.ok(s >= 60 + r.totals.averagePerHour * 20);
});

test('no average, and so no underpriced flag, with fewer than three ranked products', () => {
  const r = productRates({ products: [slow, quick] }, deps);
  assert.equal(r.totals.averagePerHour, null);
  assert.ok(r.rows.every((x) => !x.underpriced && x.suggestedPrice === null));
});

const job = (id, productId, price, cost, est, extra = {}) => ({
  id, productId, status: 'completed', price, parts: [{ cost, printTime: est, qty: 1 }], ...extra,
});

test('actual figures come from finished jobs, using the hours the job really took', () => {
  const orders = [
    job('1', 'quick', 100, 55, 2, { actualPrintTime: 4, actualsSource: { time: 'moonraker' } }),
    job('2', 'quick', 100, 55, 2, { actualPrintTime: 4, actualsSource: { time: 'moonraker' } }),
    job('3', 'slow', 120, 60, 20),                      // no actual: the estimate stands
  ];
  const r = productRates({ products: [slow, quick, mid], orders }, deps);
  const q = of(r, 'quick').actual;
  assert.equal(q.jobs, 2);
  assert.equal(q.hours, 8);
  assert.equal(q.profit, 90);
  assert.equal(q.perHour, 11.25);
  assert.equal(q.measured, 2);
  assert.equal(q.hoursDriftPct, 100, 'it took twice as long as estimated');
  assert.equal(q.confidence, 'thin');
  // Planned is untouched by what the jobs did: the two are shown side by side.
  assert.equal(of(r, 'quick').perHour, 20);
  assert.equal(of(r, 'slow').actual.perHour, 3);
  assert.equal(of(r, 'slow').actual.measured, 0);
  assert.equal(of(r, 'slow').actual.hoursDriftPct, null);
  assert.equal(of(r, 'mid').actual, null, 'never made: no actual');
  assert.equal(r.totals.actualPerHour, Math.round((150 / 28) * 100) / 100);
});

test('Not-business jobs are left out of the actual figures', () => {
  const orders = [
    job('1', 'quick', 100, 55, 2),
    job('2', 'quick', 0, 55, 2, { nonBusiness: true, actualPrintTime: 9, actualsSource: { time: 'moonraker' } }),
  ];
  const r = productRates({ products: [quick], orders }, deps);
  assert.equal(of(r, 'quick').actual.jobs, 1);
  assert.equal(of(r, 'quick').actual.profit, 45);
  assert.equal(of(r, 'quick').actual.measured, 0);
});

test('unfinished and voided jobs are not actuals; a typed actual counts for hours but not drift', () => {
  const orders = [
    { ...job('1', 'quick', 100, 55, 2), status: 'printing' },
    { ...job('2', 'quick', 100, 55, 2), voidedAt: '2026-01-01' },
    job('3', 'quick', 100, 55, 2, { actualPrintTime: 3, actualsSource: { time: 'manual' } }),
  ];
  const r = productRates({ products: [quick], orders }, deps);
  const q = of(r, 'quick').actual;
  assert.equal(q.jobs, 1);
  assert.equal(q.hours, 3);
  assert.equal(q.measured, 0);
});

test('a job hours rule: actual when recorded, estimate otherwise', () => {
  assert.equal(jobHours({ actualPrintTime: 5, parts: [{ printTime: 2 }] }), 5);
  assert.equal(jobHours({ parts: [{ printTime: 2, qty: 3 }] }), 6);
  assert.equal(jobHours({ printTime: 4 }), 4);
  assert.equal(jobHours({}), 0);
});

test('a record with no stored cost is costed by product-pricing', () => {
  require('../lib/product-pricing.js');
  const p = { id: 'x', name: 'X', basePrice: 50, parts: [{ printTime: 2, baseCost: 12 }] };
  const r = productRates({ products: [p] }, deps);
  assert.equal(typeof of(r, 'x').cost, 'number');
  assert.equal(of(r, 'x').perHour, Math.round(((50 - of(r, 'x').cost) / 2) * 100) / 100);
});

test('store hints: the best listed earners, and the listed underpriced ones', () => {
  const r = productRates({ products: [slow, quick, mid] }, deps);
  const h = storeHints(r, ['slow', 'quick', 'mid'], { top: 2 });
  assert.deepStrictEqual(h.best.map((x) => x.productId), ['quick', 'mid']);
  assert.deepStrictEqual(h.underpriced.map((x) => x.productId), ['slow']);
  // Unlisted products are nobody's business on the store.
  const only = storeHints(r, ['slow', 'mid']);
  assert.deepStrictEqual(only.best.map((x) => x.productId), ['mid', 'slow']);
  // One listed product is not a choice.
  assert.deepStrictEqual(storeHints(r, ['quick']).best, []);
  assert.deepStrictEqual(storeHints(null, null), { best: [], underpriced: [] });
});

test('empty and junk input answer, rather than throw', () => {
  const r = productRates(null, null);
  assert.deepStrictEqual(r.rows, []);
  assert.equal(r.totals.best, null);
  assert.equal(r.totals.averagePerHour, null);
  const j = productRates({ products: [null, {}, { id: 'a' }], orders: [null, 5] }, {});
  assert.equal(j.rows.length, 1);
  assert.equal(j.rows[0].missing, 'price');
});
