'use strict';
(function (global) {

/**
 * The key for "the same mesh, however it was packaged".
 *
 * Split out of `lib/model-identity.js`, which cannot be shared with the Mac
 * app: its `contentHash` falls back to `require('crypto')` and JavaScriptCore
 * has no `require`. The repo's drift guards refuse a bundled module that names
 * Node at all — rightly, since a guarded require is still a require somebody
 * will later unguard — so the pure half lives here and the whole half keeps
 * re-exporting it.
 *
 * WHY IT IS SHARED AT ALL. It is three numbers joined by punctuation, which is
 * exactly the kind of thing two implementations agree on until they do not: a
 * rounding, a separator, an order. These keys are compared against records the
 * other app wrote, so the format has to have one author.
 *
 * Triangle count is exact on purpose: a re-container preserves it, and a re-mesh
 * does not — and a re-mesh IS a different model as far as a print shop is
 * concerned, because it will slice differently.
 *
 * Returns null for geometry with no substance, so an unparsed or empty model
 * never acquires an identity that another empty one would share.
 *
 * ── WHAT IT CANNOT TELL APART: A PART AND ITS MIRROR ─────────────────────
 *
 * A mirror preserves the triangle count, the bounding box and the volume,
 * which is the whole key. Measured on a real shop's library: 28 sets of
 * "duplicates" by this key, and almost every one a mirrored pair — a left arm
 * against a right arm. Byte-identical duplicates there: zero.
 *
 * The signed volume looks like the missing information and is not. Both files
 * in that pair measure POSITIVE and agree to three decimal places, because the
 * tool that mirrored them flipped the winding to keep the normals outward.
 *
 * So a match here means THE SAME SIZE AND SHAPE, never "the same model".
 * Anything that offers to delete one of a matching pair must say which it is
 * offering, and must not call it a duplicate. See
 * `test/geometry-key-mirror.test.js`.
 */
function round(v, dp) {
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  const f = Math.pow(10, dp);
  return Math.round(n * f) / f;
}

function geometryKey(geometry) {
  const g = geometry || {};
  const tris = Number(g.triangleCount);
  const vol = Number(g.volumeMm3);
  if (!Number.isFinite(tris) || tris <= 0) return null;
  if (!Number.isFinite(vol) || vol <= 0) return null;
  const bbox = g.bbox || {};
  const dims = [round(bbox.x, 2), round(bbox.y, 2), round(bbox.z, 2)];
  if (dims.some((d) => d === null)) return null;
  return `${tris}:${round(vol, 2)}:${dims.join('x')}`;
}

/**
 * Which reader wrote a record's key, and whether it is due to be read again.
 *
 * A key is written once, on import, and nothing re-reads a file that has one —
 * right for the ordinary case, and exactly what strands a book when a reader
 * fault is fixed: the number the shop was shown stays wrong on every record
 * the old reader wrote. So each record names the reader that measured it, and
 * this number goes up when a fault is fixed. A record below it — or without
 * one, written before the rule existed — is measured again by whichever app
 * next opens the book with the file in reach, and only the keys that differ
 * change. Reader 2: one plate's size rather than every plate boxed together,
 * every component placed, roots over 8 MB read, zip64 containers opened.
 */
const READER = 2;

function needsRemeasure(record) {
  const r = Number(record && record.geometryReader);
  return !(Number.isFinite(r) && r >= READER);
}

const api = { geometryKey, round, READER, needsRemeasure };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytGeometryKey = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
