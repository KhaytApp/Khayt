'use strict';
/**
 * Fixes from the adversarial review of the merged converter features (spool match, one plate,
 * Bambu/Orca → PrusaSlicer project). Each test failed before its fix.
 *
 *   1. A Bambu → Prusa project ignored the spool match and merged with reduceColors.
 *   2. Growing a one-filament PrusaSlicer project wrote string vectors with commas and turned
 *      travel_speed into a vector; convert's own check now refuses such a config.
 *   3. A spool "grow" aimed at a Prusa project stamped colours into a config the project drops.
 *   4. Modifier / negative / support-blocker parts would load in PrusaSlicer as solid geometry.
 *   5. A mesh passed by name (the Mac app) to a Prusa target keeps the old cross-family path.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const mf = require('../lib/mf-convert');
const P = require('../lib/printer-profiles');
const SM = require('../lib/spool-match');
const { dominantState } = require('../lib/mf-mesh');

// Six painted faces on one Bambu part, filaments 1..6, a seventh unpainted on the part's filament 1.
const SIX = ['#FFFFFF', '#1A1A1A', '#E02020', '#2050E0', '#FFFF00', '#00FF00'];
const STATE = ['4', '8', '0C', '1C', '2C', '3C']; // paint codes for states 1..6
function bambu({ colours = SIX, types = colours.map(() => 'PLA'), subtype = 'normal_part' } = {}) {
  const tri = (i, code) => `<triangle v1="0" v2="${1 + (i % 3)}" v3="4"${code ? ` paint_color="${code}"` : ''}/>`;
  const faces = colours.map((_, i) => tri(i, STATE[i])).join('') + tri(6, null);
  const part = '<?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1" type="model"><mesh><vertices>'
    + '<vertex x="0" y="0" z="0"/><vertex x="30" y="0" z="0"/><vertex x="30" y="30" z="0"/><vertex x="0" y="30" z="0"/><vertex x="15" y="15" z="25"/>'
    + `</vertices><triangles>${faces}</triangles></mesh></object></resources><build/></model>`;
  const root = '<?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p"><resources><object id="2" type="model"><components><component p:path="/3D/Objects/object_1.model" objectid="1"/></components></object></resources><build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 128 128 0"/></build></model>';
  return writeZip([
    { name: '3D/3dmodel.model', data: root },
    { name: '3D/Objects/object_1.model', data: part },
    { name: 'Metadata/model_settings.config', data: `<config><object id="2"><metadata key="extruder" value="1"/><part id="1" subtype="${subtype}"><metadata key="extruder" value="1"/></part></object></config>` },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ filament_colour: colours, filament_type: types, printable_area: ['0x0', '256x0', '256x256', '0x256'] }) },
  ]);
}
const member = (r, re) => { const m = r.members.find((x) => re.test(x.name)); return m ? String(m.data) : null; };
const states = (text) => [...text.matchAll(/mmu_segmentation="([0-9A-Fa-f]+)"/g)].map((m) => dominantState(m[1]));
const ini = (text, k) => (new RegExp(`^; ${k} = (.*)$`, 'm').exec(text) || [])[1];
const optsOf = (req, targetId) => ({ targetId, mode: 'retarget', slotMap: req.slotMap || null, mergeToSlots: !!req.mergeToSlots,
  spoolMerge: req.spoolMerge || null, growToSlots: req.growToSlots || null, slotSpools: req.slotSpools || null, spoolStrict: true });

// ── 1 ─────────────────────────────────────────────────────────────────────────────────────

const INDX4 = P.getProfile('prusa-core-one-indx-4t');
const SPOOLS = [{ slot: 0, hex: '#0000FF', material: 'PETG' }, { slot: 1, hex: '#FF0000', material: 'PLA' }, { slot: 2, hex: '#000000', material: 'PLA' }, { slot: 3, hex: '#FFFFFF', material: 'PLA' }];

test('1: a Bambu → PrusaSlicer project follows the spool merge, tool colours from the loaded spools', () => {
  const buf = bambu();
  const a = mf.analyze(buf);
  const plan = SM.planSpoolMatch(a.filaments, SPOOLS, { slotCount: INDX4.maxColors, flavour: a.flavour });
  assert.equal(plan.request.kind, 'merge');
  const r = mf.convertMembers(mf.readMembers(buf), optsOf(plan.request, INDX4.id));
  assert.equal(r.ok, true, r.error);
  assert.deepEqual(r.report.prusaProject.map, plan.map, 'the spool map, not reduceColors\' own');
  assert.deepEqual(r.report.prusaProject.colours, ['#0000FF', '#FF0000', '#000000', '#FFFFFF']);
  const cfg = member(r, /Slic3r_PE\.config$/);
  assert.equal(ini(cfg, 'extruder_colour'), '#0000FF;#FF0000;#000000;#FFFFFF');
  // Every painted state is now the matched tool (1-based); the unpainted face is its part's filament 1.
  assert.deepEqual(states(member(r, /object_1\.model$/)), [...plan.map, plan.map[0]].map((t) => t + 1));
});

test('1: the preview is the output — hub:prusa-plan with the same spool request', () => {
  const buf = bambu();
  const a = mf.analyze(buf);
  const plan = SM.planSpoolMatch(a.filaments, SPOOLS, { slotCount: 4, flavour: a.flavour });
  const pv = mf.prusaPreview(buf, optsOf(plan.request, INDX4.id));
  assert.equal(pv.ok, true);
  assert.deepEqual(pv.map, plan.map);
  assert.deepEqual(pv.colours, ['#0000FF', '#FF0000', '#000000', '#FFFFFF']);
});

test('1: a spool merge that does not fit is refused, and ColorMix steps aside for a spool match', () => {
  const buf = mf.readMembers(bambu());
  const bad = mf.convertMembers(buf, { targetId: INDX4.id, mergeToSlots: true, spoolMerge: { map: [0, 0, 1, 2, 3, 9], reps: [0, 2, 3, 4] }, spoolStrict: true });
  assert.equal(bad.ok, false);
  assert.equal(bad.refused, 'spool-match');
  const a = mf.analyze(bambu());
  const plan = SM.planSpoolMatch(a.filaments, SPOOLS, { slotCount: 4, flavour: a.flavour });
  const r = mf.convertMembers(mf.readMembers(bambu()), { ...optsOf(plan.request, INDX4.id), colorMix: true });
  assert.equal(r.ok, true);
  assert.deepEqual(r.report.prusaProject.blends, []);
  assert.ok(r.report.warnings.some((w) => /ColorMix was not used/.test(w)));
});

// ── 2 ─────────────────────────────────────────────────────────────────────────────────────

const PRUSA_MESH = '<?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="3"/></triangles></mesh></object></resources><build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 100 0"/></build></model>';
function prusa(cfgLines) {
  return writeZip([{ name: '3D/3dmodel.model', data: PRUSA_MESH }, { name: 'Metadata/Slic3r_PE.config', data: cfgLines.join('\n') + '\n' }]);
}

test('2: growing a one-filament PrusaSlicer project keeps string vectors ;-separated and printer values single', () => {
  const buf = prusa(['; printer_model = MK4SMMU3', '; nozzle_diameter = 0.4', '; extruder_colour = #FF0000', '; filament_colour = #FF0000',
    '; filament_type = PLA', '; filament_settings_id = Prusament PLA', '; temperature = 215', '; travel_speed = 200', '; travel_speed_z = 12',
    '; travel_acceleration = 0', '; travel_max_lift = 0.6', '; wipe = 1', '; wiping_volumes_matrix = 0', '; wiping_volumes_extruders = 70,70']);
  const a = mf.analyze(buf);
  const plan = SM.planSpoolMatch(a.filaments, [{ slot: 2, hex: '#EE0000', material: 'PLA' }], { slotCount: 5, flavour: a.flavour });
  assert.equal(plan.request.kind, 'grow');
  const r = mf.convert(buf, optsOf(plan.request, 'prusa-mk4s-mmu3'));
  assert.equal(r.ok, true, r.error);
  const t = mf.readMembers(r.buffer).find((m) => /Slic3r_PE\.config$/.test(m.name)).data.toString();
  assert.equal(ini(t, 'extruder_colour'), '#FF0000;#FF0000;#EE0000');
  assert.equal(ini(t, 'filament_colour'), '#FF0000;#FF0000;#EE0000');
  assert.equal(ini(t, 'filament_type'), 'PLA;PLA;PLA');
  assert.equal(ini(t, 'filament_settings_id'), 'Prusament PLA;Prusament PLA;Prusament PLA');
  assert.equal(ini(t, 'temperature'), '215,215,215');
  assert.equal(ini(t, 'nozzle_diameter'), '0.4,0.4,0.4');
  assert.equal(ini(t, 'travel_max_lift'), '0.6,0.6,0.6', 'a real per-extruder travel option grows');
  for (const k of ['travel_speed', 'travel_speed_z', 'travel_acceleration']) assert.ok(!/,/.test(ini(t, k)), `${k} stays one printer value`);
  assert.equal(r.report.verified, true);
});

test('2: convert refuses a rewritten PrusaSlicer config whose colour vector is comma-separated', () => {
  // A source that already writes filament_type with commas: the slot map reorders it, and the
  // output check catches what PrusaSlicer would read as one material.
  const buf = writeZip([
    { name: '3D/3dmodel.model', data: PRUSA_MESH.replace(/<triangle v1="0" v2="1" v3="2"\/>/, '<triangle v1="0" v2="1" v3="2" slic3rpe:mmu_segmentation="4"/>') },
    { name: 'Metadata/Slic3r_PE.config', data: '; printer_model = MK4SMMU3\n; extruder_colour = #FF0000;#00FF00\n; filament_colour = #FF0000;#00FF00\n; filament_type = PLA,PETG\n' },
  ]);
  const r = mf.convert(buf, { targetId: 'prusa-mk4s-mmu3', slotMap: [1, 0] });
  assert.equal(r.ok, false);
  assert.match(r.error, /"filament_type" does not hold one value per filament/);
});

// ── 3 ─────────────────────────────────────────────────────────────────────────────────────

test('3: a spool "grow" aimed at a Prusa project puts the spool colour on the tool, without claiming a grown config', () => {
  const four = SIX.slice(0, 4);
  const buf = bambu({ colours: four });
  const a = mf.analyze(buf);
  const loaded = [{ slot: 0, hex: '#FFFFFF' }, { slot: 1, hex: '#1A1A1A' }, { slot: 3, hex: '#2050E0' }, { slot: 4, hex: '#CC0000' }];
  const plan = SM.planSpoolMatch(a.filaments, loaded, { slotCount: 5, flavour: a.flavour });
  assert.equal(plan.request.kind, 'grow');
  const r = mf.convertMembers(mf.readMembers(buf), optsOf(plan.request, 'prusa-mk4-mmu3'));
  assert.equal(r.ok, true, r.error);
  assert.equal(r.report.colorsGrown, undefined);
  assert.ok(!r.report.warnings.some((w) => /Added slot/.test(w)));
  assert.equal(r.report.prusaProject.colours[4], '#CC0000', 'tool 5 carries the red spool');
  assert.equal(ini(member(r, /Slic3r_PE\.config$/), 'filament_colour').split(';')[4], '#CC0000');
  assert.deepEqual(r.report.prusaProject.map, plan.map);
});

// ── 4 ─────────────────────────────────────────────────────────────────────────────────────

test('4: a modifier / negative / support-blocker part refuses the PrusaSlicer project', () => {
  for (const subtype of ['modifier_part', 'negative_part', 'support_blocker']) {
    const r = mf.convertMembers(mf.readMembers(bambu({ subtype })), { targetId: 'prusa-core-one-indx-8t' });
    assert.equal(r.ok, false, subtype);
    assert.match(r.error, new RegExp(`${subtype} parts`));
  }
  assert.equal(mf.convertMembers(mf.readMembers(bambu()), { targetId: 'prusa-core-one-indx-8t' }).ok, true, 'normal parts convert');
});

// ── 5 ─────────────────────────────────────────────────────────────────────────────────────

test('5: a mesh passed by name falls back to the old cross-family file for MMU3 and INDX', () => {
  for (const targetId of ['prusa-mk4-mmu3', 'prusa-core-one-indx-4t']) {
    const byName = mf.readMembers(bambu()).map((m) => (/\.model$/.test(m.name) ? { name: m.name, size: m.size, data: null } : m));
    const r = mf.convertMembers(byName, { targetId });
    assert.equal(r.ok, true, `${targetId}: ${r.error}`);
    assert.equal(r.report.crossFamily, true);
    assert.equal(r.report.prusaProject, undefined);
  }
});
