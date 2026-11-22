/**
 * lib/hueforge.js — the filament-painting engine behind Bed Ready.
 *
 * 434 lines, fifteen exported functions, and until now no tests at all. It does
 * not price anything, so it never came up in the money work — but it emits the
 * mesh that gets printed and the plan for which filament runs at which height.
 * A fault here does not show up as a wrong number; it shows up as a ruined
 * eight-hour print.
 *
 * The mesh assertions below are checked against lib/stl-parse.js, which was
 * itself verified against analytically-known solids, so this is a round trip
 * between two things rather than a fixture agreeing with itself. Printability —
 * which no parser can judge, because parseStl takes the ABSOLUTE volume and so
 * cannot see an inside-out mesh — was confirmed separately by slicing the
 * output with a real PrusaSlicer: slab, ramp and relief all produced real
 * filament and sane layer counts.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const HF = require('../lib/hueforge.js');
const { parseStl } = require('../lib/stl-parse.js');

const LAYER_H = 0.08;
const WIDTH_MM = 120;

/** Build a heightfield, mesh it, and read it back with the verified parser. */
function roundTrip(W, H, fill, opts = {}) {
  const heights = [];
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) heights.push(fill(i, j, W, H));
  const mesh = HF.heightfieldToMesh({ width: W, height: H, heights },
    { layerH: LAYER_H, widthMm: WIDTH_MM, ...opts });
  const parsed = parseStl(Buffer.from(HF.meshToStlBinary(mesh.triangles)));
  const sx = WIDTH_MM / (W - 1);
  const footprint = (W - 1) * sx * (H - 1) * sx;
  const mean = heights.reduce((a, b) => a + b, 0) / heights.length;
  return { mesh, parsed, footprint, expectedVolume: footprint * mean * LAYER_H };
}

test('a flat slab has exactly the volume its footprint and height imply', () => {
  const { mesh, parsed, expectedVolume } = roundTrip(16, 16, () => 10);
  assert.equal(mesh.sizeMm.x, WIDTH_MM);
  assert.equal(mesh.sizeMm.y, WIDTH_MM, 'pixels are square, so a square grid is a square part');
  assert.ok(Math.abs(mesh.sizeMm.z - 10 * LAYER_H) < 1e-9);
  // Relative, not absolute: a binary STL stores float32, so a round trip
  // through it is never bit-exact — 11520 comes back as 11520.000171661377.
  assert.ok(Math.abs(parsed.volumeMm3 - expectedVolume) / expectedVolume < 1e-6,
    `${parsed.volumeMm3} vs ${expectedVolume}`);
});

test('a sloped surface has the volume of its mean height', () => {
  // Smooth fields are where "footprint x mean" is a valid expectation, so these
  // are the shapes that can be checked without trusting the mesher's own maths.
  for (const [name, fill] of [
    ['linear ramp', (i, _j, W) => Math.round((i / (W - 1)) * 20)],
    ['ramp off zero', (i, _j, W) => 1 + Math.round((i / (W - 1)) * 19)],
    ['two plateaus', (i, _j, W) => (i < W / 2 ? 0 : 20)],
  ]) {
    const { parsed, expectedVolume } = roundTrip(16, 16, fill);
    assert.ok(Math.abs(parsed.volumeMm3 - expectedVolume) / expectedVolume < 1e-6,
      `${name}: ${parsed.volumeMm3} vs ${expectedVolume}`);
  }
});

test('a heightfield of zeros produces nothing, not a sliver', () => {
  // Regions at zero height are where a heightfield mesher classically produces
  // zero-thickness shells that a slicer either drops or chokes on.
  const { mesh, parsed } = roundTrip(16, 16, () => 0);
  assert.equal(parsed.volumeMm3, 0);
  assert.equal(mesh.sizeMm.z, 0);
});

test('a grid too small to have a face is refused, not crashed on', () => {
  for (const [W, H] of [[1, 8], [8, 1], [1, 1], [0, 0]]) {
    const mesh = HF.heightfieldToMesh({ width: W, height: H, heights: new Array(Math.max(0, W * H)).fill(5) },
      { layerH: LAYER_H, widthMm: WIDTH_MM });
    assert.equal(mesh.triangleCount, 0, `${W}x${H} should yield no geometry`);
    assert.deepEqual(mesh.sizeMm, { x: 0, y: 0, z: 0 });
  }
});

