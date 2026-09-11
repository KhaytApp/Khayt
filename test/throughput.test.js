'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { throughput, FINISHED } = require('../lib/throughput.js');

// A fixed instant, and the HOUR is read in the local zone by design — a shop
// asking when it is busy means its own clock. These use an explicit `whenOf`
// so the test does not depend on the machine running it.
const at = (day, hour) => ({ day, hour });
const job = (id, day, hour, status = 'completed', extra = {}) =>
  ({ id, status, _at: at(day, hour), ...extra });
const deps = {
  whenOf: (o) => {
    if (!o._at) return null;
    // 2023-01-01 was a Sunday, so day 0 lines up with getDay() === 0.
    const d = new Date(2023, 0, 1 + o._at.day, o._at.hour, 0, 0);
    return d.getTime();
  },
};
const OPEN = [true, true, true, true, true, false, false];   // Fri/Sat closed
function run(orders, input = {}) {
  return throughput({ orders, openDays: OPEN, minimum: 1, ...input }, deps);
}

test('each finished job lands in its own day and hour', () => {
  const r = run([job('a', 2, 14), job('b', 2, 14), job('c', 4, 9)]);
  assert.equal(r.matrix[2][14], 2);
  assert.equal(r.matrix[4][9], 1);
  assert.equal(r.totals.jobs, 3);
  assert.equal(r.totals.peak, 2);
});

/// The version this complements filtered on `completed` alone, so work that
/// reached a customer was not in the picture of when the shop is busy.
test('delivered work counts; unfinished, voided and untimed do not', () => {
  const r = run([
    job('a', 1, 10, 'delivered'),
    job('b', 1, 10, 'printing'),
    job('c', 1, 10, 'completed', { voidedAt: '2026-09-01' }),
    { id: 'd', status: 'completed' },                    // no timestamp at all
  ]);
  assert.equal(r.totals.jobs, 1);
  assert.deepEqual(FINISHED, ['completed', 'delivered']);
});

test('the busiest day and hour are named, and are null when nothing finished', () => {
  const r = run([job('a', 3, 16), job('b', 3, 16), job('c', 5, 2)]);
  assert.equal(r.totals.busiestDay, 3);
  assert.equal(r.totals.busiestHour, 16);

  const empty = run([]);
  assert.equal(empty.totals.busiestDay, null);
  assert.equal(empty.totals.busiestHour, null);
  assert.equal(empty.totals.closedDayShare, null);
});

/**
 * Either printers running unattended over a weekend, which is fine and worth
 * knowing, or somebody coming in on their day off, which is worth knowing for a
 * different reason. Neither app has said it.
 */
test('work finishing on a day the shop is closed is counted and shared', () => {
  const r = run([
    job('a', 1, 10),      // Monday, open
    job('b', 5, 23),      // Friday, closed
    job('c', 6, 3),       // Saturday, closed
    job('d', 6, 4),
  ]);
  assert.equal(r.totals.onClosedDays, 3);
  assert.equal(r.totals.closedDayShare, 0.75);
  assert.equal(r.byDay[5].open, false);
  assert.equal(r.byDay[1].open, true);
});

test('with no working week given, no day is called closed', () => {
  const r = throughput({ orders: [job('a', 6, 3)], minimum: 1 }, deps);
  assert.equal(r.totals.onClosedDays, 0);
  assert.ok(r.byDay.every((d) => d.open));
});

/**
 * Ten finished jobs spread over 168 cells is noise, and a grid of noise looks
 * exactly like a finding.
 */
test('a grid says whether there is enough behind it to read', () => {
  const few = throughput({ orders: [job('a', 1, 10)], openDays: OPEN }, deps);
  assert.equal(few.totals.enough, false, 'the default minimum is ten');
  assert.equal(few.totals.jobs, 1, 'and the figures are still true');

  const many = throughput({
    orders: Array.from({ length: 12 }, (_, n) => job(String(n), 1, 10)),
    openDays: OPEN,
  }, deps);
  assert.equal(many.totals.enough, true);
});

test('the day and hour totals are the matrix, so they cannot disagree with it', () => {
  const r = run([job('a', 2, 14), job('b', 2, 9), job('c', 4, 14)]);
  assert.equal(r.byDay[2].jobs, 2);
  assert.equal(r.byHour[14].jobs, 2);
  assert.equal(r.byDay.reduce((s, d) => s + d.jobs, 0), r.totals.jobs);
  assert.equal(r.byHour.reduce((s, h) => s + h.jobs, 0), r.totals.jobs);
});

test('a caller can hand over its own window predicate', () => {
  const r = throughput({ orders: [job('a', 1, 10), job('b', 2, 10)], openDays: OPEN, minimum: 1 },
                       { ...deps, inWindow: (o) => o.id === 'a' });
  assert.equal(r.totals.jobs, 1);
});

test('nothing at all is an answer, not a throw', () => {
  const r = throughput(undefined, undefined);
  assert.equal(r.totals.jobs, 0);
  assert.equal(r.totals.enough, false);
  assert.equal(r.matrix.length, 7);
  assert.equal(r.matrix[0].length, 24);
});
