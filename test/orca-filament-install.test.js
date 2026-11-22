'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const inst = require('../lib/orca-filament-install');

// Build a fake Orca-family slicer config tree under a temp base and point the module at it.
function fakeSlicer({ name = 'OrcaSlicer', machines = ['Foo 0.4 nozzle', 'Foo 0.2 nozzle', 'fdm_base', 'MyKlipper'], userPresets = {} } = {}) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'orcabase-'));
  const sys = path.join(base, name, 'system', 'Vendor', 'machine');
  fs.mkdirSync(sys, { recursive: true });
  for (const m of machines) fs.writeFileSync(path.join(sys, m + '.json'), JSON.stringify({ type: 'machine', name: m }));
  const userFil = path.join(base, name, 'user', 'default', 'filament');
  fs.mkdirSync(userFil, { recursive: true });
  for (const [fn, obj] of Object.entries(userPresets)) fs.writeFileSync(path.join(userFil, fn), JSON.stringify(obj));
  return { base, userFil };
}

test('safeFileBase keeps clean names and strips anything path-unsafe', () => {
  assert.equal(inst.safeFileBase('SUNLU PLA Matte'), 'SUNLU PLA Matte');
  assert.equal(inst.safeFileBase(''), 'filament');
  for (const s of ['../../etc/passwd', 'a/b\\c:d*e?', '..\\..\\win', 'x/y']) {
    const out = inst.safeFileBase(s);
    assert.ok(out.length > 0, `${s} → non-empty`);
    assert.equal(/[\\/:*?"<>|]/.test(out), false, `${s} → "${out}" has no path/reserved chars`);
  }
});

test('installedFilamentNames lists on-disk preset basenames for the "Installed ✓" check', () => {
  const { base } = fakeSlicer({
    name: 'OrcaSlicer',
    userPresets: { 'SUNLU PLA Matte.json': { type: 'filament' }, 'eSUN PETG.json': { type: 'filament' }, 'notes.txt': {} },
  });
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  try {
    const names = inst.installedFilamentNames('orcaslicer').sort();
    assert.deepEqual(names, ['SUNLU PLA Matte', 'eSUN PETG']); // .json only, extension stripped; notes.txt ignored
    // Matches what the installer would name a profile (safeFileBase), so the renderer can pre-mark rows.
    assert.ok(names.includes(inst.safeFileBase('SUNLU PLA Matte')));
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('installedFilamentNames returns [] when no slicer is present', () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'orcabase-empty-'));
  process.env.KHAYT_ORCA_CONFIG_BASE = empty;
  try { assert.deepEqual(inst.installedFilamentNames('orcaslicer'), []); }
  finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('detectSlicers / targets: finds the slicer, folds nozzle variants, drops internal + template machines', () => {
  const { base } = fakeSlicer();
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  try {
    const ts = inst.targets();
    assert.equal(ts.length, 1);
    assert.equal(ts[0].id, 'orcaslicer');
    const labels = ts[0].printers.map((p) => p.label);
    assert.deepEqual(labels, ['Foo']); // fdm_base + MyKlipper filtered out; nozzle variants folded
    assert.deepEqual(ts[0].printers[0].machines.sort(), ['Foo 0.2 nozzle', 'Foo 0.4 nozzle']);
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('resolveVersion reads the target’s own user presets, else the fork fallback, else none', () => {
  // Snapmaker with a versioned user preset → that version.
  const snap = fakeSlicer({ name: 'Snapmaker_Orca', userPresets: { 'a.json': { type: 'filament', version: '02.03.01.10' } } });
  process.env.KHAYT_ORCA_CONFIG_BASE = snap.base;
  try {
    const s = inst.detectSlicers().find((x) => x.id === 'snapmaker');
    assert.equal(inst.resolveVersion(s), '02.03.01.10');
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }

  // OrcaSlicer with no versioned presets → none.
  const orca = fakeSlicer({ name: 'OrcaSlicer' });
  process.env.KHAYT_ORCA_CONFIG_BASE = orca.base;
  try {
    const s = inst.detectSlicers().find((x) => x.id === 'orcaslicer');
    assert.equal(inst.resolveVersion(s), null);
  } finally { delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('installProfile rejects a file reference outside the profiles set (before any FS/network)', async () => {
  for (const bad of ['../../etc/passwd', 'profiles/../secret.json', '/etc/passwd', 'profiles/x.txt', 'notprofiles/x.json']) {
    await assert.rejects(() => inst.installProfile({ file: bad, name: 'x' }, {}), /invalid file reference/i, `should reject ${bad}`);
  }
});

test('installProfile fetches, retargets compatible_printers + version, and writes to the slicer dir', async () => {
  const { base, userFil } = fakeSlicer({ name: 'Snapmaker_Orca', userPresets: { 'seed.json': { type: 'filament', version: '02.03.01.10' } } });
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  const preset = { type: 'filament', name: 'SUNLU PLA Matte', filament_type: ['PLA'], nozzle_temperature: ['220'], compatible_printers: ['Snapmaker U1 (0.4 nozzle)'], version: 'wrong' };
  const orig = global.fetch;
  global.fetch = async () => ({ ok: true, headers: { get: () => String(Buffer.byteLength(JSON.stringify(preset))) }, arrayBuffer: async () => Buffer.from(JSON.stringify(preset)) });
  try {
    const r = await inst.installProfile({ file: 'profiles/sunlu-pla-matte.json', name: 'SUNLU PLA Matte' }, { slicerId: 'snapmaker', printerLabel: 'Foo' });
    assert.ok(r.ok);
    assert.equal(r.path, path.join(userFil, 'SUNLU PLA Matte.json'));
    const w = JSON.parse(fs.readFileSync(r.path, 'utf8'));
    assert.deepEqual(w.compatible_printers.sort(), ['Foo 0.2 nozzle', 'Foo 0.4 nozzle']); // retargeted to the chosen printer
    assert.equal(w.version, '02.03.01.10'); // restamped from the slicer’s own presets
  } finally { global.fetch = orig; delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});

test('installProfile errors clearly when no supported slicer is present', async () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'orcabase-empty-'));
  process.env.KHAYT_ORCA_CONFIG_BASE = base;
  const orig = global.fetch;
  global.fetch = async () => ({ ok: true, headers: { get: () => '20' }, arrayBuffer: async () => Buffer.from('{"type":"filament","name":"x","nozzle_temperature":["200"]}') });
  try {
    await assert.rejects(() => inst.installProfile({ file: 'profiles/x.json', name: 'x' }, {}), /no supported slicer/i);
  } finally { global.fetch = orig; delete process.env.KHAYT_ORCA_CONFIG_BASE; }
});
