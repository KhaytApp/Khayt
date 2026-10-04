'use strict';
/**
 * A colour → slot map has to move the PAINT, not only the palette.
 *
 * A painted 3MF says which filament each triangle is in its paint codes, and an
 * object-coloured one says it in each object's `extruder`. The plain retarget used to
 * reorder the filament_* arrays and leave both alone, so the palette moved while the model
 * still pointed at the old numbers — every colour printed on somebody else's slot. Ported
 * from bedready.io's retargetThreeMF (remapPaintCode / remapExtruders / stateMap, its #39),
 * together with reduceColors for "Merge to the nearest {n} slots", which the batch converter
 * offered and the engine never did.
 *
 * The fixtures are built here, small enough to read.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { convert, convertMembers, analyze } = require('../lib/mf-convert');
const { encodeSolidPaint, dominantState } = require('../lib/mf-mesh');

/** A strip of triangles, one per entry of `states`, each painted solid in that state (0 = unpainted). */
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

const MODEL_SETTINGS = '<?xml version="1.0" encoding="UTF-8"?><config><object id="1">'
  + '<metadata key="name" value="part"/><metadata key="extruder" value="1"/>'
  + '<part id="1" subtype="normal_part"><metadata key="extruder" value="2"/></part>'
  + '</object></config>';

function painted(colours, states) {
  return writeZip([
    { name: '[Content_Types].xml', data: '<Types/>' },
    { name: '3D/3dmodel.model', data: meshXml(states) },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({
      printer_model: 'Bambu Lab X1 Carbon', nozzle_diameter: ['0.4'],
      filament_colour: colours, filament_type: colours.map(() => 'PLA'),
      filament_settings_id: colours.map((_, i) => `F${i + 1}`),
    }) },
    { name: 'Metadata/model_settings.config', data: MODEL_SETTINGS },
  ]);
}

const statesOut = (buf) => {
  const xml = openZip(buf).file('3D/3dmodel.model').toString('utf8');
  return [...xml.matchAll(/<triangle\b[^>]*>/g)].map((m) => {
    const pc = /paint_color="([0-9A-Fa-f]+)"/.exec(m[0]);
    return pc ? dominantState(pc[1]) : 0;
  });
};
const settingsOut = (buf) => JSON.parse(openZip(buf).file('Metadata/project_settings.config').toString('utf8'));
const extrudersOut = (buf) => [...openZip(buf).file('Metadata/model_settings.config').toString('utf8')
  .matchAll(/key="extruder" value="(\d+)"/g)].map((m) => +m[1]);

// ── the slot map ─────────────────────────────────────────────────────────────

test('a slot map moves the paint codes with the palette', () => {
  const src = painted(['#FF0000', '#00FF00', '#0000FF'], [1, 2, 3, 0]);
  // colour 1 → slot 3, colour 2 → slot 1, colour 3 → slot 2
  const r = convert(src, { targetId: 'bambu-x1c', slotMap: [2, 0, 1] });
  assert.equal(r.ok, true);
  assert.deepEqual(settingsOut(r.buffer).filament_colour, ['#00FF00', '#0000FF', '#FF0000']);
  // Each triangle still shows the colour it was painted: red is now slot 3, and so on.
  assert.deepEqual(statesOut(r.buffer), [3, 1, 2, 0], 'unpainted stays 0 — the object extruder carries it');
  assert.equal(r.report.verified, true);
});

test('a slot map moves each object\'s and part\'s extruder too', () => {
  const src = painted(['#FF0000', '#00FF00', '#0000FF'], [1, 2, 3]);
  const r = convert(src, { targetId: 'bambu-x1c', slotMap: [2, 0, 1] });
  assert.deepEqual(extrudersOut(r.buffer), [3, 1], 'object extruder 1 → 3, part extruder 2 → 1');
});

test('without a slot map, a painted mesh is left byte-identical', () => {
  const src = painted(['#FF0000', '#00FF00'], [1, 2]);
  const r = convert(src, { targetId: 'bambu-p1s' });
  assert.equal(openZip(r.buffer).file('3D/3dmodel.model').toString('utf8'), meshXml([1, 2]));
  assert.deepEqual(extrudersOut(r.buffer), [1, 2]);
});

