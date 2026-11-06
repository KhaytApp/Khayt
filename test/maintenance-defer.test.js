'use strict';
// "Inspected — not needed", the print-hours rate, and the due-date projection
// (lib/maintenance.js). markDone's own contract is pinned in maintenance.test.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/maintenance.js');

const DAY = 24 * 60 * 60 * 1000;
const NOW = '2026-11-07T12:00:00.000Z';
const NOW_MS = Date.parse(NOW);
const ago = (d) => new Date(NOW_MS - d * DAY).toISOString();

test('a deferral pushes an hours task out and reports it', () => {
  const task = { id: 'T', intervalHours: 100, lastDoneHours: 0, lastDoneAt: ago(10) };
  assert.equal(M.taskStatus(task, 120, NOW).status, 'due');
  const patch = M.deferTask(task, 120, NOW);
  assert.equal(patch.inspectedAt, NOW);
  assert.equal(patch.inspectedHours, 120);
  assert.equal(patch.deferUntilHours, 170, 'half an interval from the inspection');
  assert.equal(patch.deferUntilAt, null, 'no date clock, no date push');
  const after = { ...task, ...patch };
  const st = M.taskStatus(after, 120, NOW);
  assert.equal(st.status, 'ok');
  assert.equal(st.deferred, true);
  assert.equal(st.hoursRemaining, 50);
  assert.equal(M.taskStatus(after, 170, NOW).status, 'due', 'due again at the pushed point');
});

test('a deferral leaves markDone fields alone and is superseded by a later completion', () => {
  const task = { id: 'T', intervalHours: 100, lastDoneHours: 0, lastDoneAt: ago(10) };
  const patch = M.deferTask(task, 120, NOW);
  assert.ok(!('lastDoneHours' in patch) && !('lastDoneAt' in patch));
  const deferred = { ...task, ...patch };
  const later = new Date(NOW_MS + DAY).toISOString();
  const done = { ...deferred, ...M.markDone(deferred, 130, later) };
  assert.deepEqual(M.markDone(deferred, 130, later), { lastDoneHours: 130, lastDoneAt: later });
  const st = M.taskStatus(done, 130, later);
  assert.equal(st.deferred, false, 'the completion wins');
  assert.equal(st.hoursRemaining, 100);
});

test('a deferral never brings a task forward', () => {
  const task = { id: 'T', intervalHours: 100, lastDoneHours: 0, lastDoneAt: ago(1) };
  const patch = M.deferTask(task, 10, NOW);
  assert.equal(patch.deferUntilHours, 100, 'it was due at 100 already');
  assert.equal(M.taskStatus({ ...task, ...patch }, 10, NOW).hoursRemaining, 90);
});

test('a day-interval task is pushed by days', () => {
  const task = { id: 'T', intervalDays: 30, lastDoneAt: ago(40) };
  assert.equal(M.taskStatus(task, 0, NOW).status, 'due');
  const patch = M.deferTask(task, 0, NOW, { days: 10 });
  assert.equal(patch.deferUntilAt, new Date(NOW_MS + 10 * DAY).toISOString());
  const st = M.taskStatus({ ...task, ...patch }, 0, NOW);
  assert.equal(st.status, 'ok');
  assert.equal(Math.round(st.daysRemaining), 10);
});

test('explicit pushes are capped at one interval; fraction defaults to half', () => {
  const task = { id: 'T', intervalHours: 100, intervalDays: 20, lastDoneHours: 0, lastDoneAt: ago(30) };
  const big = M.deferTask(task, 200, NOW, { hours: 1000, days: 1000 });
  assert.equal(big.deferUntilHours, 300);
  assert.equal(big.deferUntilAt, new Date(NOW_MS + 20 * DAY).toISOString());
  assert.equal(M.DEFER_FRACTION, 0.5);
});

test('a record with no deferral fields reads exactly as before', () => {
  const task = { id: 'T', intervalHours: 100, lastDoneHours: 0 };
  assert.deepEqual(M.taskStatus(task, 95, NOW),
    { status: 'warning', hoursRemaining: 5, daysRemaining: null, deferred: false });
  assert.equal(M.activeDeferral(task), null);
  assert.equal(M.activeDeferral({ inspectedAt: NOW }), null, 'no target, nothing deferred');
});

test('hoursPerDay averages completed jobs in the window', () => {
  const jobs = [
    { machineId: 'A', status: 'completed', printTime: 30, completedAt: ago(5) },
    { machineId: 'A', status: 'delivered', printTime: 30, date: ago(20).slice(0, 10) },
    { machineId: 'A', status: 'cancelled', printTime: 99, completedAt: ago(2) },
    { machineId: 'B', status: 'completed', printTime: 99, completedAt: ago(2) },
    { machineId: 'A', status: 'completed', printTime: 300, completedAt: ago(90) },
  ];
  assert.equal(M.hoursPerDay(jobs, 'A', NOW, 30), 2, '60 h over 30 days');
  assert.equal(M.hoursPerDay(jobs, 'C', NOW, 30), 0);
  assert.equal(M.hoursPerDay(null, 'A', NOW), 0);
});

test('hoursPerDay averages a new machine over the days it has run', () => {
  const jobs = [{ machineId: 'A', status: 'completed', printTime: 20, completedAt: ago(4) }];
  assert.equal(M.hoursPerDay(jobs, 'A', NOW, 30), 5);
});

test('projectDue takes the earlier clock, and an hours task with no rate cannot be projected', () => {
  const task = { id: 'T', intervalHours: 100, intervalDays: 60, lastDoneHours: 0, lastDoneAt: NOW };
  const byHours = M.projectDue(task, 40, 6, NOW);
  assert.equal(byHours.clock, 'hours');
  assert.equal(byHours.dueAt, new Date(NOW_MS + 10 * DAY).toISOString());
  const byDays = M.projectDue(task, 40, 0.5, NOW);
  assert.equal(byDays.clock, 'days');
  assert.equal(byDays.dueAt, new Date(NOW_MS + 60 * DAY).toISOString());
  assert.equal(M.projectDue({ intervalHours: 100, lastDoneHours: 0 }, 10, 0, NOW).dueAt, null);
  const over = M.projectDue({ intervalHours: 100, lastDoneHours: 0 }, 150, 0, NOW);
  assert.equal(over.dueAt, NOW, 'already due projects to now');
});
