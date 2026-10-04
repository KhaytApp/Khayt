'use strict';
/**
 * After a slot map or a merge, every position in the output must describe ONE filament.
 *
 * An adversarial review of the colour→slot port found three ways the converted file could
 * disagree with itself, each verified:true with no warning:
 *   - a slot map pointing past the file's filaments (the picker offers the printer's slots)
 *     moved paint and extruders to slot 4 of a 2-filament config;
 *   - only ^filament_ keys moved, so nozzle_temperature, plate temperatures, fans and the purge
 *     matrix stayed in source order — after a 6→4 merge nozzle_temperature still had 6 entries —
 *     and Prusa moved filament_colour alone;
 *   - settings that NAME a filament (support_filament, wall_filament…, per-object too) kept the
 *     old numbers, past the end after a merge.
 * The rule these check: colour, type, temperature and every filament number at each index still
 * belong together — or, where that cannot be done, nothing moves and the maker is told.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert, convertMembers } = require('../lib/mf-convert');
const { encodeSolidPaint, dominantState } = require('../lib/mf-mesh');

function meshXml(states, attr = 'paint_color') {
  let v = '', t = '';
  states.forEach((st, i) => {
    v += `<vertex x="${i}" y="0" z="0"/><vertex x="${i + 1}" y="0" z="0"/><vertex x="${i}" y="1" z="${i}"/>`;
    t += `<triangle v1="${i * 3}" v2="${i * 3 + 1}" v3="${i * 3 + 2}"${st ? ` ${attr}="${encodeSolidPaint(st)}"` : ''}/>`;
  });
  return '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh>'
    + `<vertices>${v}</vertices><triangles>${t}</triangles></mesh></object></resources>`
    + '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 100 0"/></build></model>';
}
const statesOf = (xml) => [...xml.matchAll(/<triangle\b[^>]*>/g)].map((m) => {
  const pc = /(?:paint_color|mmu_segmentation)="([0-9A-Fa-f]+)"/.exec(m[0]);
  return pc ? dominantState(pc[1]) : 0;
});

/** A Bambu project whose every per-filament setting carries its filament's identity. */
function bambuSettings(colours, extra = {}) {
  const n = colours.length;
  const flush = [];
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) flush.push(String(i * 10 + j)); // "ij"
  return Object.assign({
    printer_model: 'Bambu Lab X1 Carbon', nozzle_diameter: ['0.4'],
    printable_area: ['0x0', '256x0', '256x256', '0x256'],
    filament_colour: colours,
    filament_type: colours.map((_, i) => `T${i}`),
    filament_settings_id: colours.map((_, i) => `F${i}`),
    nozzle_temperature: colours.map((_, i) => String(200 + i)),
    hot_plate_temp: colours.map((_, i) => String(50 + i)),
    fan_max_speed: colours.map((_, i) => String(80 + i)),
    flush_volumes_matrix: flush,
    flush_volumes_vector: colours.flatMap((_, i) => [`u${i}`, `l${i}`]),
    different_settings_to_system: ['wall_loops', ...colours.map((_, i) => `diff${i}`), 'printer'],
    support_filament: '0', support_interface_filament: String(n), wall_filament: '2',
  }, extra);
}
const OBJ_SETTINGS = (n) => '<?xml version="1.0"?><config><object id="1"><metadata key="extruder" value="1"/>'
  + `<metadata key="support_filament" value="${n}"/>`
  + '<part id="1" subtype="normal_part"><metadata key="extruder" value="2"/></part></object></config>';

function bambu(colours, states, extra) {
  return writeZip([
    { name: '3D/3dmodel.model', data: meshXml(states) },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(bambuSettings(colours, extra)) },
    { name: 'Metadata/model_settings.config', data: OBJ_SETTINGS(colours.length) },
    { name: 'Metadata/custom_gcode_per_layer.xml', data: '<custom_gcodes_per_layer><plate><layer top_z="5" type="2" extruder="2" color="" extra="" gcode="tool_change"/></plate></custom_gcodes_per_layer>' },
  ]);
}
const zipText = (buf, name) => { const d = openZip(buf).file(name); return d ? d.toString('utf8') : null; };
const cfgOf = (buf) => JSON.parse(zipText(buf, 'Metadata/project_settings.config'));
const metaOf = (buf) => [...zipText(buf, 'Metadata/model_settings.config').matchAll(/key="(\w+)" value="(\d+)"/g)].map((m) => `${m[1]}=${m[2]}`);

