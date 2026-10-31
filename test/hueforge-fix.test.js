'use strict';
/**
 * Colour fixes: click an area, say what colour it should print. The area is found
 * on the picture (connected, similar colour), the colour is matched to what the
 * stack can print, and the fix survives a re-solve because it is kept as a point
 * and a hex, not as a height.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const HF = require('../lib/hueforge');
const CM = require('../lib/color-mix');

const FILS = [
  { hex: '#111318', td: 0.9 },
  { hex: '#0A3D7A', td: 2.0 },
  { hex: '#C99B27', td: 5.3 },
  { hex: '#F5F1E6', td: 10 },
];

/** Grey background with two separate red squares and one blue one. */
function picture(W, H) {
  const data = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    let c = [128, 128, 128];
    if (y >= 10 && y < 30 && x >= 10 && x < 30) c = [200, 30, 30];
    if (y >= 10 && y < 30 && x >= 60 && x < 80) c = [200, 30, 30];
    if (y >= 40 && y < 55 && x >= 10 && x < 30) c = [20, 40, 200];
    const o = (y * W + x) * 4;
    data[o] = c[0]; data[o + 1] = c[1]; data[o + 2] = c[2]; data[o + 3] = 255;
  }
  return { data, width: W, height: H };
}

test('an area is the connected run of similar colour, not every pixel that colour', () => {
  const img = picture(90, 60);
  const m = HF.regionMask(img, 15, 15, 12);
  assert.equal(m.reduce((a, b) => a + b, 0), 400, 'one 20×20 square');
  assert.equal(m[15 * 90 + 65], 0, 'the other red square is not connected');
  assert.equal(m[45 * 90 + 15], 0, 'blue is not red');
  assert.equal(HF.regionMask(img, -1, 5, 12).reduce((a, b) => a + b, 0), 0, 'a click off the picture is nothing');
});

test('a fixed area prints the stack colour nearest the one asked for', () => {
  const img = picture(90, 60);
  const plan = HF.planPainting(img, FILS, { widthMm: 36, cellMm: 0.4, passes: 2, seed: 1 });
  const W = plan.solve.width, H = plan.solve.height;
  assert.equal(W, 90);
  const fixed = HF.planPainting(img, FILS, { widthMm: 36, cellMm: 0.4, passes: 2, seed: 1,
    fixes: [{ x: 15 / (W - 1), y: 15 / (H - 1), hex: '#F5F1E6' }] });
  const f = fixed.solve.fixes[0];
  assert.ok(f.count >= 300 && f.count <= 500, `took ${f.count} pixels`);
  // Nearest by ΔE76 among the heights above the base.
  const want = CM.hexToLab('#F5F1E6');
  const d76 = (p) => (p.lab.L - want.L) ** 2 + (p.lab.a - want.a) ** 2 + (p.lab.b - want.b) ** 2;
  const usable = plan.palette.filter((p) => p.k >= plan.baseLayers);
  const nearest = usable.reduce((a, p) => (d76(p) < d76(a) ? p : a));
  assert.equal(f.k, nearest.k);
  assert.equal(f.hex, nearest.hex);
  assert.equal(fixed.solve.heights[20 * W + 20], f.k);
  // Outside the area nothing moved.
  for (const i of [5 * W + 5, 20 * W + 70, 47 * W + 20]) assert.equal(fixed.solve.heights[i], plan.solve.heights[i]);
  assert.equal(fixed.solve.preview[(20 * W + 20) * 4], Math.round(nearest.rgb.r), 'the preview shows it');
});

test('a fix is kept as a point, so it holds at another width', () => {
  const img = picture(90, 60);
  const fixes = [{ x: 0.2, y: 0.33, hex: '#0A3D7A', spread: 'small' }];
  for (const widthMm of [20, 36]) {
    const p = HF.planPainting(img, FILS, { widthMm, cellMm: 0.4, passes: 2, seed: 1, fixes });
    assert.ok(p.solve.fixes[0].count > 0, `width ${widthMm}: the fix still finds its area`);
  }
});

test('later fixes win where areas overlap, and a bad colour is skipped', () => {
  const img = picture(90, 60);
  const p = HF.planPainting(img, FILS, { widthMm: 36, cellMm: 0.4, passes: 2, seed: 1 });
  const W = p.solve.width, H = p.solve.height, at = { x: 15 / (W - 1), y: 15 / (H - 1) };
  const r = HF.applyRegionFixes(p.solve, img, p.palette, p.baseLayers,
    [Object.assign({ hex: '#F5F1E6' }, at), { hex: 'nope', x: 0, y: 0 }, Object.assign({ hex: '#111318' }, at)]);
  assert.equal(r.fixes[1].count, 0);
  assert.equal(r.heights[15 * W + 15], r.fixes[2].k);
  assert.notEqual(r.fixes[0].k, r.fixes[2].k);
  assert.notEqual(r.heights, p.solve.heights, 'the solve itself is not changed');
});
