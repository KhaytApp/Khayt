'use strict';
/**
 * Band detection asked per plate.
 *
 * detectColorBands slices the geometry it is given in Z and asks whether each slice is one
 * colour. Every plate in a project stands at z=0, so handing it a whole multi-plate file slices
 * all the plates at once. Ported with bedready.io's color-bands-plates.test.mts (its #13), where
 * both consequences were reproduced against the real detector:
 *   - two cleanly banded plates → banded=false, blamed on "in-layer detail" that does not exist;
 *   - a plate big enough to carry the area-weighted purity vote → banded=true with ITS swap
 *     heights, silently wrong for the smaller plate — and the converter writes those heights into
 *     the output file as M600 pauses.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { detectColorBands, detectColorBandsForMesh } = require('../lib/color-bands');
const { analyzeColorBands, convert } = require('../lib/mf-convert');
const { encodeSolidPaint } = require('../lib/mf-mesh');

/** Flat triangles stacked in Z, colour switching once at `swap`. */
function part(swap, top, lower, upper, facesPerLayer = 6) {
  const pos = [], st = [];
  for (let z = 0; z < top; z += 0.2) {
    for (let k = 0; k < facesPerLayer; k++) {
      pos.push(k * 3, 0, z, k * 3 + 2, 0, z, k * 3 + 1, 2, z);
      st.push(z < swap ? lower : upper);
    }
  }
  return { positions: Float32Array.from(pos), faceState: Uint8Array.from(st) };
}

/**
 * A mesh in lib/mf-mesh.js's own shape: flat arrays, with each part a face RANGE into them and
 * each part its own plate.
 */
function plated(...ps) {
  const positions = Float32Array.from(ps.flatMap((p) => Array.from(p.positions)));
  const faceState = Uint8Array.from(ps.flatMap((p) => Array.from(p.faceState)));
  let at = 0;
  const parts = ps.map((p, i) => { const r = { name: '', objectId: i + 1, start: at, end: at + p.faceState.length }; at = r.end; return r; });
  return { positions, faceState, parts, plates: ps.map((_, i) => ({ name: `Plate ${i + 1}`, partIndices: [i] })) };
}

test('a single banded plate is unaffected', () => {
  const r = detectColorBandsForMesh(plated(part(10, 20, 1, 2)), 1);
  assert.equal(r.banded, true);
  assert.deepEqual(r.changeHeights.map((h) => Math.round(h)), [10]);
});

test('plates that agree on their swaps keep the plan', () => {
  const r = detectColorBandsForMesh(plated(part(10, 20, 1, 2), part(10, 20, 1, 2)), 1);
  assert.equal(r.banded, true);
  assert.deepEqual(r.changeHeights.map((h) => Math.round(h)), [10]);
});

test('two cleanly banded plates are no longer blamed for sharing layers', () => {
  const m = plated(part(10, 20, 1, 2), part(10, 20, 2, 1));
  const whole = detectColorBands(m.positions, m.faceState, 1);
  assert.equal(whole.banded, false, 'guard: the combined file really does look unbanded');
  assert.match(whole.reason, /share layers/);
  const r = detectColorBandsForMesh(m, 1);
  assert.doesNotMatch(r.reason, /share layers/);
});

test('plates that swap at the same height but in different colours are refused', () => {
  // A: red→blue at 10 mm. B: green→yellow at 10 mm. Same heights, and one plan would carry
  // only A's colours — B's would be sent to whatever head A's plan left them.
  const r = detectColorBandsForMesh(plated(part(10, 20, 1, 2), part(10, 20, 3, 4)), 1);
  assert.equal(r.banded, false);
  assert.deepEqual(r.bands, []);
  assert.match(r.reason, /different colours/);
  // Opposite order of the same two colours is a different plan too.
  assert.equal(detectColorBandsForMesh(plated(part(10, 20, 1, 2), part(10, 20, 2, 1)), 1).banded, false);
});

test('plates needing different swap heights are refused, not averaged', () => {
  const big = part(10, 20, 1, 2, 120);
  const small = part(4, 20, 1, 2, 4);
  const m = plated(big, small);
  const whole = detectColorBands(m.positions, m.faceState, 1);
  assert.equal(whole.banded, true, 'guard: the big plate does carry the vote');
  assert.deepEqual(whole.changeHeights.map((h) => Math.round(h)), [10], '…with heights wrong for the small plate');

  const r = detectColorBandsForMesh(m, 1);
  assert.equal(r.banded, false);
  assert.deepEqual(r.changeHeights, []);
  assert.match(r.reason, /different swap heights/);
  assert.match(r.reason, /Plate 1/);
  assert.match(r.reason, /Plate 2/);
});