/** Every position's settings must come from one source filament — read its number off each. */
function assertConsistent(c, srcColours, area = ['0x0', '256x0', '256x256', '0x256']) {
  const m = c.filament_colour.length;
  for (const k of ['filament_type', 'filament_settings_id', 'nozzle_temperature', 'hot_plate_temp', 'fan_max_speed']) {
    assert.equal(c[k].length, m, `${k} has ${c[k].length} entries for ${m} filaments`);
  }
  assert.equal(c.flush_volumes_matrix.length, m * m, 'flush matrix is m×m');
  assert.equal(c.flush_volumes_vector.length, 2 * m);
  assert.equal(c.different_settings_to_system.length, m + 2);
  const src = [];
  for (let j = 0; j < m; j++) {
    const i = Number(c.filament_type[j].slice(1));
    src.push(i);
    assert.equal(c.filament_colour[j].toUpperCase(), srcColours[i].toUpperCase(), `slot ${j + 1}: colour is not filament ${i}'s`);
    // An Orca target renames the preset to "Generic <type>" (applyOrcaFilaments) — still this filament's.
    assert.ok([`F${i}`, `Generic T${i}`].includes(c.filament_settings_id[j]), `slot ${j + 1}: preset ${c.filament_settings_id[j]}`);
    assert.equal(c.nozzle_temperature[j], String(200 + i), `slot ${j + 1}: temperature`);
    assert.equal(c.hot_plate_temp[j], String(50 + i), `slot ${j + 1}: plate`);
    assert.equal(c.fan_max_speed[j], String(80 + i), `slot ${j + 1}: fan`);
    assert.deepEqual(c.flush_volumes_vector.slice(2 * j, 2 * j + 2), [`u${i}`, `l${i}`]);
    assert.equal(c.different_settings_to_system[j + 1], `diff${i}`);
  }
  for (let a = 0; a < m; a++) for (let b = 0; b < m; b++) {
    assert.equal(c.flush_volumes_matrix[a * m + b], String(src[a] * 10 + src[b]), `flush ${a}→${b}`);
  }
  assert.deepEqual(c.printable_area, area, 'never reindexed by length alone');
  return src;
}

// ── 2. a slot past the file's filaments ─────────────────────────────────────

test('a slot map past the file\'s filaments moves nothing, and says so', () => {
  const colours = ['#FF0000', '#00FF00'];
  const r = convert(bambu(colours, [1, 2]), { targetId: 'bambu-x1c', slotMap: [3, 1] });
  assert.equal(r.ok, true);
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), [1, 2], 'paint moved to a slot with no filament');
  assert.deepEqual(metaOf(r.buffer), ['extruder=1', 'support_filament=2', 'extruder=2']);
  assert.deepEqual(cfgOf(r.buffer).filament_colour, colours);
  assert.ok(r.report.warnings.some((w) => /uses slot 4, but this file has only 2 filaments/.test(w)));
});

// ── 3 + 4. a slot map moves the whole filament ──────────────────────────────

test('a Bambu slot map moves temperatures, fans, purge and filament numbers with the colour', () => {
  const colours = ['#FF0000', '#00FF00', '#0000FF', '#FFFFFF'];
  const map = [2, 0, 3, 1]; // filament i → slot map[i]
  const r = convert(bambu(colours, [1, 2, 3, 4, 0]), { targetId: 'bambu-p1s', slotMap: map });
  const c = cfgOf(r.buffer);
  const src = assertConsistent(c, colours);
  assert.deepEqual(src, [1, 3, 0, 2]);
  // Each painted triangle still shows its own colour.
  statesOf(zipText(r.buffer, '3D/3dmodel.model')).forEach((st, t) => {
    if (t < 4) assert.equal(c.filament_colour[st - 1], colours[t]);
  });
  // Filament numbers follow: wall 2 → slot 1, support interface 4 → slot 2, support 0 stays default.
  assert.equal(c.wall_filament, '1');
  assert.equal(c.support_interface_filament, '2');
  assert.equal(c.support_filament, '0');
  assert.deepEqual(metaOf(r.buffer), ['extruder=3', 'support_filament=2', 'extruder=1']);
  assert.match(zipText(r.buffer, 'Metadata/custom_gcode_per_layer.xml'), /extruder="1"/);
  assert.equal(r.report.verified, true);
});

