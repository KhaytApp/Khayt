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

// The desktop's quote rate, run for real: the helpers out of machines.js in a
// context holding a book, the same shape the renderer's globals have.
const vm = require('node:vm');
const helpersSrc = machinesSrc.slice(machinesSrc.indexOf('function machineRecentHours()'), machinesSrc.indexOf('\n  const api = {'));
const withBook = (book) => {
  const ctx = vm.createContext(Object.assign({ KhaytDepreciation: require('../lib/depreciation.js') }, book));
  vm.runInContext(`let machines = this.machines, printLog = this.printLog;\n${helpersSrc}\nthis.api = { machineRecentHours, machineWearRate };`, ctx);
  return ctx.api;
};
const recentDay = (() => { const d = new Date(); d.setDate(d.getDate() - 10); return day(d); })();

test('a quote on a machine with depreciation charges its derived wear rate, as the Mac does', () => {
  const perHour = { id: 'p', wearRate: 0.75, depreciation: { price: 3000, life: 2000, lifeUnit: 'hours', residual: 0, method: 'perHour' } };
  const flat = { id: 'f', wearRate: 0.4 };
  const bare = { id: 'b' };
  const { machineWearRate } = withBook({ machines: [perHour, flat, bare], printLog: [] });
  assert.equal(machineWearRate(perHour), 1.5, '3000 over 2000 hours, not the flat 0.75');
  assert.equal(machineWearRate(flat), 0.4, 'no depreciation: the flat rate stands');
  assert.equal(machineWearRate(bare), null, 'neither: the calculator keeps what it has');
});

test('a straight-line machine is costed on the hours it has actually printed lately', () => {
  const m = { id: 's', depreciation: { price: 3650, life: 1, lifeUnit: 'years', residual: 0, method: 'straightLine' } };
  const job = { status: 'completed', machineId: 's', date: recentDay, printTime: 90 };
  const { machineRecentHours, machineWearRate } = withBook({ machines: [m], printLog: [job] });
  const recent = machineRecentHours();
  assert.equal(recent.s, 30.44, '90 hours over 90 days, a month of it');
  const D = require('../lib/depreciation.js');
  assert.equal(machineWearRate(m), D.hourlyRate(m, { recentMonthlyHours: recent.s }));
  assert.equal(withBook({ machines: [m], printLog: [] }).machineWearRate(m), null, 'no hours known: no derived rate');
});

test('the calculator, both P&Ls and the headline all carry recent hours', () => {
  const buildSrc = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'build.js'), 'utf8');
  assert.match(buildSrc, /machineWearRate\(m\)/, 'applyMachineToCalculator');
  assert.equal((analyticsSrc.match(/recentMonthlyHours: \(typeof machineRecentHours === 'function' \? machineRecentHours\(\) : \{\}\)/g) || []).length, 7,
    'three pnlByPeriod, three machineProfit, one periodCharges');
});

test('every machine P&L gets the whole book, so earlier hours count against its life', () => {
  assert.equal((analyticsSrc.match(/range: analyticsRangeSpan\(printLog\.map\(o => o\.date\)\),\n(?:\s*\/\/[^\n]*\n)*\s*orders: printLog,/g) || []).length, 3);
});
