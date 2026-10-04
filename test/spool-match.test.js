'use strict';
/**
 * "Match to loaded spools" (lib/spool-match.js), ported from bedready.io's
 * src/lib/spool-match.ts. The first block is bedready's own test file, case for
 * case, so the port can be read against it; the rest is what Khayt adds around
 * the match — loaded slots, the material warning, and the converter request —
 * and an end-to-end run through lib/mf-convert.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const SM = require('../lib/spool-match');
const { FAR_MATCH, matchToSpools, planSpoolMatch, toRequest, slotsFromLoaded, colorDistance } = SM;
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert, convertMembers, analyze } = require('../lib/mf-convert');
const { encodeSolidPaint, dominantState } = require('../lib/mf-mesh');

const CMYK = ['#29ABE2', '#ED1E79', '#FCEE21', '#111111'];

// ── bedready.io src/lib/spool-match.test.mts ────────────────────────────────

test('each colour goes to the slot that looks most like it', () => {
  const r = matchToSpools(['#2299DD', '#E0207A', '#F5E820', '#000000'], CMYK);
  assert.deepEqual(r.map, [0, 1, 2, 3]);
  assert.deepEqual(r.far, []);
  assert.deepEqual(matchToSpools(['#1E90FF'], CMYK).far, [0]);
});

test('slots are shared: several shades of one colour all print from that spool', () => {
  const r = matchToSpools(['#E00000', '#B00000', '#FF3030', '#111111'], ['#FF0000', '#FFFFFF', '#0000FF', '#000000']);
  assert.deepEqual(r.map, [0, 0, 0, 3]);
});

test('a colour nothing resembles is still mapped, and flagged', () => {
  const r = matchToSpools(['#00A000'], CMYK);
  assert.equal(r.map.length, 1);
  assert.ok(r.distance[0] >= FAR_MATCH, `green → ΔE ${r.distance[0]}`);
  assert.deepEqual(r.far, [0]);
});

test('an exact spool is distance zero', () => {
  const r = matchToSpools(['#29ABE2'], CMYK);
  assert.equal(r.map[0], 0);
  assert.ok(r.distance[0] < 0.001);
});

test('ties go to the lower slot, so the result never flickers', () => {
  assert.equal(matchToSpools(['#808080'], ['#808080', '#808080']).map[0], 0);
});

test('no slots is not a crash: everything goes to slot 0 and is flagged', () => {
  const r = matchToSpools(['#FF0000', '#00FF00'], []);
  assert.deepEqual(r.map, [0, 0]);
  assert.deepEqual(r.far, [0, 1]);
});

test('slots not marked usable are never matched', () => {
  assert.deepEqual(matchToSpools(['#FAFAFA'], ['#FF0000', '#FFFFFF'], [true, false]).map, [0]);
  assert.deepEqual(matchToSpools(['#FAFAFA'], ['#FF0000', '#FFFFFF']).map, [1], 'no mask: every slot counts');
  assert.deepEqual(matchToSpools(['#FAFAFA'], ['#FF0000', '#FFFFFF'], [false, false]).map, [1], 'nothing marked: every slot counts');
});

test('the distance is bedready\'s ΔE76, not CIEDE2000', () => {
  // Pure red vs pure blue: ΔE76 ≈ 176.3, CIEDE2000 ≈ 52.9. The port must agree with bedready.
  assert.ok(Math.abs(colorDistance('#FF0000', '#0000FF') - 176.3) < 0.2);
});

// ── loaded slots → the arrays the match reads ───────────────────────────────

test('loaded slots become a 0-based slot list; empty slots are white placeholders nobody can match', () => {
  const s = slotsFromLoaded([{ slot: 0, hex: '#ff0000', material: 'PLA' }, { slot: 2, hex: 'FFFFFFFF', material: 'PLA Silk' }], 4);
  assert.deepEqual(s.hexes, ['#FF0000', '#FFFFFF', '#FFFFFF', '#FFFFFF']);
  assert.deepEqual(s.usable, [true, false, true, false]);
  assert.deepEqual(s.materials, ['PLA', '', 'PLA Silk', '']);
  const past = slotsFromLoaded([{ slot: 5, hex: '#000000' }], 4);
  assert.deepEqual(past.beyond, [5], 'a spool past the target\'s slots is reported, not matched');
});

test('the empty-slot mask holds in a plan: a white model colour does not go to an empty slot', () => {
  const p = planSpoolMatch(['#FAFAFA', '#FF0000'], [{ slot: 0, hex: '#FF0000' }, { slot: 3, hex: '#EEEEEE' }], { slotCount: 4, flavour: 'bambu' });
  assert.deepEqual(p.map, [3, 0]);
  assert.ok(p.rows.every((r) => p.slots.usable[r.slot]));
});

test('no spool loaded anywhere is a "no spools" answer, not a match onto placeholders', () => {
  const p = planSpoolMatch(['#FF0000'], [], { slotCount: 4 });
  assert.equal(p.ok, false);
  assert.ok(p.warnings.some((w) => w.code === 'no-spools'));
});

test('near colours match with a quality the screen can show', () => {
  const p = planSpoolMatch(['#2BA8E0', '#00A000'], CMYK.map((hex, slot) => ({ slot, hex })), { slotCount: 4, flavour: 'bambu' });
  assert.equal(p.rows[0].slot, 0);
  assert.equal(p.rows[0].quality, 'good');
  assert.equal(p.rows[1].quality, 'poor');
  assert.ok(p.warnings.some((w) => w.code === 'far' && w.index === 1));
});

test('a PETG colour on a PLA spool is matched — and warned', () => {
  const p = planSpoolMatch([{ color: '#FF0000', type: 'PETG' }, { color: '#0000FF', type: 'PLA' }],
    [{ slot: 0, hex: '#FF0000', material: 'PLA Basic' }, { slot: 1, hex: '#0000FF', material: 'PLA+' }], { slotCount: 2, flavour: 'bambu' });
  assert.deepEqual(p.map, [0, 1], 'the colour match is bedready\'s; material never re-routes it');
  assert.equal(p.rows[0].materialMismatch, true);
  assert.equal(p.rows[1].materialMismatch, false, 'PLA+ is a PLA');
  const w = p.warnings.find((x) => x.code === 'material');
  assert.deepEqual([w.index, w.file, w.spool, w.slot], [0, 'PETG', 'PLA', 1]);
});

test('the maker\'s edit to a row wins, but never onto an empty slot', () => {
  const loaded = [{ slot: 0, hex: '#FF0000' }, { slot: 1, hex: '#00FF00' }];
  const p = planSpoolMatch(['#FF0000', '#00FF00'], loaded, { slotCount: 3, flavour: 'bambu', map: [1, 2] });
  assert.deepEqual(p.map, [1, 1]);
  assert.equal(p.rows[0].edited, true);
});

// ── the converter request ───────────────────────────────────────────────────

test('the slot map is 0-based, one entry per file colour — the shape mf-convert reads', () => {
  const r = toRequest([1, 0], { n: 2, slotCount: 4, flavour: 'bambu' });
  assert.equal(r.kind, 'slotMap');
  assert.deepEqual(r.slotMap, [1, 0]);
  assert.equal(toRequest([0, 1], { n: 2, slotCount: 4 }).kind, 'none', 'identity is no remap');
});

test('a spool past the file\'s own filaments asks the converter to grow the file to that slot', () => {
  const r = toRequest([3, 2], { n: 2, slotCount: 4, flavour: 'bambu', slotHexes: ['#FFFFFF', '#FFFFFF', '#00FF00', '#FF0000'], usable: [false, false, true, true], slotMaterials: ['', '', 'PLA', 'PETG'] });
  assert.equal(r.kind, 'grow');
  assert.deepEqual(r.slotMap, [3, 2]);
  assert.equal(r.growToSlots, 4);
  assert.deepEqual(r.slotSpools, [null, null, { colour: '#00FF00', material: 'PLA' }, { colour: '#FF0000', material: 'PETG' }]);
  // A file the converter cannot grow is refused up front, with the converter's reason.
  const g = toRequest([3, 0], { n: 2, slotCount: 4, flavour: 'generic' });
  assert.deepEqual(g.refusal, { code: 'slot-past-end', slot: 4, n: 2 });
  // And without growToSlots the converter still refuses that map.
  const c = convert(bambu(['#FF0000', '#00FF00'], [1, 2]), { targetId: 'bambu-x1c', slotMap: [3, 0] });
  assert.ok(c.report.warnings.some((w) => /uses slot 4/.test(w)));
});

test('more colours than slots is a merge request, with the match as its groups', () => {
  const pal = ['#FF0000', '#E00000', '#00FF00', '#0000FF', '#FFFFFF', '#000000'];
  const loaded = [{ slot: 0, hex: '#FF0000' }, { slot: 1, hex: '#00FF00' }, { slot: 2, hex: '#0000FF' }, { slot: 3, hex: '#FFFFFF' }];
  const p = planSpoolMatch(pal, loaded, { slotCount: 4, flavour: 'bambu' });
  assert.equal(p.request.kind, 'merge');
  assert.equal(p.request.mergeToSlots, true);
  assert.deepEqual(p.request.spoolMerge.map, p.map);
  assert.deepEqual(p.request.spoolMerge.reps, [0, 2, 3, 4], 'each slot keeps the colour nearest its spool');
});

test('a PrusaSlicer file with more colours than slots keeps its filaments: a plain slot map', () => {
  const r = toRequest([0, 0, 1, 2, 3, 1], { n: 6, slotCount: 4, flavour: 'prusa' });
  assert.equal(r.kind, 'slotMap');
});

// ── end to end: a painted file, mock loaded spools, the real converter ───────

function meshXml(states) {
  let v = '', t = '';
  states.forEach((st, i) => {
    v += `<vertex x="${i}" y="0" z="0"/><vertex x="${i + 1}" y="0" z="0"/><vertex x="${i}" y="1" z="${i}"/>`;
    t += `<triangle v1="${i * 3}" v2="${i * 3 + 1}" v3="${i * 3 + 2}"${st ? ` paint_color="${encodeSolidPaint(st)}"` : ''}/>`;
  });
  return '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh>'
    + `<vertices>${v}</vertices><triangles>${t}</triangles></mesh></object></resources>`
    + '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 100 0"/></build></model>';
}
const statesOf = (xml) => [...xml.matchAll(/<triangle\b[^>]*>/g)].map((m) => {
  const pc = /paint_color="([0-9A-Fa-f]+)"/.exec(m[0]);
  return pc ? dominantState(pc[1]) : 0;
});
function settings(colours, types) {
  const n = colours.length;
  const flush = [];
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) flush.push(String(i * 10 + j));
  return {
    printer_model: 'Bambu Lab X1 Carbon', nozzle_diameter: ['0.4'],
    printable_area: ['0x0', '256x0', '256x256', '0x256'],
    filament_colour: colours,
    filament_type: types || colours.map((_, i) => `T${i}`),
    filament_settings_id: colours.map((_, i) => `F${i}`),
    nozzle_temperature: colours.map((_, i) => String(200 + i)),
    hot_plate_temp: colours.map((_, i) => String(50 + i)),
    flush_volumes_matrix: flush,
    flush_volumes_vector: colours.flatMap((_, i) => [`u${i}`, `l${i}`]),
    different_settings_to_system: ['wall_loops', ...colours.map((_, i) => `diff${i}`), 'printer'],
    support_filament: '0', wall_filament: String(n),
  };
}
const OBJ = '<?xml version="1.0"?><config><object id="1"><metadata key="extruder" value="1"/>'
  + '<part id="1" subtype="normal_part"><metadata key="extruder" value="2"/></part></object></config>';
function bambu(colours, states, types) {
  return writeZip([
    { name: '3D/3dmodel.model', data: meshXml(states) },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(settings(colours, types)) },
    { name: 'Metadata/model_settings.config', data: OBJ },
  ]);
}
const zipText = (buf, name) => openZip(buf).file(name).toString('utf8');
const cfgOf = (buf) => JSON.parse(zipText(buf, 'Metadata/project_settings.config'));

/** Every per-filament array the same length, and each slot's settings from ONE source filament. */
function assertConsistent(c) {
  const m = c.filament_colour.length;
  for (const k of ['filament_type', 'filament_settings_id', 'nozzle_temperature', 'hot_plate_temp']) assert.equal(c[k].length, m, k);
  assert.equal(c.flush_volumes_matrix.length, m * m);
  assert.equal(c.flush_volumes_vector.length, 2 * m);
  assert.equal(c.different_settings_to_system.length, m + 2);
  const src = c.filament_type.map((t) => Number(String(t).slice(1)));
  src.forEach((i, j) => {
    assert.equal(c.nozzle_temperature[j], String(200 + i), `slot ${j + 1} temperature`);
    assert.equal(c.hot_plate_temp[j], String(50 + i), `slot ${j + 1} plate`);
    assert.deepEqual(c.flush_volumes_vector.slice(2 * j, 2 * j + 2), [`u${i}`, `l${i}`]);
    assert.equal(c.different_settings_to_system[j + 1], `diff${i}`);
  });
  for (let a = 0; a < m; a++) for (let b = 0; b < m; b++) assert.equal(c.flush_volumes_matrix[a * m + b], String(src[a] * 10 + src[b]));
  assert.ok(Number(c.wall_filament) >= 1 && Number(c.wall_filament) <= m, 'filament numbers stay inside the palette');
  return src;
}