// ── merge ────────────────────────────────────────────────────────────────────

const SIX = ['#FE0202', '#FF0000', '#00FF00', '#0000FF', '#FFFFFF', '#F4F4F4'];

test('a 6→4 merge leaves every per-filament array four long, each slot one filament', () => {
  // The near-twins at 0 and 5 are least used. Slot colours must come with THEIR settings — the
  // red that survives is #FF0000 (filament 1), not the folded #FE0202 (filament 0).
  const states = [1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6];
  const r = convert(bambu(SIX, states, { support_filament: '6', wall_filament: '1' }), { targetId: 'snapmaker-u1', mergeToSlots: true });
  assert.deepEqual(r.report.colorsMerged, { from: 6, to: 4 });
  const c = cfgOf(r.buffer);
  const src = assertConsistent(c, SIX, ['0.5x1', '270.5x1', '270.5x271', '0.5x271']);
  assert.ok(!src.includes(0) && !src.includes(5), `the folded twins kept a slot: ${src}`);
  // Filament numbers point inside the four slots, at the slot their filament merged into.
  const slotOf = (i) => (src.indexOf(i) >= 0 ? src.indexOf(i) + 1 : null);
  assert.equal(c.support_filament, String(slotOf(4)), 'support_filament 6 (near-white) → the white slot');
  assert.equal(c.wall_filament, String(slotOf(1)), 'wall_filament 1 (the folded red) → the red slot');
  assert.equal(c.support_interface_filament, String(slotOf(4)));
  for (const kv of metaOf(r.buffer)) assert.ok(+kv.split('=')[1] <= 4, `${kv} points past the slots`);
  for (const st of statesOf(zipText(r.buffer, '3D/3dmodel.model'))) assert.ok(st >= 1 && st <= 4);
  assert.equal(r.report.verified, true);
});

test('a merge whose paint cannot be read does not happen', () => {
  const members = [
    { name: '3D/3dmodel.model', size: 1 << 30 },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(bambuSettings(SIX)) },
    { name: 'Metadata/model_settings.config', data: OBJ_SETTINGS(6) },
  ];
  const r = convertMembers(members, { targetId: 'snapmaker-u1', mergeToSlots: true });
  assert.equal(r.report.colorsMerged, undefined);
  assert.equal(JSON.parse(r.members.find((m) => /project_settings/.test(m.name)).data).filament_colour.length, 6);
  assert.ok(r.report.warnings.some((w) => /Colours were not merged/.test(w)));
});

test('when the mesh cannot move, the objects\' extruders do not move without it', () => {
  const members = [
    { name: '3D/3dmodel.model', size: 1 << 30 },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(bambuSettings(['#FF0000', '#00FF00'])) },
    { name: 'Metadata/model_settings.config', data: OBJ_SETTINGS(2) },
  ];
  const r = convertMembers(members, { targetId: 'bambu-p1s', slotMap: [1, 0] });
  const ms = r.members.find((m) => /model_settings/.test(m.name));
  assert.equal(String(ms.data), OBJ_SETTINGS(2), 'model_settings moved while the paint stayed');
  assert.ok(r.report.warnings.some((w) => /could not be moved/.test(w)));
});

// ── Prusa ────────────────────────────────────────────────────────────────────

