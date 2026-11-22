'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const HF = require('../lib/hueforge');

// Count pixels whose height differs from ALL orthogonal neighbours by >2 layers —
// the isolated spikes that slice into unprintable thin towers / "floating regions".
function spikes(g, W, H) {
  let n = 0;
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) {
    const c = g[j * W + i];
    let neigh = 0, bad = 0;
    for (const [di, dj] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      const x = i + di, y = j + dj;
      if (x < 0 || x >= W || y < 0 || y >= H) continue;
      neigh++; if (Math.abs(c - g[y * W + x]) > 2) bad++;
    }
    if (neigh > 0 && bad === neigh) n++;
  }
  return n;
}

// A flat field (all k=10) with a grid of 1-pixel spikes to k=30 — pure salt-and-pepper.
function speckled(W, H) {
  const g = new Uint16Array(W * H).fill(10);
  for (let j = 1; j < H - 1; j += 2) for (let i = 1; i < W - 1; i += 2) g[j * W + i] = 30;
  return g;
}

test('smoothHeights removes isolated spikes', () => {
  const W = 40, H = 40, g = speckled(W, H);
  const before = spikes(g, W, H);
  assert.ok(before > 100, 'test fixture should be spiky, got ' + before);
  const after = spikes(HF.smoothHeights(g, W, H, 1), W, H);
  assert.ok(after < before / 4, `expected big drop, ${before} -> ${after}`);
});

test('smoothing stays within the palette band (base floor + swaps untouched)', () => {
  const W = 30, H = 30, g = new Uint16Array(W * H);
  for (let i = 0; i < g.length; i++) g[i] = 12 + (i % 7); // values in [12..18]
  const out = HF.smoothHeights(g, W, H, 2);
  let lo = Infinity, hi = -Infinity;
  for (const v of out) { if (v < lo) lo = v; if (v > hi) hi = v; }
  assert.ok(lo >= 12 && hi <= 18, `out of band: ${lo}..${hi}`);
});

test('amount 0 is a no-op (raw solve preserved)', () => {
  const W = 20, H = 20, g = speckled(W, H);
  const out = HF.smoothHeights(g, W, H, 0);
  assert.strictEqual(out, g); // same reference, untouched
});

test('solveHeightfield despeckles when asked, and leaves the solve alone when not', () => {
  // 16x16 checkerboard image of black/white → maximally spiky raw solve.
  const W = 16, H = 16;
  const data = new Uint8ClampedArray(W * H * 4);
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) {
    const o = (j * W + i) * 4, v = ((i ^ j) & 1) ? 255 : 0;
    data[o] = data[o + 1] = data[o + 2] = v; data[o + 3] = 255;
  }
  const img = { data, width: W, height: H };
  const stack = HF.buildStack([{ hex: '#000000' }, { hex: '#ffffff' }], { layerH: 0.12, baseLayers: 4 });
  const raw = HF.solveHeightfield(img, stack, { smooth: 0 });
  const smoothed = HF.solveHeightfield(img, stack, { smooth: 1 });
  assert.ok(spikes(smoothed.heights, W, H) < spikes(raw.heights, W, H),
    'asking for despeckling should produce a less spiky solve');

  // And the default does NOT smooth. This asked for smoothing by default when it was
  // written, which contradicts what solveHeightfield promises — every pixel takes the
  // nearest colour the stack can print — and broke the exhaustive test of exactly that.
  // Nothing lost: the studio's relief comes from planPainting → solveFromSequence, which
  // runs its own smoothness-regularised solve, and every caller here passes `smooth` itself.
  const dflt = HF.solveHeightfield(img, stack);
  assert.deepEqual(Array.from(dflt.heights), Array.from(raw.heights),
    'the default solve must be the raw nearest-colour one');
});
