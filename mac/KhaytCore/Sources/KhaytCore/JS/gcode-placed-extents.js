'use strict';
(function (global) {

/**
 * Where a sliced G-code file's models SIT on the bed, from what the slicer
 * wrote about them, so lib/send-checks.js can say "Fits the bed" or block a
 * send that cannot fit (file.bounds, source 'placed-extents'). Nothing
 * measured a file's placed extents before, so the bed rows of send-checks
 * never ran on a real file (Mac lane, Nov 21).
 *
 * What the slicers write, best first:
 *
 *   EXCLUDE_OBJECT_DEFINE NAME=… CENTER=x,y POLYGON=[[x,y],…]
 *        Klipper's object list (OrcaSlicer, PrusaSlicer and SuperSlicer with
 *        "label objects" on and Klipper flavour, the Snapmaker U1's files).
 *        The polygon is each object's outline on the bed as placed.
 *   ; objects_info = {"objects":[{"name":…,"polygon":[[x,y],…]}]}
 *        PrusaSlicer's list for Prusa firmware's cancel-object (label
 *        objects on, firmware flavour).
 *
 *   and the height of the tallest model, from the slicer's own figure:
 *   `; max_z_height: 23.40` (Orca, Bambu Studio), `; max_layer_z = 23.4`
 *   (PrusaSlicer's config block), `;MAXZ:23.4` (Cura).
 *
 * Without an object list the footprint falls back to the extruding moves
 * (lib/gcode-geometry.js), labelled 'toolpath': a skirt, a brim or a purge
 * line is in it, so send-checks only warns on it and never blocks.
 *
 *   placedExtents(text, opts?) → {
 *     x, y, z,                    sizes in mm (z null when the file does not say)
 *     min: {x, y}, max: {x, y},   where the footprint sits (placed-extents only)
 *     source: 'placed-extents' | 'toolpath',
 *     from: 'exclude-object' | 'objects-info' | 'moves',
 *     objects,                    how many outlines were read
 *   } | null
 *
 * SCANNED WITH indexOf, NEVER A REGEX OVER THE FILE (the rule from the
 * release-notes review: a pattern run over text someone else wrote can go
 * quadratic). Each marker is found with indexOf; only its own line, capped at
 * MAX_LINE, is parsed. The end of a line is found once per region, so a file of
 * markers with no newline is still linear. At most MAX_OBJECTS outlines are
 * read. Plain JavaScript with no Node APIs: the Mac and iPhone load it in
 * JavaScriptCore.
 */

const MAX_LINE = 1 << 20;        // one object list line (PrusaSlicer's objects_info is one line)
const MAX_OBJECTS = 2000;
const MAX_POINTS = 20000;        // across every outline

const num = (s) => { const n = Number(s); return Number.isFinite(n) ? n : null; };
const r1 = (n) => Math.round(n * 10) / 10;

/** Every line that starts with `marker` (after any spaces), as [start, end) pairs, linear. */
function linesWith(text, marker, limit, each) {
  let i = text.indexOf(marker);
  let nl = -2;   // the next newline at or after i, kept between hits
  let n = 0;
  while (i !== -1 && n < limit) {
    // Only at a line start (allowing leading spaces), never mid-comment.
    let b = i - 1;
    while (b >= 0 && (text.charCodeAt(b) === 32 || text.charCodeAt(b) === 9)) b -= 1;
    const atStart = b < 0 || text.charCodeAt(b) === 10 || text.charCodeAt(b) === 13;
    if (nl !== -1 && nl < i) nl = text.indexOf('\n', i);
    const end = nl === -1 ? text.length : nl;
    if (atStart) {
      n += 1;
      if (end - i <= MAX_LINE) each(i, end);
    }
    i = text.indexOf(marker, Math.max(i + marker.length, atStart ? end : i + marker.length));
  }
}

/** [[x,y],…] from the text at `from` (a JSON array), or null. */
function pointsAt(line, from) {
  const open = line.indexOf('[', from);
  if (open === -1) return null;
  // The array's own end: brackets counted, no regex.
  let depth = 0, close = -1;
  for (let k = open; k < line.length; k++) {
    const c = line.charCodeAt(k);
    if (c === 91) depth += 1;
    else if (c === 93) { depth -= 1; if (depth === 0) { close = k; break; } }
  }
  if (close === -1) return null;
  let pts;
  try { pts = JSON.parse(line.slice(open, close + 1)); } catch (_) { return null; }
  return Array.isArray(pts) ? pts : null;
}

function createBox() {
  const b = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity, objects: 0, points: 0 };
  b.add = (pts) => {
    let any = false;
    for (const p of pts) {
      if (b.points >= MAX_POINTS) break;
      if (!Array.isArray(p) || p.length < 2) continue;
      const x = num(p[0]), y = num(p[1]);
      if (x === null || y === null) continue;
      b.points += 1; any = true;
      if (x < b.minX) b.minX = x; if (x > b.maxX) b.maxX = x;
      if (y < b.minY) b.minY = y; if (y > b.maxY) b.maxY = y;
    }
    if (any) b.objects += 1;
  };
  b.ok = () => b.objects > 0 && b.maxX >= b.minX && b.maxY >= b.minY;
  return b;
}

function fromExcludeObject(text) {
  const box = createBox();
  linesWith(text, 'EXCLUDE_OBJECT_DEFINE', MAX_OBJECTS, (s, e) => {
    const line = text.slice(s, e);
    const p = line.indexOf('POLYGON=');
    if (p === -1) return;
    const pts = pointsAt(line, p + 8);
    if (pts) box.add(pts);
  });
  return box.ok() ? box : null;
}

function fromObjectsInfo(text) {
  const box = createBox();
  linesWith(text, '; objects_info =', 4, (s, e) => {
    const line = text.slice(s, e);
    const j = line.indexOf('{');
    if (j === -1) return;
    let info;
    try { info = JSON.parse(line.slice(j)); } catch (_) { return; }
    const objs = info && Array.isArray(info.objects) ? info.objects.slice(0, MAX_OBJECTS) : [];
    for (const o of objs) if (o && Array.isArray(o.polygon)) box.add(o.polygon);
  });
  return box.ok() ? box : null;
}

/** The tallest model's height, from the slicer's own line. */
function maxZ(text) {
  for (const [marker, sep] of [['; max_z_height:', ':'], ['; max_layer_z =', '='], [';MAXZ:', ':']]) {
    let z = null;
    linesWith(text, marker, 1, (s, e) => {
      const line = text.slice(s, e);
      z = num(line.slice(line.indexOf(sep, marker.length - 1) + 1).trim());
    });
    if (z !== null && z > 0) return z;
  }
  return null;
}

/** The extruding moves' box, through lib/gcode-geometry.js (one pass of lines). */
function fromMoves(text) {
  const GG = (global && global.KhaytGcodeGeometry)
    || (typeof require === 'function' ? (() => { try { return require('./gcode-geometry.js'); } catch (_) { return null; } })() : null);
  if (!GG || typeof GG.createSilhouette !== 'function') return null;
  const s = GG.createSilhouette();
  let i = 0;
  while (i < text.length) {
    let e = text.indexOf('\n', i);
    if (e === -1) e = text.length;
    if (e - i <= 4096) s.push(text.slice(i, e));
    i = e + 1;
  }
  const r = s.result();
  return r && r.bbox && r.bbox.x > 0 && r.bbox.y > 0 ? r.bbox : null;
}

function placedExtents(input, opts) {
  const text = typeof input === 'string' ? input : '';
  if (!text) return null;
  const o = opts || {};
  const z = maxZ(text);
  let box = fromExcludeObject(text), from = 'exclude-object';
  if (!box) { box = fromObjectsInfo(text); from = 'objects-info'; }
  if (box) {
    return {
      x: r1(box.maxX - box.minX), y: r1(box.maxY - box.minY), z: z === null ? null : r1(z),
      min: { x: r1(box.minX), y: r1(box.minY) }, max: { x: r1(box.maxX), y: r1(box.maxY) },
      source: 'placed-extents',
      from,
      objects: box.objects,
    };
  }
  if (o.moves === false) return null;
  const moves = fromMoves(text);
  if (!moves) return null;
  return { x: moves.x, y: moves.y, z: z === null ? (moves.z || null) : r1(z), source: 'toolpath', from: 'moves', objects: 0 };
}

const api = { placedExtents, MAX_LINE, MAX_OBJECTS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytGcodePlacedExtents = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
