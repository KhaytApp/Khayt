'use strict';
/**
 * A library record's colours are the PRINT's, not the printer's.
 *
 * An unsliced Orca/Bambu 3MF's `filament_colour` is the spools LOADED when it
 * was saved, and the library showed all of them (Nov 16 2026: a model printed
 * in five colours showed eight; another showed a skin tone it does not use).
 * lib/thumbnail-extract.js now names only the slots the print uses: each part's
 * extruder (one-based, 0 = inherit), height-range colours, and the paint.
 *
 * Every fixture here is SYNTHETIC: it reproduces the structure of a real case
 * seen in a shop's library, with made-up colours and a few triangles. No
 * slicer config or model from a real file is copied.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const T = require('../lib/thumbnail-extract.js');
const Mesh = require('../lib/mf-mesh.js');
const MF = require('../lib/mf-convert.js');
const F = require('../lib/print-facts.js');
const { writeZip } = require('../lib/zip-write.js');

const LOADED8 = ['#111111', '#222222', '#333333', '#444444', '#555555', '#666666', '#777777', '#888888'];
const project = (colours, types) => JSON.stringify({ filament_colour: colours, filament_type: types || colours.map(() => 'PLA') });
/** model_settings.config: objects of {extruder, parts:[extruder…], plate}. */
const modelSettings = (objects) => '<?xml version="1.0"?>\n<config>\n' + objects.map((o, i) =>
  `<object id="${i + 1}">\n  <metadata key="name" value="obj${i + 1}"/>\n  <metadata key="extruder" value="${o.extruder}"/>\n` +
  (o.parts || []).map((pe, j) => `  <part id="${o.partIds ? o.partIds[j] : i + 1}" subtype="normal_part">\n    <metadata key="extruder" value="${pe}"/>\n  </part>\n`).join('') +
  '</object>').join('\n') +
  '\n<plate>\n  <metadata key="plater_id" value="1"/>\n' + objects.map((_, i) => `  <model_instance><metadata key="object_id" value="${i + 1}"/></model_instance>\n`).join('') + '</plate>\n</config>';
const ranges = (extruders) => '<?xml version="1.0"?>\n<objects>\n<object id="1">\n' +
  extruders.map((e, i) => `<range min_z="${i}" max_z="${i + 1}">\n<option opt_key="extruder">${e}</option>\n</range>`).join('\n') + '\n</object>\n</objects>';

/** A 3MF: one object per entry, each a few triangles with optional paint codes. */
function threeMf({ loaded, settings, faces, layerRanges, slice }) {
  const objects = faces.map((list, i) => {
    const tris = list.map((paint, k) => `<triangle v1="0" v2="1" v3="${2 + (k % 2)}"${paint != null ? ` paint_color="${paint}"` : ''}/>`).join('');
    return `<object id="${i + 1}" type="model"><mesh><vertices><vertex x="0" y="0" z="${i}"/><vertex x="10" y="0" z="${i}"/><vertex x="0" y="10" z="${i}"/><vertex x="10" y="10" z="${i}"/></vertices><triangles>${tris}</triangles></mesh></object>`;
  }).join('');
  const model = `<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>${objects}</resources><build>${faces.map((_, i) => `<item objectid="${i + 1}"/>`).join('')}</build></model>`;
  const members = [
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: project(loaded) },
    { name: 'Metadata/model_settings.config', data: settings },
  ];
  if (layerRanges) members.push({ name: 'Metadata/layer_config_ranges.xml', data: layerRanges });
  if (slice) members.push({ name: 'Metadata/slice_info.config', data: slice });
  return writeZip(members.map((m) => ({ name: m.name, data: Buffer.from(m.data) })));
}
const hexes = (r) => r.colors.map((c) => c.hex);
// A painted triangle split in two: one half the part's own filament (state 0), the other slot 2.
const SPLIT_0_2 = Mesh.bitsToHex([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);

test('the paint codec: every leaf state of a split triangle, not only the first', () => {
  assert.deepEqual([...Mesh.leafStates(SPLIT_0_2)].sort(), [0, 2]);
  assert.equal(Mesh.dominantState(SPLIT_0_2), 2, 'the preview keeps its one colour per face');
  assert.deepEqual([...Mesh.leafStates(Mesh.encodeSolidPaint(5))], [5]);
});

test('usedSlots: part over object, one-based, 0 inherits, height ranges and paint join in', () => {
  // An object saying 0 whose parts say 1 and 2 uses 1 and 2, not 0, 1 and 2.
  assert.deepEqual(T.usedSlots({ modelSettings: modelSettings([{ extruder: 0, parts: [1, 2], partIds: [1, 2] }]) }), [1, 2]);
  // A part saying 0 takes its object's; an object with no part line takes its own.
  assert.deepEqual(T.usedSlots({ modelSettings: modelSettings([{ extruder: 4, parts: [0] }, { extruder: 3 }]) }), [3, 4]);
  assert.deepEqual(T.usedSlots({ modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), layerRanges: ranges([1, 2, 3, 2, 3]) }), [1, 2, 3]);
  assert.deepEqual(T.usedSlots({ modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paintSlots: [5, 2] }), [1, 2, 5]);
});

