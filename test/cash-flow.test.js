'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { cashFlow, monthsEnding } = require('../lib/cash-flow.js');

const deps = { revenueOf: (o) => o.price, countsForBusiness: (o) => o.business !== false };

function run(orders, expenses = [], endMonth = '2026-09', months = 4) {
  return cashFlow({ orders, expenses, endMonth, months }, deps);
}
const row = (r, month) => r.rows.find((x) => x.month === month);

test('the months run oldest first and cross a year end', () => {
  assert.deepEqual(monthsEnding('2026-02', 4), ['2025-11', '2025-12', '2026-01', '2026-02']);
  assert.deepEqual(monthsEnding('2026-09', 1), ['2026-09']);
  assert.deepEqual(monthsEnding('not a month', 6), []);
});

/**
 * THE BUG THIS MODULE EXISTS TO FIX.
 *
 * `paidAt` is set by `recordPayment` on ANY payment, a deposit included. The
 * version this replaces then counted the job's WHOLE revenue on that day — so
 * a 10% deposit on a 20,000 job showed 20,000 of cash in, on the one chart
 * whose entire subject is money the shop actually has.
 */
test('a deposit is the deposit, not the whole job', () => {
  const r = run([{ id: 'A', price: 20000, paidAmount: 2000, paidAt: '2026-08-10' }]);
  assert.equal(row(r, '2026-08').collected, 2000);
  assert.notEqual(row(r, '2026-08').collected, 20000);
});

test('a job paid in full is the whole job', () => {
  const r = run([{ id: 'A', price: 4000, paidAmount: 4000, paidAt: '2026-08-10' }]);
  assert.equal(row(r, '2026-08').collected, 4000);
});

test('a voided order is not cash, however much was paid on it', () => {
  const r = run([
    { id: 'A', price: 5000, paidAmount: 5000, paidAt: '2026-08-01', voidedAt: '2026-08-02' },
    { id: 'B', price: 1000, paidAmount: 1000, paidAt: '2026-08-03' },
  ]);
  assert.equal(row(r, '2026-08').collected, 1000);
});

test('work outside the shop’s trade is not counted, as everywhere else', () => {
  const r = run([
    { id: 'A', price: 5000, paidAmount: 5000, paidAt: '2026-08-01', business: false },
    { id: 'B', price: 1000, paidAmount: 1000, paidAt: '2026-08-03' },
  ]);
  assert.equal(row(r, '2026-08').collected, 1000);
});

/// Counted on the day money MOVED, never on the day the job finished. That
/// difference is the whole reason this is not the P&L.
test('an unpaid order moves nothing, whatever its status', () => {
  const r = run([
    { id: 'A', status: 'completed', price: 9000, paidAmount: 0, date: '2026-08-01' },
  ]);
  assert.equal(r.totals.collected, 0);
  assert.equal(r.totals.anyMovement, false);
});

test('expenses go out on the day they were paid', () => {
  const r = run([], [
    { date: '2026-07-04', amount: 300 },
    { date: '2026-08-14', amount: 500 },
    { date: '2026-08-20', amount: '250' },
  ]);
  assert.equal(row(r, '2026-07').paidOut, 300);
  assert.equal(row(r, '2026-08').paidOut, 750);
  assert.equal(r.totals.paidOut, 1050);
});

test('net is what came in less what went out, per month and in total', () => {
  const r = run(
    [{ id: 'A', price: 1000, paidAmount: 1000, paidAt: '2026-08-02' }],
    [{ date: '2026-08-05', amount: 1400 }]);
  assert.equal(row(r, '2026-08').net, -400);
  assert.equal(r.totals.net, -400);
});

test('anything outside the window is left out, not folded into an edge month', () => {
  const r = run(
    [{ id: 'A', price: 9999, paidAmount: 9999, paidAt: '2025-01-01' }],
    [{ date: '2030-01-01', amount: 9999 }]);
  assert.equal(r.totals.collected, 0);
  assert.equal(r.totals.paidOut, 0);
  assert.equal(r.rows.length, 4);
});

/// Six empty months and six months that genuinely netted nothing look the same
/// in the totals and are not the same thing to a screen.
test('a month with movement that nets zero is not the same as an empty one', () => {
  const empty = run([], []);
  const balanced = run(
    [{ id: 'A', price: 500, paidAmount: 500, paidAt: '2026-08-02' }],
    [{ date: '2026-08-03', amount: 500 }]);
  assert.equal(empty.totals.net, 0);
  assert.equal(balanced.totals.net, 0);
  assert.equal(empty.totals.anyMovement, false);
  assert.equal(balanced.totals.anyMovement, true);
});

test('an order with no price does not become a NaN month', () => {
  const r = run([
    { id: 'A', price: 0, paidAmount: 0, paidAt: '2026-08-01' },
    { id: 'B', paidAmount: 100, paidAt: '2026-08-02' },
  ]);
  assert.equal(row(r, '2026-08').collected, 0);
  assert.ok(Number.isFinite(r.totals.net));
});

test('paying more than the price is clamped to the price', () => {
  const r = run([{ id: 'A', price: 1000, paidAmount: 5000, paidAt: '2026-08-01' }]);
  assert.equal(row(r, '2026-08').collected, 1000);
});

test('nothing at all is an answer, not a throw', () => {
  const r = cashFlow(undefined, undefined);
  assert.deepEqual(r.rows, []);
  assert.equal(r.totals.net, 0);
  assert.equal(r.totals.anyMovement, false);
});

/**
 * MONEY PAID ON A DAY NOBODY RECORDED.
 *
 * `paidAt` was added after Khayt had been in use, so a shop's older orders
 * carry a `paidAmount` and no date. A timeline cannot place them — but leaving
 * them out SILENTLY is the one thing that must not happen: the sample shop has
 * thirty paid orders and not one `paidAt`, so the chart read "collected 0.00"
 * for a shop that had been paid thirty times, and looked entirely normal doing
 * it.
 */
test('money paid on an unrecorded day is counted, separately, never silently dropped', () => {
  const r = run([
    { id: 'A', price: 1000, paidAmount: 1000, paidAt: '2026-08-01' },
    { id: 'B', price: 4000, paidAmount: 2000 },             // paid, no date
    { id: 'C', price: 900, paidAmount: 900, paidAt: null },  // same
  ]);
  assert.equal(r.totals.collected, 1000, 'only what could be placed is on the timeline');
  assert.equal(r.totals.undated, 2900);
});

test('undated money is NOT folded into the totals the columns add up to', () => {
  const r = run([{ id: 'B', price: 4000, paidAmount: 4000 }]);
  // Otherwise the figure printed under the chart disagrees with the chart.
  assert.equal(r.totals.collected, 0);
  assert.equal(r.totals.net, 0);
  assert.equal(r.totals.undated, 4000);
  assert.equal(r.totals.anyMovement, false, 'nothing can be drawn, and that is true');
});

test('a voided or out-of-scope order is not undated money either', () => {
  const r = run([
    { id: 'A', price: 1000, paidAmount: 1000, voidedAt: '2026-08-02' },
    { id: 'B', price: 1000, paidAmount: 1000, business: false },
    { id: 'C', price: 1000, paidAmount: 0 },
  ]);
  assert.equal(r.totals.undated, 0);
});
