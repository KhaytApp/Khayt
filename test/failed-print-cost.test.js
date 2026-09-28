'use strict';
/**
 * The whole cost of a failed print: filament, machine time and electricity.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/print-rates.js');
require('../lib/print-energy.js');
const F = require('../lib/failed-print-cost.js');
const Q = require('../lib/qc-failure.js');
const W = require('../lib/waste-entry.js');

const MACHINE = { id: 'M1', wearRate: 1.5, powerDraw: 200 };
const JOB = { id: 'J1', machineId: 'M1', material: 'PLA', printTime: 8, parts: [{ printTime: 8, elecRate: 0.2 }] };

test('hours: the printer\'s own, else the estimate × the fraction printed, else none', () => {
  assert.deepEqual(F.hoursFor(JOB, { actualHours: 3.5, progress: 90 }), { hours: 3.5, source: 'printer' });
  assert.deepEqual(F.hoursFor(JOB, { progress: 25 }), { hours: 2, source: 'progress' });
  assert.deepEqual(F.hoursFor(JOB, { progress: 140 }), { hours: 8, source: 'progress' });
  assert.deepEqual(F.hoursFor(JOB, {}), { hours: null, source: null });
  assert.deepEqual(F.hoursFor(JOB, { progress: 0 }), { hours: null, source: null });
});

test('the breakdown: machine time at the wear rate, power at watts × tariff', () => {
  const b = F.breakdown(JOB, { materialCost: 12.4, progress: 50 }, { machine: MACHINE });
  // 4 h × 1.5 = 6.00; 4 h × 0.2 kW × 0.2 = 0.16
  assert.deepEqual(b, { material: 12.4, machine: 6, power: 0.16, full: 18.56, hours: 4,
    hoursSource: 'progress', energyWh: null, powerSource: 'rate' });
});

test('measured energy beats the wattage', () => {
  const b = F.breakdown(JOB, { materialCost: 10, actualHours: 4,
    energy: { wh: 1000, coverage: 1 } }, { machine: MACHINE });
  assert.equal(b.power, 0.2);
  assert.equal(b.energyWh, 1000);
  assert.equal(b.powerSource, 'plug');
  // A reading that covered too little of the attempt falls back to the rate.
  const thin = F.breakdown(JOB, { materialCost: 10, actualHours: 4,
    energy: { wh: 100, coverage: 0.2 } }, { machine: MACHINE });
  assert.equal(thin.powerSource, 'rate');
});

test('no hours: filament only — never the whole estimate', () => {
  const b = F.breakdown(JOB, { materialCost: 10 }, { machine: MACHINE });
  assert.equal(b.machine, 0);
  assert.equal(b.power, 0);
  assert.equal(b.full, 10);
  assert.equal(b.powerSource, null);
});

test('the machine rate: a depreciation rate wins when the rates carry one', () => {
  assert.equal(F.hourlyRateOf({ wearRate: 0.75 }), 0.75);
  assert.equal(F.hourlyRateOf({ wearRate: 0.75, depreciationRate: 2 }), 2);
  assert.equal(F.hourlyRateOf({}), 0);
  // No machine: Khayt's default wear rate, the same one a quote would use.
  const b = F.breakdown(JOB, { actualHours: 2 }, {});
  assert.equal(b.machine, 1.5);
});

test('attach never changes `cost` — the P&L\'s material figure', () => {
  const entry = { id: 'W1', cost: 12.4, weight: 155 };
  F.attach(entry, JOB, { progress: 50 }, { machine: MACHINE });
  assert.equal(entry.cost, 12.4);
  assert.equal(entry.costMaterial, 12.4);
  assert.equal(entry.costMachine, 6);
  assert.equal(entry.costPower, 0.16);
  assert.equal(entry.costFull, 18.56);
  assert.equal(entry.failedHours, 4);
  assert.equal(entry.hoursSource, 'progress');
});

test('totals: old rows count as material only', () => {
  const t = F.totals([
    { cost: 5 },
    { cost: 10, costMaterial: 10, costMachine: 3, costPower: 0.5, costFull: 13.5, energyWh: 2500 },
    null,
  ]);
  assert.deepEqual(t, { material: 15, machine: 3, power: 0.5, full: 18.5, energyWh: 2500, costed: 1 });
  assert.equal(F.fullCostOf({ cost: 5 }), 5);
  assert.equal(F.fullCostOf({ cost: 5, costFull: 9 }), 9);
});

test('attached after the shared QC rule, the row keeps its material cost', () => {
  const inv = [{ material: 'PLA', cost: 80, weight: 1000 }];
  const plain = Q.record({ ...JOB }, { weight: 100 }, { now: 0, inventory: inv.map((x) => ({ ...x })) }).waste;
  assert.equal(plain.costFull, undefined, 'the shared rule alone writes the row it always did');
  const order = { ...JOB };
  const waste = Q.record(order, { weight: 100 }, { now: 0, inventory: inv.map((x) => ({ ...x })) }).waste;
  F.attach(waste, order, { progress: 100 }, { machine: MACHINE });
  assert.equal(waste.cost, plain.cost);
  assert.equal(waste.costMachine, 12);
  assert.equal(waste.costFull, +(plain.cost + 12 + 8 * 0.2 * 0.2).toFixed(2));
});

test('a job-linked waste entry, costed whole', () => {
  const inv = [{ id: 's1', material: 'PLA', cost: 80, weight: 1000, spoolWeight: 1000 }];
  const entry = W.forOrder({ ...JOB }, { material: 'PLA', weight: 50 }, { id: 'W1', today: '2026-09-28', inventory: inv }).entry;
  const cost = entry.cost;
  F.attach(entry, JOB, { actualHours: 1 }, { machine: MACHINE });
  assert.equal(entry.cost, cost);
  assert.equal(entry.costMachine, 1.5);
  assert.equal(entry.costPower, 0.04);
  assert.equal(entry.hoursSource, 'printer');
});
