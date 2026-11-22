'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { computeSchedule, UNASSIGNED } = require('../lib/schedule.js');

test('sequences jobs per machine and computes ready dates from working hours', () => {
  const r = computeSchedule({
    startDate: '2026-06-01', dailyHours: 8,
    jobs: [
      { id: 'A', machineId: 'm1', hours: 8 },   // day 1
      { id: 'B', machineId: 'm1', hours: 8 },    // day 2 (cum 16h)
      { id: 'C', machineId: 'm2', hours: 4 },    // day 1 on its own machine
    ],
  });
  const m1 = r.machines.find((m) => m.machineId === 'm1');
  assert.equal(m1.jobs[0].etaDate, '2026-06-02'); // 8h → 1 day
  assert.equal(m1.jobs[1].etaDate, '2026-06-03'); // 16h → 2 days
  assert.equal(m1.totalHours, 16);
  assert.equal(m1.readyDate, '2026-06-03');
  const m2 = r.machines.find((m) => m.machineId === 'm2');
  assert.equal(m2.jobs[0].etaDate, '2026-06-02'); // 4h still lands next day (ceil, min 1)
});

test('flags jobs that will miss their due date', () => {
  const r = computeSchedule({
    startDate: '2026-06-01', dailyHours: 8,
    jobs: [
      { id: 'A', machineId: 'm1', hours: 24, dueDate: '2026-06-02' }, // 3 days → 06-04 > due → late
      { id: 'B', machineId: 'm1', hours: 8, dueDate: '2026-06-30' },  // comfortable
    ],
  });
  const m1 = r.machines[0];
  assert.equal(m1.jobs[0].late, true);
  assert.equal(m1.jobs[1].late, false);
  assert.equal(m1.lateCount, 1);
});

test('unassigned jobs share a virtual lane, sorted last', () => {
  const r = computeSchedule({
    startDate: '2026-06-01', dailyHours: 8,
    jobs: [{ id: 'A', hours: 40 }, { id: 'B', machineId: 'm1', hours: 4 }],
  });
  assert.equal(r.machines[r.machines.length - 1].machineId, UNASSIGNED);
  assert.ok(r.machines[r.machines.length - 1].unassigned);
});

test('handles empty queue + clamps dailyHours', () => {
  assert.deepEqual(computeSchedule({ jobs: [], startDate: '2026-06-01' }).machines, []);
  const r = computeSchedule({ startDate: '2026-06-01', dailyHours: 0, jobs: [{ id: 'A', machineId: 'm1', hours: 1 }] });
  assert.equal(r.dailyHours, 8); // 0 → default 8
});
