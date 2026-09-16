'use strict';
/**
 * How long a job takes — by month, and by product.
 *
 * Lifted from two inline charts in renderer/analytics.js that shared one
 * fault and one weakness, each named by a test below.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/cycle-time.js');

const NOW = new Date(2026, 8, 16, 10, 0, 0).getTime();
const job = (over) => ({ id: 'J', status: 'completed', date: '2026-09-01', completedAt: '2026-09-04T12:00:00', project: 'Bracket', ...over });

test('a DELIVERED job is measured — it is past completed, not outside it', () => {
  const r = C.cycleTime([job(), job({ status: 'delivered', date: '2026-09-02', completedAt: '2026-09-04T12:00:00' })], { now: NOW });
  const sep = r.months.find((m) => m.key === '2026-09');
  assert.equal(sep.jobs, 2);
  assert.equal(sep.avgDays, 3);      // 3.5 and 2.5
  assert.equal(r.avgDays, 3);
  assert.equal(r.jobs, 2);
});

test('a job delivered without ever passing through completed has a finish day', () => {
  const r = C.cycleTime([job({ status: 'delivered', completedAt: undefined, deliveredAt: '2026-09-05T09:00:00' })], { now: NOW });
  assert.equal(r.months.find((m) => m.key === '2026-09').jobs, 1);
  assert.equal(C.daysToFinish(job({ completedAt: undefined, deliveredAt: undefined })), null, 'and one with neither cannot be measured');
});

test('voided, unfinished, out-of-trade and impossible intervals are left out', () => {
  const orders = [
    job(),
    job({ voidedAt: 'x' }),
    job({ status: 'pending' }),
    job({ status: 'cancelled' }),
    job({ hobby: true }),
    job({ date: '2026-09-10', completedAt: '2026-09-04T12:00:00' }),   // finished before taken
    job({ date: '' }),
  ];
  const r = C.cycleTime(orders, { now: NOW, countsForBusiness: (o) => !o.hobby });
  assert.equal(r.jobs, 1);
});

test('a month with nothing finished has no figure, not zero, and the window is the last six months', () => {
  const r = C.cycleTime([job()], { now: NOW });
  assert.deepEqual(r.months.map((m) => m.key), ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09']);
  assert.equal(r.months[0].avgDays, null);
  assert.equal(r.months[0].jobs, 0);
  assert.equal(C.cycleTime([], { now: NOW }).avgDays, null);
});

test('a job counts in the month it was FINISHED', () => {
  const r = C.cycleTime([job({ date: '2026-07-28', completedAt: '2026-08-02T10:00:00' })], { now: NOW });
  assert.equal(r.months.find((m) => m.key === '2026-08').jobs, 1);
  assert.equal(r.months.find((m) => m.key === '2026-07').jobs, 0);
  assert.equal(r.months.find((m) => m.key === '2026-08').avgDays, 5.4);
});

test('lead time is keyed by the product when the job names one, and by the name only when it does not', () => {
  // The original keyed on the free-text `project`, so "Bracket" and "bracket"
  // were two products and a job taken from the catalogue did not join its product.
  const orders = [
    job({ productId: 'P1', project: 'Bracket', completedAt: '2026-09-03T00:00:00' }),
    job({ productId: 'P1', project: 'Bracket (rush)', completedAt: '2026-09-05T00:00:00' }),
    job({ project: 'Lid', completedAt: '2026-09-02T00:00:00' }),
    job({ project: 'lid ', completedAt: '2026-09-04T00:00:00' }),
    job({ status: 'delivered', project: 'Vase', completedAt: '2026-09-11T00:00:00' }),
  ];
  const r = C.leadTimeByProduct(orders, {});
  assert.equal(r.jobs, 5);
  assert.deepEqual(r.rows.map((x) => [x.key, x.name, x.avgDays, x.fastest, x.slowest, x.jobs]), [
    ['name:vase', 'Vase', 10, 10, 10, 1],
    ['product:P1', 'Bracket', 3, 2, 4, 2],
    ['name:lid', 'Lid', 2, 1, 3, 2],
  ], 'slowest first; the product keeps the first name it was seen under');
  assert.equal(r.rows[1].productId, 'P1');
  assert.equal(r.rows[2].productId, null);
});

test('the table is capped, and a nameless job is still a row', () => {
  const orders = Array.from({ length: 12 }, (_, i) => job({ project: 'P' + i, completedAt: `2026-09-0${(i % 9) + 1}T00:00:00` }));
  assert.equal(C.leadTimeByProduct(orders, { top: 5 }).rows.length, 5);
  assert.equal(C.leadTimeByProduct([job({ project: '' })], {}).rows[0].name, 'Unknown');
});