test('every emitted triangle is three points of three finite numbers', () => {
  // A single NaN vertex makes a binary STL that parses but slices to nothing,
  // which is the kind of fault that is only noticed at the printer.
  const { mesh } = roundTrip(12, 12, (i, j) => 4 + ((i * j) % 7));
  assert.ok(mesh.triangleCount > 0);
  assert.equal(mesh.triangles.length, mesh.triangleCount);
  for (const t of mesh.triangles) {
    assert.equal(t.length, 3);
    for (const v of t) {
      assert.equal(v.length, 3);
      for (const n of v) assert.ok(Number.isFinite(n), `non-finite vertex ${JSON.stringify(t)}`);
    }
  }
});

test('the binary STL declares the triangle count it actually contains', () => {
  const { mesh } = roundTrip(10, 10, () => 6);
  const stl = Buffer.from(HF.meshToStlBinary(mesh.triangles));
  assert.equal(stl.readUInt32LE(80), mesh.triangleCount, 'header count');
  assert.equal(stl.length, 84 + 50 * mesh.triangleCount, 'exact binary STL size');
});

/* ── opacity model ───────────────────────────────────────────────────────── */

test('opacity rises with thickness and never leaves 0..1', () => {
  for (const td of [1.2, 4, 11]) {
    let last = -1;
    for (const h of [0, 0.08, 0.4, 0.8, 1.6, 3.2]) {
      const a = HF.layerAlpha(h, td);
      assert.ok(a >= 0 && a <= 1, `alpha ${a} out of range at td=${td} h=${h}`);
      assert.ok(a >= last, `alpha must not fall as the layer thickens (td=${td})`);
      last = a;
    }
  }
});

test('a nonsense transmission distance falls back instead of poisoning the colour', () => {
  // td is already defended — this pins that, because the fallback is what stops
  // a corrupt filament profile turning every composited colour into garbage.
  assert.equal(HF.layerAlpha(1, 0), HF.layerAlpha(1, 4), 'zero td uses the default');
  assert.equal(HF.layerAlpha(1, NaN), HF.layerAlpha(1, 4));
  assert.equal(HF.layerAlpha(1, undefined), HF.layerAlpha(1, 4));
  assert.equal(HF.layerAlpha(1, -1), 1, 'a negative td reads as fully opaque, not as a hole');
});

test('a nonsense thickness reads as zero rather than as NaN', () => {
  // `Math.max(0, h)` looks like a clamp and is not one: Math.max(0, NaN) is NaN,
  // so a bad thickness used to travel all the way into the composite as a
  // silently wrong colour. buildStack guards layerH, so nothing in the module
  // reached it — but layerAlpha is exported, and an exported guard should hold.
  assert.equal(HF.layerAlpha(NaN, 4), 0);
  assert.equal(HF.layerAlpha(undefined, 4), 0);
  assert.equal(HF.layerAlpha(-5, 4), 0, 'negative thickness is no thickness');
});

test('filaments print opaque first so the translucent ones can blend', () => {
  const input = [{ name: 'clear', td: 11 }, { name: 'black', td: 1.2 }, { name: 'mid', td: 4 }];
  const ordered = HF.orderByOpacity(input);
  assert.deepEqual(ordered.map((f) => f.name), ['black', 'mid', 'clear']);
  assert.deepEqual(input.map((f) => f.name), ['clear', 'black', 'mid'], 'the caller\'s array is untouched');
});

test('a corrupt layer height cannot produce a corrupt palette', () => {
  // buildStack is the reason the layerAlpha gap above was never reachable.
  // Verified for real: every junk value falls back and the palette stays hex.
  const fils = [{ hex: '#222222', td: 1.5 }, { hex: '#dddddd', td: 9 }];
  const good = HF.buildStack(fils, { layerH: 0.08 });
  for (const layerH of [0, -1, NaN, undefined, 'abc', Infinity]) {
    const st = HF.buildStack(fils, { layerH });
    assert.ok(st.layerH > 0 && Number.isFinite(st.layerH), `layerH ${layerH} survived as ${st.layerH}`);
    assert.equal(st.palette.length, good.palette.length);
    for (const entry of st.palette) {
      assert.match(String(entry.hex), /^#[0-9a-f]{6}$/i, `bad hex from layerH=${layerH}`);
      assert.ok(Number.isFinite(entry.height));
    }
  }
});
