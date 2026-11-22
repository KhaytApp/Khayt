'use strict';
/**
 * Hangers on a relief: a hole through the top of the picture, or a loop on a tab
 * above it. Both cut or add cells, so what matters is that the part stays one
 * closed, consistently wound shell, and that the hole is where the maths says.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const HF = require('../lib/hueforge.js');
const { parseStl } = require('../lib/stl-parse.js');

const LAYER_H = 0.08;
const WIDTH_MM = 60;

function slab(W, H, layers) {
  return { width: W, height: H, heights: new Array(W * H).fill(layers) };
}

/** Every directed edge appears once and its reverse once: closed and consistently wound. */
function assertClosed(tris) {
  const key = (p) => p.map((v) => v.toFixed(5)).join(',');
  const edges = new Map();
  for (const t of tris) {
    for (let e = 0; e < 3; e++) {
      const k = key(t[e]) + '>' + key(t[(e + 1) % 3]);
      edges.set(k, (edges.get(k) || 0) + 1);
    }
  }
  for (const [k, n] of edges) {
    assert.equal(n, 1, 'edge used twice in one direction: ' + k);
    const [a, b] = k.split('>');
    assert.equal(edges.get(b + '>' + a), 1, 'open edge: ' + k);
  }
}

test('no hanger leaves the mesh exactly as it was', () => {
  const s = slab(31, 21, 10);
  const plain = HF.heightfieldToMesh(s, { layerH: LAYER_H, widthMm: WIDTH_MM });
  const none = HF.heightfieldToMesh(s, { layerH: LAYER_H, widthMm: WIDTH_MM, hang: 'nope' });
  assert.equal(none.triangleCount, plain.triangleCount);
  assert.deepEqual(none.sizeMm, plain.sizeMm);
});

test('a hole is a closed shell with the hole’s volume taken out', () => {
  const W = 121, H = 81, layers = 20;           // 0.5 mm cells
  const mesh = HF.heightfieldToMesh(slab(W, H, layers), { layerH: LAYER_H, widthMm: WIDTH_MM, hang: 'hole', holeMm: 5 });
  assertClosed(mesh.triangles);
  const vol = parseStl(Buffer.from(HF.meshToStlBinary(mesh.triangles))).volumeMm3;
  const sx = WIDTH_MM / (W - 1);
  const full = (W - 1) * sx * (H - 1) * sx * layers * LAYER_H;
  const hole = Math.PI * 2.5 * 2.5 * layers * LAYER_H;
  // Cells are square, so the hole is a staircase circle: within a cell's worth of rim.
  assert.ok(Math.abs((full - vol) - hole) < 2 * Math.PI * 2.5 * sx * layers * LAYER_H,
    `removed ${full - vol} vs a ${hole} mm³ hole`);
  assert.deepEqual(mesh.sizeMm, { x: WIDTH_MM, y: (H - 1) * sx, z: layers * LAYER_H }, 'a hole does not change the size');
});

test('the hole sits a wall’s width below the top edge, centred', () => {
  const lay = HF.hangLayout(121, 81, 0.5, { hang: 'hole', holeMm: 4, wallMm: 2.5 });
  assert.equal(lay.extra, 0);
  assert.equal(lay.cx, 60);
  assert.equal(lay.cy, 9);                     // (2 + 2.5) mm / 0.5 mm
  assert.ok(lay.inHole(60, 9) && !lay.inHole(60, 4.5) && !lay.inHole(60, 13.5));
});

test('a loop adds a tab above the picture, thick enough to hold a keyring', () => {
  const W = 121, H = 81, layers = 30;
  const plain = HF.heightfieldToMesh(slab(W, H, layers), { layerH: LAYER_H, widthMm: WIDTH_MM });
  const mesh = HF.heightfieldToMesh(slab(W, H, layers), { layerH: LAYER_H, widthMm: WIDTH_MM, hang: 'loop', holeMm: 4, baseLayers: 5 });
  assertClosed(mesh.triangles);
  const lay = HF.hangLayout(W, H, 0.5, { hang: 'loop', holeMm: 4 });
  assert.equal(lay.extra, 18);                 // 2 × (2 + 2.5) mm / 0.5 mm
  assert.ok(Math.abs(mesh.sizeMm.y - (plain.sizeMm.y + 18 * 0.5)) < 1e-9);
  // The tab prints 1.6 mm (20 layers), not the 0.4 mm base.
  const tabTop = mesh.triangles.filter((t) => t.every((p) => p[1] > plain.sizeMm.y + 0.5 && p[2] > 0));
  assert.ok(tabTop.length > 0);
  for (const t of tabTop) for (const p of t) assert.ok(Math.abs(p[2] - 20 * LAYER_H) < 1e-9);
  // Nothing of the tab is wider than its head.
  for (const t of mesh.triangles) for (const p of t) {
    if (p[1] > plain.sizeMm.y + 1e-9) assert.ok(Math.abs(p[0] - 30) <= 4.5 + 0.5 + 1e-9, 'tab vertex at x=' + p[0]);
  }
});

test('a loop on a relief thinner than 1.6 mm is as thick as the relief', () => {
  assert.equal(HF.hangTabLayers(0.08, 5, 12), 12);
  assert.equal(HF.hangTabLayers(0.08, 5, 40), 20);
  assert.equal(HF.hangTabLayers(0.2, 2, 40), 8);
  assert.equal(HF.hangTabLayers(0.08, 6, 3), 6, 'never thinner than the base');
});

test('a hole that would cut a small picture in two is left out', () => {
  assert.equal(HF.hangLayout(12, 12, 0.5, { hang: 'hole', holeMm: 4 }), null);
  const mesh = HF.heightfieldToMesh(slab(12, 12, 10), { layerH: LAYER_H, widthMm: 5.5, hang: 'hole', holeMm: 4 });
  assert.equal(mesh.triangleCount, HF.heightfieldToMesh(slab(12, 12, 10), { layerH: LAYER_H, widthMm: 5.5 }).triangleCount);
});

test('odd sizes and uneven surfaces stay closed', () => {
  for (const [W, H, holeMm, hang] of [[57, 33, 3, 'hole'], [57, 33, 7.3, 'loop'], [200, 90, 4, 'loop'], [64, 64, 12, 'hole']]) {
    const heights = [];
    for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) heights.push(5 + ((i * 7 + j * 13) % 17));
    const mesh = HF.heightfieldToMesh({ width: W, height: H, heights }, { layerH: LAYER_H, widthMm: W * 0.4, hang, holeMm, baseLayers: 5 });
    assertClosed(mesh.triangles);
  }
});
