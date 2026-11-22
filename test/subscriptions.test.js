'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  INTERVALS,
  nextRunDate,
  cyclesDue,
  isDueForCycle,
  selectDueSubscriptions,
  advanceSchedule,
  markCyclePatch,
} = require('../lib/subscriptions');

// A fixed "now" for determinism: 2026-06-16 (midday, to prove time-of-day is
// discarded and day-granularity comparison is used).
const NOW = new Date(2026, 5, 16, 12, 30, 0).getTime();
const TODAY = '2026-06-16';

const sub = (over) => ({
  id: 'SUB-1',
  status: 'active',
  interval: 'weekly',
  nextRunAt: TODAY,
  ...over,
});

/* ───────────────────────── nextRunDate ───────────────────────── */

test('nextRunDate: daily adds one day', () => {
  assert.equal(nextRunDate('2026-06-16', 'daily'), '2026-06-17');
});

test('nextRunDate: weekly adds seven days', () => {
  assert.equal(nextRunDate('2026-06-16', 'weekly'), '2026-06-23');
});

test('nextRunDate: biweekly adds fourteen days (across month boundary)', () => {
  assert.equal(nextRunDate('2026-06-25', 'biweekly'), '2026-07-09');
});

test('nextRunDate: monthly keeps day-of-month', () => {
  assert.equal(nextRunDate('2026-06-15', 'monthly'), '2026-07-15');
});

test('nextRunDate: monthly clamps Jan 31 -> Feb 28 (non-leap)', () => {
  assert.equal(nextRunDate('2026-01-31', 'monthly'), '2026-02-28');
});

test('nextRunDate: monthly clamps Jan 31 -> Feb 29 (leap year)', () => {
  assert.equal(nextRunDate('2024-01-31', 'monthly'), '2024-02-29');
});

test('nextRunDate: monthly clamps Jan 30 -> Feb 28 then back to Mar 30', () => {
  // Spec note: clamping is per-hop; Jan 30 -> Feb 28 -> Mar 28 (carries clamp).
  const feb = nextRunDate('2026-01-30', 'monthly');
  assert.equal(feb, '2026-02-28');
  assert.equal(nextRunDate(feb, 'monthly'), '2026-03-28');
});

test('nextRunDate: monthly across year boundary', () => {
  assert.equal(nextRunDate('2026-12-10', 'monthly'), '2027-01-10');
});

test('nextRunDate: quarterly adds three months with clamping', () => {
  assert.equal(nextRunDate('2026-01-31', 'quarterly'), '2026-04-30');
});

test('nextRunDate: yearly adds twelve months', () => {
  assert.equal(nextRunDate('2026-06-16', 'yearly'), '2027-06-16');
});

test('nextRunDate: yearly clamps Feb 29 -> Feb 28', () => {
  assert.equal(nextRunDate('2024-02-29', 'yearly'), '2025-02-28');
});

test('nextRunDate: accepts an ISO timestamp and normalises to the day', () => {
  assert.equal(nextRunDate('2026-06-16T23:59:00.000Z', 'daily'), '2026-06-17');
});

test('nextRunDate: every declared interval produces a valid future date', () => {
  for (const iv of INTERVALS) {
    const out = nextRunDate('2026-06-16', iv);
    assert.match(out, /^\d{4}-\d{2}-\d{2}$/, `${iv} produced ${out}`);
    assert.ok(out > '2026-06-16', `${iv} should advance past the source date`);
  }
});

test('nextRunDate: rejects unknown interval and bad date', () => {
  assert.throws(() => nextRunDate('2026-06-16', 'fortnightly'));
  assert.throws(() => nextRunDate('not-a-date', 'daily'));
});

/* ───────────────────────── isDueForCycle ───────────────────────── */

test('isDueForCycle: due when active and nextRunAt is today', () => {
  assert.equal(isDueForCycle(sub({ nextRunAt: TODAY }), NOW), true);
});

test('isDueForCycle: due when nextRunAt is in the past', () => {
  assert.equal(isDueForCycle(sub({ nextRunAt: '2026-05-01' }), NOW), true);
});

test('isDueForCycle: not due when nextRunAt is in the future', () => {
  assert.equal(isDueForCycle(sub({ nextRunAt: '2026-07-01' }), NOW), false);
});

