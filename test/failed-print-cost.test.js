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

// ── byGroup: where the failures cost ────────────────────────────────────────

const ORDERS = [
  { id: 'J1', machineId: 'M1', clientId: 'C1' },
  { id: 'J2', machineId: 'M2', clientId: 'C2' },
  { id: 'J3', client: 'Walk-in Sara' },            // a name typed on the job, no record
  { id: 'J4', clientId: 'C9' },                     // a customer since deleted
];
const MACHINES = [{ id: 'M1', name: 'U1' }, { id: 'M2', name: 'X1C' }];
const SPOOLS = [{ id: 'S1', material: 'PETG' }];
const CLIENTS = [{ id: 'C1', name: 'Noura' }, { id: 'C2', company: 'Acme' }];
// A breakdown row (job-linked), a legacy row with `cost` only, a row whose
// printer is reached only through its job (the desktop's `forOrder` writes no
// machineId), a row on no job at all, and one whose material is only on its spool.
const LOG = [
  { id: 'W1', orderId: 'J1', machineId: 'M1', material: 'PLA', cost: 4,
    costMaterial: 4, costMachine: 6, costPower: 1, costFull: 11 },
  { id: 'W2', machineId: 'M1', material: 'PLA', cost: 2.5 },
  { id: 'W3', orderId: 'J2', material: 'PETG', cost: 3,
    costMaterial: 3, costMachine: 9, costPower: 2, costFull: 14 },
  { id: 'W4', material: 'ABS', cost: 1.25 },
  { id: 'W5', orderId: 'J3', machineId: 'M2', material: '', spoolId: 'S1', cost: 0.75 },
  { id: 'W6', orderId: 'J4', machineId: 'M-gone', material: 'PLA', cost: 1 },
];
const CTX = { orders: ORDERS, machines: MACHINES, spools: SPOOLS, clients: CLIENTS };

test('byGroup: by printer — the row\'s machine, else its job\'s; a printer no longer in the book keeps its id', () => {
  const rows = F.byGroup(LOG, Object.assign({ by: 'machine' }, CTX));
  assert.deepEqual(rows.map((r) => [r.key, r.label, r.full, r.count]), [
    ['M2', 'X1C', 14.75, 2],
    ['M1', 'U1', 13.5, 2],
    [null, 'Unknown', 1.25, 1],
    ['M-gone', 'M-gone', 1, 1],
  ]);
  const m2 = rows[0];
  assert.deepEqual([m2.material, m2.machine, m2.power], [3.75, 9, 2]);
  assert.equal(rows[2].unknown, true);
  assert.equal(rows[0].unknown, false);
});

test('byGroup: by material — the row\'s, else the spool it came off', () => {
  const rows = F.byGroup(LOG, Object.assign({ by: 'material' }, CTX));
  assert.deepEqual(rows.map((r) => [r.key, r.full, r.count]), [
    ['PETG', 14.75, 2],
    ['PLA', 14.5, 3],
    ['ABS', 1.25, 1],
  ]);
  assert.ok(!rows.some((r) => r.unknown), 'every row had a material');
});

test('byGroup: by customer — only through the job; no job is Unknown', () => {
  const rows = F.byGroup(LOG, Object.assign({ by: 'customer' }, CTX));
  assert.deepEqual(rows.map((r) => [r.key, r.label, r.full, r.count]), [
    ['C2', 'Acme', 14, 1],
    ['C1', 'Noura', 11, 1],
    [null, 'Unknown', 3.75, 2],                     // W2 and W4 have no job
    ['C9', 'C9', 1, 1],
    ['name:walk-in sara', 'Walk-in Sara', 0.75, 1],
  ]);
});

test('byGroup: a legacy row (cost only, no breakdown) counts as material only', () => {
  const [row] = F.byGroup([{ machineId: 'M1', material: 'PLA', cost: 2.5 }], { by: 'machine', machines: MACHINES });
  assert.deepEqual(row, { key: 'M1', label: 'U1', full: 2.5, material: 2.5, machine: 0, power: 0, count: 1, unknown: false });
});

test('byGroup and totals agree on "full", whichever way the log is cut', () => {
  const t = F.totals(LOG);
  for (const by of ['machine', 'material', 'customer']) {
    const rows = F.byGroup(LOG, Object.assign({ by }, CTX));
    const sum = rows.reduce((s, r) => s + r.full, 0);
    assert.equal(Math.round(sum * 100) / 100, t.full, by);
    assert.equal(rows.reduce((s, r) => s + r.count, 0), LOG.length, by);
  }
});

test('byGroup: nothing in, nothing out; an unknown grouping is no rows', () => {
  assert.deepEqual(F.byGroup([], { by: 'machine' }), []);
  assert.deepEqual(F.byGroup(null), []);
  assert.deepEqual(F.byGroup(LOG, { by: 'colour' }), []);
  // No context at all: every printer is still its own group, by id.
  assert.deepEqual(F.byGroup([{ machineId: 'M1', cost: 1 }, null]).map((r) => r.label), ['M1']);
});