// A six-colour painted file onto a four-head U1 with four loaded spools (slot 2 a near-white).
const SIX = ['#FF0000', '#C00000', '#00C000', '#FFFFFF', '#0000FF', '#F0F0F0'];
const LOADED = [
  { slot: 0, hex: '#E01010', material: 'PLA' },
  { slot: 1, hex: '#0010E0', material: 'PLA' },
  { slot: 2, hex: '#FAFAFA', material: 'PLA' },
  { slot: 3, hex: '#10B010', material: 'PLA' },
];

test('end to end: six painted colours onto four loaded spools — paint lands on the matched slots, every array agrees', () => {
  const states = [1, 2, 3, 4, 5, 6, 1, 0];
  const buf = bambu(SIX, states);
  const a = analyze(buf);
  const plan = planSpoolMatch(a.filaments, LOADED, { slotCount: 4, flavour: a.flavour });
  assert.deepEqual(plan.map, [0, 0, 3, 2, 1, 2]);
  assert.equal(plan.request.kind, 'merge');
  const r = convert(buf, { targetId: 'snapmaker-u1', mergeToSlots: true, spoolMerge: plan.request.spoolMerge, spoolStrict: true });
  assert.equal(r.ok, true, r.error);
  const c = cfgOf(r.buffer);
  assert.equal(c.filament_colour.length, 4, 'merged to the four heads');
  const src = assertConsistent(c);
  assert.deepEqual(src, plan.request.spoolMerge.reps, 'each slot keeps the settings of the colour nearest its spool');
  // Each painted triangle now names the slot its colour was matched to (1-based paint states).
  const want = states.map((st) => (st ? plan.map[st - 1] + 1 : 0));
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), want);
  // The object's extruders moved with the paint: extruder 1 (red) → slot 1, part extruder 2 (dark red) → slot 1.
  assert.match(zipText(r.buffer, 'Metadata/model_settings.config'), /key="extruder" value="1"[\s\S]*key="extruder" value="1"/);
  assert.ok(r.report.warnings.some((w) => /Matched 6 colours to the spools loaded in 4 slots/.test(w)));
  assert.equal(r.report.verified, true, 'the converter\'s own self-check passes');
});

