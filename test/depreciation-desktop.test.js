'use strict';

/**
 * Depreciation on the desktop: the machine sheet can set it, the P&L and the
 * machine table count it, and wear is counted once (maintainer, 2026-09-28).
 * The rules are the Mac's lib/depreciation.js (#1659); this pins the desktop's
 * use of them, and the date-range bounds they are pro-rated over.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const DR = require('../lib/date-range.js');

const at = new Date(2026, 8, 17);   // 17 Sep 2026
const day = (d) => DR.localDay(d);

test('bounds: each named range, cut to today while it is running', () => {
  assert.deepEqual(DR.bounds('month', { now: at }), { from: '2026-09-01', to: '2026-09-17' });
  assert.deepEqual(DR.bounds('last_month', { now: at }), { from: '2026-08-01', to: '2026-08-31' });
  assert.deepEqual(DR.bounds('quarter', { now: at }), { from: '2026-07-01', to: '2026-09-17' });
  assert.deepEqual(DR.bounds('last_quarter', { now: at }), { from: '2026-04-01', to: '2026-06-30' });
  assert.deepEqual(DR.bounds('year', { now: at }), { from: '2026-01-01', to: '2026-09-17' });
  assert.deepEqual(DR.bounds('last_quarter', { now: new Date(2026, 0, 10) }), { from: '2025-10-01', to: '2025-12-31' });
  assert.deepEqual(DR.bounds('custom', { now: at, from: '2026-05-01', to: '2026-12-31' }), { from: '2026-05-01', to: '2026-09-17' });
  assert.equal(DR.bounds('all', { now: at }), null, 'all spans the data, which only the caller knows');
  assert.equal(DR.bounds('custom', { now: at }), null);
});

test('bounds and inRange agree about every day of every range', () => {
  for (const range of ['month', 'last_month', 'quarter', 'last_quarter', 'year']) {
    const b = DR.bounds(range, { now: at });
    for (let d = new Date(2025, 11, 1); d <= new Date(2026, 9, 31); d.setDate(d.getDate() + 1)) {
      const s = day(d);
      if (s > day(at)) continue;   // bounds stop at today; inRange does not ask
      assert.equal(s >= b.from && s <= b.to, DR.inRange(s, range, { now: at }), `${range} ${s}`);
    }
  }
});

const machinesSrc = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'machines.js'), 'utf8');
const analyticsSrc = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');

test('the machine sheet sets depreciation through the shared rule', () => {
  for (const id of ['machDepPrice', 'machDepDate', 'machDepLife', 'machDepLifeUnit', 'machDepResidual', 'machDepMethod', 'machDepMonthlyHours']) {
    assert.match(machinesSrc, new RegExp(`id="${id}"`), id);
  }
  assert.match(machinesSrc, /const next = DEP\.clean\(\{/);
  assert.match(machinesSrc, /if \(next\) draft\.depreciation = next; else delete draft\.depreciation;/);
});

test('wear is counted once on the desktop: stocked cost, and depreciation', () => {
  assert.equal((analyticsSrc.match(/partCostOf: stockedPartCost,/g) || []).length, 3, 'every machine P&L view');
  assert.equal((analyticsSrc.match(/range: analyticsRangeSpan\(/g) || []).length, 3);
  assert.equal((analyticsSrc.match(/machines: \(typeof machines !== 'undefined' \? machines : \[\]\),/g) || []).length, 3, 'every pnlByPeriod view');
  assert.match(analyticsSrc, /return \{ orders, expenses: expenseRows, waste: wasteRows, depreciation \};/, 'the headline and the CSV');
});
