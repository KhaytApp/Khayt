'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  proposeSchedule,
  machineLoadMins,
  urgencyScore,
  machineAcceptsMaterial,
  downtimeHours,
} = require('../lib/scheduling');

// A fixed "now" so dueDate-based urgency is deterministic. 2026-06-16 local.
const NOW = new Date('2026-06-16T12:00:00').getTime();

function machine(id, extra) {
  return Object.assign({ id, name: id, isOffline: false }, extra || {});
}
function order(id, extra) {
  return Object.assign({ id, status: 'pending' }, extra || {});
}

function findAssign(res, orderId) {
  return res.assignments.find(a => a.orderId === orderId);
}
function findUnassign(res, orderId) {
  return res.unassignable.find(u => u.orderId === orderId);
}

test('machineLoadMins sums printTime of orders assigned to the machine', () => {
  const m = machine('m1');
  const orders = [
    order('a', { machineId: 'm1', printTime: 2 }),
    order('b', { machineId: 'm1', printTime: 3 }),
    order('c', { machineId: 'm2', printTime: 5 }),
    order('d', { machineId: 'm1' }), // no printTime -> 0
  ];
  assert.equal(machineLoadMins(m, orders), 5);
  assert.equal(machineLoadMins(machine('m2'), orders), 5);
  assert.equal(machineLoadMins(m, []), 0);
  assert.equal(machineLoadMins(null, orders), 0);
});

test('capability filter: PLA order not placed on a PETG-only printer', () => {
  const machines = [
    machine('petg', { compatMaterials: ['PETG'] }),
    machine('pla', { compatMaterials: ['PLA'] }),
  ];
  const orders = [order('o1', { material: 'PLA Black', printTime: 2 })];
  const res = proposeSchedule(machines, orders, { now: NOW });
  const a = findAssign(res, 'o1');
  assert.ok(a, 'order assigned');
  assert.equal(a.machineId, 'pla');
  assert.equal(res.unassignable.length, 0);
});

test('empty/absent compatMaterials accepts any material', () => {
  assert.equal(machineAcceptsMaterial({ id: 'm' }, 'Nylon'), true);
  assert.equal(machineAcceptsMaterial({ id: 'm', compatMaterials: [] }, 'Nylon'), true);
  assert.equal(machineAcceptsMaterial({ id: 'm', compatMaterials: ['PLA'] }, 'PLA Red'), true);
  assert.equal(machineAcceptsMaterial({ id: 'm', compatMaterials: ['PETG'] }, 'PLA'), false);
});

test('offline machines are skipped', () => {
  const machines = [
    machine('off', { compatMaterials: ['PLA'], isOffline: true }),
    machine('on', { compatMaterials: ['PLA'] }),
  ];
  const orders = [order('o1', { material: 'PLA', printTime: 1 })];
  const res = proposeSchedule(machines, orders, { now: NOW });
  assert.equal(findAssign(res, 'o1').machineId, 'on');
});

test('no capable printer -> unassignable with no compatible printer reason', () => {
  const machines = [machine('petg', { compatMaterials: ['PETG'] })];
  const orders = [order('o1', { material: 'Nylon', printTime: 1 })];
  const res = proposeSchedule(machines, orders, { now: NOW });
  assert.equal(res.assignments.length, 0);
  const u = findUnassign(res, 'o1');
  assert.ok(u);
  assert.equal(u.reason, 'no compatible printer');
});

test('all printers offline -> unassignable with all printers offline reason', () => {
  const machines = [
    machine('m1', { compatMaterials: ['PLA'], isOffline: true }),
    machine('m2', { compatMaterials: ['PLA'], isOffline: true }),
  ];
  const orders = [order('o1', { material: 'PLA', printTime: 1 })];
  const res = proposeSchedule(machines, orders, { now: NOW });
  const u = findUnassign(res, 'o1');
  assert.ok(u);
  assert.equal(u.reason, 'all printers offline');
});