test('eight loaded, five printed: only the five, each named by its slot', () => {
  const r = T.colorsFromConfigs({ projectSettings: project(LOADED8), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paint: { slots: [1, 2, 4, 5, 8] } });
  assert.deepEqual(hexes(r), ['#111111', '#222222', '#444444', '#555555', '#888888']);
  assert.deepEqual(r.colors.map((c) => c.label), ['Filament 1', 'Filament 2', 'Filament 4', 'Filament 5', 'Filament 8']);
  assert.equal(r.slotsKnown, true);
  assert.equal(r.colourCount, 5);
});

test('a loaded spool the print never touches is not one of its colours', () => {
  const loaded = ['#AAAAAA', '#FFFFFF', '#000000', '#FFCC99'];
  const r = T.colorsFromConfigs({ projectSettings: project(loaded), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paint: { slots: [1, 2, 3] } });
  assert.deepEqual(hexes(r), ['#AAAAAA', '#FFFFFF', '#000000']);
  assert.ok(!hexes(r).includes('#FFCC99'));
});

test('one-based: slot 4 is the fourth colour, not the fifth', () => {
  const r = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 4)), modelSettings: modelSettings([{ extruder: 4, parts: [0] }]), paint: { slots: [] } });
  assert.deepEqual(hexes(r), ['#444444']);
});

test('no slice, no swap figure: 0, not colours − 1', () => {
  const r = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 3)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paint: { slots: [1, 2, 3] } });
  assert.equal(r.colors.length, 3);
  assert.equal(r.swapCount, 0);
});

test('height-range colour: every range\'s slot counts, so a relief keeps its colours', () => {
  const four = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 4)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]),
    layerRanges: ranges([1, 2, 3, 4]), paint: { slots: [] } });
  assert.deepEqual(hexes(four), LOADED8.slice(0, 4), 'a colour test changing slot at each height: all four');
  const three = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 4)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]),
    layerRanges: ranges([1, 2, 3, 2, 3]), paint: { slots: [] } });
  assert.deepEqual(hexes(three), LOADED8.slice(0, 3), 'a relief over three slots of four loaded: three');
});

test('painted but unread, or a mixed filament: no colours, never the loaded spools', () => {
  const unread = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 4)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paint: { unread: true } });
  assert.deepEqual(unread.colors, []);
  assert.equal(unread.slotsKnown, false);
  assert.equal(unread.colourCount, null);
  const mixed = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 4)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paint: { slots: [1, 6] } });
  assert.deepEqual(mixed.colors, []);
  assert.equal(mixed.slotsKnown, false);
});

test('a host that passes no paint keeps the old answer, marked legacy (the Mac until it moves over)', () => {
  const r = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 4)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]) });
  assert.deepEqual(hexes(r), LOADED8.slice(0, 4));
  assert.equal(r.legacy, true);
  assert.equal(r.reader, 1, 'a legacy answer is not stamped as the new reader');
  assert.equal(r.swapCount, 3);
});