test('an unbanded plate names itself in the reason', () => {
  const pos = [], st = [];
  for (let z = 0; z < 20; z += 0.2) {
    for (let k = 0; k < 6; k++) { pos.push(k * 3, 0, z, k * 3 + 2, 0, z, k * 3 + 1, 2, z); st.push(k % 2 ? 1 : 2); }
  }
  const r = detectColorBandsForMesh(plated(part(10, 20, 1, 2), { positions: Float32Array.from(pos), faceState: Uint8Array.from(st) }), 1);
  assert.equal(r.banded, false);
  assert.match(r.reason, /Plate 2/);
});

test('a file with no plate metadata behaves exactly as before', () => {
  const p = part(10, 20, 1, 2);
  assert.deepEqual(detectColorBandsForMesh({ ...p, parts: [], plates: [] }, 1), detectColorBands(p.positions, p.faceState, 1));
});

// ── through the real parser and the real converter ──────────────────────────
// The tests above hand-build `parts`/`plates`; these paint a genuine two-plate Bambu file so
// they would fail if lib/mf-mesh.js stopped populating them.

/** One object of vertical walls: `faces` triangles `width` wide per 0.2 mm, colour `lower` below `swap`. */
function objectXml(id, swap, top, lower, upper, width) {
  const v = [], t = [];
  let n = 0;
  for (let z = 0; z < top - 1e-6; z += 0.2) {
    const z1 = +(z + 0.2).toFixed(3), z0 = +z.toFixed(3);
    v.push(`<vertex x="0" y="0" z="${z0}"/>`, `<vertex x="${width}" y="0" z="${z0}"/>`, `<vertex x="0" y="0" z="${z1}"/>`);
    t.push(`<triangle v1="${n}" v2="${n + 1}" v3="${n + 2}" paint_color="${encodeSolidPaint(z0 < swap ? lower : upper)}"/>`);
    n += 3;
  }
  return `<object id="${id}" type="model"><mesh><vertices>${v.join('')}</vertices><triangles>${t.join('')}</triangles></mesh></object>`;
}

function twoPlates(a, b) {
  const model = '<?xml version="1.0"?><model unit="millimeter"><resources>'
    + objectXml(1, ...a) + objectXml(2, ...b) + '</resources><build>'
    + '<item objectid="1" transform="1 0 0 0 1 0 0 0 1 128 128 0"/>'
    + '<item objectid="2" transform="1 0 0 0 1 0 0 0 1 435 128 0"/></build></model>';
  const plates = '<?xml version="1.0"?><config>'
    + '<object id="1"><metadata key="extruder" value="1"/></object><object id="2"><metadata key="extruder" value="1"/></object>'
    + '<plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="Big"/><model_instance><metadata key="object_id" value="1"/></model_instance></plate>'
    + '<plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="Small"/><model_instance><metadata key="object_id" value="2"/></model_instance></plate>'
    + '</config>';
  return writeZip([
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/model_settings.config', data: plates },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({
      printer_model: 'Bambu Lab X1 Carbon', layer_height: '0.2', nozzle_diameter: ['0.4'],
      filament_colour: ['#FF0000', '#00FF00'], filament_type: ['PLA', 'PLA'],
    }) },
  ]);
}

test('a real two-plate file with different swap heights is refused by the analysis', () => {
  // The big plate swaps at 10 mm and carries the vote; the small one swaps at 4 mm.
  const r = analyzeColorBands(twoPlates([10, 20, 1, 2, 120], [4, 20, 1, 2, 4]));
  assert.equal(r.available, true);
  assert.equal(r.banded, false);
  assert.match(r.reason, /different swap heights/);
  assert.match(r.reason, /Big/);
  assert.match(r.reason, /Small/);
});

test('a real two-plate file whose plates differ only in colour is refused, and gets no pauses', () => {
  const r = convert(twoPlates([10, 20, 1, 2, 30], [10, 20, 2, 1, 30]), { targetId: 'snapmaker-u1', bandSwap: true });
  assert.notEqual(r.report.bandSwap, true);
  assert.equal(openZip(r.buffer).file('Metadata/custom_gcode_per_layer.xml'), null);
  assert.match(analyzeColorBands(twoPlates([10, 20, 1, 2, 30], [10, 20, 2, 1, 30])).reason, /different colours/);
});

test('…and the converter writes no pauses at one plate\'s heights for both', () => {
  const r = convert(twoPlates([10, 20, 1, 2, 120], [4, 20, 1, 2, 4]), { targetId: 'snapmaker-u1', bandSwap: true });
  assert.equal(r.ok, true);
  assert.notEqual(r.report.bandSwap, true);
  assert.equal(openZip(r.buffer).file('Metadata/custom_gcode_per_layer.xml'), null);
});

test('a real two-plate file whose plates agree still gets its swap plan', () => {
  const r = analyzeColorBands(twoPlates([10, 20, 1, 2, 30], [10, 20, 1, 2, 30]));
  assert.equal(r.banded, true);
  assert.deepEqual(r.changeHeights.map((h) => Math.round(h)), [10]);
});
