/**
 * Revenue forecasting — pure series + regression projection.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { monthlyRevenueSeries, linreg, forecast } = require('../lib/forecast.js');

// Fixed clock: 2026-06-15 UTC (current partial month June excluded from series).
const NOW = Date.parse('2026-06-15T00:00:00Z');
const at = (y, m, d = 10) => new Date(Date.UTC(y, m - 1, d)).toISOString();
const ordersFor = (rev) => Object.entries(rev).flatMap(([ym, amt]) => {
  const [y, m] = ym.split('-').map(Number);
  return [{ status: 'completed', completedAt: at(y, m), price: amt }];
});

test('monthlyRevenueSeries: last N whole months, current partial month excluded, gaps = 0', () => {
  const s = monthlyRevenueSeries(ordersFor({ '2026-03': 100, '2026-05': 300 }), { now: NOW, months: 4 });
  assert.deepEqual(s.map((x) => x.label), ['2026-02', '2026-03', '2026-04', '2026-05']);
  assert.deepEqual(s.map((x) => x.revenue), [0, 100, 0, 300]);
  // June (current, partial) is NOT in the series
  assert.ok(!s.some((x) => x.label === '2026-06'));
});

test('only completed/delivered orders count', () => {
  const orders = [
    { status: 'completed', completedAt: at(2026, 5), price: 200 },
    { status: 'printing', completedAt: at(2026, 5), price: 999 },
    { status: 'quote', date: at(2026, 5), price: 999 },
  ];
  const s = monthlyRevenueSeries(orders, { now: NOW, months: 2 });
  assert.equal(s.find((x) => x.label === '2026-05').revenue, 200);
});

test('linreg recovers a clean slope', () => {
  const { slope, intercept } = linreg([10, 20, 30, 40]);
  assert.equal(Math.round(slope), 10);
  assert.equal(Math.round(intercept), 10);
});

test('forecast: rising trend projects upward (≥3 non-zero months)', () => {
  const f = forecast(ordersFor({ '2026-01': 100, '2026-02': 200, '2026-03': 300, '2026-04': 400, '2026-05': 500 }), { now: NOW, months: 5, periods: 2 });
  assert.equal(f.method, 'trend');
  assert.equal(f.projection.length, 2);
  assert.equal(f.projection[0].label, '2026-06');
  assert.ok(f.nextMonth > 500, 'next month above last actual');
  assert.ok(f.projection[1].projected > f.projection[0].projected, 'keeps rising');
  assert.ok(f.trendPct > 0);
});

test('forecast: sparse data falls back to average (never negative)', () => {
  const f = forecast(ordersFor({ '2026-05': 300 }), { now: NOW, months: 6, periods: 1 });
  assert.equal(f.method, 'average');
  assert.ok(f.nextMonth >= 0);
  // declining trend must still clamp at 0, never below
  const decl = forecast(ordersFor({ '2026-01': 500, '2026-02': 300, '2026-03': 100, '2026-04': 10, '2026-05': 1 }), { now: NOW, months: 5, periods: 4 });
  assert.ok(decl.projection.every((p) => p.projected >= 0));
});

test('forecast: no data → method none, zero projection', () => {
  const f = forecast([], { now: NOW, months: 6, periods: 3 });
  assert.equal(f.method, 'none');
  assert.equal(f.nextMonth, 0);
});

test('months are bucketed by the LOCAL calendar, not UTC', () => {
  // Riyadh is UTC+3, so a UTC-based month key put orders completed between 00:00 and 03:00
  // on the 1st into the PREVIOUS month. The other tests build both "now" and the fixtures
  // with Date.UTC, so they were self-consistently wrong and never caught it.
  const early = new Date('2026-08-01T01:30:00+03:00');
  if (early.getMonth() === early.getUTCMonth()) return;  // degenerate in a UTC-ish TZ

  // Window ends at the current (partial) month, so ask from September to include August.
  const series = monthlyRevenueSeries(
    [{ date: '2026-08-01T01:30:00+03:00', price: 1000, status: 'completed' },
     { date: '2026-08-15T12:00:00+03:00', price: 1000, status: 'completed' }],
    { now: new Date('2026-09-10T12:00:00+03:00').getTime(), months: 3 },
  );
  const aug = series.find((p) => p.label === '2026-08');
  assert.ok(aug, `August bucket missing: ${series.map((p) => p.label).join(', ')}`);
  assert.equal(aug.revenue, 2000, 'both August orders must land in August, not July');
});
