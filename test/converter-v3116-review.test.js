'use strict';
/**
 * Pre-release review of the v3.11.6 converter work: each test below failed before its fix.
 */
require('./helpers/no-installed-slicer');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert } = require('../lib/mf-convert');
const mesh = require('../lib/mf-mesh');
const { encodeSolidPaint } = mesh;

const K = 6;
function bandedObject(id) {
  const v = [], t = [];
  let n = 0;
  for (let z = 0; z < 30 - 1e-6; z += 0.2) {
    const z0 = +z.toFixed(3), z1 = +(z + 0.2).toFixed(3);
    v.push(`<vertex x="0" y="0" z="${z0}"/>`, `<vertex x="30" y="0" z="${z0}"/>`, `<vertex x="0" y="0" z="${z1}"/>`);
    t.push(`<triangle v1="${n}" v2="${n + 1}" v3="${n + 2}" paint_color="${encodeSolidPaint(1 + Math.min(K - 1, Math.floor(z0 / 5)))}"/>`);
    n += 3;
  }
  return `<object id="${id}" type="model"><mesh><vertices>${v.join('')}</vertices><triangles>${t.join('')}</triangles></mesh></object>`;
}

test('band-swap on a two-plate file pauses on BOTH plates', () => {
  const model = '<?xml version="1.0"?><model unit="millimeter"><resources>' + bandedObject(1) + bandedObject(2)
    + '</resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 128 128 0"/><item objectid="2" transform="1 0 0 0 1 0 0 0 1 435 128 0"/></build></model>';
  const ms = '<?xml version="1.0"?><config><object id="1"><metadata key="extruder" value="1"/></object><object id="2"><metadata key="extruder" value="1"/></object>'
    + '<plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="1"/></model_instance></plate>'
    + '<plate><metadata key="plater_id" value="2"/><model_instance><metadata key="object_id" value="2"/></model_instance></plate></config>';
  const cols = ['#FF0000', '#00FF00', '#0000FF', '#FFFF00', '#FF00FF', '#00FFFF'];
  const buf = writeZip([
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/model_settings.config', data: ms },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ printer_model: 'Bambu Lab X1 Carbon', layer_height: '0.2', nozzle_diameter: ['0.4'], filament_colour: cols, filament_type: cols.map(() => 'PLA') }) },
  ]);
  const r = convert(buf, { targetId: 'snapmaker-u1', bandSwap: true });
  assert.equal(r.report.bandSwap, true);
  const xml = openZip(r.buffer).file('Metadata/custom_gcode_per_layer.xml').toString();
  const plates = [...xml.matchAll(/<plate>([\s\S]*?)<\/plate>/g)].map((m) => m[1]);
  assert.deepEqual(plates.map((p) => /<plate_info id="(\d+)"/.exec(p)[1]), ['1', '2']);
  assert.equal(plates[0].replace(/id="\d+"/, ''), plates[1].replace(/id="\d+"/, ''), 'the same pauses on each plate');
  assert.ok(/gcode="M600"/.test(plates[1]));
});

test('a run of unclosed <triangle tags is read in linear time', () => {
  const model = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/></vertices><triangles>'
    + '<triangle '.repeat(32000) + '</triangles></mesh></object></resources><build><item objectid="1"/></build></model>';
  const cfg = '<?xml version="1.0"?><config><object id="1" instances_count="1"><metadata type="object" key="extruder" value="1"/><volume firstid="0" lastid="10"><metadata type="volume" key="extruder" value="2"/></volume></object></config>';
  const buf = writeZip([{ name: '3D/3dmodel.model', data: model }, { name: 'Metadata/Slic3r_PE_model.config', data: cfg }]);
  const t0 = Date.now();
  try { mesh.extractMeshFromBuffer(buf); } catch (_) { /* refused is fine; slow is not */ }
  assert.ok(Date.now() - t0 < 3000, `took ${Date.now() - t0} ms`);
});

test('Prusa volume extruders still paint a self-closing triangle', () => {
  const model = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh><vertices>'
    + '<vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="1"/></vertices><triangles>'
    + '<triangle v1="0" v2="1" v3="2" /></triangles></mesh></object></resources><build><item objectid="1"/></build></model>';
  const cfg = '<?xml version="1.0"?><config><object id="1" instances_count="1"><metadata type="object" key="extruder" value="1"/><volume firstid="0" lastid="0"><metadata type="volume" key="extruder" value="2"/></volume></object></config>';
  const m = mesh.extractMeshFromBuffer(writeZip([{ name: '3D/3dmodel.model', data: model }, { name: 'Metadata/Slic3r_PE_model.config', data: cfg }]));
  assert.deepEqual(Array.from(m.faceState), [2]);
});

test('held: a Bambu file aimed at an MMU3 or INDX is not made a PrusaSlicer project', () => {
  const P = require('../lib/printer-profiles');
  assert.equal(P.prusaProjectReady, false, 'held until a converted file is opened in PrusaSlicer 2.9');
  const pp = require('../lib/prusa-project');
  for (const id of ['prusa-mk4-mmu3', 'prusa-mk4s-mmu3', 'prusa-core-one-indx-8t', 'prusa-core-one-indx-4t']) {
    assert.equal(pp.applies('bambu', P.getProfile(id), []), false, id);
  }
});

test('colours sharing a spool keep the settings of the colour closest to that spool', () => {
  const SM = require('../lib/spool-match');
  const colours = ['#FF0000', '#B00000', '#00FF00'];
  const types = ['PLA', 'PETG', 'PLA'];
  const states = [1, 1, 1, 2, 3];
  let v = '', t = '';
  states.forEach((st, i) => {
    v += `<vertex x="${i * 10}" y="0" z="0"/><vertex x="${i * 10 + 10}" y="0" z="0"/><vertex x="${i * 10}" y="10" z="10"/>`;
    t += `<triangle v1="${i * 3}" v2="${i * 3 + 1}" v3="${i * 3 + 2}" paint_color="${encodeSolidPaint(st)}"/>`;
  });
  const buf = writeZip([
    { name: '3D/3dmodel.model', data: '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh>'
      + `<vertices>${v}</vertices><triangles>${t}</triangles></mesh></object></resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 100 0"/></build></model>` },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ printer_model: 'Bambu Lab X1 Carbon', nozzle_diameter: ['0.4'],
      printable_area: ['0x0', '256x0', '256x256', '0x256'], filament_colour: colours, filament_type: types,
      filament_settings_id: ['F0', 'F1', 'F2'], nozzle_temperature: ['200', '240', '202'] }) },
    { name: 'Metadata/model_settings.config', data: '<?xml version="1.0"?><config><object id="1"><metadata key="extruder" value="1"/></object></config>' },
  ]);
  const a = require('../lib/mf-convert').analyze(buf);
  const plan = SM.planSpoolMatch(a.filaments, [{ slot: 0, hex: '#FF0000', material: 'PLA' }, { slot: 1, hex: '#00FF00', material: 'PLA' }], { slotCount: 4, flavour: a.flavour });
  assert.deepEqual(plan.map, [0, 0, 1]);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: plan.request.slotMap, slotSpools: plan.request.slotSpools, spoolStrict: true });
  const c = JSON.parse(openZip(r.buffer).file('Metadata/project_settings.config').toString());
  assert.equal(c.filament_colour[0], '#FF0000', 'slot 1 is the red PLA it holds, not the dark-red PETG');
  assert.equal(c.filament_type[0], 'PLA');
  assert.equal(c.nozzle_temperature[0], '200');
});
