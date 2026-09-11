'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { quoteFunnel, FINISHED } = require('../lib/quote-funnel.js');

const NOW = Date.parse('2026-09-11T00:00:00Z');
function run(orders, deps = {}) {
  return quoteFunnel({ orders, now: NOW }, deps);
}
const step = (r, key) => r.steps.find((s) => s.key === key);

/**
 * THE BUG THIS MODULE EXISTS TO FIX.
 *
 * The last step counted `status === 'completed'` only. `delivered` is PAST
 * completed in Khayt's pipeline — it is where finished work ends up — so every
 * job that reached a customer fell out of the funnel's final step, and the win
 * rate was too low for every shop that marks work delivered.
 */
test('delivered work is finished work, so the win rate is not too low', () => {
  const r = run([
    { id: '1', status: 'delivered', price: 100, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
    { id: '2', status: 'completed', price: 100, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
  ]);
  assert.equal(step(r, 'finished').count, 2);
  assert.equal(r.totals.winRateByCount, 1);
  assert.deepEqual(FINISHED, ['completed', 'delivered']);
});

test('a cancelled quote is not a converted one', () => {
  const r = run([
    { id: '1', status: 'cancelled', price: 9000, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
    { id: '2', status: 'printing', price: 100, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
  ]);
  assert.equal(step(r, 'accepted').count, 2, 'it WAS accepted, and that is history');
  assert.equal(step(r, 'converted').count, 1);
  assert.equal(step(r, 'finished').count, 0);
});

test('a voided order and work outside the trade are not in the funnel at all', () => {
  const r = run([
    { id: '1', status: 'quote', price: 100, voidedAt: '2026-08-02' },
    { id: '2', status: 'quote', price: 100, business: false },
    { id: '3', status: 'quote', price: 100 },
  ], { countsForBusiness: (o) => o.business !== false });
  assert.equal(step(r, 'created').count, 1);
});

test('an order that was never quoted is not in the funnel', () => {
  const r = run([
    { id: '1', status: 'completed', price: 500 },
    { id: '2', status: 'completed', price: 500, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
  ]);
  assert.equal(step(r, 'created').count, 1);
});

/**
 * Ten small quotes won and one large one lost is a very different month from
 * the reverse, and a count cannot tell them apart.
 */
test('the win rate is reported by count AND by value, because they disagree', () => {
  const r = run([
    { id: '1', status: 'completed', price: 1000, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
    { id: '2', status: 'quote', price: 99000, quoteSentAt: '2026-08-01' },
  ]);
  assert.equal(r.totals.winRateByCount, 0.5);
  assert.equal(r.totals.winRateByValue, 1000 / 100000);
});

test('how long a customer takes to decide is the median, not the mean', () => {
  const r = run([
    { id: '1', status: 'completed', price: 1, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
    { id: '2', status: 'completed', price: 1, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-04' },
    // One quote somebody sat on for most of a year, which must not set the
    // figure a shop plans around.
    { id: '3', status: 'completed', price: 1, quoteSentAt: '2026-01-01', quoteAcceptedAt: '2026-09-01' },
  ]);
  assert.equal(r.totals.medianDaysToDecide, 3);
});

test('a quote with no sent date measures from the day it was raised', () => {
  const r = run([
    { id: '1', status: 'completed', price: 1, date: '2026-08-01', quoteAcceptedAt: '2026-08-06' },
  ]);
  assert.equal(r.totals.medianDaysToDecide, 5);
});

/// A funnel is a report; an open quote is a phone call.
test('quotes still waiting are counted, valued, and the oldest is named', () => {
  const r = run([
    { id: '1', status: 'quote', price: 20000, quoteSentAt: '2026-07-01' },
    { id: '2', status: 'quote', price: 500, quoteSentAt: '2026-09-09' },
    { id: '3', status: 'completed', price: 100, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
  ]);
  assert.equal(r.totals.openCount, 2);
  assert.equal(r.totals.openValue, 20500);
  assert.equal(r.totals.oldestOpenDays, 72);
});

test('an accepted quote is no longer open, whatever its status', () => {
  const r = run([
    { id: '1', status: 'quote', price: 100, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
  ]);
  assert.equal(r.totals.openCount, 0);
});

/**
 * `valueOf` is on `Object.prototype`, so `typeof deps.valueOf === 'function'`
 * is true for `{}` — a dep named that would never fall back, and the inherited
 * method would run instead and throw. The parameter is `priceOf` for that
 * reason and this test is the reason it stays that way.
 */
test('no deps at all still works', () => {
  const r = run([
    { id: '1', status: 'completed', price: 250, quoteSentAt: '2026-08-01', quoteAcceptedAt: '2026-08-02' },
  ]);
  assert.equal(step(r, 'finished').value, 250);
  assert.equal(r.totals.winRateByValue, 1);
});

test('nothing at all is an answer, not a throw', () => {
  const r = quoteFunnel(undefined, undefined);
  assert.equal(r.steps.length, 5);
  assert.equal(r.totals.winRateByCount, null, 'a shop that has never quoted has no rate');
  assert.equal(r.totals.medianDaysToDecide, null);
  assert.equal(r.totals.oldestOpenDays, null);
});