test('end to end: a two-colour file with its spools swapped is a plain slot map, applied whole', () => {
  const buf = bambu(['#FF0000', '#00FF00'], [1, 2, 2, 0]);
  const a = analyze(buf);
  const plan = planSpoolMatch(a.filaments, [{ slot: 0, hex: '#00FF00' }, { slot: 1, hex: '#FF0000' }], { slotCount: 4, flavour: a.flavour });
  assert.equal(plan.request.kind, 'slotMap');
  assert.deepEqual(plan.request.slotMap, [1, 0]);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: plan.request.slotMap, spoolStrict: true });
  assert.equal(r.ok, true, r.error);
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), [2, 1, 1, 0]);
  const c = cfgOf(r.buffer);
  assert.deepEqual(c.filament_colour, ['#00FF00', '#FF0000']);
  assertConsistent(c);
});

test('analyze reports each filament\'s material, so the plan can warn PETG onto PLA', () => {
  const a = analyze(bambu(['#FF0000', '#00FF00'], [1, 2], ['PETG', 'PLA']));
  assert.deepEqual(a.filaments.map((f) => f.type), ['PETG', 'PLA']);
  const plan = planSpoolMatch(a.filaments, [{ slot: 0, hex: '#FF0000', material: 'PLA' }, { slot: 1, hex: '#00FF00', material: 'PLA' }], { slotCount: 2, flavour: a.flavour });
  assert.ok(plan.warnings.some((w) => w.code === 'material' && w.index === 0));
});