test('an unpainted mesh under a slot map is left byte-identical', () => {
  const src = painted(['#FF0000', '#00FF00'], [0, 0]);
  const r = convert(src, { targetId: 'bambu-p1s', slotMap: [1, 0] });
  assert.equal(openZip(r.buffer).file('3D/3dmodel.model').toString('utf8'), meshXml([0, 0]));
  assert.deepEqual(extrudersOut(r.buffer), [2, 1], 'the extruders still follow the map');
});

test('a host that passes the mesh by name gets a warning, not a crash', () => {
  // The native Mac app hands a large mesh over by name only. Nothing to rewrite, so say so.
  const members = [
    { name: '3D/3dmodel.model', size: 1 << 30 },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ printer_model: 'X1C', filament_colour: ['#FF0000', '#00FF00'] }) },
  ];
  const r = convertMembers(members, { targetId: 'bambu-p1s', slotMap: [1, 0] });
  assert.equal(r.ok, true);
  assert.ok(r.report.warnings.some((w) => /painted colours could not be moved/.test(w)));
});

// ── merge to the nearest slots ──────────────────────────────────────────────

// Two near-twins (a red and a white), each used least, so they are the ones that fold.
const SIX = ['#FF0000', '#FE0202', '#00FF00', '#0000FF', '#FFFFFF', '#F4F4F4'];

test('mergeToSlots folds six colours into the U1\'s four, paint and all', () => {
  const states = [1, 1, 1, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6];
  const r = convert(painted(SIX, states), { targetId: 'snapmaker-u1', mergeToSlots: true });
  assert.equal(r.ok, true);
  const cfg = settingsOut(r.buffer);
  assert.equal(cfg.filament_colour.length, 4);
  assert.deepEqual(r.report.colorsMerged, { from: 6, to: 4 });
  for (const k of ['filament_type', 'filament_settings_id']) assert.equal(cfg[k].length, 4, k);
  const out = statesOut(r.buffer);
  assert.ok(out.every((s) => s >= 1 && s <= 4), `a painted state points past the slots: ${out}`);
  // Every triangle prints in the slot whose colour is nearest the one it was painted.
  const near = (hex, pal) => pal.indexOf(pal.slice().sort((a, b) => dist(a, hex) - dist(b, hex))[0]);
  states.forEach((st, i) => assert.equal(out[i] - 1, near(SIX[st - 1], cfg.filament_colour), `triangle ${i}`));
  assert.equal(r.report.verified, true);
  assert.ok(r.report.warnings.some((w) => /Merged 6 colours into the nearest 4/.test(w)));
});

test('without mergeToSlots, extra colours are only warned about — as before', () => {
  const r = convert(painted(SIX, [1, 2, 3, 4, 5, 6]), { targetId: 'snapmaker-u1' });
  assert.equal(settingsOut(r.buffer).filament_colour.length, 6);
  assert.ok(r.report.warnings.some((w) => /need manual mapping/.test(w)));
  assert.equal(r.report.colorsMerged, undefined);
});

test('mergeToSlots on a file that already fits changes nothing', () => {
  const r = convert(painted(['#FF0000', '#00FF00'], [1, 2]), { targetId: 'snapmaker-u1', mergeToSlots: true });
  assert.equal(r.report.colorsMerged, undefined);
  assert.equal(openZip(r.buffer).file('3D/3dmodel.model').toString('utf8'), meshXml([1, 2]));
});

test('the analysis of a merged file reads four colours back', () => {
  const r = convert(painted(SIX, [1, 2, 3, 4, 5, 6]), { targetId: 'snapmaker-u1', mergeToSlots: true });
  assert.equal(analyze(r.buffer).colorCount, 4);
});

function dist(a, b) {
  const p = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const x = p(a), y = p(b);
  return (x[0] - y[0]) ** 2 + (x[1] - y[1]) ** 2 + (x[2] - y[2]) ** 2;
}

test('the batch converter\'s "Merge to the nearest {n} slots" reaches the engine', () => {
  // It used to be the absence of the other two options and nothing else.
  const fs = require('node:fs');
  const path = require('node:path');
  const renderer = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'converter.js'), 'utf8');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(renderer, /mergeToSlots = colourCapable && batchColorMode === 'merge'/);
  assert.match(renderer, /mfConvert\(\{[^}]*mergeToSlots:/);
  const handler = main.slice(main.indexOf("ipcMain.handle('hub:mf-convert'"));
  assert.match(handler.slice(0, 1200), /opts: \{[^}]*mergeToSlots/, 'main.js drops the option before the worker');
});
