'use strict';
/**
 * "Split into plates" (lib/plate-split.js): every plate of a multi-plate Bambu project
 * as its own U1 file, each with only the filaments that plate prints with, in slots 1..k.
 *
 * The fixture is test/helpers/multi-plate-3mf.js with EIGHT filaments, spread so that
 * no plate uses the project's first four:
 *
 *   plate 1  object 2 (filament 5), object 5 (filament 6, lid part filament 7)  → 5 6 7
 *   plate 2  object 7 (filament 2, painted 3 and 8), object 9 ×2 (filament 1)   → 1 2 3 8
 *   plate 3  object 11 (filament 4, painted 1 2 5 6)                             → 1 2 4 5 6
 *
 * Plate 3 has five colours of its own, more than the U1's four, so it falls back to
 * merging to the nearest — among its own colours only.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('./helpers/no-installed-slicer'); // the converter's own rules, not the installed preset's

const split = require('../lib/plate-split');
const plates = require('../lib/plates');
const mf = require('../lib/mf-convert');
const mfMesh = require('../lib/mf-mesh');
const fullSpectrum = require('../lib/full-spectrum');
const { openZip } = require('../lib/zip-read');
const { buildMultiPlate3mf, COLOURS } = require('./helpers/multi-plate-3mf');

const PALETTE = ['#FFFFFF', '#1A1A1A', '#E02020', '#2050E0', '#20C040', '#F0C020', '#A040C0', '#FF8000'];
const paint = (...states) => (i) => states[Math.floor(i / (12 / states.length))] != null
  ? mfMesh.encodeSolidPaint(states[Math.floor(i / (12 / states.length))]) : null;

function wide() {
  return buildMultiPlate3mf({
    palette: PALETTE,
    objects(objs) {
      const by = (id) => objs.find((o) => o.id === id);
      Object.assign(by(2), { extruder: 5 }); by(2).parts[0].extruder = 5;
      Object.assign(by(5), { extruder: 6 }); by(5).parts[0].extruder = 6; by(5).parts[1].extruder = 7;
      // faces 0-5 state 3, 6-11 state 8
      Object.assign(by(7), { extruder: 2, paint: paint(3, 8) }); by(7).parts[0].extruder = 2;
      Object.assign(by(9), { extruder: 1 }); by(9).parts[0].extruder = 1;
      Object.assign(by(11), { extruder: 4, paint: paint(1, 2, 5, 6) }); by(11).parts[0].extruder = 4;
    },
  });
}

const U1 = { targetId: 'snapmaker-u1', sourceName: '/models/statue.3mf' };
const zipText = (buf, re) => {
  const z = openZip(buf);
  const e = z.entries.find((x) => re.test(x.name));
  return e ? z.file(e.name).toString('utf8') : null;
};
const cfg = (buf) => JSON.parse(zipText(buf, /project_settings\.config$/));
/** Every object's and part's extruder in model_settings, as { 'o2': 1, 'p4': 3 }. */
function extruders(buf) {
  const ms = zipText(buf, /model_settings\.config$/);
  const out = {};
  for (const ob of ms.matchAll(/<object id="(\d+)">([\s\S]*?)<\/object>/g)) {
    const own = ob[2].replace(/<part\b[\s\S]*?<\/part>/g, '');
    out[`o${ob[1]}`] = +/key="extruder" value="(\d+)"/.exec(own)[1];
    for (const p of ob[2].matchAll(/<part id="(\d+)"[\s\S]*?key="extruder" value="(\d+)"[\s\S]*?<\/part>/g)) out[`p${p[1]}`] = +p[2];
  }
  return out;
}
/** Every leaf paint state in one geometry member, sorted. */
function paintStates(buf, name) {
  const t = zipText(buf, new RegExp(name.replace(/[./]/g, '\\$&') + '$'));
  const s = new Set();
  for (const c of t.matchAll(/paint_color="([0-9A-F]+)"/gi)) fullSpectrum.remapPaintCode(c[1], (x) => { s.add(x); return x; });
  return [...s].sort((a, b) => a - b);
}
const items = (buf) => [...zipText(buf, /3D\/3dmodel\.model$/).matchAll(/<item\b[^>]*transform="([^"]+)"/g)]
  .map((m) => m[1].split(/\s+/).map(Number).slice(9, 11));

