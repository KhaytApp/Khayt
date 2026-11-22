'use strict';
// Care plans and the parts buy list (lib/care-plans.js).
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/care-plans.js');
const M = require('../lib/maintenance.js');

const DAY = 24 * 60 * 60 * 1000;
const NOW = '2026-11-07T12:00:00.000Z';
const NOW_MS = Date.parse(NOW);
const ago = (d) => new Date(NOW_MS - d * DAY).toISOString();

test('every plan names a source, a known kind and only catalogued parts', () => {
  const starterIds = new Set(M.STARTER_TASKS.map((t) => t.id));
  for (const p of C.allPlans()) {
    assert.ok(p.source === 'starter' || /^https:\/\//.test(p.source), p.id);
    assert.ok(['fdm', 'resin'].includes(p.kind), p.id);
    assert.ok(p.tasks.length > 0, p.id);
    const seen = new Set();
    for (const t of p.tasks) {
      assert.ok(!seen.has(t.id), `${p.id} lists ${t.id} twice`);
      seen.add(t.id);
      assert.ok(t.intervalHours > 0 || t.intervalDays > 0, `${p.id}/${t.id} has no interval`);
      for (const x of t.parts) assert.ok(C.part(x.id), `${p.id}/${t.id} uses unknown part ${x.id}`);
      // A task marked starter carries the starter list's interval exactly.
      if (t.source === 'starter' || p.source === 'starter') {
        const s = M.STARTER_TASKS.find((x) => x.id === t.id);
        if (s) assert.deepEqual([t.intervalHours, t.intervalDays], [s.intervalHours, s.intervalDays], `${p.id}/${t.id}`);
        else assert.ok(!starterIds.has(t.id));
      }
    }
  }
});

test('the common machines are covered', () => {
  const ids = C.allPlans().map((p) => p.id);
  for (const id of ['bambu-x1', 'bambu-p1', 'bambu-a1', 'bambu-a1-mini', 'prusa-mk4', 'prusa-core-one',
    'snapmaker-u1', 'creality-k1', 'creality-ender3-v3-ke', 'creality-ender3-v3']) {
    assert.ok(ids.includes(id), id);
  }
  assert.ok(C.allPlans().filter((p) => p.kind === 'resin').length >= 1);
  assert.deepEqual(C.plansFor('prusa').map((p) => p.id), ['prusa-mk4', 'prusa-core-one']);
});

test('a machine record is matched to its plan, the longest name first', () => {
  assert.equal(C.matchPlan('Bambu Lab', 'A1 mini'), 'bambu-a1-mini');
  assert.equal(C.matchPlan('Bambu Lab', 'A1'), 'bambu-a1');
  assert.equal(C.matchPlan('Creality', 'K1 Max'), 'creality-k1');
  assert.equal(C.matchPlan('Creality', 'Ender-3 V3 KE'), 'creality-ender3-v3-ke');
  assert.equal(C.matchPlan('Creality', 'Ender-3 V3 SE'), 'creality-ender3-v3');
  assert.equal(C.matchPlan('', '', 'Snapmaker U1 #2'), 'snapmaker-u1');
  assert.equal(C.matchPlan('', '', 'Front printer'), null);
  assert.equal(C.matchPlan(), null);
});

test('comparePlan finds the tasks a machine has, by careTaskId or by name', () => {
  const tasks = [
    { id: 'R1', machineId: 'A', name: 'whatever', careTaskId: 'leadscrew', intervalDays: 90 },
    { id: 'R2', machineId: 'A', name: 'Clean the fans and heatsink', intervalHours: 300, intervalDays: 90 },
    { id: 'R3', machineId: 'B', careTaskId: 'rods', intervalDays: 30 },
  ];
  const out = C.comparePlan(tasks, 'A', 'bambu-p1', { fans: 'Clean the fans and heatsink' });
  assert.deepEqual(out.same.map((r) => r.recordId), ['R1']);
  assert.deepEqual(out.differ.map((r) => [r.recordId, r.hadHours, r.hadDays]), [['R2', 300, 90]]);
  assert.ok(out.add.some((t) => t.id === 'rods'), "another machine's task is not this one's");
  assert.equal(out.add.length, C.plan('bambu-p1').tasks.length - 2);
});

test('applyPlan adds the missing tasks counted from now and re-times only what is confirmed', () => {
  const had = [
    { id: 'R2', machineId: 'A', name: 'Fans', intervalHours: 300, intervalDays: 90, lastDoneHours: 5, lastDoneAt: ago(3) },
    { id: 'X', machineId: 'B', name: 'other' },
  ];
  const names = { fans: 'Fans', rods: 'Rods' };
  const kept = C.applyPlan(had, { machineId: 'A', planId: 'bambu-p1', meter: 42, nowIso: NOW, names, namesById: names });
  const fans = kept.tasks.find((t) => t.id === 'R2');
  assert.equal(fans.intervalHours, 300, 'not confirmed: the shop keeps its interval');
  assert.equal(fans.careTaskId, 'fans');
  assert.equal(fans.lastDoneAt, ago(3));
  assert.deepEqual(had[0].careTaskId, undefined, 'input not mutated');
  const rods = kept.tasks.find((t) => t.careTaskId === 'rods');
  assert.equal(rods.name, 'Rods');
  assert.equal(rods.machineId, 'A');
  assert.equal(rods.lastDoneHours, 42);
  assert.equal(rods.lastDoneAt, NOW);
  assert.equal(rods.intervalHours, null, 'the other app writes null for an unused clock');
  assert.equal(rods.intervalDays, 30);
  assert.equal(rods.carePlanId, 'bambu-p1');
  assert.equal(kept.added.length, C.plan('bambu-p1').tasks.length - 1);

  const swapped = C.applyPlan(had, { machineId: 'A', planId: 'bambu-p1', meter: 42, nowIso: NOW,
    namesById: names, confirm: ['R2'], ids: { rods: 'MTASK-rods' } });
  const f2 = swapped.tasks.find((t) => t.id === 'R2');
  assert.deepEqual([f2.intervalHours, f2.intervalDays, f2.lastDoneHours], [null, 7, 5]);
  assert.ok(swapped.tasks.some((t) => t.id === 'MTASK-rods'));

  const again = C.applyPlan(swapped.tasks, { machineId: 'A', planId: 'bambu-p1', meter: 50, nowIso: NOW });
  assert.deepEqual([again.added, again.changed], [[], []], 'applying twice adds nothing');
  assert.deepEqual(C.applyPlan(had, { planId: 'nope' }).tasks, had);
});

test('partsBuyList projects from print-hours and orders by date', () => {
  // 3 h/day over the last 30 days on A.
  const jobs = [{ machineId: 'A', status: 'completed', printTime: 0, completedAt: ago(60) }];
  for (let d = 0; d < 30; d++) jobs.push({ machineId: 'A', status: 'completed', printTime: 3, completedAt: ago(d) });
  const machines = [{ id: 'A', name: 'Alpha' }, { id: 'R', name: 'Gone', status: 'retired' }];
  const meter = M.hoursMeter(jobs, 'A'); // 90
  const tasks = [
    // 500 h nozzle done at 0 -> 410 h left at 3 h/day -> ~137 days: outside 90.
    { id: 'N', machineId: 'A', name: 'Nozzle', careTaskId: 'nozzle', carePlanId: 'bambu-p1',
      intervalHours: 500, lastDoneHours: 0, lastDoneAt: ago(30) },
    // 120 h -> 30 left -> 10 days; part listed on the record.
    { id: 'T', machineId: 'A', name: 'Tube', intervalHours: 120, lastDoneHours: 0, lastDoneAt: ago(30),
      parts: [{ id: 'ptfe_tube', qty: 2 }] },
    // Grease, 90-day clock, 85 days ago -> due in 5 days, order-by 2 days ago.
    { id: 'L', machineId: 'A', name: 'Screws', careTaskId: 'leadscrew', carePlanId: 'bambu-p1',
      intervalDays: 90, lastDoneHours: 0, lastDoneAt: ago(85) },
    // No parts: not listed.
    { id: 'F', machineId: 'A', name: 'Fans', careTaskId: 'fans', carePlanId: 'bambu-p1', intervalDays: 7, lastDoneAt: ago(10) },
    // Retired machine: not listed.
    { id: 'Z', machineId: 'R', parts: [{ id: 'nozzle', qty: 1 }], intervalDays: 1, lastDoneAt: ago(10) },
  ];
  assert.equal(meter, 90);
  const rows = C.partsBuyList({ machines, tasks, jobs, now: NOW });
  assert.deepEqual(rows.map((r) => [r.taskId, r.partId, r.qty]), [['L', 'grease', 1], ['T', 'ptfe_tube', 2]]);
  const [grease, tube] = rows;
  assert.equal(grease.dueAt, new Date(NOW_MS + 5 * DAY).toISOString());
  assert.equal(grease.orderBy, new Date(NOW_MS - 2 * DAY).toISOString());
  assert.equal(grease.late, true);
  assert.equal(grease.machineName, 'Alpha');
  assert.equal(tube.dueAt, new Date(NOW_MS + 10 * DAY).toISOString());
  assert.equal(tube.orderBy, new Date(NOW_MS + 3 * DAY).toISOString());
  assert.equal(tube.late, false);

  const far = C.partsBuyList({ machines, tasks, jobs, now: NOW, horizonDays: 200 });
  assert.ok(far.some((r) => r.taskId === 'N' && r.partId === 'nozzle'));
  const quick = C.partsBuyList({ machines, tasks, jobs, now: NOW, leadDays: { ptfe_tube: 0 } });
  assert.equal(quick.find((r) => r.partId === 'ptfe_tube').orderBy, tube.dueAt);
  assert.deepEqual(C.partsTotals(far).map((t) => t.partId), ['grease', 'ptfe_tube', 'nozzle']);
});

test('a deferred task moves out of the buy list window', () => {
  const jobs = [{ machineId: 'A', status: 'completed', printTime: 300, completedAt: ago(1) }];
  const task = { id: 'T', machineId: 'A', intervalHours: 100, lastDoneHours: 0, lastDoneAt: ago(10),
    parts: [{ id: 'nozzle', qty: 1 }] };
  const now = C.partsBuyList({ machines: [{ id: 'A' }], tasks: [task], jobs, now: NOW });
  assert.equal(now[0].dueAt, NOW, 'overdue projects to now');
  const deferred = { ...task, ...M.deferTask(task, 300, NOW) };
  const later = C.partsBuyList({ machines: [{ id: 'A' }], tasks: [deferred], jobs, now: NOW });
  assert.ok(later[0].dueAt > NOW);
});
