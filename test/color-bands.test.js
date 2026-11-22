'use strict';
// Colour-banding detector tests (ported from the bedready.io reference color-bands.test.mts). Validate
// detectColorBands on synthetic meshes covering the cases that decide whether a model can be printed with
// a small number of filament-swap pauses. Run: node --test test/color-bands.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const { detectColorBands } = require('../lib/color-bands');

// Build one vertical triangle spanning [zlo, zhi] with the given face state, as 9 flat floats. Vertical so
// the face's area distributes across the Z bins it overlaps — exactly how real wall geometry behaves.
function wall(zlo, zhi, x = 0) {
  // verts: (x,0,zlo) (x+1,0,zlo) (x,0,zhi) — a right triangle standing up in the XZ plane.
  return [x, 0, zlo, x + 1, 0, zlo, x, 0, zhi];
}
function mesh(faces) {
  const positions = new Float32Array(faces.flatMap((f) => wall(f.z[0], f.z[1], f.x)));
  const faceState = new Uint8Array(faces.map((f) => f.state));
  return { positions, faceState };
}

test('clean 3-colour stack → banded, 2 changes, no manual swaps (fits 4 heads)', () => {
  const { positions, faceState } = mesh([
    { z: [0, 10], state: 1 },
    { z: [10, 20], state: 2 },
    { z: [20, 30], state: 3 },
  ]);
  const r = detectColorBands(positions, faceState, 1);
  assert.equal(r.banded, true);
  assert.deepEqual(r.bands.map((b) => b.state), [1, 2, 3]);
  assert.equal(r.colorCount, 3);
  assert.equal(r.manualSwaps, 0);
  assert.equal(r.changeHeights.length, 2);
  assert.ok(Math.abs(r.changeHeights[0] - 10) < 0.3);
  assert.ok(Math.abs(r.changeHeights[1] - 20) < 0.3);
});

test('in-layer detail (two colours share every layer) → NOT banded', () => {
  const { positions, faceState } = mesh([
    { z: [0, 30], state: 1, x: 0 },
    { z: [0, 30], state: 2, x: 5 },
  ]);
  const r = detectColorBands(positions, faceState, 1);
  assert.equal(r.banded, false);
  assert.ok(r.purity < 0.9);
});

test('recurring colour A-B-A → 3 bands, 2 distinct colours', () => {
  const { positions, faceState } = mesh([
    { z: [0, 10], state: 1 },
    { z: [10, 20], state: 2 },
    { z: [20, 30], state: 1 },
  ]);
  const r = detectColorBands(positions, faceState, 1);
  assert.equal(r.banded, true);
  assert.deepEqual(r.bands.map((b) => b.state), [1, 2, 1]);
  assert.equal(r.colorCount, 2);
  assert.equal(r.changeHeights.length, 2);
});

test('single colour → banded, one band, zero swaps', () => {
  const { positions, faceState } = mesh([{ z: [0, 30], state: 1 }]);
  const r = detectColorBands(positions, faceState, 1);
  assert.equal(r.banded, true);
  assert.equal(r.bands.length, 1);
  assert.equal(r.colorCount, 1);
  assert.equal(r.changeHeights.length, 0);
});

test('base faces (state 0) resolve to baseState', () => {
  const { positions, faceState } = mesh([
    { z: [0, 10], state: 0 }, // base
    { z: [10, 20], state: 2 },
  ]);
  const r = detectColorBands(positions, faceState, 3); // baseState = 3
  assert.equal(r.banded, true);
  assert.deepEqual(r.bands.map((b) => b.state), [3, 2]);
});

test('a tiny straddling seam face is tolerated (still banded)', () => {
  const { positions, faceState } = mesh([
    { z: [0, 10], state: 1 },
    { z: [0, 10], state: 1, x: 2 },
    { z: [10, 20], state: 2 },
    { z: [10, 20], state: 2, x: 2 },
    { z: [9, 11], state: 2, x: 9 }, // small straddler
  ]);
  const r = detectColorBands(positions, faceState, 1);
  assert.equal(r.banded, true);
  assert.deepEqual(r.bands.map((b) => b.state), [1, 2]);
});

test('>4 bands → manual swaps = bands − 4 (toolchanger uses 4 heads first)', () => {
  const faces = [1, 2, 3, 4, 5, 6].map((state, i) => ({ z: [i * 10, i * 10 + 10], state }));
  const { positions, faceState } = mesh(faces);
  const r = detectColorBands(positions, faceState, 1);
  assert.equal(r.banded, true);
  assert.equal(r.bands.length, 6);
  assert.equal(r.colorCount, 6);
  assert.equal(r.manualSwaps, 2);
});

test('empty mesh → not banded, graceful', () => {
  const r = detectColorBands(new Float32Array(0), new Uint8Array(0), 1);
  assert.equal(r.banded, false);
  assert.equal(r.bands.length, 0);
});

/* ── the swap count must equal what the planner actually emits ───────────── */

test('manualSwaps agrees with buildBandSwapPlan for every head count', () => {
  // These are two halves of one answer shown on the same screen: the converter prints
  // "print all N colours exactly with X filament swap(s)" from manualSwaps, directly above
  // the plan's own instruction list. They disagreed.
  //
  // `bands.length - HEADS` was wrong in both directions — a colour recurring up Z makes
  // several bands but occupies one head (1,2,1,2,1,2 = 6 bands, 2 colours, 0 swaps on a
  // 4-head machine), while that same sequence on a single extruder needs FIVE swaps.
  const { buildBandSwapPlan } = require('../lib/swap-pauses.js');
  const palette = ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#ff00ff'];
  const sequences = [
    [1, 2, 1, 2, 1, 2],   // recurring colours
    [1, 2, 3],            // fits 4 heads
    [1, 2, 3, 4, 5],      // one more colour than heads
    [1, 1, 1],            // single colour
  ];
  for (const seq of sequences) {
    const faces = [];
    seq.forEach((state, i) => {
      for (let k = 0; k < 8; k++) faces.push({ z: [i * 10, i * 10 + 10], state, x: 0 });
    });
    const m = mesh(faces);
    for (const heads of [4, 1]) {
      const r = detectColorBands(m.positions, m.faceState, 1, { binHeight: 1, heads });
      if (!r.banded) continue;
      const plan = buildBandSwapPlan(r.bands, palette, 'M600', 0.2, 1, heads);
      assert.equal(r.manualSwaps, (plan.instructions || []).length,
        `reported ${r.manualSwaps} swaps but the planner emits ${(plan.instructions || []).length} ` +
        `for states [${seq}] on ${heads} head(s)`);
    }
  }
});
