'use strict';
(function () {

/**
 * "Find similar": the models most like one model, ranked.
 *
 * A PORT of the Mac's `LibrarySimilar` (mac/KhaytCore/Sources/KhaytCore/
 * LibrarySimilar.swift) and the `stem` it leans on (`LibraryStacks.stem`), so
 * the desktop ranks the same way the Mac does. The Mac's rule is Swift-only;
 * this file is its JavaScript twin and is NOT in the Mac's JS bundle. Change
 * one, change the other — test/library-similar.test.js pins the numbers.
 *
 * ── THE ORDER ─────────────────────────────────────────────────────────────
 *
 * 1. The same bytes (`contentHash`) — the same file.
 * 2. The same `geometryKey` — the same triangle count, volume and box. A
 *    strong hint, never proof: a part MIRRORED left-to-right keeps all three,
 *    so a left arm and a right arm match here (lib/geometry-key.js). Every
 *    match of this kind carries `mirrorCaveat`, and the screen says so.
 * 3. Everything else, by a score: how close the bounding box is (its three
 *    sides sorted, so a part lying down matches itself standing up), the
 *    volume and the triangle count, plus the same group, shared tags and the
 *    same name once variant words are off (`stem`).
 *
 * A model with no measured mesh can still find others by group, tags and
 * name. Archived models are never offered. PURE: facts in, ids out.
 */

const VARIANT_WORDS = new Set([
  'support', 'supports', 'supported', 'supportless', 'supportfree', 'unsupported', 'presupported',
  'pre', 'nosupport', 'nosupports', 'no', 'free', 'tree', 'with', 'without',
  'hollow', 'hollowed', 'solid', 'scaled', 'scale', 'mirror', 'mirrored', 'left', 'right',
  'lh', 'rh', 'copy', 'final', 'fixed', 'repaired', 'remix', 'remixed', 'new', 'old', 'alt',
  'small', 'medium', 'large', 'big', 'mini', 'tiny', 'huge', 'xl', 'half', 'full', 'size',
  'draft', 'fine', 'high', 'low', 'res', 'lowres', 'hires', 'test', 'print', 'ready',
  'stl', '3mf', 'obj', 'step', 'gcode',
]);

// The Mac's separator set: " _-.,()[]{}+/\|·—–:;'\"" plus whitespace.
const SEPARATORS = /[\s_\-.,()[\]{}+/\\|·—–:;'"]+/u;

/** A size, scale, version or copy number: `150%`, `0.4mm`, `v2`, `x2`, `2x`, `003`. */
function isFigure(word) {
  let w = String(word);
  if (/^[vxr]/.test(w)) w = w.slice(1);
  for (const suffix of ['%', 'mm', 'cm', 'm', 'x', 'pct']) {
    if (w.endsWith(suffix) && w.length > suffix.length) { w = w.slice(0, -suffix.length); break; }
  }
  if (!w) return false;
  return /^[\p{N}.,]+$/u.test(w);
}

/** A title with its variant words, sizes, versions and copy numbers taken
 *  off, folded for case: "Dragon_150% (supportless) v2" -> "dragon". */
function stem(title) {
  let name = String(title || '');
  for (const ext of ['.stl', '.3mf', '.obj', '.step', '.stp', '.gcode']) {
    if (name.toLowerCase().endsWith(ext)) name = name.slice(0, -ext.length);
  }
  return name.toLowerCase().split(SEPARATORS)
    .filter((w) => w && !VARIANT_WORDS.has(w) && !isFigure(w))
    .join(' ');
}

/** `triangles:volume:XxYxZ`, unpacked; null when nothing was measured. */
function shapeOf(key) {
  if (typeof key !== 'string' || !key) return null;
  const p = key.split(':');
  if (p.length !== 3) return null;
  const t = Number(p[0]), v = Number(p[1]);
  if (!p[0] || !Number.isFinite(t) || t <= 0 || !p[1] || !Number.isFinite(v)) return null;
  const d = p[2].split('x').filter((s) => s !== '').map(Number).filter((n) => !Number.isNaN(n));
  if (d.length !== 3 || !d.every((n) => Number.isFinite(n) && n >= 0)) return null;
  return { tris: t, volume: v, sides: d.slice().sort((a, b) => a - b) };
}

/** 1 when equal, falling to 0 as one becomes twice the other (or more). */
function closeness(a, b) {
  if (!Number.isFinite(a) || !Number.isFinite(b)) return 0;
  const hi = Math.max(Math.abs(a), Math.abs(b)), lo = Math.min(Math.abs(a), Math.abs(b));
  if (!(hi > 0)) return 1;
  return Math.max(0, 1 - (hi - lo) / hi * 2);
}

const THRESHOLD = 0.45;
const LIMIT = 30;
const RANK = { sameFile: 0, sameShape: 1, near: 2 };

/**
 * The models most like `target`, best first; the target itself is not listed.
 * Each model: {id, title, group?, tags?, contentHash?, geometryKey?, archived?}.
 * @returns {Array<{id:string, why:'sameFile'|'sameShape'|'near', score:number, mirrorCaveat:boolean}>}
 */
function ranked(target, all, limit) {
  const max = limit == null ? LIMIT : Math.max(0, limit);
  const t = target || {};
  const mine = shapeOf(t.geometryKey);
  const myTags = new Set((t.tags || []).map((x) => String(x).toLowerCase()));
  const myStem = stem(t.title);
  const myGroup = String(t.group || '').toLowerCase();
  const out = [];
  for (const m of Array.isArray(all) ? all : []) {
    if (!m || m.id === t.id || m.archived) continue;
    if (t.contentHash && m.contentHash === t.contentHash) { out.push({ id: m.id, why: 'sameFile', score: 1 }); continue; }
    if (mine && t.geometryKey && m.geometryKey === t.geometryKey) { out.push({ id: m.id, why: 'sameShape', score: 1 }); continue; }
    const group = String(m.group || '').toLowerCase();
    const sameGroup = !!myGroup && group === myGroup;
    const theirTags = new Set((m.tags || []).map((x) => String(x).toLowerCase()));
    const union = new Set([...myTags, ...theirTags]);
    let shared = 0; for (const x of myTags) if (theirTags.has(x)) shared++;
    const tagShare = union.size ? shared / union.size : 0;
    const sameStem = myStem.length >= 3 && stem(m.title) === myStem;
    const said = (sameGroup ? 0.4 : 0) + 0.3 * tagShare + (sameStem ? 0.3 : 0);
    const theirs = shapeOf(m.geometryKey);
    let score;
    if (mine && theirs) {
      const sides = (closeness(mine.sides[0], theirs.sides[0]) + closeness(mine.sides[1], theirs.sides[1])
        + closeness(mine.sides[2], theirs.sides[2])) / 3;
      const shape = 0.6 * sides + 0.25 * closeness(mine.volume, theirs.volume) + 0.15 * closeness(mine.tris, theirs.tris);
      score = 0.8 * shape + 0.2 * said;
    } else {
      score = said;
    }
    if (score < THRESHOLD) continue;
    out.push({ id: m.id, why: 'near', score: Math.min(1, score) });
  }
  const titles = new Map();
  for (const m of Array.isArray(all) ? all : []) if (m && !titles.has(m.id)) titles.set(m.id, String(m.title || ''));
  out.sort((a, b) => (RANK[a.why] - RANK[b.why]) || (b.score - a.score)
    || titles.get(a.id).localeCompare(titles.get(b.id), undefined, { numeric: true, sensitivity: 'base' }));
  return out.slice(0, max).map((x) => ({ ...x, mirrorCaveat: x.why === 'sameShape' }));
}

const api = { VARIANT_WORDS, THRESHOLD, LIMIT, stem, isFigure, shapeOf, closeness, ranked };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLibrarySimilar = api;

})();
