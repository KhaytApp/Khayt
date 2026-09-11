'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { breakEven } = require('../lib/break-even.js');

const deps = { revenueOf: (o) => o.price, partCostOf: (p) => p.cost };
const job = (date, price, ...costs) => ({
  date, price, parts: costs.map((cost) => ({ cost })),
});

test('break-even is the fixed costs divided by what is left of each riyal', () => {
  // 1000 billed, 250 of it spent making the thing → 75% left over.
  // 3000 of rent needs 4000 billed to cover it.
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 3000 }],
    completed: [job('2026-09-01', 1000, 250)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.totalFixed, 3000);
  assert.equal(r.marginPct, 0.75);
  assert.equal(r.breakEvenRevenue, 4000);
});

/**
 * THE CORRECTION THIS MODULE CARRIES.
 *
 * The inline version costed a job by looking up each part's spool and skipped
 * any part with no `filamentId`. An unlinked part cost nothing, the margin came
 * out too high, and the target came out too LOW — a shop told it needed to bill
 * less than it does, on a figure whose whole job is to be a floor.
 */
test('every part costs something, including one with no spool linked', () => {
  const linked = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 1000 }],
    completed: [job('2026-09-01', 1000, 500)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  // The same job, with the cost the old rule would have thrown away.
  const asIfFree = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 1000 }],
    completed: [job('2026-09-01', 1000, 0)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(asIfFree.breakEvenRevenue, 1000, 'a free job implies a 100% margin');
  assert.equal(linked.breakEvenRevenue, 2000);
  assert.ok(linked.breakEvenRevenue > asIfFree.breakEvenRevenue,
    'costing the work must RAISE the target, never lower it');
});

test('no finished work is no answer, not a margin of zero', () => {
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 3000 }],
    completed: [], since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.breakEvenRevenue, null);
  assert.equal(r.marginPct, null, 'zero would read as "you can never break even"');
  assert.equal(r.avgRevenuePerJob, null);
  assert.equal(r.jobsCounted, 0);
  // The fixed costs are still known and still worth showing.
  assert.equal(r.totalFixed, 3000);
});

test('no fixed costs means no target, and that is not an error', () => {
  const r = breakEven({
    fixedCosts: [], completed: [job('2026-09-01', 1000, 250)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.totalFixed, 0);
  assert.equal(r.breakEvenRevenue, null);
  assert.equal(r.marginPct, 0.75, 'the margin is still knowable');
});

/// A window where the work cost more than it earned has no break-even point.
/// A negative margin would produce a negative target — a number that reads as
/// "bill less to break even".
test('a loss-making window has no target, not a negative one', () => {
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 3000 }],
    completed: [job('2026-09-01', 100, 400)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.marginPct, 0);
  assert.equal(r.breakEvenRevenue, null);
});

test('only the chosen window informs the margin', () => {
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 1000 }],
    completed: [
      job('2026-01-01', 1000, 900),   // a bad month, long ago
      job('2026-09-01', 1000, 250),
    ],
    since: '2026-06-01', month: '2026-09',
  }, deps);
  assert.equal(r.jobsCounted, 1);
  assert.equal(r.marginPct, 0.75);
});

test('this month is this month, and the surplus is signed', () => {
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 3000 }],
    completed: [
      job('2026-08-31', 5000, 1250),
      job('2026-09-02', 1000, 250),
      job('2026-09-20', 500, 125),
    ],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.billedThisMonth, 1500, 'August is not this month');
  assert.equal(r.breakEvenRevenue, 4000);
  assert.equal(r.surplus, -2500);
  assert.equal(r.progressPct, 37.5);
});

test('progress is clamped, so a very good month does not draw past the end', () => {
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: 1000 }],
    completed: [job('2026-09-01', 100000, 25000)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.progressPct, 100);
  assert.ok(r.surplus > 0);
});

test('junk in the fixed costs does not become a NaN target', () => {
  const r = breakEven({
    fixedCosts: [{ name: 'Rent', amount: '3000' }, { name: 'Junk', amount: 'abc' }, null],
    completed: [job('2026-09-01', 1000, 250)],
    since: '2026-01-01', month: '2026-09',
  }, deps);
  assert.equal(r.totalFixed, 3000);
  assert.equal(r.breakEvenRevenue, 4000);
  assert.equal(r.costs.length, 2);
});

test('nothing at all is an answer, not a throw', () => {
  const r = breakEven(undefined, undefined);
  assert.equal(r.totalFixed, 0);
  assert.equal(r.breakEvenRevenue, null);
  assert.equal(r.billedThisMonth, 0);
  assert.deepEqual(r.costs, []);
});
