'use strict';
/**
 * What each machine earned, and what it cost to keep earning it.
 *
 * Lifted out of `renderer/analytics.js`, where it was computed inline — fine
 * until a second app wants the same answer, and then there are two
 * implementations of "what did this machine earn" and the one a shop happens
 * to be looking at decides. Worse here than most: this is the number an owner
 * uses to decide whether to RETIRE a machine.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { machineProfit } = require('../lib/machine-pl.js');

const deps = {
  revenueOf: (o) => +o.price || 0,
  partCostOf: (p) => +p.cost || 0,
};
const job = (id, machineId, price, parts = []) =>
  ({ id, machineId, price, parts, status: 'completed' });

test('a machine\'s net is its revenue less material, linked expenses and maintenance', () => {
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }],
    completed: [job('a', 'M1', 1000, [{ cost: 200 }, { cost: 50 }])],
    expenses: [{ orderId: 'a', amount: 120 }],
    maintenance: [{ machineId: 'M1', cost: 80 }],
  }, deps);
  const u1 = rows.find(r => r.machineId === 'M1');
  assert.equal(u1.revenue, 1000);
  assert.equal(u1.materialCost, 250);
  assert.equal(u1.linkedExpenses, 120);
  assert.equal(u1.maintenance, 80);
  assert.equal(u1.net, 550);
  assert.equal(u1.marginPct, 55);
});

test('work that names no machine is its own row, not silently dropped', () => {
  // A shop's unassigned work is money it earned. Leaving it out makes the
  // machine rows fail to add up to the shop's own P&L, and the difference is
  // invisible.
  const { rows, totals } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }],
    completed: [job('a', 'M1', 100), job('b', '', 400), job('c', 'GONE', 250)],
    unassigned: 'Unassigned',
  }, deps);
  const none = rows.find(r => r.machineId === '__none__');
  assert.equal(none.jobs, 2, 'a job naming a machine that no longer exists was lost');
  assert.equal(none.revenue, 650);
  assert.equal(totals.revenue, 750);
});

test('a machine that finished nothing has no row', () => {
  // A row of zeroes reads as a machine that lost nothing, which is a different
  // claim from having done no work.
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }, { id: 'M2', name: 'Idle' }],
    completed: [job('a', 'M1', 100)],
  }, deps);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].machineId, 'M1');
});

test('a machine serviced in a range it did no work in still does not invent a row', () => {
  // The maintenance is counted where it belongs — but a machine with no
  // finished jobs has no P&L to put it in, and inventing one would show a
  // printer as pure loss for a month it was simply not used.
  const { rows, totals } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }],
    completed: [],
    maintenance: [{ machineId: 'M1', cost: 300 }],
  }, deps);
  assert.equal(rows.length, 0);
  assert.equal(totals.net, 0);
});

test('a machine that earned nothing has NO margin, not a margin of zero', () => {
  // 0% reads as "broke even". Null reads as "there is no answer", which is the
  // truth for a machine whose jobs were all priced at nothing.
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }],
    completed: [job('a', 'M1', 0, [{ cost: 40 }])],
  }, deps);
  assert.equal(rows[0].marginPct, null);
  assert.equal(rows[0].net, -40);
});

test('the best earner is first, because that is the order it is read in', () => {
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'Poor' }, { id: 'M2', name: 'Rich' }],
    completed: [job('a', 'M1', 100), job('b', 'M2', 900)],
  }, deps);
  assert.deepEqual(rows.map(r => r.machineId), ['M2', 'M1']);
});

test('an expense linked to one order is charged once, to that order\'s machine', () => {
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }, { id: 'M2', name: 'X1C' }],
    completed: [job('a', 'M1', 500), job('b', 'M2', 500)],
    expenses: [{ orderId: 'a', amount: 60 }, { orderId: 'a', amount: 40 },
               { orderId: 'zzz', amount: 999 }],
  }, deps);
  assert.equal(rows.find(r => r.machineId === 'M1').linkedExpenses, 100);
  assert.equal(rows.find(r => r.machineId === 'M2').linkedExpenses, 0,
    'an expense for another machine\'s order was charged here');
});

test('the totals are the rows, so a screen cannot show a sum that is not there', () => {
  const { rows, totals } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }, { id: 'M2', name: 'X1C' }],
    completed: [job('a', 'M1', 300, [{ cost: 50 }]), job('b', 'M2', 700, [{ cost: 90 }])],
    expenses: [{ orderId: 'b', amount: 10 }],
    maintenance: [{ machineId: 'M1', cost: 20 }],
  }, deps);
  assert.equal(totals.net, rows.reduce((s, r) => s + r.net, 0));
  assert.equal(totals.revenue, 1000);
  assert.equal(totals.maintenance, 20);
});
