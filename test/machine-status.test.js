'use strict';
/**
 * A printer in service, under service or retired, and when one may be
 * deleted — and the rules that must take notice (lib/machine-status.js).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const MS = require('../lib/machine-status.js');
const D = require('../lib/depreciation.js');
const AD = require('../lib/auto-dispatch.js');
const S = require('../lib/scheduling.js');
const MT = require('../lib/maintenance.js');

const book = () => ({
  machines: [{ id: 'M1', name: 'X1C' }, { id: 'M2', name: 'Spare' }, { id: 'M3', name: 'Old' }],
  printLog: [
    { id: 'J1', machineId: 'M1', status: 'completed' },
    { id: 'J2', machineId: 'M1', status: 'pending' },
    { id: 'J3', machineId: 'M1', status: 'printing' },
    { id: 'J4', parts: [{ id: 'P', machineId: 'M3' }], status: 'completed' },
  ],
  machMaintLog: [{ id: 'L1', machineId: 'M1' }],
  printFiles: [{ id: 'F', setups: [{ machineId: 'M1' }] }],
  // Top level, where both apps write it — not under settings.
  printerCompletions: { M1: [{ at: 'x' }] },
  tombstones: [{ collection: 'machines', id: 'M2' }],
});

test('the three states, from the fields both apps write', () => {
  assert.equal(MS.stateOf({ id: 'a' }), 'active');
  assert.equal(MS.stateOf({ id: 'a', isOffline: true }), 'service');
  assert.equal(MS.stateOf({ id: 'a', status: 'offline' }), 'service');
  assert.equal(MS.stateOf({ id: 'a', status: 'retired' }), 'retired');
  assert.equal(MS.stateOf({ id: 'a', retiredAt: '2026-10-01', isOffline: true }), 'retired', 'retired wins');
  assert.ok(MS.inService({ id: 'a' }) && !MS.inService({ id: 'a', isOffline: true }));
});

test('references count every record that names the machine, nested ones included', () => {
  const r = MS.references(book(), 'M1');
  assert.deepEqual(r.by, { printLog: 3, machMaintLog: 1, printFiles: 1, printerCompletions: 1 });
  assert.equal(r.total, 6);
  // A book from before the cache moved out of settings still counts, and once.
  const legacy = Object.assign(book(), { printerCompletions: undefined, settings: { printerCompletions: { M3: {} } } });
  assert.equal(MS.references(legacy, 'M3').by.printerCompletions, 1);
  const both = Object.assign(book(), { settings: { printerCompletions: { M1: {} } } });
  assert.equal(MS.references(both, 'M1').total, 6, 'kept in both places is one record');
  assert.equal(MS.references(book(), 'M3').by.printLog, 1, 'a part on the machine is history');
  assert.equal(MS.references(book(), 'M2').total, 0, 'a tombstone is not history');
});

test('delete only a printer nothing remembers; anything else is refused and retired instead', () => {
  const b = book();
  assert.deepEqual(MS.canDelete(b, 'M1').reason, 'has_history');
  assert.equal(MS.canDelete(b, 'nope').reason, 'missing');
  const out = MS.remove(b, 'M2');
  assert.equal(out.removed.id, 'M2');
  assert.deepEqual(b.machines.map((m) => m.id), ['M1', 'M3']);
  assert.equal(MS.remove(b, 'M1').removed, null);
  assert.equal(b.machines.length, 2);
});

test('retire stamps the day, clears under-service, and takes unfinished jobs off it', () => {
  const b = book();
  b.machines[0].isOffline = true;
  b.machines[0].offlineReason = 'belt';
  const r = MS.retire(b, 'M1', { at: '2026-10-18T09:00:00Z', reason: 'sold' });
  assert.ok(r.ok);
  assert.deepEqual(r.unassigned.sort(), ['J2', 'J3']);
  assert.equal(b.printLog.find((j) => j.id === 'J1').machineId, 'M1', 'history keeps its printer');
  const m = b.machines[0];
  assert.equal(m.status, 'retired');
  assert.equal(m.retiredAt, '2026-10-18');
  assert.equal(m.retiredReason, 'sold');
  assert.equal(m.isOffline, false);
  assert.equal(m.offlineReason, undefined);
  assert.equal(MS.retire(b, 'M1', {}).reason, 'no_date');
  const back = MS.unretire(m);
  assert.equal(MS.stateOf(back), 'active');
  assert.equal(back.name, 'X1C');
});

test('under service on and off', () => {
  const on = MS.setUnderService({ id: 'a', name: 'n' }, { on: true, reason: 'nozzle', since: '2026-10-18' });
  assert.deepEqual([on.isOffline, on.offlineReason, on.offlineSince], [true, 'nozzle', '2026-10-18']);
  const off = MS.setUnderService(Object.assign({ status: 'offline' }, on), { on: false });
  assert.equal(off.isOffline, false);
  assert.equal(off.offlineReason, undefined);
  assert.equal(off.status, undefined);
});

test('depreciation stops at the retire date', () => {
  const m = { id: 'M', depreciation: { price: 1200, residual: 0, life: 1, lifeUnit: 'years',
    method: 'straightLine', purchaseDate: '2026-01-01' } };
  const P = [{ key: 'a', from: '2026-03-01', to: '2026-03-31' }, { key: 'b', from: '2026-04-01', to: '2026-04-30' }];
  const live = D.periodCharges([m], [], P, {});
  const gone = D.periodCharges([Object.assign({}, m, { status: 'retired', retiredAt: '2026-03-15' })], [], P, {});
  assert.ok(gone.a.total > 0 && gone.a.total < live.a.total, 'charged for half of March');
  assert.equal(gone.b, undefined, 'nothing after it went');
});

test('dispatch proposes nothing for a printer under service or retired', () => {
  const linked = { printerApi: { type: 'moonraker', host: '192.168.1.5' } };
  assert.equal(AD.machineBlocked(Object.assign({ id: 'a', isOffline: true }, linked), { state: 'idle' }), 'ad.under_service');
  assert.equal(AD.machineBlocked(Object.assign({ id: 'a', status: 'retired' }, linked), { state: 'idle' }), 'ad.retired');
});

test('the schedule never places work on a retired printer', () => {
  const out = S.proposeSchedule([{ id: 'R', status: 'retired', retiredAt: '2026-01-01' }, { id: 'A' }],
    [{ id: 'J', status: 'pending', printTime: 1 }], {});
  assert.deepEqual(out.assignments.map((a) => a.machineId), ['A']);
  const only = S.proposeSchedule([{ id: 'R', status: 'retired' }], [{ id: 'J', status: 'pending', printTime: 1 }], {});
  assert.equal(only.assignments.length, 0, 'a retired printer alone takes nothing');
});

test('maintenance for a retired or deleted printer is never due, given the machines', () => {
  const tasks = [{ id: 't1', machineId: 'R', intervalDays: 1, lastDoneAt: '2020-01-01' },
    { id: 't2', machineId: 'gone', intervalDays: 1, lastDoneAt: '2020-01-01' },
    { id: 't3', machineId: 'A', intervalDays: 1, lastDoneAt: '2020-01-01' }];
  const machines = [{ id: 'R', status: 'retired' }, { id: 'A' }];
  const all = MT.dueTasks(tasks, {}, Date.parse('2026-10-18'));
  const live = MT.dueTasks(tasks, {}, Date.parse('2026-10-18'), machines);
  assert.ok(all.length >= live.length);
  assert.ok(!live.some((t) => t.machineId === 'R' || t.machineId === 'gone'));
});
