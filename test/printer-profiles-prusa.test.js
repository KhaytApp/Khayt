'use strict';
/**
 * The Prusa MMU3 and CORE One INDX entries in lib/printer-profiles.js.
 *
 * Every value is Prusa's own, from the PrusaResearch 2.5.10 profile bundle, copied exactly
 * from bedready.io's src/lib/targets.ts — which is where they were read off. A printer_model
 * that names the wrong machine is the failure this guards: the MK4 + MMU3 once carried
 * "MK4IS", Prusa's id for the SINGLE-extruder MK4, and a retarget relabelled a five-colour
 * project as a one-filament printer.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/printer-profiles');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert } = require('../lib/mf-convert');

const EXPECT = {
  'prusa-mk4-mmu3': { printerModel: 'MK4ISMMU3', printerSettingsId: 'Original Prusa MK4 MMU3 0.4 nozzle', printerVariant: '0.4', maxColors: 5, bed: { x: 250, y: 210, z: 220 } },
  'prusa-mk4s-mmu3': { printerModel: 'MK4SMMU3', printerSettingsId: 'Original Prusa MK4S MMU3 0.4 nozzle', printerVariant: '0.4', maxColors: 5, bed: { x: 250, y: 210, z: 220 } },
  'prusa-core-one-indx-8t': { printerModel: 'COREONE_INDX8T', printerSettingsId: 'Prusa CORE One INDX 8T HF0.4 nozzle', printerVariant: 'HF0.4', maxColors: 8, bed: { x: 248, y: 205, z: 270 } },
  'prusa-core-one-indx-4t': { printerModel: 'COREONE_INDX4T', printerSettingsId: 'Prusa CORE One INDX 4T HF0.4 nozzle', printerVariant: 'HF0.4', maxColors: 4, bed: { x: 248, y: 205, z: 270 } },
};

for (const [id, want] of Object.entries(EXPECT)) {
  test(`${id} carries Prusa's own identity`, () => {
    const p = P.getProfile(id);
    assert.ok(p, `${id} is missing`);
    assert.equal(p.flavour, 'prusa');
    assert.equal(p.nozzle, 0.4);
    for (const k of Object.keys(want)) assert.deepEqual(p[k], want[k], `${id}.${k}`);
  });
}

test('the INDX toolchangers are listed for the converter, with their slot counts', () => {
  const listed = P.listProfiles();
  for (const id of Object.keys(EXPECT)) assert.ok(listed.some((p) => p.id === id), `${id} is not offered`);
  assert.equal(new Set(listed.map((p) => p.id)).size, listed.length, 'profile ids are unique');
});

test('a Prusa retarget writes the exact preset name and variant, keeping the `; ` prefix', () => {
  const cfg = [
    '; printer_model = MK4S', '; printer_settings_id = Original Prusa MK4S 0.4 nozzle', '; printer_variant = 0.4',
    '; nozzle_diameter = 0.4', '; bed_shape = 0x0,250x0,250x210,0x210', '; max_print_height = 220',
    '; filament_colour = #FF0000;#00FF00', '',
  ].join('\n');
  const r = convert(writeZip([
    { name: '3D/3dmodel.model', data: '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>' },
    { name: 'Metadata/Slic3r_PE.config', data: cfg },
  ]), { targetId: 'prusa-core-one-indx-8t' });
  const text = openZip(r.buffer).file('Metadata/Slic3r_PE.config').toString('utf8');
  assert.match(text, /^; printer_model = COREONE_INDX8T$/m);
  assert.match(text, /^; printer_settings_id = Prusa CORE One INDX 8T HF0\.4 nozzle$/m);
  assert.match(text, /^; printer_variant = HF0\.4$/m);
  assert.match(text, /^; bed_shape = 0x0,248x0,248x205,0x205$/m);
  assert.match(text, /^; max_print_height = 270$/m);
});
