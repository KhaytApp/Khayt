'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { capacity, BOOKED } = require('../lib/capacity.js');

const machines = [
  { id: 'm1', name: 'U1', targetHoursPerDay: 12 },
  { id: 'm2', name: 'Prusa', targetHoursPerDay: 8 },
];
function run(orders, extra = {}) {
  return capacity({ machines, orders, days: 7, unassigned: 'Unassigned', ...extra });
}
const of = (r, id) => r.rows.find((x) => x.machineId === id);

/**
 * THE ONE THIS MODULE EXISTS FOR.
 *
 * `pct` was `Math.min(100, …)`, so a machine booked three weeks over read as
 * exactly full — identical to one with nothing left and nothing waiting. "Full"
 * means take no more today; "300%" means the shop is three weeks behind and
 * somebody has to be told.
 */
test('overbooked is not the same as full, and is not clamped to it', () => {
  const full = run([{ machineId: 'm1', status: 'printing', printTime: 84 }]);
  const over = run([{ machineId: 'm1', status: 'printing', printTime: 252 }]);
  assert.equal(of(full, 'm1').loadPct, 100);
  assert.equal(of(full, 'm1').overbooked, false);
  assert.equal(of(over, 'm1').loadPct, 300);
  assert.equal(of(over, 'm1').overbooked, true);
});

/// The figure a shop actually acts on. "238%" is a fact; "17 days" is a date.
test('the queue reports when it clears, not just how full it is', () => {
  const r = run([{ machineId: 'm1', status: 'printing', printTime: 60 }]);
  assert.equal(of(r, 'm1').daysToClear, 5);          // 60h at 12h/day
  assert.equal(r.totals.daysToClear, 3);             // 60h across 20h/day
});

test('a voided order does not book a machine', () => {
  const r = run([
    { machineId: 'm1', status: 'pending', printTime: 12 },
    { machineId: 'm1', status: 'pending', printTime: 99, voidedAt: '2026-09-01' },
  ]);
  assert.equal(of(r, 'm1').bookedHours, 12);
  assert.equal(of(r, 'm1').jobs, 1);
});

/// A quote is not booked. Nobody has said yes to it, and counting it would make
/// the shop refuse work it has room for.
test('a quote does not book, and neither does finished work', () => {
  const r = run([
    { machineId: 'm1', status: 'quote', printTime: 50 },
    { machineId: 'm1', status: 'completed', printTime: 50 },
    { machineId: 'm1', status: 'delivered', printTime: 50 },
    { machineId: 'm1', status: 'cancelled', printTime: 50 },
    { machineId: 'm1', status: 'pending', printTime: 6 },
  ]);
  assert.equal(of(r, 'm1').bookedHours, 6);
  assert.deepEqual(BOOKED, ['pending', 'printing', 'post', 'qc', 'on_hold']);
});

/// Dropping it is how a queue grows behind a panel reading 40%.
test('work that names no machine is still work, and is held apart', () => {
  const r = run([
    { machineId: 'm1', status: 'pending', printTime: 12 },
    { status: 'pending', printTime: 30 },
  ]);
  assert.equal(of(r, '__none__').bookedHours, 30);
  assert.equal(r.totals.untargeted, 30);
  // It cannot be a percentage of anything, so it is NOT folded into the load.
  assert.equal(r.totals.loadPct, 12 / 140 * 100);
  assert.equal(r.totals.bookedHours, 42);
});

test('a machine with no target set keeps its hours but has no percentage', () => {
  const r = capacity({
    machines: [...machines, { id: 'm3', name: 'Old one' }],
    orders: [{ machineId: 'm3', status: 'pending', printTime: 40 }],
    days: 7, unassigned: 'Unassigned',
  });
  assert.equal(of(r, 'm3').bookedHours, 40);
  assert.equal(of(r, 'm3').loadPct, null, 'a percentage of nothing is not zero');
  assert.equal(of(r, 'm3').daysToClear, null);
  assert.equal(r.totals.untargeted, 40);
});

test('no machine has a target at all, which is a thing to say', () => {
  const r = capacity({
    machines: [{ id: 'm3', name: 'Old one' }],
    orders: [{ machineId: 'm3', status: 'pending', printTime: 40 }],
    days: 7,
  });
  assert.equal(r.totals.noTargets, true);
  assert.equal(r.totals.loadPct, null);
  assert.equal(r.totals.bookedHours, 40);
});

test('an idle machine with a target is still a row — that IS the answer', () => {
  const r = run([]);
  assert.equal(r.rows.length, 2);
  assert.equal(of(r, 'm1').loadPct, 0);
  assert.equal(of(r, 'm1').daysToClear, 0);
  assert.equal(r.totals.overbooked, false);
});

test('the busiest machine is first', () => {
  const r = run([
    { machineId: 'm2', status: 'pending', printTime: 50 },
    { machineId: 'm1', status: 'pending', printTime: 12 },
  ]);
  assert.equal(r.rows[0].machineId, 'm2');
});

test('the window is the caller’s to choose', () => {
  const orders = [{ machineId: 'm1', status: 'pending', printTime: 84 }];
  assert.equal(of(run(orders, { days: 7 }), 'm1').loadPct, 100);
  assert.equal(of(run(orders, { days: 14 }), 'm1').loadPct, 50);
  // Days to clear does not depend on the window — it is hours over hours a day.
  assert.equal(of(run(orders, { days: 14 }), 'm1').daysToClear, 7);
});

test('an estimate can come from somewhere other than printTime', () => {
  const r = capacity({ machines, orders: [{ machineId: 'm1', status: 'pending', eta: 24 }], days: 7 },
                     { hoursOf: (o) => o.eta });
  assert.equal(of(r, 'm1').bookedHours, 24);
});

test('nothing at all is an answer, not a throw', () => {
  const r = capacity(undefined, undefined);
  assert.deepEqual(r.rows, []);
  assert.equal(r.totals.bookedHours, 0);
  assert.equal(r.totals.noTargets, true);
});
