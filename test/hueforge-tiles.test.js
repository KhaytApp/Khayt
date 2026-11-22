'use strict';
/**
 * Tiles: a relief bigger than the bed, cut into pieces that each fit. What
 * matters is that every piece fits, that together they are exactly the picture
 * (no gap, no overlap), and that the heights along a seam match on both sides.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const HF = require('../lib/hueforge.js');
const { parseStl } = require('../lib/stl-parse.js');

const BED = { x: 270, y: 270 };

test('a picture that fits is one tile', () => {
  const t = HF.planTiles(301, 201, 120, BED);
  assert.equal(t.cols, 1); assert.equal(t.rows, 1);
  assert.deepEqual([t.tiles[0].i0, t.tiles[0].i1, t.tiles[0].j0, t.tiles[0].j1], [0, 300, 0, 200]);
});

test('a wide picture is cut into columns that each fit with the margin', () => {
  const t = HF.planTiles(601, 301, 600, BED);   // 600 × 300 mm
  assert.equal(t.cols, 3); assert.equal(t.rows, 2);
  for (const tile of t.tiles) {
    assert.ok(tile.widthMm <= 260 + 1e-9 && tile.depthMm <= 260 + 1e-9, JSON.stringify(tile));
  }
  // Exactly the picture: the cells add up and the seams are shared.
  const cells = t.tiles.reduce((a, x) => a + (x.i1 - x.i0) * (x.j1 - x.j0), 0);
  assert.equal(cells, 600 * 300);
  assert.equal(t.tiles[0].i1, t.tiles[1].i0);
  assert.equal(t.tiles[0].j1, t.tiles[3].j0);
});

test('just over the usable bed is two tiles, not one', () => {
  assert.equal(HF.planTiles(300, 100, 261, BED).cols, 2);
  assert.equal(HF.planTiles(300, 100, 260, BED).cols, 1);
});

test('the heights along a seam are the same on both sides', () => {
  const W = 401, H = 151, heights = new Uint16Array(W * H);
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) heights[j * W + i] = 5 + ((i * 3 + j * 7) % 23);
  const solve = { width: W, height: H, heights };
  const plan = HF.planTiles(W, H, 400, BED);
  assert.equal(plan.cols, 2);
  const [a, b] = plan.tiles.map((t) => HF.tileSolve(solve, t));
  for (let j = 0; j < H; j++) assert.equal(a.heights[j * a.width + a.width - 1], b.heights[j * b.width]);
  // Together the two meshes hold exactly the volume of the whole.
  const vol = (s, w) => parseStl(Buffer.from(HF.meshToStlBinary(HF.heightfieldToMesh(s, { layerH: 0.08, widthMm: w }).triangles))).volumeMm3;
  const whole = vol(solve, 400);
  const parts = plan.tiles.reduce((acc, t) => acc + vol(HF.tileSolve(solve, t), t.widthMm), 0);
  assert.ok(Math.abs(parts - whole) / whole < 1e-5, `${parts} vs ${whole}`);
});

test('a tiny grid is never cut thinner than two cells', () => {
  const t = HF.planTiles(5, 5, 2000, BED);
  assert.equal(t.cols, 2);
  for (const tile of t.tiles) assert.ok(tile.i1 - tile.i0 >= 2);
});