test('a slice: a filament printed at 0 g is dropped; one with no used_g is kept', () => {
  const slice = '<config><plate><filament id="1" color="#123456" used_g="12.5"/><filament id="2" color="#654321" used_g="0.00"/><filament id="3" color="#ABCDEF"/></plate></config>';
  const r = T.colorsFromConfigs({ sliceInfo: slice, projectSettings: project(LOADED8.slice(0, 3)), paint: { slots: [] } });
  assert.deepEqual(hexes(r), ['#123456', '#ABCDEF']);
  assert.equal(r.colors[0].grams, 12.5);
  assert.equal(r.swapCount, 1, 'a sliced file keeps its swap figure');
});

test('a whole 3MF: paint read from the mesh, state 0 is the part\'s own filament', () => {
  const loaded = ['#AA0000', '#00AA00', '#0000AA', '#AAAA00'];
  // One object on slot 3: an unpainted face, a face painted "base", and one split base/slot 2.
  const buf = threeMf({ loaded, settings: modelSettings([{ extruder: 3, parts: [0] }]), faces: [[null, Mesh.encodeSolidPaint(0), SPLIT_0_2]] });
  const r = T.colours3mf(buf);
  assert.equal(r.slotsKnown, true);
  assert.deepEqual(hexes(r), ['#00AA00', '#0000AA'], 'slots 2 and 3; slot 1 is loaded and unused');
  // The per-plate palettes, for the converter: state 0 is slot 3 here, not slot 1.
  const plates = MF.platePalettes(MF.readMembers(buf));
  assert.deepEqual(plates[0].colorIndices, [1, 2]);
});

test('a whole 3MF with no paint: the parts\' slots, without touching the mesh', () => {
  const buf = threeMf({ loaded: LOADED8.slice(0, 4), settings: modelSettings([{ extruder: 0, parts: [2] }, { extruder: 4 }]), faces: [[null], [null]] });
  assert.deepEqual(hexes(T.colours3mf(buf)), ['#222222', '#444444']);
});

test('print-facts: materials narrowed to the slots used, when the host says which', () => {
  const projectSettings = project(LOADED8.slice(0, 3), ['PLA', 'PETG', 'TPU']);
  assert.deepEqual(F.printFacts({ projectSettings }).materials, ['PLA', 'PETG', 'TPU'], 'unchanged without usedSlots');
  assert.deepEqual(F.printFacts({ projectSettings, usedSlots: [1] }).materials, ['PLA']);
  assert.deepEqual(F.printFacts({ projectSettings, usedSlots: [3, 1] }).materials, ['TPU', 'PLA']);
  assert.deepEqual(F.printFacts({ projectSettings, usedSlots: [5] }).materials, ['PLA', 'PETG', 'TPU'], 'a slot past the list: all, not a guess');
});

test('the desktop\'s re-read and the rule agree on which reader is current', () => {
  const src = fs.readFileSync(path.join(__dirname, '../renderer/printfiles.js'), 'utf8');
  const m = /const COLOURS_READER = (\d+);/.exec(src);
  assert.ok(m, 'renderer/printfiles.js names the reader it re-reads below');
  assert.equal(+m[1], T.COLOURS_READER);
  assert.equal(T.coloursStale({}), true);
  assert.equal(T.coloursStale({ coloursReader: T.COLOURS_READER }), false);
});

test('swapsKnown: only a slice knows its swaps, so a card can tell "not yet" from a sliced 0', () => {
  const unsliced = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 2)), modelSettings: modelSettings([{ extruder: 1, parts: [1] }]), paint: { slots: [] } });
  assert.equal(unsliced.swapCount, 0);
  assert.equal(unsliced.swapsKnown, false);
  const oneColour = T.colorsFromConfigs({ sliceInfo: '<filament id="1" color="#123456" used_g="5"/>', paint: { slots: [] } });
  assert.equal(oneColour.swapCount, 0);
  assert.equal(oneColour.swapsKnown, true, 'a sliced one-colour print really has no swaps');
  const legacy = T.colorsFromConfigs({ projectSettings: project(LOADED8.slice(0, 3)) });
  assert.equal(legacy.swapsKnown, false, 'the old colours − 1 is a guess');
  assert.equal(T.colours3mf(Buffer.from('nonsense')).swapsKnown, false);
});