const PRUSA_CFG = [
  '; printer_model = MK3SMMU2S',
  '; nozzle_diameter = 0.4,0.4,0.4',
  '; extruder_colour = #FF0000;#00FF00;#0000FF',
  '; filament_colour = #FF0000;#00FF00;#0000FF',
  '; filament_type = PLA;PETG;ASA',
  '; filament_settings_id = "Prusament PLA";"Prusament PETG";"Prusament ASA"',
  '; temperature = 215,240,260',
  '; first_layer_bed_temperature = 60,85,105',
  '; start_filament_gcode = "; PLA\\nM900 K0";"; PETG\\nM900 K1";"; ASA\\nM900 K2"',
  '; retract_length = 0.8,0.9,1.0',
  '; wiping_volumes_matrix = 0,1,2,10,11,12,20,21,22',
  '; wiping_volumes_extruders = u0,l0,u1,l1,u2,l2',
  '; perimeter_extruder = 3',
  '; support_material_extruder = 0',
  '',
].join('\n');
const PRUSA_MODEL_CFG = '<?xml version="1.0"?><config><object id="1" instances_count="1"><metadata type="object" key="extruder" value="1"/>'
  + '<metadata type="object" key="infill_extruder" value="2"/><volume firstid="0" lastid="2"><metadata type="volume" key="extruder" value="3"/></volume></object></config>';

function prusa(cfg = PRUSA_CFG) {
  return writeZip([
    { name: '3D/3dmodel.model', data: meshXml([1, 2, 3], 'slic3rpe:mmu_segmentation') },
    { name: 'Metadata/Slic3r_PE.config', data: cfg },
    { name: 'Metadata/Slic3r_PE_model.config', data: PRUSA_MODEL_CFG },
  ]);
}
const ini = (text, k) => (new RegExp(`^; ${k} = (.*)$`, 'm').exec(text) || [])[1];

test('a Prusa slot map moves every per-filament option, extruder_colour and wiping volumes', () => {
  // filament 0 → slot 3, 1 → slot 1, 2 → slot 2  ⇒  slots hold filaments [1, 2, 0]
  const r = convert(prusa(), { targetId: 'prusa-mk3s-mmu2s', slotMap: [2, 0, 1] });
  const t = zipText(r.buffer, 'Metadata/Slic3r_PE.config');
  assert.equal(ini(t, 'filament_colour'), '#00FF00;#0000FF;#FF0000');
  assert.equal(ini(t, 'extruder_colour'), '#00FF00;#0000FF;#FF0000');
  assert.equal(ini(t, 'filament_type'), 'PETG;ASA;PLA');
  assert.equal(ini(t, 'filament_settings_id'), '"Prusament PETG";"Prusament ASA";"Prusament PLA"');
  assert.equal(ini(t, 'temperature'), '240,260,215');
  assert.equal(ini(t, 'first_layer_bed_temperature'), '85,105,60');
  assert.equal(ini(t, 'start_filament_gcode'), '"; PETG\\nM900 K1";"; ASA\\nM900 K2";"; PLA\\nM900 K0"');
  assert.equal(ini(t, 'retract_length'), '0.8,0.9,1.0', 'the physical extruder\'s own settings stay');
  assert.equal(ini(t, 'wiping_volumes_matrix'), '11,12,10,21,22,20,1,2,0');
  assert.equal(ini(t, 'wiping_volumes_extruders'), 'u1,l1,u2,l2,u0,l0');
  assert.equal(ini(t, 'perimeter_extruder'), '2', 'perimeter filament 3 → slot 2');
  assert.equal(ini(t, 'support_material_extruder'), '0');
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), [3, 1, 2]);
  assert.deepEqual([...zipText(r.buffer, 'Metadata/Slic3r_PE_model.config').matchAll(/key="(\w+)" value="(\d)"/g)].map((m) => m[2]), ['3', '1', '2']);
});

test('a Prusa config that cannot be matched to its filaments moves nothing', () => {
  // temperature lists two values for three filaments: there is no way to move it with its colour.
  const r = convert(prusa(PRUSA_CFG.replace('temperature = 215,240,260', 'temperature = 215,240')),
    { targetId: 'prusa-mk3s-mmu2s', slotMap: [2, 0, 1] });
  const t = zipText(r.buffer, 'Metadata/Slic3r_PE.config');
  assert.equal(ini(t, 'filament_colour'), '#FF0000;#00FF00;#0000FF');
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), [1, 2, 3]);
  assert.ok(r.report.warnings.some((w) => /"temperature" setting could not be matched/.test(w)));
});