// ── the converter's refusals reach the screen instead of a file nothing moved in ──

test('strict: a merge whose mesh never reached the converter is refused, not written', () => {
  // The Mac app passes a model over 4 MB by name: the mesh never crosses into the converter.
  const members = [
    { name: '3D/3dmodel.model', size: 1 << 30 },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(settings(SIX)) },
    { name: 'Metadata/model_settings.config', data: OBJ },
  ];
  const plan = planSpoolMatch(SIX, LOADED, { slotCount: 4, flavour: 'bambu' });
  const r = convertMembers(members, { targetId: 'snapmaker-u1', mergeToSlots: true, spoolMerge: plan.request.spoolMerge, spoolStrict: true });
  assert.equal(r.ok, false);
  assert.equal(r.refused, 'spool-match');
  assert.match(r.error, /not merged: this app could not read the model/);
});

test('strict: a palette that is not the config\'s refuses the match', () => {
  // filament_colour lists none, but slice_info (which extractFilaments falls back to) says 3.
  const members = [
    { name: '3D/3dmodel.model', data: meshXml([1, 2, 3]) },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ printer_model: 'X1C', filament_colour: [] }) },
    { name: 'Metadata/slice_info.config', data: '<config><plate><filament id="1" color="#FF0000"/><filament id="2" color="#00FF00"/><filament id="3" color="#0000FF"/></plate></config>' },
    { name: 'Metadata/model_settings.config', data: OBJ },
  ];
  const r = convertMembers(members, { targetId: 'bambu-p1s', slotMap: [2, 0, 1], spoolStrict: true });
  assert.equal(r.ok, false);
  assert.match(r.error, /colour list does not match its filament settings/);
});

