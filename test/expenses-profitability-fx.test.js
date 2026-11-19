'use strict';
/**
 * The order editor's profitability box (renderer/expenses.js
 * buildProfitabilityHtml) for a job taken in another currency.
 *
 * 4.11.0 release review, L2: the job's cost (its parts' partTotalCost, plus a
 * product's labour and packaging) is in the SHOP's currency and `order.price`
 * is in the JOB's, and the box subtracted one from the other. The price is now
 * converted at the job's `fxRate` (shop currency per one unit of the job's),
 * the rule renderer/job-page.js moneyHtml uses: no rate, a non-positive one or
 * 1 means the job is already in shop currency.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../renderer/util.js');

// The renderer globals the box reads, kept to what this test needs: each part
// costs its `cost` field, prices print as plain numbers with two decimals.
global.partTotalCost = (p) => +p.cost || 0;
global.computePartBreakdown = (p) => ({ material: +p.cost || 0, machine: 0, labor: 0, buffer: 0 });
global.fmtPrice = (v) => `#${(+v).toFixed(2)}#`;
global.t = (k) => k;
if (typeof global.escapeHtml !== 'function') {
  global.escapeHtml = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
const { buildProfitabilityHtml } = require('../renderer/expenses.js');

const figures = (html) => [...html.matchAll(/#(-?[\d.]+)#/g)].map((m) => +m[1]);

test('a USD job priced 100 at 3.75 with 150 SAR of cost makes 225 SAR, not -50', () => {
  const html = buildProfitabilityHtml({ price: 100, fxRate: 3.75, parts: [{ cost: 150 }] });
  // revenue, estimated cost, profit
  assert.deepEqual(figures(html).slice(0, 3), [375, 150, 225]);
  assert.match(html, /\(60%\)/, '225 / 375');
});

test('a job already in shop currency is unchanged: no rate, a rate of 1, or a bad one', () => {
  for (const fxRate of [undefined, null, 1, 0, -2, 'abc']) {
    const html = buildProfitabilityHtml({ price: 200, fxRate, parts: [{ cost: 150 }] });
    assert.deepEqual(figures(html).slice(0, 3), [200, 150, 50], `fxRate ${String(fxRate)}`);
  }
});

test('the actual row converts the price the same way', () => {
  const html = buildProfitabilityHtml({
    price: 100, fxRate: 3.75, actualWeight: 10,
    parts: [{ cost: 150, printWeight: 10 }],
  });
  // estimated row (3), then the actual row: revenue, actual cost, profit
  assert.deepEqual(figures(html).slice(3, 6), [375, 150, 225]);
});
