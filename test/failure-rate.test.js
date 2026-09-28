/**
 * A failure allowance learned from the shop's own failures.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { suggest, attempts } = require('../lib/failure-rate.js');
const QC = require('../lib/qc-failure.js');

const done = (id, machineId, material, date, extra) => Object.assign(
  { id, machineId, material, status: 'completed', date, completedAt: date + 'T10:00:00Z' }, extra);

/** `n` finished jobs on one machine and material. */
function jobs(n, machineId, material, date, prefix) {
  return Array.from({ length: n }, (_, k) => done(`${prefix || machineId}-${material}-${k}`, machineId, material, date));
}

test('failed ÷ attempts, from waste rows tied to jobs', () => {
  const orders = jobs(18, 'M1', 'PLA', '2026-09-01');
  const wasteLog = [
    { orderId: orders[0].id, date: '2026-08-30', material: 'PLA', machineId: 'M1' },
    { orderId: orders[1].id, date: '2026-08-30', material: 'PLA', machineId: 'M1' },
  ];
  const s = suggest({ orders, wasteLog }, { today: '2026-09-28', machineId: 'M1', material: 'PLA' });
  assert.equal(s.enough, true);
  assert.equal(s.scope, 'machine_material');
  assert.equal(s.attempts, 20);
  assert.equal(s.failures, 2);
  assert.equal(s.pct, 10);
});

test('a QC failure is counted ONCE, though it writes a defect and a waste row', () => {
  const order = { id: 'J1', machineId: 'M1', material: 'PLA', status: 'printing' };
  const wasteLog = [];
  QC.record(order, { failureType: 'warping', weight: 0 }, { now: Date.parse('2026-09-20T09:00:00Z'), wasteLog });
  // …and reprinted and passed.
  order.status = 'completed';
  order.completedAt = '2026-09-21T09:00:00Z';
  order.date = '2026-09-21';
  order.qcStatus = 'pass';
  const rows = attempts({ orders: [order], wasteLog }, { today: '2026-09-28' });
  assert.equal(rows.filter((r) => r.failed).length, 1);
  assert.equal(rows.filter((r) => !r.failed).length, 1);
});

test('a job still standing at a QC fail is a failure and not a success', () => {
  const order = done('J1', 'M1', 'PLA', '2026-09-10', { qcStatus: 'fail', qcFailedAt: '2026-09-10T10:00:00Z' });
  const rows = attempts({ orders: [order], wasteLog: [] }, { today: '2026-09-28' });
  assert.deepEqual(rows.map((r) => r.failed), [true]);
});

test('two failures on one job are two attempts', () => {
  const order = done('J1', 'M1', 'PLA', '2026-09-10', {
    defects: [{ at: '2026-09-08T10:00:00Z' }, { at: '2026-09-09T10:00:00Z' }],
  });
  const wasteLog = [{ orderId: 'J1', date: '2026-09-08' }, { orderId: 'J1', date: '2026-09-09' }];
  const rows = attempts({ orders: [order], wasteLog }, { today: '2026-09-28' });
  assert.equal(rows.filter((r) => r.failed).length, 2);
  assert.equal(rows.length, 3);
});

test('outside the window, and waste naming no job, are left out', () => {
  const orders = [done('old', 'M1', 'PLA', '2026-01-01'), done('new', 'M1', 'PLA', '2026-09-20')];
  const wasteLog = [
    { orderId: 'new', date: '2026-05-01' },          // too old
    { date: '2026-09-20', material: 'PLA' },          // no job
  ];
  const rows = attempts({ orders, wasteLog }, { today: '2026-09-28', days: 90 });
  assert.deepEqual(rows.map((r) => r.failed), [false]);
});

test('voided and unfinished jobs are not successes', () => {
  const orders = [done('v', 'M1', 'PLA', '2026-09-20', { voidedAt: 'x' }),
                  { id: 'p', machineId: 'M1', material: 'PLA', status: 'printing', date: '2026-09-20' }];
  assert.equal(attempts({ orders }, { today: '2026-09-28' }).length, 0);
});

test('falls back machine → material → shop until there is enough', () => {
  const orders = [
    ...jobs(5, 'M1', 'PETG', '2026-09-01'),            // machine+material: 5
    ...jobs(10, 'M1', 'PLA', '2026-09-01'),            // machine: 15
    ...jobs(20, 'M2', 'PETG', '2026-09-01'),           // material PETG: 25
  ];
  const wasteLog = [{ orderId: orders[20].id, date: '2026-09-01' }];   // an M2 PETG failure
  const s = suggest({ orders, wasteLog }, { today: '2026-09-28', machineId: 'M1', material: 'petg' });
  assert.equal(s.scope, 'material');
  assert.equal(s.attempts, 26);
  assert.equal(s.failures, 1);
  assert.equal(s.pct, Math.round(1 / 26 * 1000) / 10);
  // A lower bar answers from the machine and material.
  const small = suggest({ orders, wasteLog }, { today: '2026-09-28', machineId: 'M1', material: 'PETG', minSample: 5 });
  assert.equal(small.scope, 'machine_material');
  assert.equal(small.pct, 0);
});

test('not enough anywhere: no figure, and the count to say so', () => {
  const orders = jobs(4, 'M1', 'PLA', '2026-09-01');
  const s = suggest({ orders, wasteLog: [{ orderId: orders[0].id, date: '2026-09-01' }] },
                    { today: '2026-09-28', machineId: 'M1', material: 'PLA' });
  assert.equal(s.enough, false);
  assert.equal(s.pct, null);
  assert.equal(s.attempts, 5);
  assert.equal(s.failures, 1);
});

test('no today, no answer — this module has no clock', () => {
  const s = suggest({ orders: jobs(30, 'M1', 'PLA', '2026-09-01') }, {});
  assert.equal(s.enough, false);
  assert.equal(s.attempts, 0);
});
