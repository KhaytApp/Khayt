'use strict';
/**
 * Bambu/Orca → PrusaSlicer project (lib/prusa-project.js), ported from bedready.io's
 * src/lib/prusa-project.ts and its prusa-project.test.mts. The tests marked "bedready" carry that
 * suite's expectations unchanged — they were first checked against PrusaSlicer 2.9.6 itself (it
 * read the Slic3r_PE.config identity, sliced the remapped paint onto the expected tools, and printed
 * the base with the part's own filament). The rest are Khayt's: the refusals, the per-extruder
 * consistency and an end-to-end run of bedready.io's own sample.3mf.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const mf = require('../lib/mf-convert');
const P = require('../lib/printer-profiles');
const { dominantState, encodeSolidPaint } = require('../lib/mf-mesh');
const PP = require('../lib/prusa-project');

const INDX8 = P.getProfile('prusa-core-one-indx-8t');
const INDX4 = P.getProfile('prusa-core-one-indx-4t');

// A MakerWorld-shaped file: root object 2 → component in 3D/Objects/object_1.model. Four side faces
// painted with filaments 1..4; the two base faces unpainted, on a part assigned filament 2.
function fixture({ area = true, colours = ['#FF0000', '#00FF00', '#0000FF', '#FFFF00'], types = ['PLA', 'PLA', 'PETG', 'PLA'], sides = ['4', '8', '0C', '1C'] } = {}) {
  const t = (a, b, c, code) => `<triangle v1="${a}" v2="${b}" v3="${c}"${code ? ` paint_color="${code}"` : ''}/>`;
  const part = `<?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="30" y="0" z="0"/><vertex x="30" y="30" z="0"/><vertex x="0" y="30" z="0"/><vertex x="15" y="15" z="25"/></vertices><triangles>${t(0, 1, 4, sides[0])}${t(1, 2, 4, sides[1])}${t(2, 3, 4, sides[2])}${t(3, 0, 4, sides[3])}${t(0, 2, 1)}${t(0, 3, 2)}</triangles></mesh></object></resources><build/></model>`;
  const root = '<?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p"><resources><object id="2" type="model"><components><component p:path="/3D/Objects/object_1.model" objectid="1"/></components></object></resources><build><item objectid="2" transform="1 0 0 0 1 0 0 0 1 128 128 0"/></build></model>';
  return [
    { name: '[Content_Types].xml', data: '<Types/>' },
    { name: '3D/3dmodel.model', data: root },
    { name: '3D/Objects/object_1.model', data: part },
    { name: 'Metadata/model_settings.config', data: '<config><object id="2"><metadata key="extruder" value="1"/><part id="1" subtype="normal_part"><metadata key="extruder" value="2"/></part></object></config>' },
    {
      name: 'Metadata/project_settings.config',
      data: JSON.stringify({
        filament_colour: colours,
        ...(types ? { filament_type: types } : {}),
        ...(area ? { printable_area: ['0x0', '256x0', '256x256', '0x256'] } : {}),
      }),
    },
  ];
}
const zipOf = (members) => writeZip(members.map((m) => ({ name: m.name, data: m.data })));
const memberOut = (members, name) => {
  const m = members.find((x) => x.name === name);
  return m ? String(m.data) : undefined;
};
const paintsIn = (text) => [...String(text).matchAll(/slic3rpe:mmu_segmentation="([^"]+)"/g)].map((m) => m[1]);
const paints = (out) => paintsIn(memberOut(out, '3D/Objects/object_1.model'));

/** Every `; key = a;b;c` line of a PrusaSlicer config, split. */
function iniVectors(text) {
  const o = {};
  for (const line of String(text).split('\n')) {
    const m = /^; (\w+) = (.*)$/.exec(line);
    if (m) o[m[1]] = m[2].split(/[;,]/);
  }
  return o;
}
/** The guiding rule, checked on the file itself: every per-extruder key has one value per tool. */
function assertPerExtruderConsistent(cfgText, tools) {
  const v = iniVectors(cfgText);
  for (const k of ['nozzle_diameter', 'extruder_colour', 'filament_colour', 'filament_type']) {
    assert.equal(v[k].length, tools, `${k} has ${v[k].length} values for ${tools} tools`);
  }
  assert.deepEqual(v.extruder_colour, v.filament_colour, 'extruder_colour and filament_colour disagree');
}

// ── bedready: the project rewrite ────────────────────────────────────────────────────────────