test('isDueForCycle: not due when paused or cancelled', () => {
  assert.equal(isDueForCycle(sub({ status: 'paused' }), NOW), false);
  assert.equal(isDueForCycle(sub({ status: 'cancelled' }), NOW), false);
});

test('isDueForCycle: not due past endAt', () => {
  assert.equal(isDueForCycle(sub({ nextRunAt: '2026-05-01', endAt: '2026-06-01' }), NOW), false);
});

test('isDueForCycle: still due when endAt is today or later', () => {
  assert.equal(isDueForCycle(sub({ nextRunAt: '2026-05-01', endAt: TODAY }), NOW), true);
});

/* ───────────────────── selectDueSubscriptions ───────────────────── */

test('selectDueSubscriptions: empty / non-array input is safe', () => {
  assert.deepEqual(selectDueSubscriptions([], NOW), []);
  assert.deepEqual(selectDueSubscriptions(undefined, NOW), []);
  assert.deepEqual(selectDueSubscriptions(null, NOW), []);
});

test('selectDueSubscriptions: filters paused, cancelled, and future subs', () => {
  const subs = [
    sub({ id: 'A', nextRunAt: '2026-06-10' }),                 // due
    sub({ id: 'B', nextRunAt: '2026-06-10', status: 'paused' }), // paused
    sub({ id: 'C', nextRunAt: '2026-06-10', status: 'cancelled' }), // cancelled
    sub({ id: 'D', nextRunAt: '2026-12-01' }),                 // future
  ];
  const due = selectDueSubscriptions(subs, NOW);
  assert.deepEqual(due.map((s) => s.id), ['A']);
});

test('selectDueSubscriptions: sorts soonest nextRunAt first', () => {
  const subs = [
    sub({ id: 'late', nextRunAt: '2026-06-15' }),
    sub({ id: 'early', nextRunAt: '2026-05-01' }),
    sub({ id: 'mid', nextRunAt: '2026-06-01' }),
  ];
  const due = selectDueSubscriptions(subs, NOW);
  assert.deepEqual(due.map((s) => s.id), ['early', 'mid', 'late']);
});

test('selectDueSubscriptions: annotates cyclesDue without mutating input', () => {
  const original = sub({ id: 'X', interval: 'weekly', nextRunAt: '2026-06-09' });
  const due = selectDueSubscriptions([original], NOW);
  assert.equal(due[0].cyclesDue, 2); // 06-09 due, next 06-16 == today => 2 boundaries
  assert.equal('cyclesDue' in original, false, 'input must not be mutated');
});

/* ───────────────────────── cyclesDue ───────────────────────── */

test('cyclesDue: future nextRunAt -> 0', () => {
  assert.equal(cyclesDue(sub({ nextRunAt: '2026-07-01' }), NOW), 0);
});

test('cyclesDue: nextRunAt exactly today -> 1', () => {
  assert.equal(cyclesDue(sub({ nextRunAt: TODAY }), NOW), 1);
});

test('cyclesDue: app closed 3 weeks for a weekly sub counts missed periods', () => {
  // nextRunAt 2026-05-26; boundaries: 05-26, 06-02, 06-09, 06-16(today) => 4.
  assert.equal(cyclesDue(sub({ interval: 'weekly', nextRunAt: '2026-05-26' }), NOW), 4);
});

test('cyclesDue: daily sub closed a week counts each day', () => {
  // 06-10..06-16 inclusive => 7.
  assert.equal(cyclesDue(sub({ interval: 'daily', nextRunAt: '2026-06-10' }), NOW), 7);
});

test('cyclesDue: monthly sub a few months stale', () => {
  // 2026-03-16, 04-16, 05-16, 06-16(today) => 4.
  assert.equal(cyclesDue(sub({ interval: 'monthly', nextRunAt: '2026-03-16' }), NOW), 4);
});

/* ───────────────────────── advanceSchedule ───────────────────────── */

test('advanceSchedule: lands strictly in the future (single missed cycle)', () => {
  const patch = advanceSchedule(sub({ interval: 'weekly', nextRunAt: TODAY }), NOW);
  assert.equal(patch.nextRunAt, '2026-06-23');
  assert.ok(patch.nextRunAt > TODAY);
});

