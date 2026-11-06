'use strict';
// chromaWeight: lightness-first colour matching for HueForge plans (ported from Bed Ready,
// Nov 2026). The default of 1 must leave every plan bit-for-bit as it was, because the desktop
// and Bed Ready both call planPainting without it; only a caller that asks for < 1 changes.
const { test } = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const HF = require('../lib/hueforge');
const KC = require('../lib/color-mix');

function img(W, H, f) {
  const d = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const c = f(x, y, W, H), o = (y * W + x) * 4;
    d[o] = c[0]; d[o + 1] = c[1]; d[o + 2] = c[2]; d[o + 3] = c[3] == null ? 255 : c[3];
  }
  return { data: d, width: W, height: H };
}
const IMGS = {
  grad: img(64, 48, (x, y, W, H) => [x / W * 255, y / H * 255, 128]),
  face: img(60, 60, (x, y) => { const r = Math.hypot(x - 30, y - 30); return [200 - r * 2, 150 - r * 2, 120 - r * 1.5]; }),
  stripes: img(50, 40, (x, y) => [(x * 37) % 256, (y * 53) % 256, ((x + y) * 17) % 256, x < 3 ? 0 : 255]),
};
const PALS = {
  four: [{ hex: '#111318', td: 0.9 }, { hex: '#0A3D7A', td: 2 }, { hex: '#C99B27', td: 5.3 }, { hex: '#F5F1E6', td: 10 }],
  gray: [{ hex: '#161616' }, { hex: '#5A5B5D' }, { hex: '#BDBEC0' }, { hex: '#F4F4F2' }],
};
const fingerprint = (plan) => crypto.createHash('sha256')
  .update(JSON.stringify(plan, (k, v) => (v && ArrayBuffer.isView(v) ? Array.from(v) : v)))
  .digest('hex').slice(0, 16);

// Fingerprints of the whole plan (sequence, bands, heights, preview, losses, palette) taken from
// lib/hueforge.js BEFORE chromaWeight existed. If one of these moves, the default plan changed.
const BEFORE = {
  'grad/four/{}': '4df2407215daa151',
  'grad/four/{"tdScale":0.3,"heightMm":3.2}': 'd9aeb7d63d124c47',
  'grad/gray/{"tdScale":0.5,"dither":true,"smooth":1}': '585b7d94cad70986',
  'face/four/{"tdScale":0.3,"heightMm":3.2}': 'cbd4a0601f9f8579',
  'face/gray/{}': '19c0de9049c3b485',
  'stripes/four/{"tdScale":0.5,"dither":true,"smooth":1}': 'b792d4074fbaad7a',
  'stripes/gray/{"tdScale":0.3,"heightMm":3.2}': '1f9faeb1337bc8cc',
};
const cases = () => Object.keys(BEFORE).map((key) => {
  const [ik, pk, o] = key.split(/\/(?=[a-z]+\/\{)|\/(?=\{)/);
  return { key, im: IMGS[ik], pal: PALS[pk], opts: JSON.parse(o) };
});

test('chromaWeight omitted, 1, or invalid gives the same plan as before it existed, byte for byte', () => {
  for (const { key, im, pal, opts } of cases()) {
    const base = Object.assign({ anneal: 300 }, opts);
    assert.strictEqual(fingerprint(HF.planPainting(im, pal, base)), BEFORE[key], `${key} (omitted)`);
    for (const cw of [1, 0, NaN]) {
      assert.strictEqual(fingerprint(HF.planPainting(im, pal, Object.assign({}, base, { chromaWeight: cw }))), BEFORE[key], `${key} (chromaWeight ${cw})`);
    }
  }
});

test('chromaWeight < 1 does change the plan', () => {
  const { im, pal, opts } = cases()[3];
  const a = HF.planPainting(im, pal, Object.assign({ anneal: 300 }, opts));
  const b = HF.planPainting(im, pal, Object.assign({ anneal: 300, chromaWeight: 0.5 }, opts));
  assert.notStrictEqual(fingerprint(a), fingerprint(b));
});

// One pixel of saturated blue against a black→red→white stack. Its nearest composite by plain
// Lab distance is a pale pink near the top (closer in a/b, 24 L units too light); weighted
// lightness-first it lands on the deep red at the right depth.
const FILS = [{ hex: '#161616' }, { hex: '#C04040' }, { hex: '#F4F4F2' }];
const SEQ = [0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2];
const SOLVE = { layerH: 0.08, baseLayers: 2, dither: false, tdScale: 0.3 };
const pick = (rgb, cw) => HF.solveFromSequence({ data: new Uint8ClampedArray([...rgb, 255]), width: 1, height: 1 }, FILS, SEQ, Object.assign({ chromaWeight: cw }, SOLVE)).heights[0];

test('chromaWeight 0.5 matches lightness first where a closer hue at the wrong lightness used to win', () => {
  const rgb = [0, 0, 224];
  const L = KC.rgbToLab({ r: rgb[0], g: rgb[1], b: rgb[2] }).L;
  const pal = HF.compositeSequence(FILS, SEQ, SOLVE.layerH, SOLVE.tdScale);
  const at = (k) => pal.find((p) => p.k === k).lab;
  const k1 = pick(rgb, 1), k5 = pick(rgb, 0.5);
  assert.strictEqual(k1, 9, 'plain Lab distance picks the pale layer');
  assert.strictEqual(k5, 6, 'lightness-first picks the deep layer');
  assert.ok(Math.abs(at(k5).L - L) < 2 && Math.abs(at(k1).L - L) > 20, `ΔL ${Math.abs(at(k5).L - L)} vs ${Math.abs(at(k1).L - L)}`);
  // and the hue it gave up was genuinely closer
  const dab = (k) => Math.hypot(at(k).a - KC.rgbToLab({ r: 0, g: 0, b: 224 }).a, at(k).b - KC.rgbToLab({ r: 0, g: 0, b: 224 }).b);
  assert.ok(dab(k1) < dab(k5));
});

test('sequenceLoss takes chromaWeight and stays the same at 1', () => {
  const reps = HF.quantizeTargets(IMGS.face, 32);
  const pal = HF.compositeSequence(PALS.four, [0, 0, 1, 1, 2, 2, 3, 3], 0.08, 0.3);
  const base = HF.sequenceLoss(reps, pal, 2, false);
  assert.strictEqual(HF.sequenceLoss(reps, pal, 2, false, 1), base);
  assert.notStrictEqual(HF.sequenceLoss(reps, pal, 2, false, 0.5), base);
});
