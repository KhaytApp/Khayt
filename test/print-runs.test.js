const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/print-runs.js');
const PL = require('../lib/machine-pl.js');
const NW = require('../lib/nozzle-wear.js');

const at = (h) => `2026-10-16T${String(h).padStart(2, '0')}:00:00.000Z`;

/** What a host does with the fields: merge, and a null planned comes off. */
function apply(order, f) {
  if (!f) return order;
  const out = { ...order, machineId: f.machineId, printRuns: f.printRuns };
  if (f.plannedMachineId) out.plannedMachineId = f.plannedMachineId;
  else delete out.plannedMachineId;
  return out;
}

// ── WRITING ────────────────────────────────────────────────────────────────

test('an unassigned job sent to a printer is now on that printer', () => {
  const f = R.fields({ id: 'J1', status: 'pending' },
    { machineId: 'M2', at: at(9), started: true, file: '/Users/x/Sliced/Lamp_plate1.gcode' });
  assert.equal(f.machineId, 'M2');
  assert.equal(f.plannedMachineId, null, 'nothing was planned, so there is no plan to contrast');
  assert.deepEqual(f.printRuns, [{ machineId: 'M2', at: at(9), started: true, file: 'Lamp_plate1.gcode' }]);
});

test('a job planned for one machine and sent to another keeps the plan, and the actual wins machineId', () => {
  const f = R.fields({ id: 'J1', status: 'queued', machineId: 'M1' },
    { machineId: 'M2', at: at(9), started: true });
  assert.equal(f.machineId, 'M2', 'what printed is what the P&L and wear read');
  assert.equal(f.plannedMachineId, 'M1', 'the hand-picked machine was overwritten without a trace');
});

test('sent to the machine it was planned for: nothing to say', () => {
  const f = R.fields({ id: 'J1', status: 'queued', machineId: 'M1' }, { machineId: 'M1', at: at(9) });
  assert.equal(f.machineId, 'M1');
  assert.equal(f.plannedMachineId, null);
  assert.equal(f.printRuns[0].started, false, 'an upload without a start is recorded as not started');
});

test('a reprint on another machine after a failure is not a change of plan', () => {
  let job = { id: 'J1', status: 'pending' };
  job = apply(job, R.fields(job, { machineId: 'M1', at: at(9), started: true }));
  job = apply(job, R.fields(job, { machineId: 'M2', at: at(14), started: true }));
  assert.equal(job.machineId, 'M2');
  assert.equal(job.plannedMachineId, undefined, 'M1 was where the first attempt ran, not a plan');
  assert.equal(job.printRuns.length, 2, 'the history keeps both attempts');
});

test('the original plan survives a reprint, and goes when the job finally prints where it was planned', () => {
  let job = { id: 'J1', status: 'queued', machineId: 'M1' };
  job = apply(job, R.fields(job, { machineId: 'M2', at: at(9), started: true }));
  job = apply(job, R.fields(job, { machineId: 'M3', at: at(12), started: true }));
  assert.equal(job.plannedMachineId, 'M1', 'the plan was lost on the second send');
  job = apply(job, R.fields(job, { machineId: 'M1', at: at(15), started: true }));
  assert.equal(job.machineId, 'M1');
  assert.equal(job.plannedMachineId, undefined);
});

test('a machine picked by hand after a send is the newest plan', () => {
  let job = { id: 'J1', status: 'pending' };
  job = apply(job, R.fields(job, { machineId: 'M1', at: at(9), started: true }));
  job = { ...job, machineId: 'M3' }; // the shop re-assigned it on the board
  job = apply(job, R.fields(job, { machineId: 'M2', at: at(14), started: true }));
  assert.equal(job.plannedMachineId, 'M3');
});

test('a finished or cancelled job, a missing machine or a missing time writes nothing', () => {
  assert.equal(R.fields({ id: 'J1', status: 'completed', machineId: 'M1' }, { machineId: 'M2', at: at(9) }), null);
  assert.equal(R.fields({ id: 'J1', status: 'cancelled' }, { machineId: 'M2', at: at(9) }), null);
  assert.equal(R.fields({ id: 'J1', status: 'pending' }, { machineId: '', at: at(9) }), null);
  assert.equal(R.fields({ id: 'J1', status: 'pending' }, { machineId: 'M1' }), null);
  assert.equal(R.fields(null, { machineId: 'M1', at: at(9) }), null);
});

test('the history is capped, oldest dropped, and junk in it is ignored', () => {
  const runs = [null, 'x', { at: at(1) }];
  for (let i = 0; i < R.RUNS_CAP + 5; i++) runs.push({ machineId: 'M1', at: `run-${i}` });
  const f = R.fields({ id: 'J1', status: 'pending', machineId: 'M1', printRuns: runs }, { machineId: 'M1', at: 'last' });
  assert.equal(f.printRuns.length, R.RUNS_CAP);
  assert.equal(f.printRuns[f.printRuns.length - 1].at, 'last');
  assert.ok(f.printRuns.every((r) => r && r.machineId));
});

// ── READING ────────────────────────────────────────────────────────────────

test('a job Khayt never sent reads as nothing — the book on disk needs no migration', () => {
  assert.equal(R.printedOn({ id: 'J1', machineId: 'M1', status: 'completed' }), null);
  assert.equal(R.printedOn({ id: 'J1', printRuns: 'nonsense' }), null);
  assert.equal(R.printedOn(null), null);
});

test('printedOn names the last machine, the plan it departed from, and the earlier attempts newest first', () => {
  let job = { id: 'J1', status: 'queued', machineId: 'M1' };
  job = apply(job, R.fields(job, { machineId: 'M2', at: at(9), started: true }));
  job = apply(job, R.fields(job, { machineId: 'M3', at: at(12), started: false, file: 'a/b.gcode' }));
  const p = R.printedOn(job);
  assert.equal(p.machineId, 'M3');
  assert.equal(p.at, at(12));
  assert.equal(p.started, false);
  assert.equal(p.file, 'b.gcode');
  assert.equal(p.planned, 'M1');
  assert.deepEqual(p.earlier, [{ machineId: 'M2', at: at(9), started: true }]);
});

// ── WHAT READS IT ──────────────────────────────────────────────────────────

test('a reprint on another machine charges the P&L and the nozzle once, to the machine that printed it', () => {
  let job = {
    id: 'J1', status: 'pending', machineId: 'M1', date: '2026-10-16', printTime: 4, actualPrintTime: 5,
    parts: [{ material: 'PLA', printWeight: 100, qty: 1 }],
  };
  job = apply(job, R.fields(job, { machineId: 'M1', at: at(9), started: true }));   // failed
  job = apply(job, R.fields(job, { machineId: 'M2', at: at(14), started: true }));  // the one that worked
  job = { ...job, status: 'completed' };

  const machines = [{ id: 'M1', name: 'Ender' }, { id: 'M2', name: 'Prusa' }];
  const pl = PL.machineProfit({ machines, completed: [job], unassigned: 'None' }, {});
  const rowOf = (id) => pl.rows.find((r) => r.machineId === id);
  assert.equal(rowOf('M2').jobs, 1);
  assert.equal(rowOf('M1'), undefined, 'the failed attempt counted as a job on the first machine');
  assert.equal(pl.totals.jobs, 1, 'two sends counted twice');
  assert.equal(pl.totals.hours, rowOf('M2').hours);

  assert.equal(NW.nozzleWear([job], { id: 'M2' }, {}).grams, 100);
  assert.equal(NW.nozzleWear([job], { id: 'M1' }, {}).grams, 0);
});