let RESULT;
const result = () => (RESULT = RESULT || split.splitPlates(wide(), U1));

test('the plate filaments are read exactly: objects, parts and every paint state', () => {
  const members = plates.readMembers(wide());
  const got = [1, 2, 3].map((i) => {
    const ex = plates.extractPlateMembers(members, i);
    return split.plateFilaments(ex.members, 8);
  });
  assert.deepEqual(got.map((g) => g.used.map((k) => k + 1)), [[5, 6, 7], [1, 2, 3, 8], [1, 2, 4, 5, 6]]);
  assert.ok(got.every((g) => g.exact));
});

test('every plate becomes its own file, named after the source', () => {
  const r = result();
  assert.ok(r.ok, r.error);
  assert.deepEqual(r.files.map((f) => [f.ok, f.fileName]),
    [[true, 'statue-plate1.3mf'], [true, 'statue-plate2.3mf'], [true, 'statue-plate3.3mf']]);
  for (const f of r.files) {
    assert.ok(f.report.verified, `plate ${f.index} re-validates`);
    assert.deepEqual(plates.checkPackage(plates.readMembers(f.buffer)), [], `plate ${f.index} references only what it contains`);
    assert.equal(cfg(f.buffer).printer_model, 'Snapmaker U1');
  }
});

test('a plate within the slot count carries only its own colours, in slots 1..k, settings and all', () => {
  const [p1, p2] = result().files;
  // Plate 1: filaments 5, 6, 7 → slots 1, 2, 3.
  const c1 = cfg(p1.buffer);
  assert.deepEqual(c1.filament_colour, [PALETTE[4], PALETTE[5], PALETTE[6]]);
  assert.deepEqual(c1.nozzle_temperature, ['204', '205', '206'], 'each slot keeps its own filament\'s temperature');
  assert.deepEqual(extruders(p1.buffer), { o2: 1, p1: 1, o5: 2, p3: 2, p4: 3 });
  assert.deepEqual(p1.report.plate.filaments, [5, 6, 7]);
  assert.deepEqual(p1.report.plateColours, { used: [5, 6, 7], slots: [PALETTE[4], PALETTE[5], PALETTE[6]], merged: false });

  // Plate 2: filaments 1, 2, 3, 8 → slots 1, 2, 3, 4. The paint moves with them: 3 stays 3, 8 → 4.
  const c2 = cfg(p2.buffer);
  assert.deepEqual(c2.filament_colour, [PALETTE[0], PALETTE[1], PALETTE[2], PALETTE[7]]);
  assert.deepEqual(c2.nozzle_temperature, ['200', '201', '202', '207']);
  assert.deepEqual(extruders(p2.buffer), { o7: 2, p6: 2, o9: 1, p8: 1 });
  assert.deepEqual(paintStates(p2.buffer, '3D/Objects/object_3.model'), [3, 4]);
});

test('a plate with more colours of its own than the printer has slots is merged among its own colours, with a warning', () => {
  const p3 = result().files[2];
  const c3 = cfg(p3.buffer);
  assert.equal(c3.filament_colour.length, 4);
  const own = [1, 2, 4, 5, 6].map((k) => PALETTE[k - 1]);
  assert.ok(c3.filament_colour.every((h) => own.includes(h)), 'never a colour this plate does not print with');
  assert.equal(p3.report.plateColours.merged, true);
  assert.ok(p3.report.warnings.some((w) => /uses 5 colours of its own/.test(w)));
  // Paint and the object's own filament all land on one of the four slots.
  const states = paintStates(p3.buffer, '3D/Objects/object_5.model');
  assert.ok(states.every((s) => s >= 1 && s <= 4), `paint in slots 1..4: ${states}`);
  const ex = extruders(p3.buffer);
  assert.ok(ex.o11 >= 1 && ex.o11 <= 4);
  // The object's base filament (4, blue) is a colour the plate keeps or merges — it is
  // never sent to a slot whose colour came from outside the plate.
  assert.ok(own.includes(c3.filament_colour[ex.o11 - 1]));
});

test('each file is centred on the U1 bed, keeping the author\'s offset from the plate centre', () => {
  const [p1, p2, p3] = result().files;
  // Bambu bed centre 128,128 → U1 printable_area centre 135.5,136.
  assert.deepEqual(items(p3.buffer), [[135.5, 136]]);
  assert.deepEqual(items(p2.buffer), [[135.5, 108], [107.5, 168], [157.5, 168]]);
  assert.deepEqual(items(p1.buffer), [[107.5, 136], [167.5, 136]]);
  assert.deepEqual(p3.report.plate.recentred, [7.5, 8]);
});

