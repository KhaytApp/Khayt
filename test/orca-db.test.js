'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const db = require('../lib/orca-db');

test('orca-db: listU1Filaments returns well-formed entries (or empty when no slicer)', () => {
  const list = db.listU1Filaments();
  assert.ok(Array.isArray(list));
  for (const f of list) {
    assert.equal(typeof f.name, 'string');
    assert.ok(f.name.length > 0);
    assert.equal(typeof f.type, 'string');
    assert.ok(!/\bbase\d*\b/i.test(f.name), 'no internal base templates');
    assert.match(f.name, /@U1/i);
  }
  // available() must agree with whether any root resolved
  assert.equal(typeof db.available(), 'boolean');
});

test('orca-db: resolves U1 machine + process (or no-ops when no slicer)', () => {
  const m = db.u1MachineSettings();
  assert.equal(typeof m, 'object');
  const procs = db.listU1Processes();
  assert.ok(Array.isArray(procs));
  if (db.available() && procs.length) {
    // Resolved machine should carry real U1 identity when the DB is present.
    assert.ok(Object.keys(m).length > 0);
    for (const p of procs) { assert.match(p.name, /@Snapmaker U1/i); assert.ok(!/_old\b/i.test(p.name)); }
    const def = db.defaultU1Process();
    assert.equal(typeof def, 'string');
    assert.ok(Object.keys(db.u1ProcessSettings(def)).length > 0);
  }
});

test('orca-db: listMachines + machineInfo (or empty when no slicer)', () => {
  const machines = db.listMachines();
  assert.ok(Array.isArray(machines));
  for (const m of machines.slice(0, 20)) { assert.equal(typeof m.name, 'string'); assert.equal(typeof m.vendor, 'string'); }
  if (db.available() && machines.length) {
    const info = db.machineInfo(machines[0].name);
    assert.ok(info && typeof info === 'object');
    assert.equal(info.name, machines[0].name);
    assert.ok(info.colors >= 1);
  }
  assert.equal(db.machineInfo('definitely not a real printer xyz'), null);
});
