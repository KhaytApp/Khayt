'use strict';

(function (global) {
/**
 * Telling whether the shop already has this model.
 *
 * The case that matters is not tidiness. A repeat customer sends the same
 * bracket they sent in March; without this it becomes a second library entry
 * with no history, and the shop re-slices a part they already have a known-good
 * setup for (lib/print-setups.js) and a measured cost for (lib/printer-actuals).
 * Recognising the file is what connects the new job to everything already
 * learned about the old one.
 *
 * Two kinds of match, and they are NOT the same claim:
 *
 *   contentHash   the bytes are identical. This is certain. Same file.
 *   geometryKey   the mesh has the same triangle count, volume and bounding box.
 *                 This is a STRONG HINT and nothing more — it survives a
 *                 re-container (the same STL saved binary instead of ascii, or
 *                 wrapped into a 3MF) but it is not proof, and two genuinely
 *                 different parts can collide.
 *
 * The distinction is the whole point of keeping them apart. "You already have
 * this file" is a statement a shop can act on without checking. "This looks like
 * a part you already have" is an invitation to look. Presenting the second as
 * the first would eventually merge two different customers' parts, which is a
 * far worse failure than a missed duplicate.
 *
 * Pure. Hashing is delegated so this module runs in the renderer too.
 */

/**
 * SHA-256 of a file's bytes, hex.
 *
 * @param {Buffer|Uint8Array|ArrayBuffer|string} bytes
 * @param {{createHash?: function}} [deps]  node:crypto, injected
 */
function contentHash(bytes, deps = {}) {
  const createHash = deps.createHash
    || (typeof require === 'function' ? require('crypto').createHash : null);
  if (typeof createHash !== 'function') return null;
  if (bytes === null || bytes === undefined) return null;
  let buf = bytes;
  if (buf instanceof ArrayBuffer) buf = Buffer.from(buf);
  else if (ArrayBuffer.isView(buf) && !Buffer.isBuffer(buf)) buf = Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength);
  else if (typeof buf === 'string') buf = Buffer.from(buf, 'utf8');
  if (!Buffer.isBuffer(buf)) return null;
  // An empty file is not a model, and hashing it would give every empty file the
  // same identity — which would then "already exist" for the next one.
  if (!buf.length) return null;
  return createHash('sha256').update(buf).digest('hex');
}

/* `geometryKey` and its rounding now live in lib/geometry-key.js, so the Mac app
   can bundle them: this file falls back to require('crypto') for contentHash,
   and a bundled module may not name Node at all. Everything here re-exports
   them, so every existing caller is untouched. */
let GK;
try { GK = require('./geometry-key.js'); } catch (e) { GK = null; }
if (!GK) GK = global.KhaytGeometryKey;
const round = (v, dp) => GK.round(v, dp);

/**
 * A key for "the same mesh, however it was packaged".
 *
 * Triangle count is exact on purpose: a re-container preserves it, and a re-mesh
 * does not — and a re-mesh IS a different model as far as a print shop is
 * concerned, because it will slice differently.
 *
 * Returns null for geometry with no substance, so an unparsed or empty model
 * never acquires an identity that another empty one would share.
 */
function geometryKey(geometry) { return GK.geometryKey(geometry); }

/** Nearest half-millimetre — see gcodeGeometryKey for why that size. */
function snap(v) {
  const n = Number(v);
  return Number.isFinite(n) ? Math.round(n * 2) / 2 : null;
}

/**
 * The same idea for g-code, which has no mesh to measure.
 *
 * Takes what lib/gcode-geometry.js walked out of the toolpath: the printed
 * bounding box, and how far the material reaches in each height band. Both are
 * needed — the bands alone describe a shape at any size, and the bbox alone
 * cannot tell two plaques of equal outer size apart.
 *
 * Prefixed `g:` so a key from a toolpath is never mistaken for one from a mesh.
 * They live in the same field and are compared the same way; the prefix means a
 * reader of the stored value can always say which kind of measurement it was.
 *
 * Like geometryKey(), this is an ENVELOPE and belongs to `similar`, not `exact`.
 * A relief pressed into a flat face does not change it.
 */
function gcodeGeometryKey(silhouette) {
  const g = silhouette || {};
  const bbox = g.bbox || {};
  // Half a millimetre, not a tenth. The envelope is quantised by the slicing
  // itself: the top layer lands wherever the layer height puts it, so the same
  // figure sliced at 0.2 and 0.3 mm measured 86.6 and 86.5 mm tall and a tenth
  // of a millimetre split it across two keys. Extrusion width moves X and Y the
  // same way. A coarser bucket still separates any two models a shop would
  // confuse, and a near-miss at a bucket edge costs only a suggestion that was
  // never made — never a wrong one, because this key can only ever say
  // "similar".
  const dims = [snap(bbox.x), snap(bbox.y), snap(bbox.z)];
  if (dims.some((d) => d === null || !(d > 0))) return null;
  const bands = Array.isArray(g.bands) ? g.bands : [];
  if (!bands.length) return null;
  const flat = [];
  for (const b of bands) {
    // 0 is a real answer — a height band with no material in it. null is not,
    // and round() would turn it into 0, quietly keying an unmeasured band as an
    // empty one. Check the number before rounding it, not after.
    const w = Array.isArray(b) ? b[0] : null;
    const d = Array.isArray(b) ? b[1] : null;
    if (!Number.isFinite(w) || !Number.isFinite(d)) return null;
    flat.push(`${round(w, 1)}/${round(d, 1)}`);
  }
  return `g:${dims.join('x')}:${flat.join(',')}`;
}

/** Build the identity fields to store on a library record. */
function identify({ bytes, geometry }, deps = {}) {
  return {
    contentHash: contentHash(bytes, deps),
    geometryKey: geometryKey(geometry),
  };
}

/**
 * What in the library matches this candidate.
 *
 * `exact` and `similar` are disjoint: a record that matches by content is not
 * also reported as a look-alike, because the caller shows a different sentence
 * for each and a record in both lists would be described two ways at once.
 *
 * @param {Array} records    library entries carrying contentHash / geometryKey
 * @param {{contentHash?: string, geometryKey?: string, id?: string}} candidate
 * @returns {{exact: Array, similar: Array}}
 */
function findMatches(records, candidate) {
  const list = Array.isArray(records) ? records.filter((r) => r && typeof r === 'object') : [];
  const c = candidate || {};
  const exact = [];
  const similar = [];
  for (const r of list) {
    // Never match a record against itself — re-checking an existing entry after
    // an edit must not report that it duplicates itself.
    if (c.id && r.id === c.id) continue;
    if (c.contentHash && r.contentHash && r.contentHash === c.contentHash) {
      exact.push(r);
      continue;
    }
    if (c.geometryKey && r.geometryKey && r.geometryKey === c.geometryKey) {
      similar.push(r);
    }
  }
  return { exact, similar };
}

/** Groups of records that are byte-identical to each other, largest first. */
function duplicateGroups(records) {
  const list = Array.isArray(records) ? records.filter((r) => r && typeof r === 'object') : [];
  const byHash = new Map();
  for (const r of list) {
    if (!r.contentHash) continue;
    if (!byHash.has(r.contentHash)) byHash.set(r.contentHash, []);
    byHash.get(r.contentHash).push(r);
  }
  return [...byHash.values()]
    .filter((g) => g.length > 1)
    .sort((a, b) => b.length - a.length);
}

// Which reader measured a record, and whether it is due again — the rule is
// in geometry-key.js so the Mac app reads the same one; re-exported so the
// renderer keeps asking this module about identity.
const READER = GK.READER;
const needsRemeasure = (record) => GK.needsRemeasure(record);

const api = { contentHash, geometryKey, gcodeGeometryKey, identify, findMatches, duplicateGroups,
              READER, needsRemeasure };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytModelIdentity = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
