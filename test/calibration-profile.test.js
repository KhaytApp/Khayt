'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const cal = require('../lib/calibration-profile');

// Build a fake slicer config tree with a machine + a base user filament preset, and point the module at it.
function fakeSlicer({ name = 'OrcaSlicer', machines = ['Foo 0.4 nozzle'], filaments = {} } = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'calibbase-'));
  const sys = path.join(base, name, 'system', 'Vendor', 'machine');
  fs.mkdirSync(sys, { recursive: true });
  for (const m of machines) fs.writeFileSync(path.join(sys, m + '.json'), JSON.stringify({ type: 'machine', name: m }));
  const userFil = path.join(base, name, 'user', 'default', 'filament');
  fs.mkdirSync(userFil, { recursive: true });
  for (const [fn, obj] of Object.entries(filaments)) fs.writeFileSync(path.join(userFil, fn), JSON.stringify(obj));
  return { base, userFil };
}

test('overridesFromValues maps only provided measurements to Orca keys (one-element string arrays)', () => {
  const o = cal.overridesFromValues({ nozzleTemp: 205, flowRatio: '0.98', pressureAdvance: 0.021, retractionLength: '', maxVolSpeed: undefined });
  assert.deepEqual(o.nozzle_temperature, ['205']);
  assert.deepEqual(o.nozzle_temperature_initial_layer, ['205']);
  assert.deepEqual(o.filament_flow_ratio, ['0.98']);
  assert.deepEqual(o.pressure_advance, ['0.021']);
  assert.deepEqual(o.enable_pressure_advance, ['1']);
  assert.ok(!('filament_retraction_length' in o), 'blank retraction is not written');
  assert.ok(!('filament_max_volumetric_speed' in o), 'omitted max-vol-speed is not written');
  assert.deepEqual(cal.overridesFromValues({}), {}, 'no values → no overrides');
});

test('calibrationTargets lists slicers with printers + user filaments and their current values', () => {
  const { base } = fakeSlicer({
    filaments: { 'PolyLite PLA.json': { type: 'filament', name: 'PolyLite PLA', filament_type: ['PLA'], filament_flow_ratio: ['0.95'], nozzle_temperature: ['210'] } },
  });
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  try {
    const ts = cal.calibrationTargets();
    assert.equal(ts.length, 1);
    assert.equal(ts[0].id, 'orcaslicer');
    assert.deepEqual(ts[0].printers.map((p) => p.label), ['Foo']);
    assert.equal(ts[0].filaments.length, 1);
    const f = ts[0].filaments[0];
    assert.equal(f.name, 'PolyLite PLA');
    assert.equal(f.type, 'PLA');
    assert.equal(f.current.flowRatio, '0.95');
    assert.equal(f.current.nozzleTemp, '210');
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('saveCalibratedProfile derives a tuned preset from the base, keeping everything else', () => {
  const { base, userFil } = fakeSlicer({
    name: 'Snapmaker_Orca',
    filaments: {
      'Base PLA.json': { type: 'filament', name: 'Base PLA', inherits: 'Generic PLA @Snapmaker', filament_type: ['PLA'], filament_flow_ratio: ['0.95'], nozzle_temperature: ['210'], version: '02.03.01.10' },
    },
  });
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  try {
    const r = cal.saveCalibratedProfile({
      slicerId: 'snapmaker', baseFile: 'Base PLA.json', printerLabel: 'Foo',
      name: 'Base PLA (tuned)', values: { nozzleTemp: 205, flowRatio: 0.985, pressureAdvance: 0.02 },
    });
    assert.ok(r.ok);
    assert.equal(r.path, path.join(userFil, 'Base PLA (tuned).json'));
    const w = JSON.parse(fs.readFileSync(r.path, 'utf8'));
    assert.equal(w.name, 'Base PLA (tuned)');
    assert.equal(w.from, 'User');
    assert.equal(w.inherits, 'Generic PLA @Snapmaker', 'inherit chain preserved (preset stays valid)');
    assert.deepEqual(w.nozzle_temperature, ['205']);       // overridden
    assert.deepEqual(w.filament_flow_ratio, ['0.985']);    // overridden
    assert.deepEqual(w.pressure_advance, ['0.02']);
    assert.deepEqual(w.enable_pressure_advance, ['1']);
    assert.deepEqual(w.compatible_printers, ['Foo 0.4 nozzle']); // retargeted to the chosen printer
    assert.equal(w.version, '02.03.01.10');                // stamped from the slicer's own presets
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('saveCalibratedProfile rejects no-values, a missing base, and confines the base filename', () => {
  const { base } = fakeSlicer({ filaments: { 'Base.json': { type: 'filament', name: 'Base', filament_type: ['PLA'] } } });
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  try {
    assert.throws(() => cal.saveCalibratedProfile({ slicerId: 'orcaslicer', baseFile: 'Base.json', values: {} }), /at least one/i);
    assert.throws(() => cal.saveCalibratedProfile({ slicerId: 'orcaslicer', baseFile: '', values: { nozzleTemp: 200 } }), /base filament/i);
    // Traversal attempt: path.basename strips the dirs, so it resolves to a non-existent file in the dir.
    assert.throws(() => cal.saveCalibratedProfile({ slicerId: 'orcaslicer', baseFile: '../../../etc/passwd', values: { nozzleTemp: 200 } }), /read the base/i);
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});
