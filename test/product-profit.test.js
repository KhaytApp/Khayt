'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { productProfit, FINISHED } = require('../lib/product-profit.js');

const deps = { partCostOf: (p) => p.cost, countsForBusiness: (o) => o.business !== false };
const products = [{ id: 'p1', name: 'Big slow thing' }, { id: 'p2', name: 'Small quick thing' }];
const job = (id, productId, status, price, cost, hours) => ({
  id, productId, status, price, parts: [{ cost, printTime: hours, qty: 1 }],
});
function run(orders, expenses = []) {
  return productProfit({ orders, products, expenses, untagged: 'Untagged' }, deps);
}
const of = (r, id) => r.rows.find((x) => x.productId === id);

/**
 * THE REASON THIS TABLE EXISTS.
 *
 * The row a shop opens it to find is the big seller that earns nothing —
 * and ranking by revenue, which is what the version this replaces did, puts
 * that row at the top looking like the best thing in the shop.
 */
test('rows are ranked by what they earn, not by what they bill', () => {
  const r = run([
    job('1', 'p1', 'completed', 10000, 9800, 40),   // huge revenue, almost no profit
    job('2', 'p2', 'completed', 2000, 200, 4),
  ]);
  assert.equal(r.rows[0].productId, 'p2');
  assert.equal(r.rows[0].profit, 1800);
  assert.equal(r.rows[1].profit, 200);
});

/**
 * A print shop's constraint is the hours its printers can run. Two products at
 * the same margin are not equal if one takes two hours and the other twenty.
 */
test('profit per machine hour is reported, and it reorders the answer', () => {
  const r = run([
    job('1', 'p1', 'completed', 5000, 2000, 40),
    job('2', 'p2', 'delivered', 800, 100, 2),
    job('3', 'p2', 'delivered', 800, 100, 2),
  ]);
  assert.equal(of(r, 'p1').profitPerHour, 75);
  assert.equal(of(r, 'p2').profitPerHour, 350);
  // The biggest earner is p1; the best use of a machine hour is p2.
  assert.equal(r.rows[0].productId, 'p1');
  assert.equal(r.totals.bestPerHour.productId, 'p2');
});

/**
 * The same mistake the quote funnel made, in a second place: `delivered` is
 * where finished work ends up, so a product that reached a customer dropped
 * out of its own profitability row.
 */
test('delivered work counts, so a product does not vanish once it ships', () => {
  const r = run([
    job('1', 'p1', 'delivered', 1000, 400, 5),
    job('2', 'p1', 'completed', 1000, 400, 5),
  ]);
  assert.equal(of(r, 'p1').jobs, 2);
  assert.equal(of(r, 'p1').revenue, 2000);
  assert.deepEqual(FINISHED, ['completed', 'delivered']);
});

test('unfinished, voided and out-of-trade work is not in the table', () => {
  const r = run([
    job('1', 'p1', 'printing', 9000, 10, 5),
    job('2', 'p1', 'quote', 9000, 10, 5),
    { ...job('3', 'p1', 'completed', 9000, 10, 5), voidedAt: '2026-09-01' },
    { ...job('4', 'p1', 'completed', 9000, 10, 5), business: false },
    job('5', 'p1', 'completed', 100, 10, 1),
  ]);
  assert.equal(of(r, 'p1').jobs, 1);
  assert.equal(of(r, 'p1').revenue, 100);
});

test('an expense booked against a job is part of that product’s cost', () => {
  const r = run(
    [job('1', 'p1', 'completed', 1000, 100, 5)],
    [{ orderId: '1', amount: 300 }, { orderId: 'other', amount: 5000 }]);
  assert.equal(of(r, 'p1').cost, 400);
  assert.equal(of(r, 'p1').profit, 600);
});

test('work naming no product is collected under one name, not dropped', () => {
  const r = run([
    { id: '1', status: 'completed', price: 500, parts: [{ cost: 100, printTime: 2, qty: 1 }] },
  ]);
  assert.equal(of(r, '__none__').name, 'Untagged');
  assert.equal(of(r, '__none__').revenue, 500);
});

/// 0% would read as "it breaks even" rather than "nothing is known", and
/// Infinity sorts first and is not an answer.
test('no revenue is no margin, and no recorded hours is no rate', () => {
  const r = run([
    { id: '1', productId: 'p1', status: 'completed', price: 0,
      parts: [{ cost: 0, printTime: 0, qty: 1 }] },
  ]);
  assert.equal(of(r, 'p1').marginPct, null);
  assert.equal(of(r, 'p1').profitPerHour, null);
  assert.equal(r.totals.bestPerHour, null);
});

test('hours count every unit, not every line', () => {
  const r = productProfit({
    orders: [{ id: '1', productId: 'p1', status: 'completed', price: 900,
               parts: [{ cost: 0, printTime: 3, qty: 4 }] }],
    products, expenses: [], untagged: 'Untagged',
  }, deps);
  assert.equal(of(r, 'p1').hours, 12);
});

test('the totals are the rows, so the table cannot disagree with its own sum', () => {
  const r = run([
    job('1', 'p1', 'completed', 1000, 400, 5),
    job('2', 'p2', 'delivered', 500, 100, 2),
  ]);
  assert.equal(r.totals.revenue, r.rows.reduce((s, x) => s + x.revenue, 0));
  assert.equal(r.totals.profit, r.rows.reduce((s, x) => s + x.profit, 0));
  assert.equal(r.totals.jobs, 2);
  assert.equal(r.totals.marginPct, (1500 - 500) / 1500 * 100);
});

test('nothing at all is an answer, not a throw', () => {
  const r = productProfit(undefined, undefined);
  assert.deepEqual(r.rows, []);
  assert.equal(r.totals.revenue, 0);
  assert.equal(r.totals.marginPct, null);
  assert.equal(r.totals.bestPerHour, null);
});
