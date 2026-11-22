'use strict';
/**
 * Revenue per print-hour and material cost per gram, by month.
 *
 * Lifted from `renderCostTrends` in renderer/analytics.js, which had the
 * arithmetic inline and two defects in it — each named by a test below. The
 * shape is the one every report here takes: money and scope injected, `null`
 * where there is no answer.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/cost-trends.js');

const NOW = new Date(2026, 8, 16, 10, 0, 0).getTime(); // 16 Sep 2026, local
const done = (over) => ({ status: 'completed', date: '2026-09-02', price: 300, printTime: 3, ...over });

test('twelve months ending with this one, oldest first', () => {
  const keys = T.monthKeys(NOW, 12);
  assert.equal(keys.length, 12);
  assert.equal(keys[0], '2025-10');
  assert.equal(keys[11], '2026-09');
  assert.deepEqual(T.costTrends([], [], { now: NOW }).months.map((m) => m.key), keys);
});

test('a DELIVERED job counts — it is past completed, not outside it', () => {
  // The original counted `status === 'completed'` only, so a shop that hands
  // work over promptly saw its best months as empty.
  const orders = [done(), done({ status: 'delivered', price: 600 })];
  const r = T.costTrends(orders, [], { now: NOW });
  const sep = r.months.find((m) => m.key === '2026-09');
  assert.equal(sep.revenue, 900);
  assert.equal(sep.hours, 6);
  assert.equal(sep.perHour, 150);
  assert.equal(r.perHour, 150);
});

test('voided, out-of-trade and unfinished work is left out', () => {
  const orders = [
    done(),
    done({ voidedAt: '2026-09-03T00:00:00Z', price: 9999 }),
    done({ status: 'pending', price: 9999 }),
    done({ status: 'quote', price: 9999 }),
    done({ status: 'cancelled', price: 9999 }),
    done({ price: 9999, hobby: true }),
  ];
  const r = T.costTrends(orders, [], { now: NOW, countsForBusiness: (o) => !o.hobby });
  assert.equal(r.months.find((m) => m.key === '2026-09').revenue, 300);
});

test('a job counts in the month it was FINISHED, and revenue is the money rule\'s answer', () => {
  const orders = [done({ date: '2026-07-30', completedAt: '2026-08-02T09:00:00', price: 100 })];
  const r = T.costTrends(orders, [], { now: NOW, revenueOf: (o) => o.price * 2 });
  assert.equal(r.months.find((m) => m.key === '2026-08').revenue, 200);
  assert.equal(r.months.find((m) => m.key === '2026-07').revenue, 0);
  // With no completion instant, the day it was taken stands in.
  const r2 = T.costTrends([done({ date: '2026-07-30' })], [], { now: NOW });
  assert.equal(r2.months.find((m) => m.key === '2026-07').revenue, 300);
});

test('a month with no printing has NO per-hour figure, not zero', () => {
  const r = T.costTrends([done({ printTime: 0 })], [], { now: NOW });
  assert.equal(r.months.find((m) => m.key === '2026-09').perHour, null);
  assert.equal(r.perHour, null);
  assert.equal(r.months.find((m) => m.key === '2026-01').perHour, null, 'an empty month has none either');
});

test('a gram costs what the spool cost over what it weighed NEW — not what is left of it', () => {
  // The original divided by `weight`, the remaining grams, so a spool got
  // dearer per gram as it was used and a nearly finished one cost a fortune.
  const spools = [{ id: 's1', cost: 75, weight: 120, spoolWeight: 1000, openedAt: '2026-09-01T08:00:00Z' }];
  const r = T.costTrends([], spools, { now: NOW });
  assert.equal(r.months.find((m) => m.key === '2026-09').costPerGram, 0.075);
  assert.equal(r.costPerGram, 0.075);
});

test('cost per gram is a trend by the month the spool was opened, weighted by grams', () => {
  // The original computed today's shelf twelve times, so the "trend" was one
  // number repeated.
  const spools = [
    { id: 'a', cost: 60, spoolWeight: 1000, openedAt: '2026-07-10T08:00:00Z' },  // 0.06
    { id: 'b', cost: 100, spoolWeight: 1000, openedAt: '2026-09-01T08:00:00Z' }, // 0.10
    { id: 'c', cost: 50, spoolWeight: 500, openedAt: '2026-09-20T08:00:00Z' },   // 0.10
    { id: 'd', cost: 80, spoolWeight: 1000 },                                     // never opened: whole-window only
    { id: 'e', cost: 0, spoolWeight: 1000, openedAt: '2026-09-02T08:00:00Z' },    // no cost: not a reading
    { id: 'f', cost: 40, weight: 200, openedAt: '2026-09-02T08:00:00Z' },         // no new weight: not a reading
  ];
  const r = T.costTrends([], spools, { now: NOW });
  const by = Object.fromEntries(r.months.map((m) => [m.key, m]));
  assert.equal(by['2026-07'].costPerGram, 0.06);
  assert.equal(by['2026-07'].spoolsOpened, 1);
  assert.equal(by['2026-09'].costPerGram, 0.1);
  assert.equal(by['2026-09'].spoolsOpened, 2);
  assert.equal(by['2026-08'].costPerGram, null, 'no spool opened: no answer, not zero');
  assert.equal(by['2026-08'].spoolsOpened, 0);
  // The whole window: 290 over 3500 g, the never-opened spool included.
  assert.equal(r.costPerGram, round4(290 / 3500));
});

test('junk cannot produce a NaN', () => {
  const r = T.costTrends([null, {}, { status: 'completed', printTime: 'x', price: 'y', date: 'garbage' }],
                         [null, {}, { cost: 'a', spoolWeight: 'b', openedAt: 'nope' }], { now: NOW });
  for (const m of r.months) {
    for (const [k, v] of Object.entries(m)) {
      if (k === 'key') continue;
      assert.ok(v === null || Number.isFinite(v), `${m.key}.${k} is ${v}`);
    }
  }
});

function round4(v) { return Math.round(v * 10000) / 10000; }
