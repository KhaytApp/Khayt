'use strict';
/**
 * Full Spectrum settings that Orca keeps, and that print.
 *
 * Orca rebuilds a named system preset on import and re-applies only the keys listed in
 * `different_settings_to_system` — so a Full Spectrum file that did not list its mix keys
 * opened as a stock U1 preset with the mixes gone. lib/hueforge-3mf.js already pinned its
 * own keys; applyFullSpectrumConfig did not. The support gaps and purge routing are from
 * bedready.io's withMixes, learned on real mixed prints (src/lib/convert.ts).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('./helpers/no-installed-slicer'); // the converter's own rules, not the installed preset's
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert } = require('../lib/mf-convert');
const fs = require('../lib/full-spectrum');

const MODEL = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>';

function fiveColours(extra = {}) {
  return writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(Object.assign({
      printer_model: 'X1C', nozzle_diameter: ['0.4'], print_settings_id: '0.20mm Standard @BBL X1C',
      filament_colour: ['#FF0000', '#00AA00', '#0000FF', '#FFFF00', '#FF00FF'],
      filament_type: ['PLA', 'PLA', 'PLA', 'PLA', 'PLA'],
    }, extra)) },
  ]);
}
const cfgOf = (r) => JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));

test('every Full Spectrum key is pinned so Orca does not revert it', () => {
  const r = convert(fiveColours(), { targetId: 'snapmaker-u1', fullSpectrum: true });
  assert.equal(r.report.fullSpectrum, true);
  const c = cfgOf(r);
  const dss = c.different_settings_to_system;
  assert.ok(Array.isArray(dss), 'different_settings_to_system is written');
  assert.equal(dss.length, c.filament_colour.length + 2, 'filament count + 2 entries');
  const pinned = dss[0].split(';');
  for (const k of ['mixed_filament_definitions', ...Object.keys(fs.MIXED_DITHERING_DEFAULTS),
    'support_top_z_distance', 'support_bottom_z_distance', 'flush_into_objects', 'flush_into_infill', 'flush_into_support']) {
    assert.ok(pinned.includes(k), `${k} is not pinned`);
  }
});

test('print keys the source already declared stay pinned', () => {
  const r = convert(fiveColours({ different_settings_to_system: ['wall_loops;sparse_infill_density', '', '', '', '', '', ''] }),
    { targetId: 'snapmaker-u1', fullSpectrum: true });
  const pinned = cfgOf(r).different_settings_to_system[0].split(';');
  assert.ok(pinned.includes('wall_loops') && pinned.includes('sparse_infill_density'));
  assert.ok(pinned.includes('mixed_filament_definitions'));
});

test('mixed zones get support clearance — a floor, never a cut', () => {
  const low = cfgOf(convert(fiveColours({ support_top_z_distance: '0.2', support_bottom_z_distance: '0.1' }),
    { targetId: 'snapmaker-u1', fullSpectrum: true }));
  assert.equal(low.support_top_z_distance, '0.35');
  assert.equal(low.support_bottom_z_distance, '0.25');
  const high = cfgOf(convert(fiveColours({ support_top_z_distance: '0.5', support_bottom_z_distance: '0.4' }),
    { targetId: 'snapmaker-u1', fullSpectrum: true }));
  assert.equal(high.support_top_z_distance, '0.5');
  assert.equal(high.support_bottom_z_distance, '0.4');
});

test('mix purge goes to the tower, not into the model or the supports', () => {
  const c = cfgOf(convert(fiveColours({ flush_into_support: '1', flush_into_objects: '1', flush_into_infill: '1' }),
    { targetId: 'snapmaker-u1', fullSpectrum: true }));
  assert.equal(c.flush_into_objects, '0');
  assert.equal(c.flush_into_infill, '0');
  assert.equal(c.flush_into_support, '0');
});

test('Subdivide Mix Layer is on by default and off on request', () => {
  const on = cfgOf(convert(fiveColours(), { targetId: 'snapmaker-u1', fullSpectrum: true }));
  assert.equal(on.dithering_local_z_mode, '1');
  const off = cfgOf(convert(fiveColours(), { targetId: 'snapmaker-u1', fullSpectrum: true, fsSubdivide: false }));
  assert.equal(off.dithering_local_z_mode, '0');
  assert.equal(off.dithering_local_z_infill, '0');
});

test('a fixed mixed-colour layer height switches to the fixed-step pipeline', () => {
  const c = cfgOf(convert(fiveColours(), { targetId: 'snapmaker-u1', fullSpectrum: true, fsMixedLayerHeight: 0.08 }));
  assert.equal(c.dithering_z_step_size, '0.08');
  assert.equal(c.dithering_step_painted_zones_only, '1');
  assert.equal(c.dithering_local_z_mode, '0');
  assert.ok(c.different_settings_to_system[0].split(';').includes('dithering_z_step_size'));
});

test('a plain retarget touches none of it', () => {
  const c = cfgOf(convert(fiveColours({ flush_into_support: '1' }), { targetId: 'snapmaker-u1' }));
  assert.equal(c.flush_into_support, '1');
  assert.equal(c.different_settings_to_system, undefined);
});