test('strict: a slot past the file\'s filaments refuses the match', () => {
  const r = convert(bambu(['#FF0000', '#00FF00'], [1, 2]), { targetId: 'bambu-x1c', slotMap: [2, 0], spoolStrict: true });
  assert.equal(r.ok, false);
  assert.match(r.error, /uses slot 3, but this file has only 2 filaments/);
});

test('strict: k×n per-variant arrays refuse the match', () => {
  const s = settings(['#FF0000', '#00FF00']);
  s.filament_flow_ratio = ['0.98', '0.98', '0.95', '0.95']; // two values per filament
  const buf = writeZip([
    { name: '3D/3dmodel.model', data: meshXml([1, 2]) },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(s) },
    { name: 'Metadata/model_settings.config', data: OBJ },
  ]);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: [1, 0], spoolStrict: true });
  assert.equal(r.ok, false);
  assert.match(r.error, /several values per filament/);
});

test('strict: a malformed spool merge is refused rather than replaced by reduceColors\' own groups', () => {
  const r = convert(bambu(SIX, [1, 2, 3, 4, 5, 6]), { targetId: 'snapmaker-u1', mergeToSlots: true, spoolMerge: { map: [0, 0, 1, 2, 3, 9], reps: [0, 2, 3, 4] }, spoolStrict: true });
  assert.equal(r.ok, false);
  assert.equal(r.refused, 'spool-match');
});

test('without spoolStrict nothing about an ordinary slot map changes', () => {
  const r = convert(bambu(['#FF0000', '#00FF00'], [1, 2]), { targetId: 'bambu-x1c', slotMap: [3, 0] });
  assert.equal(r.ok, true);
});

// ── growing the file to the slots the spools are in ──────────────────────────

const AMS = [{ slot: 2, hex: '#E01010', material: 'PLA Basic' }, { slot: 3, hex: '#10E010', material: 'PLA Matte' }];

