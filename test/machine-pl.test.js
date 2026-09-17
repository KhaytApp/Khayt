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

// ── HOURS AND UTILISATION ───────────────────────────────────────────────────
//
// `renderPrinterUtilizationChart` worked these out inline, three ways wrong:
// it capped utilisation at 100, it measured hours from the ESTIMATE even where
// the printer had measured the print, and it computed a margin from material
// cost alone — so the same machine carried one margin in that chart and
// another in the P&L table on the same screen.

test('utilisation is NOT capped at 100', () => {
  // A printer meant to run 8h a day, over 10 days, that ran 120 hours. It is
  // at 150% and that is the whole reading: the machine to buy a second of.
  // `Math.min(100, …)` made it identical to one that hit its target exactly.
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1', targetHoursPerDay: 8 }],
    completed: [{ id: 'a', machineId: 'M1', price: 100, printTime: 120 }],
    days: 10,
  }, deps);
  assert.equal(rows[0].hours, 120);
  assert.equal(rows[0].utilisationPct, 150);
});

test('hours come from what the print TOOK, not what it was quoted at', () => {
  // The estimate said four hours; the printer measured six. A shop whose
  // prints run over read as under-worked, from the same book.
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1', targetHoursPerDay: 6 }],
    completed: [
      { id: 'a', machineId: 'M1', price: 100, printTime: 4, actualPrintTime: 6,
        actualsSource: 'printer' },
      // No actual recorded, so the estimate is the best account there is.
      { id: 'b', machineId: 'M1', price: 100, printTime: 3 },
    ],
    days: 3,
  }, deps);
  assert.equal(rows[0].hours, 9, 'the quoted 4 was counted instead of the measured 6');
  assert.equal(rows[0].measured, 1, 'how many of the hours are measured is reportable');
  assert.equal(rows[0].utilisationPct, 50);
});

test('a TYPED actual still counts as hours, unlike in machine-accuracy', () => {
  // The two modules ask different questions. Accuracy must know where the
  // figure came from, because an estimate confirmed by hand compared against
  // itself reports a perfectly calibrated machine. "How busy was it" does not
  // care: the shop's own account of the time is the best there is.
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1', targetHoursPerDay: 1 }],
    completed: [{ id: 'a', machineId: 'M1', price: 1, printTime: 2,
                  actualPrintTime: 5, actualsSource: 'typed' }],
    days: 10,
  }, deps);
  assert.equal(rows[0].hours, 5);
});

test('no target and no range mean no utilisation, not nought per cent', () => {
  // A machine nobody has set a target for has no utilisation. Zero would read
  // as idle, which is a claim about the machine rather than about the book.
  const noTarget = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }],
    completed: [{ id: 'a', machineId: 'M1', price: 100, printTime: 9 }],
    days: 30,
  }, deps).rows[0];
  assert.equal(noTarget.utilisationPct, null);
  assert.equal(noTarget.hours, 9, 'the hours are still known');

  const noDays = machineProfit({
    machines: [{ id: 'M1', name: 'U1', targetHoursPerDay: 8 }],
    completed: [{ id: 'a', machineId: 'M1', price: 100, printTime: 9 }],
  }, deps).rows[0];
  assert.equal(noDays.utilisationPct, null, 'utilisation without a denominator is a guess');
});

test('work naming no machine has hours but never a utilisation', () => {
  const { rows } = machineProfit({
    machines: [{ id: 'M1', name: 'U1', targetHoursPerDay: 8 }],
    completed: [{ id: 'a', price: 100, printTime: 5 }],
    unassigned: 'Unassigned',
    days: 1,
  }, deps);
  const none = rows.find(r => r.machineId === '__none__');
  assert.equal(none.hours, 5);
  assert.equal(none.utilisationPct, null, 'nothing has a target for work with no machine');
});

test('the totals carry the hours, so a screen never re-adds them', () => {
  const { totals } = machineProfit({
    machines: [{ id: 'M1', name: 'A' }, { id: 'M2', name: 'B' }],
    completed: [
      { id: 'a', machineId: 'M1', price: 10, printTime: 3, actualPrintTime: 4 },
      { id: 'b', machineId: 'M2', price: 10, printTime: 2 },
    ],
    days: 1,
  }, deps);
  assert.equal(totals.hours, 6);
  assert.equal(totals.measured, 1);
});
