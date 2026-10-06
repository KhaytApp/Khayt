'use strict';
/**
 * Two small U1 safety ports from bedready.io (src/lib/convert.ts):
 *
 *  - forceOrcaGenerator: Orca imports a 3MF as a full project only when the root model's
 *    producer is one it trusts. A Creality Print file loaded as "geometry only", colours gone.
 *  - applyVlhGuard: Snapmaker Orca will not slice variable layer height with a prime tower or
 *    tree supports, and reverts an un-pinned tower-off on import.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('./helpers/no-installed-slicer'); // the converter's own rules, not the installed preset's
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert, convertMembers } = require('../lib/mf-convert');

const modelBy = (app) => '<?xml version="1.0"?><model unit="millimeter">'
  + (app ? `<metadata name="Application">${app}</metadata>` : '')
  + '<resources><object id="1"/></resources></model>';
const PROJ = (extra = {}) => JSON.stringify(Object.assign({
  printer_model: 'K2 Plus', nozzle_diameter: ['0.4'], filament_colour: ['#FF0000', '#00FF00'], filament_type: ['PLA', 'PLA'],
}, extra));
const file = (app, extra = [], proj) => writeZip([
  { name: '3D/3dmodel.model', data: modelBy(app) },
  { name: 'Metadata/project_settings.config', data: proj || PROJ() },
  ...extra,
]);
const modelOf = (r) => openZip(r.buffer).file('3D/3dmodel.model').toString('utf8');
const cfgOf = (r) => JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));

test('a Creality Print producer is rewritten so Snapmaker Orca loads the whole project', () => {
  const r = convert(file('Creality_Print V6.1.0'), { targetId: 'snapmaker-u1' });
  assert.match(modelOf(r), /<metadata name="Application">OrcaSlicer-2\.1\.1<\/metadata>/);
  assert.equal(r.report.producerRewritten, 'Creality_Print V6.1.0');
});

test('a trusted producer, or none at all, leaves the mesh byte-identical', () => {
  for (const app of ['BambuStudio-01.10.02.76', 'OrcaSlicer-2.3.0', 'SnapmakerOrca-2.1.0', null]) {
    const r = convert(file(app), { targetId: 'snapmaker-u1' });
    assert.equal(modelOf(r), modelBy(app), String(app));
    assert.equal(r.report.producerRewritten, undefined);
  }
});

test('a Bambu target is not given an Orca producer', () => {
  const r = convert(file('Creality_Print V6.1.0'), { targetId: 'bambu-x1c' });
  assert.equal(modelOf(r), modelBy('Creality_Print V6.1.0'));
});

test('a mesh passed by name is left alone, without a crash', () => {
  const r = convertMembers([
    { name: '3D/3dmodel.model', size: 1 << 30 },
    { name: 'Metadata/project_settings.config', data: PROJ() },
  ], { targetId: 'snapmaker-u1' });
  assert.equal(r.ok, true);
  assert.equal(r.members.find((m) => m.name === '3D/3dmodel.model').data, undefined);
});

const VLH = [{ name: 'Metadata/layer_heights_profile.txt', data: 'object_id=1|0.2;0.1;10;0.3' }];

test('variable layer height on the U1: tower off, tree → normal, both pinned', () => {
  const r = convert(file('OrcaSlicer-2.3.0', VLH, PROJ({ enable_prime_tower: '1', support_type: 'tree(auto)' })), { targetId: 'snapmaker-u1' });
  const c = cfgOf(r);
  assert.equal(c.enable_prime_tower, '0');
  assert.equal(c.support_type, 'normal(auto)');
  const pinned = c.different_settings_to_system[0].split(';');
  assert.ok(pinned.includes('enable_prime_tower') && pinned.includes('support_type'));
  assert.equal(r.report.vlhGuard, true);
  assert.ok(openZip(r.buffer).file('Metadata/layer_heights_profile.txt'), 'the VLH profile itself is kept');
});

test('the VLH guard keeps what the source already pinned', () => {
  const r = convert(file('OrcaSlicer-2.3.0', VLH, PROJ({ enable_prime_tower: '1', different_settings_to_system: ['wall_loops', 'f1', 'f2', 'printer'] })),
    { targetId: 'snapmaker-u1' });
  const dss = cfgOf(r).different_settings_to_system;
  assert.deepEqual(dss[0].split(';'), ['enable_prime_tower', 'wall_loops']);
  assert.deepEqual(dss.slice(1), ['f1', 'f2', 'printer']);
});

test('no VLH, another printer, or keepPrimeTowerVlh: the tower stays', () => {
  const tower = PROJ({ enable_prime_tower: '1', support_type: 'tree(auto)' });
  assert.equal(cfgOf(convert(file(null, [], tower), { targetId: 'snapmaker-u1' })).enable_prime_tower, '1');
  assert.equal(cfgOf(convert(file(null, VLH, tower), { targetId: 'bambu-x1c' })).enable_prime_tower, '1');
  assert.equal(cfgOf(convert(file(null, VLH, tower), { targetId: 'snapmaker-u1', keepPrimeTowerVlh: true })).enable_prime_tower, '1');
});