test('a project whose colours already fit keeps its own slot numbers on every plate', () => {
  const r = split.splitPlates(buildMultiPlate3mf(), U1);
  assert.ok(r.ok);
  for (const f of r.files) {
    assert.deepEqual(cfg(f.buffer).filament_colour, COLOURS, `plate ${f.index}`);
    assert.equal(f.report.plateColours, undefined);
    assert.equal(f.report.plate.filaments, null);
  }
  // Plate 3 (filament 4) stays on filament 4: one spool layout prints every plate.
  assert.deepEqual(extruders(r.files[2].buffer), { o11: 4, p10: 4 });
});

test('the variable layer height stays by default, the prime tower goes', () => {
  const p1 = result().files[0];
  assert.ok(zipText(p1.buffer, /layer_heights_profile\.txt$/), 'plate 1 keeps its layer height profile');
  assert.equal(cfg(p1.buffer).enable_prime_tower, '0');
  assert.equal(p1.report.vlhGuard, true);
});

test('dropVariableLayerHeight keeps the prime tower and drops the VLH members, and says so', () => {
  const r = split.splitPlates(wide(), Object.assign({ dropVariableLayerHeight: true }, U1));
  const p1 = r.files[0];
  assert.equal(zipText(p1.buffer, /layer_heights_profile\.txt$/), null);
  assert.equal(cfg(p1.buffer).enable_prime_tower, undefined, 'the tower setting is left as the source had it');
  assert.deepEqual(p1.report.vlhDropped, ['Metadata/layer_heights_profile.txt']);
  assert.ok(p1.report.warnings.some((w) => /variable layer height was removed/.test(w)));
  assert.equal(p1.report.vlhGuard, undefined);
});

test('a plate that cannot be split fails alone; the others still convert', () => {
  const r = split.splitPlates(buildMultiPlate3mf({ sharedObject: true }), U1);
  assert.ok(r.ok);
  assert.deepEqual(r.files.map((f) => f.ok), [true, false, false]);
  assert.equal(r.files[1].code, 'shared-object');
});

test('a one-plate project is refused: convert the whole file', () => {
  const one = plates.extractPlate(buildMultiPlate3mf(), 3).buffer;
  const r = split.splitPlates(one, U1);
  assert.equal(r.ok, false);
  assert.equal(r.code, 'single-plate');
});

test('a mesh passed by name (as the Mac does for large files) converts without a plate map, and says why', () => {
  const members = plates.readMembers(wide());
  for (const m of members) if (/^3D\/Objects\//.test(m.name)) Object.defineProperty(m, 'data', { value: undefined });
  const r = split.convertPlateMembers(members, 1, U1);
  assert.ok(r.ok, r.error);
  assert.equal(r.report.plateColours, undefined);
  assert.equal(r.report.plate.exact, false);
  assert.ok(r.report.warnings.some((w) => /could not all be read/.test(w)));
  // Untouched members say which source member they are a copy of: thumbnails are renamed.
  const thumb = r.members.find((m) => m.name === 'Metadata/plate_1.png');
  assert.equal(thumb.sourceName, 'Metadata/plate_1.png');
  const r3 = split.convertPlateMembers(plates.readMembers(wide()), 3, U1);
  assert.equal(r3.members.find((m) => m.name === 'Metadata/plate_1.png').sourceName, 'Metadata/plate_3.png');
});

test('outside a split, plateColours is the only way in: mergeToSlots and no option behave as before', () => {
  const buf = wide();
  const plain = mf.convert(buf, { targetId: 'snapmaker-u1' });
  assert.equal(cfg(plain.buffer).filament_colour.length, 8, 'no option: every colour stays');
  assert.equal(plain.report.plateColours, undefined);
  const merged = mf.convert(buf, { targetId: 'snapmaker-u1', mergeToSlots: true });
  assert.equal(cfg(merged.buffer).filament_colour.length, 4);
  assert.equal(merged.report.plateColours, undefined);
  assert.ok(merged.report.warnings.some((w) => /Merged 8 colours into the nearest 4/.test(w)));
});
