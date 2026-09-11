'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { customerMix, FINISHED } = require('../lib/customer-mix.js');

const deps = { revenueOf: (o) => o.price, countsForBusiness: (o) => o.business !== false };
const job = (id, clientId, date, price, status = 'completed', extra = {}) =>
  ({ id, clientId, date, price, status, ...extra });
function run(orders, window = {}) {
  return customerMix({ orders, ...window }, deps);
}

/**
 * THE ONE THIS MODULE EXISTS FOR.
 *
 * The version it replaces decided who was new with `firstOrderDate[id] ===
 * o.date` — a DATE comparison. A customer whose first two jobs landed on the
 * same day counted as new twice, so a shop taking two jobs from one new
 * customer recorded two new-customer sales. Identity is the ORDER, not the day.
 */
test('a new customer’s second job on the same day is a returning sale', () => {
  const r = run([
    job('a', 'c1', '2026-09-01', 1000),
    job('b', 'c1', '2026-09-01', 500),
  ]);
  assert.equal(r.fresh.jobs, 1);
  assert.equal(r.fresh.revenue, 1000);
  assert.equal(r.returning.jobs, 1);
  assert.equal(r.returning.revenue, 500);
});

/**
 * A customer whose first sale AND a repeat both fall in the window is in both
 * halves — which is the best thing that can happen, and must not be counted as
 * two people.
 */
test('one customer who came back is one customer, not two', () => {
  const r = run([
    job('a', 'c1', '2026-09-01', 1000),
    job('b', 'c1', '2026-09-05', 500),
    job('c', 'c2', '2026-09-02', 300),
  ]);
  assert.equal(r.fresh.clients, 2);
  assert.equal(r.returning.clients, 1);
  assert.equal(r.totals.clients, 2, 'c1 was counted twice');
});

test('delivered work counts, and voided and out-of-trade work does not', () => {
  const r = run([
    job('a', 'c1', '2026-09-01', 100, 'delivered'),
    job('b', 'c2', '2026-09-01', 900, 'completed', { voidedAt: '2026-09-02' }),
    job('c', 'c3', '2026-09-01', 900, 'completed', { business: false }),
    job('d', 'c4', '2026-09-01', 900, 'printing'),
  ]);
  assert.equal(r.totals.jobs, 1);
  assert.equal(r.totals.revenue, 100);
  assert.deepEqual(FINISHED, ['completed', 'delivered']);
});

/// History decides who is new, so it must not be pre-filtered to the window.
test('a customer who first bought before the window is returning inside it', () => {
  const r = run([
    job('a', 'c1', '2024-01-01', 5000),
    job('b', 'c1', '2026-09-01', 1000),
  ], { from: '2026-09-01' });
  assert.equal(r.fresh.jobs, 0);
  assert.equal(r.returning.jobs, 1);
  assert.equal(r.returning.revenue, 1000);
  assert.equal(r.totals.revenue, 1000, 'the old order is history, not revenue in the window');
});

test('the window is inclusive at both ends', () => {
  const orders = [
    job('a', 'c1', '2026-08-31', 1),
    job('b', 'c2', '2026-09-01', 10),
    job('c', 'c3', '2026-09-30', 100),
    job('d', 'c4', '2026-10-01', 1000),
  ];
  const r = run(orders, { from: '2026-09-01', to: '2026-09-30' });
  assert.equal(r.totals.revenue, 110);
});

test('the split shares add to one, and are null when there is nothing', () => {
  const r = run([
    job('a', 'c1', '2026-09-01', 750),
    job('b', 'c1', '2026-09-05', 250),
  ]);
  assert.equal(r.fresh.shareOfRevenue, 0.75);
  assert.equal(r.returning.shareOfRevenue, 0.25);

  const empty = run([]);
  // 0% would read as "none of your money came from new customers", a claim
  // about a shop that simply has no finished work.
  assert.equal(empty.fresh.shareOfRevenue, null);
  assert.equal(empty.returning.shareOfRevenue, null);
});

/// What a shop is buying when it spends on getting found.
test('the average first order is reported, and is null with no new customers', () => {
  const r = run([
    job('a', 'c1', '2026-09-01', 800),
    job('b', 'c2', '2026-09-02', 400),
  ]);
  assert.equal(r.totals.firstOrderValue, 600);

  const none = run([
    job('a', 'c1', '2024-01-01', 500),
    job('b', 'c1', '2026-09-01', 500),
  ], { from: '2026-09-01' });
  assert.equal(none.totals.firstOrderValue, null);
});

test('an order with no customer on it is not in either half', () => {
  const r = run([
    { id: 'a', status: 'completed', date: '2026-09-01', price: 900 },
    job('b', 'c1', '2026-09-01', 100),
  ]);
  assert.equal(r.totals.revenue, 100);
});

test('nothing at all is an answer, not a throw', () => {
  const r = customerMix(undefined, undefined);
  assert.equal(r.totals.revenue, 0);
  assert.equal(r.totals.clients, 0);
  assert.equal(r.totals.firstOrderValue, null);
});

/**
 * The other app's range picker offers named periods — "this quarter" — and
 * owns a predicate for them. Re-deriving the bounds outside the module would
 * be a second answer to a question `lib/date-range.js` already answers.
 */
test('a caller can hand over its own window predicate instead of dates', () => {
  const orders = [
    job('a', 'c1', '2024-01-01', 5000),
    job('b', 'c1', '2026-09-01', 1000),
    job('c', 'c2', '2026-09-02', 300),
  ];
  const r = customerMix({ orders }, {
    ...deps, inWindow: (o) => o.date.startsWith('2026-09'),
  });
  assert.equal(r.totals.revenue, 1300);
  // History still decides who is new, so c1 is returning even though its first
  // order is outside the window.
  assert.equal(r.returning.jobs, 1);
  assert.equal(r.fresh.jobs, 1);
});

test('the predicate wins over from/to when both are given', () => {
  const orders = [job('a', 'c1', '2026-09-01', 100), job('b', 'c2', '2026-01-01', 900)];
  const r = customerMix({ orders, from: '2026-09-01' }, {
    ...deps, inWindow: () => true,
  });
  assert.equal(r.totals.revenue, 1000);
});
