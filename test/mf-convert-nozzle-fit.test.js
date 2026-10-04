'use strict';
/**
 * A changed nozzle refits the widths and layer heights that go with it.
 *
 * A retarget writes the target's nozzle_diameter, but line widths and layer heights are
 * process settings that arrive from the source untouched: a 0.6-nozzle file converted for a
 * 0.4 printer claimed a 0.4 nozzle while asking for 0.63 mm lines. Ported from bedready.io's
 * applyNozzleFit (src/lib/convert.ts).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert } = require('../lib/mf-convert');

const MODEL = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>';

function bambu(nozzle, extra = {}) {
  return writeZip([
    { name: '3D/3dmodel.model', data: MODEL },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(Object.assign({
      printer_model: 'Bambu Lab X1 Carbon', nozzle_diameter: [String(nozzle)],
      filament_colour: ['#FF0000'], filament_type: ['PLA'],
      line_width: '0.63', outer_wall_line_width: '0.62', inner_wall_line_width: '0.63',
      sparse_infill_line_width: '0.63', top_surface_line_width: '0.62',
      layer_height: '0.3', initial_layer_print_height: '0.3',
      max_layer_height: ['0.42'], min_layer_height: ['0.12'],
      skin_infill_line_width: '100%',
    }, extra)) },
  ]);
}
const cfgOf = (r) => JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString('utf8'));

test('a 0.6 source for a 0.4 printer gets 0.4-sized lines', () => {
  const r = convert(bambu(0.6), { targetId: 'bambu-p1s' });
  const c = cfgOf(r);
  assert.deepEqual(c.nozzle_diameter, ['0.4']);
  assert.equal(c.line_width, '0.42');
  assert.equal(c.outer_wall_line_width, '0.41');
  assert.equal(c.sparse_infill_line_width, '0.42');
  assert.equal(c.layer_height, '0.2');
  assert.equal(c.initial_layer_print_height, '0.2');
  assert.deepEqual(c.max_layer_height, ['0.28']);
  assert.deepEqual(c.min_layer_height, ['0.08']);
  assert.equal(c.skin_infill_line_width, '100%', 'a percentage is already nozzle-relative');
  assert.ok(r.report.nozzleFit.some((f) => f.key === 'line_width' && f.from === '0.63' && f.to === '0.42'));
});

test('layer height stays inside 20–80% of the new nozzle', () => {
  // 0.36 on a 0.4 scaled to a 0.2 is 0.18, past 80% of 0.2 (0.16).
  const c = cfgOf(convert(bambu(0.4, { layer_height: '0.36', line_width: '0.42' }),
    { targetId: 'ignored', targetProfile: { id: 'c-02', name: 'Fine', flavour: 'bambu', maxColors: 4, nozzle: 0.2, printerModel: 'Fine', bed: { x: 200, y: 200, z: 200 } } }));
  assert.equal(c.layer_height, '0.16');
  assert.equal(c.line_width, '0.21');
});

test('a matched nozzle changes nothing', () => {
  const r = convert(bambu(0.4, { line_width: '0.45', layer_height: '0.28' }), { targetId: 'bambu-p1s' });
  const c = cfgOf(r);
  assert.equal(c.line_width, '0.45');
  assert.equal(c.layer_height, '0.28');
  assert.equal(r.report.nozzleFit, undefined);
});

test('a PrusaSlicer config is refitted too, keeping its `; ` prefix', () => {
  const cfg = [
    '; printer_model = MK3S', '; nozzle_diameter = 0.6', '; layer_height = 0.3', '; first_layer_height = 0.3',
    '; extrusion_width = 0.68', '; perimeter_extrusion_width = 0', '; infill_extrusion_width = 110%',
    '; filament_colour = #FF0000', '',
  ].join('\n');
  const r = convert(writeZip([{ name: '3D/3dmodel.model', data: MODEL }, { name: 'Metadata/Slic3r_PE.config', data: cfg }]),
    { targetId: 'prusa-xl-5t' });
  const text = openZip(r.buffer).file('Metadata/Slic3r_PE.config').toString('utf8');
  assert.match(text, /^; nozzle_diameter = 0.4$/m);
  assert.match(text, /^; extrusion_width = 0.45$/m);
  assert.match(text, /^; layer_height = 0.2$/m);
  assert.match(text, /^; perimeter_extrusion_width = 0$/m, '0 is "auto" and stays auto');
  assert.match(text, /^; infill_extrusion_width = 110%$/m);
});
