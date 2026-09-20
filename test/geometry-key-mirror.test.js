'use strict';
/**
 * What the geometry key CANNOT tell apart, pinned so nothing is built on the
 * assumption that it can.
 *
 * ── MEASURED, NOT REASONED ────────────────────────────────────────────────
 *
 * A real shop's library was checked for duplicates by this key: 28 sets, 56
 * files. Almost every one was a mirrored PAIR — `longer right arm` against
 * `longer left arm`, `Face_Horn_R` against `Face_Horn_L`. Byte-identical
 * duplicates in the same library: zero.
 *
 * A mirror preserves the triangle count, the bounding box and the volume —
 * which is the whole key.
 *
 * ── AND THE OBVIOUS FIX DOES NOT WORK ─────────────────────────────────────
 *
 * The mesh reader accumulates a SIGNED volume and takes its absolute value, so
 * the sign looks like the missing information. The two real files above were
 * measured: both signed volumes are POSITIVE and agree to three decimal places
 * (2104.981 against 2104.982), because the tool that mirrored them flipped the
 * winding to keep the normals pointing outward.
 *
 * A sign term would have changed the key's format, required every stored key
 * to be remeasured, and distinguished nothing.
 *
 * So this is a documented limit rather than a patched one. Anything built on
 * this key must treat a match as "the same size and shape", never as "the same
 * model" — a duplicate-finder that deletes one of these loses an arm.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/geometry-key.js');
const { geometryKey } = globalThis.KhaytGeometryKey;

/** The real pair, as the shop's own records carry them. */
const part = { triangleCount: 345904, volumeMm3: 2104.98,
               bbox: { x: 6.11, y: 22.7, z: 111.61 } };

test('a part and its mirror share a key — a limit, not a bug to be surprised by', () => {
  const mirror = { ...part, bbox: { ...part.bbox } };
  assert.strictEqual(geometryKey(part), geometryKey(mirror),
    'the key now separates mirrored parts. If that is deliberate: READER must be '
    + 'bumped in lib/geometry-key.js so every stored key is remeasured, and this '
    + 'test should be rewritten to say what it now separates.');
});

test('what it does separate is a re-mesh, which is what it is for', () => {
  assert.notStrictEqual(geometryKey(part), geometryKey({ ...part, triangleCount: 172952 }),
    'a re-meshed model shares a key with the original, so the key says nothing');
  assert.notStrictEqual(geometryKey(part), geometryKey({ ...part, volumeMm3: 2200 }));
  assert.notStrictEqual(geometryKey(part),
    geometryKey({ ...part, bbox: { ...part.bbox, z: 112 } }));
});

test('nothing without substance gets an identity another empty thing would share', () => {
  assert.strictEqual(geometryKey({ triangleCount: 0, volumeMm3: 0, bbox: {} }), null);
  assert.strictEqual(geometryKey({}), null);
});
