'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { dominantState, encodeSolidPaint, hexToBits, bitsToHex, extractMeshFromBuffer } = require('../lib/mf-mesh');
const { meshTo3mf } = require('../lib/mf-write');
const { writeZip } = require('../lib/zip-write');

// The paint codec: a solid-painted facet's code must decode back to the same filament state.
test('encodeSolidPaint / dominantState round-trip for every filament state', () => {
  for (let s = 1; s <= 16; s++) {
    const code = encodeSolidPaint(s);
    assert.equal(dominantState(code), s, `state ${s} → ${code} → ${dominantState(code)}`);
  }
});

test('dominantState reads a subdivided code as its first leaf state', () => {
  // ss=1 (split), side=0, then two child triangles: first solid state 2, second solid state 3.
  const bits = [1, 0, 0, 0].concat([0, 0, 0, 1]).concat([0, 0, 1, 1]);
  const hex = bitsToHex(bits);
  assert.equal(dominantState(hex), 2, 'first leaf wins');
});

test('hexToBits reads nibbles reversed, LSB-first (matches slicer serialization)', () => {
  // "8" = 0b1000 → LSB-first bits [0,0,0,1]
  assert.deepEqual(hexToBits('8'), [0, 0, 0, 1]);
});

test('extractMeshFromBuffer returns flat positions + palette from a generic 3MF', () => {
  const buf = meshTo3mf([[[0, 0, 0], [10, 0, 0], [0, 20, 5]]]);
  const m = extractMeshFromBuffer(buf);
  assert.equal(m.positions.length, 9, 'one facet → 9 floats');
  assert.equal(m.faceState.length, 1);
  assert.deepEqual([m.positions[0], m.positions[1], m.positions[2]], [0, 0, 0]);
});

// Regression: a "component bomb" — a chain where every object references the same
// child twice — expands to 2^depth instances. The subtree counter MUST memoize (and
// the instance cap MUST fire) or extraction hangs the main process. With 26 links the
// root subtree is 2^25 (~33M) instances; an un-memoized walk would make ~33M calls and
// never return, so simply reaching the assertion proves the fix holds.
test('extractMeshFromBuffer bails fast on a doubled-component bomb (no exponential hang)', () => {
  const LINKS = 26;
  const objs = [];
  for (let i = 1; i < LINKS; i++) {
    objs.push(`<object id="${i}" type="model"><components><component objectid="${i + 1}"/><component objectid="${i + 1}"/></components></object>`);
  }
  // Leaf carries a real one-triangle mesh.
  objs.push(`<object id="${LINKS}" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>`);
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>${objs.join('')}</resources><build><item objectid="1"/></build></model>`;
  const buf = writeZip([{ name: '3D/3dmodel.model', data: model }]);

  const m = extractMeshFromBuffer(buf);
  assert.equal(m.skipped, true, 'instance cap tripped → mesh skipped rather than expanded');
  assert.equal(m.positions.length, 0, 'no geometry emitted for the bomb');
});
