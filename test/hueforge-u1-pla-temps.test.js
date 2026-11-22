/**
 * The HueForge U1 export prints PLA at PLA temperatures.
 *
 * `hueforge-u1-template.json` was captured from a real U1 project, and the
 * project it came from had ABS loaded: 270 °C nozzle, 90 °C bed, ABS fans and
 * density — all under the label "Generic PLA". The export copies the template
 * and changes only colours and layer height, so every HueForge relief from
 * Khayt (Mac and Windows/Linux) went to the printer at ABS temperatures. Found
 * by slicing an export with the Snapmaker Orca CLI: the G-code read M104 S270
 * on every tool and M140 S90 (bedready.io had the same template; its #99 era
 * review, Nov 7 2026).
 *
 * The values below are Snapmaker's U1 "Generic PLA" preset — the same table
 * bedready's converter applies (`u1FilamentPreset("PLA")`).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const TEMPLATE = require('../lib/hueforge-u1-template.json');
const HF = require('../lib/hueforge.js');
const M3 = require('../lib/hueforge-3mf.js');
const { openZip } = require('../lib/zip-read.js');

const U1_PLA = {
  additional_cooling_fan_speed: '70', close_fan_the_first_x_layers: '1',
  cool_plate_temp: '35', cool_plate_temp_initial_layer: '35',
  eng_plate_temp: '0', eng_plate_temp_initial_layer: '0',
  fan_cooling_layer_time: '100', fan_max_speed: '100', fan_min_speed: '100',
  filament_density: '1.24', filament_end_gcode: '\n', filament_flow_ratio: '0.98',
  filament_max_volumetric_speed: '12', filament_multitool_ramming_flow: '20',
  graphic_effect_plate_temp: '65', graphic_effect_plate_temp_initial_layer: '65',
  hot_plate_temp: '65', hot_plate_temp_initial_layer: '65',
  nozzle_temperature: '220', nozzle_temperature_initial_layer: '220',
  nozzle_temperature_range_high: '240', nozzle_temperature_range_low: '190',
  overhang_fan_speed: '100', overhang_fan_threshold: '50%', slow_down_layer_time: '8',
  temperature_vitrification: '45',
  textured_plate_temp: '65', textured_plate_temp_initial_layer: '65',
};

test('the template says PLA and carries the U1 PLA preset in every slot', () => {
  assert.deepEqual(TEMPLATE.filament_type, ['PLA', 'PLA', 'PLA', 'PLA']);
  for (const [key, value] of Object.entries(U1_PLA)) {
    assert.deepEqual(TEMPLATE[key], [value, value, value, value], key);
  }
});

test('no slot is set hotter than PLA can take, on any plate', () => {
  for (const t of TEMPLATE.nozzle_temperature.concat(TEMPLATE.nozzle_temperature_initial_layer)) {
    assert.ok(+t <= 240, `nozzle ${t} °C`);
  }
  for (const key of Object.keys(TEMPLATE).filter((k) => /_plate_temp(_initial_layer)?$/.test(k))) {
    for (const t of TEMPLATE[key]) assert.ok(+t <= 70, `${key} ${t} °C`);
  }
  // The plate the template selects must have a real temperature: 0 there
  // would mean "bed off" on the plate actually in use.
  const plate = { 'Textured PEI Plate': 'textured_plate_temp', 'High Temp Plate': 'hot_plate_temp',
                  'Cool Plate': 'cool_plate_temp', 'Engineering Plate': 'eng_plate_temp' }[TEMPLATE.curr_bed_type];
  assert.ok(plate, `unknown bed type ${TEMPLATE.curr_bed_type}`);
  for (const t of TEMPLATE[plate]) assert.ok(+t > 0, `${plate} is 0`);
});

test('an exported project carries the PLA preset, not the old ABS values', () => {
  const W = 12, H = 12, heights = [];
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) heights.push(4 + i * 3);
  const mesh = HF.heightfieldToMesh({ width: W, height: H, heights }, { layerH: 0.08, widthMm: 60 });
  const bands = [{ z0: 0, z1: 0.8, head: 0, hex: '#111111' }, { z0: 0.8, z1: 3, head: 1, hex: '#eeeeee' }];
  const buf = M3.buildU1_3mf({ triangles: mesh.triangles, bands, layerH: 0.08, name: 'pla', sizeMm: mesh.sizeMm });
  const zip = openZip(buf);
  const cfg = JSON.parse(Buffer.from(zip.file('Metadata/project_settings.config')).toString('utf8'));
  assert.deepEqual(cfg.nozzle_temperature, ['220', '220', '220', '220']);
  assert.deepEqual(cfg.textured_plate_temp, ['65', '65', '65', '65']);
  // Every temperature the export carries is a PLA one. (`sparse_infill_speed`
  // is also "270", in mm/s — which is why this asks the temperature keys only.)
  for (const key of Object.keys(cfg).filter((k) => /(^|_)(temp|temperature)(_|$)/.test(k))) {
    for (const t of [].concat(cfg[key])) assert.ok(+t < 250, `${key} ${t}`);
  }
});
