'use strict';
/**
 * applyMarkup on a job in another currency prices it as newOrder does.
 *
 * beta.38 review (Nov 16): applyMarkup multiplied the parts' cost (shop
 * currency) by the job's fxRate, where newOrder divides (`toJob = v / fx`). A
 * USD job at 3.75 re-marked to 60% came out 600 instead of 42.67, and nothing
 * stopped it: the bill went up, not below what was paid.
 *
 * The rule pinned here: a job taken at markup A and changed to B costs the
 * same as the job taken at B, in the shop's currency and in another.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/product-price.js');
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
const N = require('../lib/order-new.js');
const E = require('../lib/order-edit.js');

const part = (over) => Object.assign({ name: 'p.stl', material: 'PLA', qty: 1, printWeight: 100, printTime: 2, unitCost: 100, baseCost: 100 }, over || {});
const tokens = () => ({ tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) });
const clients = [{ id: 'C-USD', currency: 'USD' }];
const settings = () => ({ currency: 'SAR', invNumNext: 7, quoteNumNext: 3, rushFeePct: 25, exchangeRates: { USD: 3.75 } });
const take = (input) => N.newOrder(input, { settings: settings(), orders: [], clients, now: new Date('2026-11-16T08:00:00Z'), tokens: tokens() });

for (const [label, clientId, fx] of [['fx = 1 (the shop’s currency)', undefined, 1], ['fx = 3.75 (USD)', 'C-USD', 3.75]]) {
  for (const extra of [{}, { discountPct: 10 }, { parts: [part(), part({ qty: 2, baseCost: 60 })] }]) {
    test(`${label}: 50% changed to 60% costs what a job taken at 60% costs ${JSON.stringify(extra)}`, () => {
      const base = Object.assign({ parts: [part()], clientId }, extra);
      const at50 = take(Object.assign({}, base, { margin: 50 }));
      const at60 = take(Object.assign({}, base, { margin: 60 }));
      assert.equal(+at50.fxRate || 1, fx, 'the fixture is in the currency it says');
      const r = E.applyMarkup(at50, 60, { priceSeenOk: true });
      assert.equal(r.ok, true, r.reason);
      assert.equal(at50.price, at60.price);
      assert.equal(at50.marginPct, 60);
    });
  }
}

test('the review’s own case: 100 SAR of parts, a USD job at 3.75, re-marked to 60%', () => {
  const job = take({ parts: [part()], clientId: 'C-USD', margin: 50 });
  assert.equal(job.price, 40, '100 SAR × 1.5 ÷ 3.75');
  E.applyMarkup(job, 60, { priceSeenOk: true });
  assert.equal(job.price, 42.67, '100 SAR × 1.6 ÷ 3.75, never 600');
});
