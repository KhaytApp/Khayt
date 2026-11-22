/**
 * lib/hueforge.js — solveHeightfield, the part that actually decides the print.
 *
 * Everything already tested sits DOWNSTREAM of this. The mesh can be
 * geometrically exact and the 3MF colour bands can match a working export, and
 * the print is still wrong if the solve picked the wrong height for a pixel.
 * It had no tests.
 *
 * Its contract is stated outright — "for each pixel, choose the palette height
 * whose colour is the closest CIEDE2000 match to the target pixel" — so this
 * checks the contract itself rather than a proxy for it: the nearest entry is
 * recomputed here, independently, and compared for every pixel.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const HF = require('../lib/hueforge.js');
const KC = require('../lib/color-mix.js');

const FILAMENTS = [
  { hex: '#141414', td: 1.4 },   // near-black, opaque
  { hex: '#1b3a6b', td: 3 },     // navy
  { hex: '#c9a227', td: 5 },     // gold
  { hex: '#f4f4f4', td: 9 },     // white, translucent
];
const stack = () => HF.buildStack(FILAMENTS, { layerH: 0.08 });

/** An RGBA image from a per-pixel colour function. */
function image(w, h, fn) {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const [r, g, b, a] = fn(x, y);
      const o = (y * w + x) * 4;
      data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = a === undefined ? 255 : a;
    }
  }
  return { data, width: w, height: h };
}

/** The nearest palette entry, worked out here rather than trusted from there. */
function nearestK(palette, r, g, b) {
  const lab = KC.rgbToLab({ r, g, b });
  let best = palette[0], bestD = Infinity;
  for (const p of palette) {
    const d = KC.ciede2000(lab, p.lab);
    if (d < bestD) { bestD = d; best = p; }
  }
  return best.k;
}

test('every pixel gets the closest colour the stack can actually print', () => {
  // The contract, checked exhaustively. Not "the output looks plausible" —
  // every pixel is compared against an independently computed nearest match.
  const st = stack();
  const img = image(16, 16, (x, y) => [x * 16, y * 16, (x + y) * 8]);
  const out = HF.solveHeightfield(img, st);

  assert.equal(out.width, 16);
  assert.equal(out.heights.length, 256);
  for (let i = 0; i < out.heights.length; i++) {
    const o = i * 4;
    const want = nearestK(st.palette, img.data[o], img.data[o + 1], img.data[o + 2]);
    assert.equal(out.heights[i], want, `pixel ${i} took height ${out.heights[i]}, nearest was ${want}`);
  }
});

test('one colour in gives one height out', () => {
  const st = stack();
  const out = HF.solveHeightfield(image(8, 8, () => [200, 160, 40]), st);
  const first = out.heights[0];
  for (const k of out.heights) assert.equal(k, first, 'a flat image must not produce a textured relief');
  assert.equal(out.minK, first);
  assert.equal(out.maxK, first);
});

test('no pixel is placed outside the stack it was solved against', () => {
  // A height above totalLayers is a print taller than the plan; below
  // baseLayers is a floor the bed shows through.
  const st = stack();
  const ks = st.palette.map((p) => p.k);
  const lo = Math.min(...ks), hi = Math.max(...ks);
  const out = HF.solveHeightfield(image(12, 12, (x, y) => [x * 21, 255 - y * 21, 128]), st);
  for (const k of out.heights) {
    assert.ok(k >= lo && k <= hi, `height ${k} outside the palette's ${lo}..${hi}`);
  }
  assert.equal(out.minK, Math.min(...out.heights));
  assert.equal(out.maxK, Math.max(...out.heights));
});

test('a transparent pixel prints as the base, whatever colour it claims to be', () => {
  // Transparency carries an RGB that was never meant to be seen — often pure
  // white or leftover matte. Solving for it would emboss the background.
  const st = stack();
  const base = st.palette[0].k;
  const out = HF.solveHeightfield(image(4, 4, (x) => (x === 0 ? [255, 255, 255, 0] : [20, 20, 20, 255])), st);
  for (let y = 0; y < 4; y++) {
    assert.equal(out.heights[y * 4], base, 'a transparent pixel must fall to the base');
  }
  // And the opaque neighbours must be unaffected by sitting next to one.
  const opaque = nearestK(st.palette, 20, 20, 20);
  assert.equal(out.heights[1], opaque);
});

test('the preview shows the colour that height will actually print', () => {
  // The preview is what a shop judges the result by before committing filament.
  // If it does not match the chosen height, they approve something else.
  const st = stack();
  const out = HF.solveHeightfield(image(8, 8, (x, y) => [x * 30, y * 30, 90]), st);
  const byK = new Map(st.palette.map((p) => [p.k, KC.hexToRgb(p.hex)]));
  for (let i = 0; i < out.heights.length; i++) {
    const want = byK.get(out.heights[i]);
    const o = i * 4;
    assert.equal(out.preview[o], want.r, `preview red at ${i}`);
    assert.equal(out.preview[o + 1], want.g);
    assert.equal(out.preview[o + 2], want.b);
    assert.equal(out.preview[o + 3], 255, 'the preview is opaque');
  }
});

test('the same picture solves the same way twice', () => {
  // A shop re-opening a project must not be shown a different relief.
  const st = stack();
  const img = image(10, 10, (x, y) => [(x * y) % 256, x * 25, y * 25]);
  const a = HF.solveHeightfield(img, st);
  const b = HF.solveHeightfield(img, st);
  assert.deepEqual(Array.from(a.heights), Array.from(b.heights));
});

test('a stack with no palette returns an empty solve rather than throwing', () => {
  const out = HF.solveHeightfield(image(4, 4, () => [10, 20, 30]),
    { palette: [], layerH: 0.08, baseLayers: 4, totalLayers: 0, bands: [], filaments: [] });
  assert.equal(out.heights.length, 16);
  assert.ok(Array.from(out.heights).every((k) => k === 0));
});