test('end to end: a 2-colour file onto slots 3 and 4 of a 4-slot X1C grows every per-filament array to 4', () => {
  const states = [1, 2, 2, 1, 0];
  const buf = bambu(['#FF0000', '#00FF00'], states);
  const a = analyze(buf);
  const plan = planSpoolMatch(a.filaments, AMS, { slotCount: 4, flavour: a.flavour });
  assert.equal(plan.request.kind, 'grow');
  assert.deepEqual(plan.request.slotMap, [2, 3]);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: plan.request.slotMap, growToSlots: plan.request.growToSlots, slotSpools: plan.request.slotSpools, spoolStrict: true });
  assert.equal(r.ok, true, r.error);
  const c = cfgOf(r.buffer);
  assert.equal(c.filament_colour.length, 4);
  assert.equal(c.flush_volumes_matrix.length, 16);
  const src = assertConsistent(c);
  assert.deepEqual(src, [0, 1, 0, 1], 'slots 3/4 are full copies of the filaments mapped to them; 1/2 keep their own');
  assert.deepEqual(c.filament_colour, ['#FF0000', '#00FF00', '#E01010', '#10E010'], 'new slots take the loaded spools\' colours');
  for (let a2 = 0; a2 < 4; a2++) assert.equal(c.flush_volumes_matrix[a2 * 4 + a2], String(src[a2] * 11), 'diagonal is the copied filament\'s own (0 in a real file)');
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), states.map((st) => (st ? st + 2 : 0)), 'paint on slots 3 and 4');
  assert.match(zipText(r.buffer, 'Metadata/model_settings.config'), /key="extruder" value="3"[\s\S]*key="extruder" value="4"/);
  assert.equal(c.wall_filament, '4', 'filament 2 → slot 4');
  assert.equal(r.report.verified, true);
  assert.ok(r.report.warnings.some((w) => /Added slots 3, 4/.test(w)));
});

test('growth: a slot nothing maps to between two loaded ones copies the first filament', () => {
  const buf = bambu(['#FF0000', '#00FF00'], [1, 2]);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: [3, 0], growToSlots: 4, slotSpools: [null, null, null, { colour: '#AA0000', material: 'PLA' }], spoolStrict: true });
  assert.equal(r.ok, true, r.error);
  const c = cfgOf(r.buffer);
  const src = assertConsistent(c);
  assert.deepEqual(src, [1, 1, 0, 0]);
  assert.equal(c.filament_colour[3], '#AA0000');
  assert.deepEqual(statesOf(zipText(r.buffer, '3D/3dmodel.model')), [4, 1]);
});

test('growth: a spool of another material keeps the copied type, with a warning', () => {
  const buf = bambu(['#FF0000', '#00FF00'], [1, 2], ['PLA', 'PLA']);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: [2, 1], growToSlots: 4, slotSpools: [null, null, { colour: '#FF0000', material: 'PETG HF' }], spoolStrict: true });
  assert.equal(r.ok, true, r.error);
  assert.equal(cfgOf(r.buffer).filament_type[2], 'PLA');
  assert.ok(r.report.warnings.some((w) => /slot 3 holds PETG but takes PLA settings/.test(w)));
});

test('growth still refuses a mesh passed by name', () => {
  const members = [
    { name: '3D/3dmodel.model', size: 1 << 30 },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(settings(['#FF0000', '#00FF00'])) },
    { name: 'Metadata/model_settings.config', data: OBJ },
  ];
  const r = convertMembers(members, { targetId: 'bambu-x1c', slotMap: [2, 3], growToSlots: 4, slotSpools: [], spoolStrict: true });
  assert.equal(r.ok, false);
  assert.equal(r.refused, 'spool-match');
  assert.match(r.error, /could not read the model/);
});

test('growth still refuses k×n per-variant arrays, and a slot past the printer', () => {
  const s2 = settings(['#FF0000', '#00FF00']);
  s2.filament_flow_ratio = ['0.98', '0.98', '0.95', '0.95'];
  const buf = writeZip([
    { name: '3D/3dmodel.model', data: meshXml([1, 2]) },
    { name: 'Metadata/project_settings.config', data: JSON.stringify(s2) },
    { name: 'Metadata/model_settings.config', data: OBJ },
  ]);
  const r = convert(buf, { targetId: 'bambu-x1c', slotMap: [2, 3], growToSlots: 4, spoolStrict: true });
  assert.equal(r.ok, false);
  const r2 = convert(bambu(['#FF0000', '#00FF00'], [1, 2]), { targetId: 'bambu-x1c', slotMap: [5, 0], growToSlots: 4, spoolStrict: true });
  assert.equal(r2.ok, false, 'slot 6 of a 4-slot printer is not grown to');
});