test('bedready: every face is painted explicitly, unpainted ones with their PART\'s filament', () => {
  const { members: out } = PP.toPrusaProject(fixture(), INDX8, { map: null, colours: [], types: [] });
  assert.deepEqual(paints(out), ['4', '8', '0C', '1C', '8', '8']);
  const part = memberOut(out, '3D/Objects/object_1.model');
  assert.ok(!part.includes('paint_color='));
  assert.match(part, /xmlns:slic3rpe="http:\/\/schemas\.slic3r\.org\/3mf\/2017\/06"/);
});

test('bedready: the slot map moves painted states and the base together', () => {
  const { members: out } = PP.toPrusaProject(fixture(), INDX8, { map: [3, 2, 1, 0], colours: [], types: [] });
  assert.deepEqual(paints(out), ['1C', '0C', '8', '4', '0C', '0C']);
});

test('bedready: a state past the machine\'s tools is clamped onto it in the low-level rewrite', () => {
  const { members: out } = PP.toPrusaProject(fixture(), INDX4, { map: [0, 1, 2, 7], colours: [], types: [] });
  assert.equal(paints(out)[3], '1C');
});

test('bedready: build items move from the source bed\'s centre to the INDX\'s', () => {
  const { members: out } = PP.toPrusaProject(fixture(), INDX8, { map: null, colours: [], types: [] });
  const tr = /transform="([^"]+)"/.exec(memberOut(out, '3D/3dmodel.model'))[1].split(' ').map(Number);
  assert.deepEqual(tr.slice(9), [124, 102.5, 0]);
  const unmoved = PP.toPrusaProject(fixture({ area: false }), INDX8, { map: null, colours: [], types: [] }).members;
  assert.match(memberOut(unmoved, '3D/3dmodel.model'), /transform="1 0 0 0 1 0 0 0 1 128 128 0"/);
});

