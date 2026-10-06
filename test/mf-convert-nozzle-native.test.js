'use strict';
/**
 * The nozzle refit and the installed-slicer overlay.
 *
 * applyOrcaNative overlays the installed slicer's machine profile and, when one resolves, its
 * process preset. Only a PROCESS preset brings widths and layer heights made for the target
 * nozzle; it answered "applied" even when none resolved, so the refit was skipped and the
 * source nozzle's widths survived. A stubbed orca-db stands in for the installed slicer.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

let processPreset = {};
const stubPath = path.join(__dirname, '..', 'lib', 'orca-db.js');
require.cache[require.resolve(stubPath)] = {
  id: stubPath, filename: stubPath, loaded: true,
  exports: {
    machineSettings: (name) => (name === 'Stub U1 (0.4 nozzle)' ? { nozzle_diameter: ['0.4'], max_layer_height: ['0.32'], min_layer_height: ['0.08'] } : null),
    defaultProcessFor: () => 'Stub 0.20mm',
    resolvePreset: () => processPreset,
  },
};
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert } = require('../lib/mf-convert');

const TARGET = { id: 'c-stub', name: 'Stub U1', flavour: 'orca', maxColors: 4, nozzle: 0.4, printerModel: 'Stub U1', orcaMachine: 'Stub U1 (0.4 nozzle)', bed: { x: 270, y: 270, z: 270 } };
const src = () => writeZip([
  { name: '3D/3dmodel.model', data: '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>' },
  { name: 'Metadata/project_settings.config', data: JSON.stringify({
    printer_model: 'Creality K2 Plus', nozzle_diameter: ['0.6'], filament_colour: ['#FF0000'], filament_type: ['PLA'],
    line_width: '0.63', layer_height: '0.3', max_layer_height: ['0.42'],
  }) },
]);
const cfgOf = (r) => JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString());

test('machine overlaid but no process preset resolved: widths are still refitted', () => {
  processPreset = {};
  const c = cfgOf(convert(src(), { targetId: 'ignored', targetProfile: TARGET }));
  assert.equal(c.line_width, '0.42', 'the 0.6 nozzle\'s widths survived');
  assert.equal(c.layer_height, '0.2');
  assert.deepEqual(c.max_layer_height, ['0.32'], 'the machine\'s own limit, not scaled a second time');
});

test('a resolved process preset is the target nozzle\'s own and is not refitted', () => {
  processPreset = { line_width: '0.45', layer_height: '0.24' };
  const c = cfgOf(convert(src(), { targetId: 'ignored', targetProfile: TARGET }));
  assert.equal(c.line_width, '0.45');
  assert.equal(c.layer_height, '0.24');
});

test('the process preset does not reset which filament prints supports and walls', () => {
  // A preset's support_filament is its default (0, "the object's own"); the file's 2 names its
  // second filament, the support material. Overlaying it would print supports in the model colour.
  processPreset = { support_filament: '0', support_interface_filament: '0', wall_filament: '0', layer_height: '0.2' };
  const two = writeZip([
    { name: '3D/3dmodel.model', data: '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>' },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({
      printer_model: 'Creality K2 Plus', nozzle_diameter: ['0.4'], filament_colour: ['#FF0000', '#FFFFFF'], filament_type: ['PLA', 'PVA'],
      support_filament: '2', support_interface_filament: '2', wall_filament: '1',
    }) },
  ]);
  const c = cfgOf(convert(two, { targetId: 'ignored', targetProfile: TARGET }));
  assert.equal(c.support_filament, '2');
  assert.equal(c.support_interface_filament, '2');
  assert.equal(c.wall_filament, '1');
  assert.equal(c.layer_height, '0.2', 'the rest of the preset still applies');
});