// Prusa MMU: the same growth through the INI config, extruder vectors and wiping volumes included.
const PRUSA2 = [
  '; printer_model = MK4SMMU3',
  '; nozzle_diameter = 0.4,0.4',
  '; extruder_colour = #FF0000;#00FF00',
  '; filament_colour = #FF0000;#00FF00',
  '; filament_type = PLA;PETG',
  '; filament_settings_id = "Prusament PLA";"Prusament PETG"',
  '; temperature = 215,240',
  '; retract_length = 0.8,0.9',
  '; wiping_volumes_matrix = 0,1,10,0',
  '; wiping_volumes_extruders = u0,l0,u1,l1',
  '; perimeter_extruder = 2',
  '; bed_shape = 0x0,250x0,250x210,0x210',
  '',
].join('\n');
const prusaIni = (text, k) => (new RegExp(`^; ${k} = (.*)$`, 'm').exec(text) || [])[1];

test('end to end: a 2-colour PrusaSlicer project grows onto slots 3 and 4 of an MK4S MMU3', () => {
  const buf = writeZip([
    { name: '3D/3dmodel.model', data: meshXml([1, 2, 0]).replace(/paint_color=/g, 'slic3rpe:mmu_segmentation=') },
    { name: 'Metadata/Slic3r_PE.config', data: PRUSA2 },
  ]);
  const a = analyze(buf);
  assert.equal(a.flavour, 'prusa');
  const plan = planSpoolMatch(a.filaments, AMS, { slotCount: 5, flavour: a.flavour });
  assert.equal(plan.request.kind, 'grow');
  const r = convert(buf, { targetId: 'prusa-mk4s-mmu3', slotMap: plan.request.slotMap, growToSlots: plan.request.growToSlots, slotSpools: plan.request.slotSpools, spoolStrict: true });
  assert.equal(r.ok, true, r.error);
  const t = zipText(r.buffer, 'Metadata/Slic3r_PE.config');
  assert.equal(prusaIni(t, 'filament_colour'), '#FF0000;#00FF00;#E01010;#10E010');
  assert.equal(prusaIni(t, 'extruder_colour'), '#FF0000;#00FF00;#E01010;#10E010');
  assert.equal(prusaIni(t, 'filament_type'), 'PLA;PETG;PLA;PETG');
  assert.equal(prusaIni(t, 'filament_settings_id'), '"Prusament PLA";"Prusament PETG";"Prusament PLA";"Prusament PETG"');
  assert.equal(prusaIni(t, 'temperature'), '215,240,215,240');
  assert.equal(prusaIni(t, 'nozzle_diameter'), '0.4,0.4,0.4,0.4', 'one extruder per filament on an MMU project');
  assert.equal(prusaIni(t, 'retract_length'), '0.8,0.9,0.8,0.9');
  assert.equal(prusaIni(t, 'wiping_volumes_matrix').split(',').length, 16);
  assert.equal(prusaIni(t, 'wiping_volumes_extruders'), 'u0,l0,u1,l1,u0,l0,u1,l1');
  assert.equal(prusaIni(t, 'perimeter_extruder'), '4');
  assert.equal(prusaIni(t, 'bed_shape'), '0x0,250x0,250x210,0x210', 'never grown by length alone');
  const st = [...zipText(r.buffer, '3D/3dmodel.model').matchAll(/<triangle\b[^>]*>/g)].map((m) => {
    const pc = /mmu_segmentation="([0-9A-Fa-f]+)"/.exec(m[0]); return pc ? dominantState(pc[1]) : 0;
  });
  assert.deepEqual(st, [3, 4, 0]);
  assert.ok(r.report.warnings.some((w) => /slot 4 holds PLA but takes PETG settings/.test(w)));
});