test('bedready: Bambu metadata goes; a minimal Slic3r_PE.config naming the preset comes in', () => {
  const { members: out, removed } = PP.toPrusaProject(fixture(), INDX8, { map: null, colours: ['#ff0000', '#00FF00'], types: ['PLA', 'PETG'] });
  assert.deepEqual(removed.sort(), ['Metadata/model_settings.config', 'Metadata/project_settings.config']);
  const cfg = memberOut(out, 'Metadata/Slic3r_PE.config');
  assert.match(cfg, /^; printer_settings_id = Prusa CORE One INDX 8T HF0\.4 nozzle$/m);
  assert.match(cfg, /^; printer_model = COREONE_INDX8T$/m);
  assert.match(cfg, /^; printer_variant = HF0\.4$/m);
  assert.match(cfg, /^; bed_shape = 0x0,248x0,248x205,0x205$/m);
  assert.match(cfg, /^; nozzle_diameter = 0\.4(,0\.4){7}$/m);
  assert.match(cfg, /^; extruder_colour = #FF0000;#00FF00(;#FFFFFF){6}$/m);
  assert.match(cfg, /^; filament_type = PLA;PETG(;PLA){6}$/m);
});

test('bedready: the config carries identity and colour only — no Prusa profile content', () => {
  const keys = PP.prusaProjectConfig(INDX4, [], [])
    .split('\n').filter((l) => /^; \w+ =/.test(l)).map((l) => l.slice(2).split(' =')[0]);
  assert.deepEqual(keys, [
    'printer_settings_id', 'printer_model', 'printer_variant', 'bed_shape', 'max_print_height',
    'nozzle_diameter', 'extruder_colour', 'filament_colour', 'filament_type',
  ]);
});

test('bedready: convert routes a Bambu file to a Prusa project for the INDX, and nowhere else changes', () => {
  const r = mf.convert(zipOf(fixture()), { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, true, r.error);
  const z = openZip(r.buffer);
  assert.ok(z.file('Metadata/Slic3r_PE.config'), 'an INDX target gets a PrusaSlicer project');
  assert.equal(paintsIn(z.file('3D/Objects/object_1.model').toString('utf8')).length, 6);
  assert.equal(r.report.crossFamily, undefined, 'no "use Generic" any more');
  assert.equal(r.report.verified, true);
  // Bambu → Creality (Orca family) is unchanged: a same-family reprofile, no Prusa config.
  const k2 = openZip(mf.convert(zipOf(fixture()), { targetId: 'creality-k2' }).buffer);
  assert.equal(k2.file('Metadata/Slic3r_PE.config'), null);
});

// ── bedready: ColorMix ───────────────────────────────────────────────────────────────────────

const LOADED = ['#FF0000', '#0000FF', '#FFFFFF', '#000000', '#00FF00', '#FFFF00', '#00FFFF', '#FF8000'];

test('bedready: a colour with a close spool stays on it; one with none becomes a blend above the tools', () => {
  const plan = PP.planColorMix(['#FF0000', '#800080'], LOADED, 8);
  assert.equal(plan.map[0], 0, 'red is loaded: no blend');
  assert.equal(plan.map[1], 8, 'purple → the first virtual id after 8 tools');
  assert.deepEqual(plan.blends[0].components.map((c) => c.tool).sort(), [1, 2], 'from red and blue');
});

test('bedready: only PrusaSlicer\'s dialog ratios are used: 1:1, 1:3, 3:1, 1:1:1', () => {
  const plan = PP.planColorMix(['#800080', '#C04040', '#4040C0', '#808080', '#7F3F7F'], LOADED, 8);
  for (const b of plan.blends) {
    const r = b.components.map((c) => +c.ratio.toFixed(4)).sort();
    const ok = [[0.5, 0.5], [0.25, 0.75], [0.3333, 0.3333, 0.3333]].some((x) => JSON.stringify(x) === JSON.stringify(r));
    assert.ok(ok, `ratio ${r}`);
    assert.ok(Math.abs(b.components.reduce((s, c) => s + c.ratio, 0) - 1) < 1e-9);
  }
});

test('bedready: identical blends are shared, and the paint encoding caps how many exist', () => {
  const same = PP.planColorMix(['#800080', '#7F007F'], LOADED, 8);
  assert.equal(same.blends.length, 1);
  assert.equal(same.map[0], same.map[1]);
  const many = Array.from({ length: 30 }, (_, i) => `#${(((i * 2654435761) >>> 8) & 0xffffff).toString(16).padStart(6, '0')}`);
  const capped = PP.planColorMix(many, LOADED, 8);
  assert.ok(capped.blends.length <= 8);
  assert.ok(capped.map.every((m) => m < 8 + capped.blends.length));
});

test('bedready: the FullSpectrum JSON has PrusaSlicer\'s shape: every physical tool, virtual ids after them', () => {
  const plan = PP.planColorMix(['#800080'], LOADED, 8);
  const j = JSON.parse(PP.fullSpectrumJson(INDX8, LOADED, plan.blends));
  assert.equal(j.version, 1);
  assert.equal(j.physical_extruders.length, 8);
  assert.deepEqual(j.physical_extruders[1], { id: 2, color: '#0000FF' });
  assert.equal(j.virtual_extruders[0].id, 9);
  assert.equal(j.virtual_extruders[0].kind, 'fullspectrum');
  assert.equal(j.virtual_extruders[0].color, undefined, 'left to PrusaSlicer\'s own mixer');
});

test('bedready: unusable slots are neither spools nor blend components', () => {
  const slots = ['#FF0000', '#0000FF', '#FFFFFF', '#FFFFFF'];
  const usable = [true, true, false, false];
  const plan = PP.planColorMix(['#FFC0CB', '#FF0000'], slots, 4, usable);
  for (const b of plan.blends) for (const c of b.components) assert.ok(c.tool <= 2, `blend uses placeholder tool ${c.tool}`);
  assert.ok(plan.map.every((m) => m >= 4 || usable[m]), 'a colour was matched to a placeholder slot');
  const open = PP.planColorMix(['#FFC0CB'], slots, 4);
  assert.ok(open.map[0] === 2 || open.blends.some((b) => b.components.some((c) => c.tool > 2)), 'without a mask white counts as loaded');
});

// ── Khayt: ColorMix through the converter ────────────────────────────────────────────────────

// Five colours for a four-tool INDX: red, blue, white and black painted on three faces each, purple
// on one. The merge folds the least-used purple into a tool; ColorMix gives it back as a blend.
const FIVE = {
  colours: ['#FF0000', '#0000FF', '#FFFFFF', '#000000', '#800080'],
  types: ['PLA', 'PLA', 'PLA', 'PLA', 'PLA'],
};
const FIVE_PAINT = [1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5];
function fiveColourFile() {
  const tris = FIVE_PAINT.map((s) => `<triangle v1="0" v2="1" v3="2" paint_color="${encodeSolidPaint(s)}"/>`).join('');
  const model = `<?xml version="1.0"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources><object id="1" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="20" y="0" z="0"/><vertex x="0" y="20" z="0"/></vertices><triangles>${tris}</triangles></mesh></object></resources><build><item objectid="1"/></build></model>`;
  return [
    { name: '[Content_Types].xml', data: '<Types/>' },
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ filament_colour: FIVE.colours, filament_type: FIVE.types }) },
  ];
}