test('deadline ordering: earlier dueDate scheduled first (lower position)', () => {
  const machines = [machine('m1')]; // single machine -> positions reflect order
  const orders = [
    order('late', { material: 'PLA', dueDate: '2026-06-25', printTime: 1 }),
    order('soon', { material: 'PLA', dueDate: '2026-06-17', printTime: 1 }),
    order('mid', { material: 'PLA', dueDate: '2026-06-20', printTime: 1 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  const pos = id => findAssign(res, id).position;
  assert.ok(pos('soon') < pos('mid'));
  assert.ok(pos('mid') < pos('late'));
});

test('overdue jobs are most urgent (scheduled before future-due jobs)', () => {
  const machines = [machine('m1')];
  const orders = [
    order('future', { material: 'PLA', dueDate: '2026-06-30', printTime: 1 }),
    order('overdue', { material: 'PLA', dueDate: '2026-06-01', printTime: 1 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  assert.ok(findAssign(res, 'overdue').position < findAssign(res, 'future').position);
});

test('priority breaks ties within the same deadline tier', () => {
  const machines = [machine('m1')];
  const orders = [
    order('normal', { material: 'PLA', dueDate: '2026-06-30', printTime: 1, priorityLevel: 'normal' }),
    order('urgent', { material: 'PLA', dueDate: '2026-06-30', printTime: 1, priorityLevel: 'urgent' }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  assert.ok(findAssign(res, 'urgent').position < findAssign(res, 'normal').position);
});

test('greedy load balancing distributes across two equal idle printers', () => {
  const machines = [machine('m1'), machine('m2')];
  const orders = [
    order('a', { material: 'PLA', printTime: 1 }),
    order('b', { material: 'PLA', printTime: 1 }),
    order('c', { material: 'PLA', printTime: 1 }),
    order('d', { material: 'PLA', printTime: 1 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  const byMachine = {};
  for (const a of res.assignments) {
    byMachine[a.machineId] = (byMachine[a.machineId] || 0) + 1;
  }
  assert.equal(byMachine.m1, 2);
  assert.equal(byMachine.m2, 2);
});

test('greedy load balancing accounts for already-assigned seed load', () => {
  const machines = [machine('m1'), machine('m2')];
  const orders = [
    // m1 already has 10h of work assigned.
    order('seed', { machineId: 'm1', material: 'PLA', printTime: 10 }),
    order('new1', { material: 'PLA', printTime: 1 }),
    order('new2', { material: 'PLA', printTime: 1 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  // The idle m2 should absorb the new work, not the loaded m1.
  assert.equal(findAssign(res, 'new1').machineId, 'm2');
  assert.equal(findAssign(res, 'new2').machineId, 'm2');
});

test('determinism: same input yields identical output', () => {
  const machines = [machine('m1'), machine('m2')];
  const orders = [
    order('a', { material: 'PLA', dueDate: '2026-06-20', printTime: 2 }),
    order('b', { material: 'PLA', dueDate: '2026-06-18', printTime: 3 }),
    order('c', { material: 'PLA', dueDate: '2026-06-19', printTime: 1 }),
  ];
  const r1 = proposeSchedule(machines, orders, { now: NOW });
  const r2 = proposeSchedule(machines, orders, { now: NOW });
  assert.deepEqual(r1, r2);
});

test('same-material batching prefers a machine already running that material', () => {
  // Two equal-capacity machines; m1 seeded with PLA, m2 seeded with PETG.
  // A new PLA job within tolerance should batch onto m1.
  const machines = [
    machine('m1', { compatMaterials: ['PLA', 'PETG'] }),
    machine('m2', { compatMaterials: ['PLA', 'PETG'] }),
  ];
  const orders = [
    order('s1', { machineId: 'm1', material: 'PLA', printTime: 1 }),
    order('s2', { machineId: 'm2', material: 'PETG', printTime: 1 }),
    order('new', { material: 'PLA', printTime: 1 }),
  ];
  // batchTolerance lets batching override the otherwise-equal load.
  const res = proposeSchedule(machines, orders, { now: NOW, batchToleranceMins: 0 });
  assert.equal(findAssign(res, 'new').machineId, 'm1');
  assert.equal(findAssign(res, 'new').reason, 'batched with same material');
});

test('batching never crosses an earlier deadline tier', () => {
  // Single machine: deadline order must hold even though materials interleave.
  const machines = [machine('m1', { compatMaterials: ['PLA', 'PETG'] })];
  const orders = [
    order('pla_late', { material: 'PLA', dueDate: '2026-06-30', printTime: 1 }),
    order('petg_soon', { material: 'PETG', dueDate: '2026-06-17', printTime: 1 }),
    order('pla_soon', { material: 'PLA', dueDate: '2026-06-17', printTime: 1 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW, batchToleranceMins: 100 });
  // The soon-due PETG job must not be pushed behind the late-due PLA job
  // for the sake of clustering PLA together.
  assert.ok(findAssign(res, 'petg_soon').position < findAssign(res, 'pla_late').position);
});

test('includeAssigned controls whether placed orders are reconsidered', () => {
  const machines = [machine('m1'), machine('m2')];
  const orders = [order('a', { machineId: 'm1', material: 'PLA', printTime: 1 })];
  const def = proposeSchedule(machines, orders, { now: NOW });
  assert.equal(def.assignments.length, 0, 'assigned order skipped by default');

  const inc = proposeSchedule(machines, orders, { now: NOW, includeAssigned: true });
  assert.equal(inc.assignments.length, 1, 'assigned order reconsidered when opted in');
});

test('non-schedulable statuses are ignored', () => {
  const machines = [machine('m1')];
  const orders = [
    order('done', { status: 'completed', material: 'PLA', printTime: 1 }),
    order('printing', { status: 'printing', material: 'PLA', printTime: 1 }),
    order('q', { status: 'queued', material: 'PLA', printTime: 1 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  assert.equal(res.assignments.length, 1);
  assert.equal(res.assignments[0].orderId, 'q');
});

test('projectedFinishMins reflects cumulative load on the chosen machine', () => {
  const machines = [machine('m1')];
  const orders = [
    order('a', { material: 'PLA', dueDate: '2026-06-17', printTime: 2 }),
    order('b', { material: 'PLA', dueDate: '2026-06-18', printTime: 3 }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  assert.equal(findAssign(res, 'a').projectedFinishMins, 2);
  assert.equal(findAssign(res, 'b').projectedFinishMins, 5);
});

test('empty inputs are safe', () => {
  assert.deepEqual(proposeSchedule([], [], { now: NOW }), { assignments: [], unassignable: [] });
  assert.deepEqual(proposeSchedule(null, null, {}), { assignments: [], unassignable: [] });
  assert.deepEqual(proposeSchedule(undefined, undefined), { assignments: [], unassignable: [] });
  assert.deepEqual(proposeSchedule([machine('m1')], [], {}), { assignments: [], unassignable: [] });
});

test('proposeSchedule does not mutate its inputs', () => {
  const machines = [machine('m1', { compatMaterials: ['PLA'] })];
  const orders = [order('o1', { material: 'PLA', printTime: 1 })];
  const machineSnap = JSON.stringify(machines);
  const orderSnap = JSON.stringify(orders);
  proposeSchedule(machines, orders, { now: NOW });
  assert.equal(JSON.stringify(machines), machineSnap);
  assert.equal(JSON.stringify(orders), orderSnap);
});

test('urgencyScore reproduces the kanban ordering idea', () => {
  // Overdue most negative; no due date is a large positive bucket.
  const overdue = urgencyScore({ dueDate: '2026-06-01', printTime: 1 }, NOW);
  const today = urgencyScore({ dueDate: '2026-06-16', printTime: 1 }, NOW);
  const noDue = urgencyScore({ printTime: 1 }, NOW);
  assert.ok(overdue < today);
  assert.ok(today < noDue);
  assert.equal(today, 0);
});

test('no due dates anywhere: still places by priority then stable id', () => {
  const machines = [machine('m1')];
  const orders = [
    order('z', { material: 'PLA', printTime: 1, priorityLevel: 'normal' }),
    order('a', { material: 'PLA', printTime: 1, priorityLevel: 'normal' }),
    order('m', { material: 'PLA', printTime: 1, priorityLevel: 'urgent' }),
  ];
  const res = proposeSchedule(machines, orders, { now: NOW });
  // urgent first, then alphabetical id among equal-priority.
  assert.equal(findAssign(res, 'm').position, 0);
  assert.ok(findAssign(res, 'a').position < findAssign(res, 'z').position);
});

// ── A MACHINE BOOKED OUT IS A MACHINE WITH LESS TO GIVE ────────────────────
//
// `downtimeBlocks` was recorded since 3.0 and read by a badge and a chart. Not
// by the scheduler, so it would put a job on a printer the shop had already
// booked out and call it the earliest finish.

const HOUR_MS = 3600000;
const NOW_SCHED = Date.UTC(2026, 8, 8, 7, 0, 0);
const window_ = (fromH, toH) => ({
  from: new Date(NOW_SCHED + fromH * HOUR_MS).toISOString(),
  to: new Date(NOW_SCHED + toH * HOUR_MS).toISOString(),
});

test('work goes to the machine that is not booked out', () => {
  const machines = [
    { id: 'M1', downtimeBlocks: [window_(1, 9)] },   // out for eight hours
    { id: 'M2' },
  ];
  const res = proposeSchedule(machines, [
    { id: 'a', status: 'pending', printTime: 2 },
  ], { now: NOW_SCHED });
  assert.equal(res.assignments[0].machineId, 'M2',
    'the job went to the printer the shop had booked out for maintenance');
});

test('the down machine is still used when it is the only one', () => {
  // The work has to go somewhere, and the shop can see the projected finish.
  // Refusing outright would be a scheduler that stops scheduling.
  const res = proposeSchedule([{ id: 'M1', downtimeBlocks: [window_(1, 9)] }], [
    { id: 'a', status: 'pending', printTime: 2 },
  ], { now: NOW_SCHED });
  assert.equal(res.assignments[0].machineId, 'M1');
  assert.equal(res.unassignable.length, 0);
});

test('a window already past does not count against a machine', () => {
  const machines = [{ id: 'M1', downtimeBlocks: [window_(-40, -20)] }, { id: 'M2' }];
  const res = proposeSchedule(machines, [
    { id: 'a', status: 'pending', printTime: 2 },
  ], { now: NOW_SCHED });
  // Tie on load, so the deterministic tiebreak picks the lower id — which is
  // the behaviour with no downtime at all.
  assert.equal(res.assignments[0].machineId, 'M1');
});

test('a window beyond the horizon does not shorten today', () => {
  const machines = [{ id: 'M1', downtimeBlocks: [window_(24 * 60, 24 * 80)] }, { id: 'M2' }];
  const res = proposeSchedule(machines, [
    { id: 'a', status: 'pending', printTime: 2 },
  ], { now: NOW_SCHED });
  assert.equal(res.assignments[0].machineId, 'M1',
    'a window booked for next quarter changed where work goes today');
});

test('downtime is counted in HOURS, the unit this scheduler balances in', () => {
  // The field names say minutes and the unit is hours — `projectedFinishMins`
  // comes to 2 for two one-hour jobs. Returning minutes here would have made
  // every maintenance window count sixty times over, which is the kind of
  // mistake that looks like a scheduler with an opinion.
  const hours = downtimeHours({ downtimeBlocks: [window_(1, 5)] }, NOW_SCHED, 14);
  assert.equal(hours, 4);
});