test('advanceSchedule: catch-up skips past all missed periods to next future date', () => {
  // weekly, stale from 2026-05-26 -> next future boundary after today is 06-23.
  const patch = advanceSchedule(sub({ interval: 'weekly', nextRunAt: '2026-05-26' }), NOW);
  assert.equal(patch.nextRunAt, '2026-06-23');
  assert.ok(patch.nextRunAt > TODAY);
});

test('advanceSchedule: stamps lastRunAt from injected now', () => {
  const patch = advanceSchedule(sub({ nextRunAt: TODAY }), NOW);
  assert.equal(patch.lastRunAt, new Date(NOW).toISOString());
});

test('advanceSchedule: monthly catch-up across clamp lands in future', () => {
  // Per-hop clamp carries: 01-31 -> 02-28 -> 03-28 -> ... -> 06-28 (first > today).
  const patch = advanceSchedule(sub({ interval: 'monthly', nextRunAt: '2026-01-31' }), NOW);
  assert.ok(patch.nextRunAt > TODAY, `expected future, got ${patch.nextRunAt}`);
  assert.equal(patch.nextRunAt, '2026-06-28');
});

/* ───────────────────────── markCyclePatch ───────────────────────── */

test('markCyclePatch: advances by exactly one interval from the cursor', () => {
  const patch = markCyclePatch(sub({ interval: 'weekly', nextRunAt: '2026-05-26' }), NOW);
  assert.equal(patch.nextRunAt, '2026-06-02'); // one hop, NOT a catch-up jump
});

test('markCyclePatch: monthly advances one month with clamping', () => {
  const patch = markCyclePatch(sub({ interval: 'monthly', nextRunAt: '2026-01-31' }), NOW);
  assert.equal(patch.nextRunAt, '2026-02-28');
});

test('markCyclePatch: stamps lastRunAt from injected runIso', () => {
  const patch = markCyclePatch(sub({ nextRunAt: TODAY }), NOW);
  assert.equal(patch.lastRunAt, new Date(NOW).toISOString());
});

test('markCyclePatch: throws on missing nextRunAt', () => {
  assert.throws(() => markCyclePatch(sub({ nextRunAt: undefined }), NOW));
});

/* ─────────────── catch-up consistency: N markCyclePatch == advanceSchedule ─────────────── */

test('looping markCyclePatch for cyclesDue lands on advanceSchedule target', () => {
  const s = sub({ interval: 'weekly', nextRunAt: '2026-05-26' });
  const n = cyclesDue(s, NOW);
  let cursor = s.nextRunAt;
  for (let i = 0; i < n; i++) {
    cursor = markCyclePatch({ interval: s.interval, nextRunAt: cursor }, NOW).nextRunAt;
  }
  assert.equal(cursor, advanceSchedule(s, NOW).nextRunAt);
});

/* ─────────────── determinism: same inputs -> identical results ─────────────── */

test('selectDueSubscriptions is deterministic for a fixed now', () => {
  const subs = [sub({ id: 'A', nextRunAt: '2026-06-01' })];
  assert.deepEqual(selectDueSubscriptions(subs, NOW), selectDueSubscriptions(subs, NOW));
});

test('monthlyRecurringRevenue normalizes intervals + ignores non-active', () => {
  const { monthlyRecurringRevenue } = require('../lib/subscriptions.js');
  const subs = [
    { status: 'active', amount: 100, interval: 'monthly' },    // 100/mo
    { status: 'active', amount: 300, interval: 'quarterly' },  // 100/mo
    { status: 'active', amount: 1200, interval: 'yearly' },    // 100/mo
    { status: 'paused', amount: 999, interval: 'monthly' },    // ignored
    { status: 'active', amount: 0, interval: 'monthly' },      // 0
  ];
  assert.equal(monthlyRecurringRevenue(subs), 300);
  assert.equal(monthlyRecurringRevenue([]), 0);
  // weekly ≈ 4.33 cycles/month
  assert.ok(Math.abs(monthlyRecurringRevenue([{ status: 'active', amount: 10, interval: 'weekly' }]) - 43.45) < 0.2);
});