test('ColorMix: a colour merged off the tools comes back as a blend of loaded tools', () => {
  const r = mf.convert(zipOf(fiveColourFile()), { targetId: 'prusa-core-one-indx-4t', colorMix: true });
  assert.equal(r.ok, true, r.error);
  const z = openZip(r.buffer);
  const fsJson = JSON.parse(z.file(PP.FULL_SPECTRUM_FILE).toString('utf8'));
  assert.equal(fsJson.physical_extruders.length, 4);
  assert.equal(fsJson.virtual_extruders.length, 1);
  assert.equal(fsJson.virtual_extruders[0].id, 5);
  assert.deepEqual(fsJson.virtual_extruders[0].components.map((c) => c.extruder).sort(), [1, 2], 'purple from red + blue');
  const codes = paintsIn(z.file('3D/3dmodel.model').toString('utf8')).map(dominantState);
  assert.deepEqual(codes, FIVE_PAINT, 'red, blue, white, black on tools 1-4; purple on virtual extruder 5');
  const cfg = z.file('Metadata/Slic3r_PE.config').toString('utf8');
  assertPerExtruderConsistent(cfg, 4);
  // The physical tools in the FullSpectrum file are the config's own tool colours.
  assert.deepEqual(fsJson.physical_extruders.map((e) => e.color), iniVectors(cfg).filament_colour);
  assert.equal(r.report.prusaProject.blends.length, 1);
  assert.equal(r.report.prusaProject.merged, true);
  assert.equal(r.report.verified, true);
});

test('ColorMix: off unless asked, and never on a printer that cannot mix', () => {
  const off = openZip(mf.convert(zipOf(fiveColourFile()), { targetId: 'prusa-core-one-indx-4t' }).buffer);
  assert.equal(off.file(PP.FULL_SPECTRUM_FILE), null);
  // Without ColorMix purple prints on the tool it was merged into — a real one.
  const codes = paintsIn(off.file('3D/3dmodel.model').toString('utf8')).map(dominantState);
  assert.deepEqual(codes.slice(0, 12), FIVE_PAINT.slice(0, 12));
  assert.ok(codes[12] >= 1 && codes[12] <= 4);
  // Six colours on the five-slot MMU3: merged, and asking for ColorMix only earns a warning.
  const six = fixture({ colours: [...FIVE.colours, '#00FF00'], types: [...FIVE.types, 'PLA'] });

  const mk4 = mf.convert(zipOf(six), { targetId: 'prusa-mk4s-mmu3', colorMix: true });
  assert.equal(mk4.ok, true, mk4.error);
  assert.equal(openZip(mk4.buffer).file(PP.FULL_SPECTRUM_FILE), null, 'MMU3 is not a ColorMix target');
  assert.ok(mk4.report.warnings.some((w) => /does not mix colours/.test(w)));
});

test('ColorMix never blends two materials into one layer cycle', () => {
  const slots = ['#FF0000', '#0000FF', '#FFFFFF', '#FFFFFF'];
  const plan = PP.planColorMix(['#800080'], slots, 4, [true, true, false, false], ['PLA', 'PETG', 'PLA', 'PLA']);
  assert.equal(plan.blends.length, 0, 'red PLA + blue PETG is not a purple');
  const same = PP.planColorMix(['#800080'], slots, 4, [true, true, false, false], ['PLA', 'pla', 'PLA', 'PLA']);
  assert.equal(same.blends.length, 1);
});

test('with no more colours than tools, ColorMix has nothing to do and the colours stay put', () => {
  const r = mf.convert(zipOf(fixture()), { targetId: 'prusa-core-one-indx-8t', colorMix: true });
  assert.equal(r.ok, true, r.error);
  assert.equal(openZip(r.buffer).file(PP.FULL_SPECTRUM_FILE), null);
  assert.deepEqual(r.report.prusaProject.map, [0, 1, 2, 3]);
});

// ── Khayt: the merge and the manual map keep colour, material and paint together ──────────────

