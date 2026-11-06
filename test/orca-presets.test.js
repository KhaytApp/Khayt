'use strict';
/**
 * lib/orca-presets.js — the rules the filament installer and the tuned-profile save share with
 * the native Mac app. The Node file-system halves (orca-filament-install, calibration-profile)
 * have their own tests; these pin the pure rules on their own, and prove the module loads with
 * no Node at all, which is how JavaScriptCore loads it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const P = require('../lib/orca-presets');

test('loads with no require, module or process — the JavaScriptCore way', () => {
  const code = fs.readFileSync(path.join(__dirname, '..', 'lib', 'orca-presets.js'), 'utf8');
  const sandbox = {};
  sandbox.globalThis = sandbox;
  vm.runInNewContext(code, sandbox);
  assert.equal(typeof sandbox.KhaytOrcaPresets.groupPrinters, 'function');
});

test('groupPrinters folds nozzle variants and drops internal and template machines', () => {
  const out = P.groupPrinters(['Foo 0.4 nozzle', 'Foo (0.2 nozzle)', 'fdm_base', 'MyKlipper', 'Bar 0.6 nozzle']);
  assert.deepEqual(out, [
    { label: 'Bar', machines: ['Bar 0.6 nozzle'] },
    { label: 'Foo', machines: ['Foo (0.2 nozzle)', 'Foo 0.4 nozzle'] },
  ]);
});

test('defaultPrinter prefers the U1, then the first', () => {
  assert.equal(P.defaultPrinter([{ label: 'A' }, { label: 'Snapmaker U1' }]).label, 'Snapmaker U1');
  assert.equal(P.defaultPrinter([{ label: 'A' }]).label, 'A');
  assert.equal(P.defaultPrinter([]), null);
});

test('pickVersion takes the commonest, else the fallback, else none', () => {
  assert.equal(P.pickVersion(['1', '2', '2', undefined, ''], 'x'), '2');
  assert.equal(P.pickVersion([], '02.03.01.10'), '02.03.01.10');
  assert.equal(P.pickVersion([null], undefined), null);
});

test('userProfileName: default when present, else the first that is not a backup', () => {
  assert.equal(P.userProfileName([], true), 'default');
  assert.equal(P.userProfileName(['backup-1', '12345'], false), '12345');
  assert.equal(P.userProfileName([], false), 'default');
});

test('validProfileRef accepts only served profile files', () => {
  assert.equal(P.validProfileRef('profiles/sunlu-pla.json'), true);
  for (const bad of ['../x.json', 'profiles/../x.json', 'profiles/a/b.json', '', null]) assert.equal(P.validProfileRef(bad), false, String(bad));
});

test('retarget sets the machines and the version, and removes a stale version', () => {
  const p = P.retarget({ version: 'old' }, { machines: ['M 0.4 nozzle'] }, null);
  assert.deepEqual(p, { compatible_printers: ['M 0.4 nozzle'] });
  assert.equal(P.retarget({}, { machines: [] }, '9').version, '9');
});

test('tunedPreset applies the measurements and makes a user preset of its own', () => {
  const r = P.tunedPreset({ type: 'filament', name: 'Base', setting_id: 'GF1', version: 'v' },
    { nozzleTemp: '210', flowRatio: 0.97 }, '', { machines: ['P'] }, null);
  assert.equal(r.name, 'Base (tuned)');
  assert.deepEqual(r.applied, ['nozzle_temperature', 'nozzle_temperature_initial_layer', 'filament_flow_ratio']);
  assert.equal(r.preset.from, 'User');
  assert.equal(r.preset.setting_id, undefined);
  assert.equal(r.preset.version, undefined);
  assert.deepEqual(r.preset.compatible_printers, ['P']);
  assert.throws(() => P.tunedPreset({ type: 'filament' }, {}, 'x'), /at least one measured value/);
  assert.throws(() => P.tunedPreset({ type: 'machine' }, { nozzleTemp: 1 }, 'x'), /isn’t a filament preset/);
});

test('userFilament reads what the calibration form prefills', () => {
  const f = P.userFilament({ type: 'filament', filament_type: ['PLA'], nozzle_temperature: ['205'], pressure_advance: 0.02 }, 'My PLA.json');
  assert.deepEqual(f, { name: 'My PLA', file: 'My PLA.json', type: 'PLA',
    current: { nozzleTemp: '205', flowRatio: '', pressureAdvance: '0.02', retractionLength: '', maxVolSpeed: '' } });
  assert.equal(P.userFilament({ type: 'process' }, 'x.json'), null);
});