test('a merge onto fewer tools gives each tool ONE filament\'s colour and material, and the paint follows', () => {
  const r = mf.convert(zipOf(fiveColourFile()), { targetId: 'prusa-core-one-indx-4t' });
  assert.equal(r.ok, true, r.error);
  const pp = r.report.prusaProject;
  const src = FIVE.colours;
  pp.map.forEach((tool, i) => assert.ok(tool >= 0 && tool < 4, `colour ${i} → ${tool}`));
  // Every tool's colour is one of the source colours that maps to it.
  for (let s = 0; s < 4; s++) {
    const on = pp.map.map((t, i) => (t === s ? src[i] : null)).filter(Boolean);
    assert.ok(on.includes(pp.colours[s]), `tool ${s + 1} carries ${pp.colours[s]}, not one of ${on}`);
  }
  assert.ok(r.report.warnings.some((w) => /Merged 5 colours into 4/.test(w)));
  assertPerExtruderConsistent(openZip(r.buffer).file('Metadata/Slic3r_PE.config').toString('utf8'), 4);
});

test('a manual slot map is honoured, and the tool carries the material of what it was given', () => {
  const r = mf.convert(zipOf(fixture()), { targetId: 'prusa-core-one-indx-8t', slotMap: [7, 6, 5, 4] });
  assert.equal(r.ok, true, r.error);
  const z = openZip(r.buffer);
  const v = iniVectors(z.file('Metadata/Slic3r_PE.config').toString('utf8'));
  assert.deepEqual(v.filament_colour.slice(4), ['#FFFF00', '#0000FF', '#00FF00', '#FF0000']);
  assert.deepEqual(v.filament_type.slice(4), ['PLA', 'PETG', 'PLA', 'PLA'], 'blue PETG went to tool 6 with its colour');
  const codes = paintsIn(z.file('3D/Objects/object_1.model').toString('utf8')).map(dominantState);
  assert.deepEqual(codes, [8, 7, 6, 5, 7, 7], 'sides on tools 8..5, the filament-2 base with filament 2 on tool 7');
});

test('two materials sharing a tool is said, not hidden', () => {
  const r = mf.convert(zipOf(fixture()), { targetId: 'prusa-core-one-indx-8t', slotMap: [0, 1, 1, 2] });
  assert.equal(r.ok, true, r.error);
  assert.ok(r.report.warnings.some((w) => /tool 2 \(PLA \+ PETG\)/.test(w)), r.report.warnings.join(' | '));
});

// ── Khayt: refuse rather than guess ──────────────────────────────────────────────────────────

test('refuses a slot past the target\'s tools instead of clamping it', () => {
  const r = mf.convert(zipOf(fixture()), { targetId: 'prusa-core-one-indx-4t', slotMap: [0, 1, 2, 7] });
  assert.equal(r.ok, false);
  assert.match(r.error, /slot 8, but Prusa CORE One INDX 4T has 4 tools/);
});

test('refuses a colour list and a material list of different lengths', () => {
  const r = mf.convert(zipOf(fixture({ types: ['PLA', 'PLA'] })), { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, false);
  assert.match(r.error, /4 colours but 2 materials/);
});

test('refuses a model painted with a filament its colour list does not have', () => {
  // State 6 ("3C") on a four-colour file.
  const r = mf.convert(zipOf(fixture({ sides: ['4', '8', '0C', '3C'] })), { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, false);
  assert.match(r.error, /painted with filament 6, but this file lists only 4 colours/);
});

test('refuses when there is no colour list to place on the tools', () => {
  const f = fixture().filter((m) => !/project_settings/.test(m.name));
  const r = mf.convert(zipOf(f), { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, false);
  assert.match(r.error, /colour list could not be read/);
});

test('refuses (Mac app) when the mesh never crossed into this process', () => {
  const members = mf.readMembers(zipOf(fixture()));
  const byName = members.map((m) => (/\.model$/.test(m.name) ? { name: m.name, size: m.size, data: null } : m));
  const r = mf.convertMembers(byName, { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, false);
  assert.match(r.error, /could not read the model/);
});

test('without a material list every tool is PLA, and the report says so', () => {
  const r = mf.convert(zipOf(fixture({ types: null })), { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, true, r.error);
  assert.ok(r.report.warnings.some((w) => /every tool is set to PLA/.test(w)));
});

test('convertMembers on string members (the Mac app\'s shape) returns text members', () => {
  const r = mf.convertMembers(fixture(), { targetId: 'prusa-core-one-indx-8t' });
  assert.equal(r.ok, true, r.error);
  assert.equal(typeof memberOut(r.members, 'Metadata/Slic3r_PE.config'), 'string');
  assert.equal(r.members.find((m) => m.name === '[Content_Types].xml').data, '<Types/>', 'untouched members pass through');
});

test('a printer without a verified preset name keeps the old cross-family path', () => {
  const r = mf.convert(zipOf(fixture()), { targetId: 'prusa-xl-5t' });
  assert.equal(r.ok, true);
  assert.equal(r.report.crossFamily, true);
  assert.equal(r.report.prusaProject, undefined);
  assert.equal(PP.applies('bambu', P.getProfile('prusa-xl-5t')), false);
  assert.equal(PP.applies('prusa', INDX8), false, 'a Prusa source retargets the old way');
  assert.equal(PP.applies('orca', INDX8), true);
});

test('prusaPreview: the plan the convert will run, or why not', () => {
  const p = mf.prusaPreview(zipOf(fiveColourFile()), { targetId: 'prusa-core-one-indx-4t', colorMix: true });
  assert.equal(p.available, true);
  assert.equal(p.ok, true);
  assert.equal(p.tools, 4);
  assert.equal(p.blends.length, 1);
  assert.equal(p.blends[0].id, 5);
  assert.equal(p.merged, true);
  assert.equal(p.colorMixCapable, true);
  const bad = mf.prusaPreview(zipOf(fixture()), { targetId: 'prusa-core-one-indx-4t', slotMap: [0, 1, 2, 7] });
  assert.equal(bad.ok, false);
  assert.match(bad.error, /slot 8/);
  assert.equal(mf.prusaPreview(zipOf(fixture()), { targetId: 'bambu-x1c' }).available, false);
});

// ── end to end: bedready.io's own sample.3mf ─────────────────────────────────────────────────

const SAMPLE = [
  path.join(__dirname, '../../bedready-io/sample.3mf'),
  '/home/user/bedready-io/sample.3mf',
].find((p) => fs.existsSync(p));

for (const targetId of ['prusa-mk4s-mmu3', 'prusa-core-one-indx-8t']) {
  test(`sample.3mf (Bambu) → ${targetId}: a PrusaSlicer project with consistent tools and paint`, { skip: !SAMPLE && 'bedready-io checkout not present' }, () => {
    const src = fs.readFileSync(SAMPLE);
    const target = P.getProfile(targetId);
    const before = mf.readMembers(src);
    const srcModel = before.find((m) => m.name === '3D/3dmodel.model').data.toString('utf8');
    const r = mf.convert(src, { targetId, colorMix: true });
    assert.equal(r.ok, true, r.error);
    assert.equal(r.report.verified, true);
    const z = openZip(r.buffer);
    const names = z.entries.map((e) => e.name).sort();
    assert.ok(names.includes('Metadata/Slic3r_PE.config'));
    assert.ok(!names.some((n) => /project_settings|model_settings|slice_info/.test(n)), names.join(','));
    const cfg = z.file('Metadata/Slic3r_PE.config').toString('utf8');
    assert.match(cfg, new RegExp(`^; printer_settings_id = ${target.printerSettingsId.replace(/[.+]/g, '\\$&')}$`, 'm'));
    assert.match(cfg, new RegExp(`^; printer_model = ${target.printerModel}$`, 'm'));
    assert.match(cfg, new RegExp(`^; bed_shape = 0x0,${target.bed.x}x0,${target.bed.x}x${target.bed.y},0x${target.bed.y}$`, 'm'));
    assertPerExtruderConsistent(cfg, target.maxColors);
    assert.deepEqual(iniVectors(cfg).filament_colour.slice(0, 2), ['#FF0000', '#00AA55']);
    // Every triangle painted the Prusa way, and each code means what the Bambu one did: the six
    // painted faces filament 1, the six unpainted ones the object's own (also 1).
    const model = z.file('3D/3dmodel.model').toString('utf8');
    assert.ok(!/paint_color=/.test(model));
    const tris = (srcModel.match(/<triangle\b/g) || []).length;
    const codes = paintsIn(model);
    assert.equal(codes.length, tris);
    assert.deepEqual(codes.map(dominantState), new Array(tris).fill(1));
    assert.ok(codes.every((c) => c === encodeSolidPaint(1)));
    assert.equal(z.file(PP.FULL_SPECTRUM_FILE), null, 'two colours on many tools: nothing to blend');
  });
}
