'use strict';
(function (global) {

/**
 * What KIND OF FILE a library model is: 3MF, STL, STEP, OBJ, G-code,
 * something else, or no file at all.
 *
 * ── WHY IT EXISTS ─────────────────────────────────────────────────────────
 *
 * Every model record already says what it was made from
 * (`printFiles[].sourceFile: { filename, originalName, ext, kind }`), and a
 * shop asks of its library "which of these are sliced and ready, and which
 * are bare meshes?" — which is a question about the file type. The library's
 * File type filter needs a short fixed list rather than every extension ever
 * imported, and three apps draw that filter, so the sorting has one author.
 *
 * ── THE RULE ──────────────────────────────────────────────────────────────
 *
 *   gcode   the extension is gcode (or gco, g, bgcode), OR `sourceFile.kind`
 *           is 'gcode', OR the name ends `.gcode.3mf` — a sliced plate a
 *           Bambu-family slicer exports, which is a zip by its extension and
 *           a G-code file by what is done with it. Asked FIRST, so that one
 *           is never counted as a 3MF project.
 *   3mf     3mf
 *   stl     stl
 *   step    step, stp
 *   obj     obj
 *   other   any other extension, or a file with none
 *   nofile  the record has no file: saved from a web page with nothing
 *           downloaded yet (no `sourceFile`, no linked path).
 *
 * The extension is `sourceFile.ext` when the record has one, else the end of
 * the first name it does have: `sourceFile.filename`, `sourceFile.originalName`,
 * then — for a model LINKED in place rather than copied in — the member of
 * the archive it sits in (`archiveMember`) or the path itself (`externalPath`).
 */

/** The types, in the order every menu lists them. */
const TYPES = ['3mf', 'stl', 'step', 'obj', 'gcode', 'other', 'nofile'];

// No prototype: a file called `x.constructor` must not find Object's own.
const BY_EXT = Object.assign(Object.create(null), {
  '3mf': '3mf', stl: 'stl', step: 'step', stp: 'step', obj: 'obj',
  gcode: 'gcode', gco: 'gcode', g: 'gcode', bgcode: 'gcode',
});

function text(v) { return typeof v === 'string' ? v.trim() : ''; }

/** A name's extension, lower case, without the dot; '' when it has none. */
function extOf(name) {
  const leaf = text(name).split(/[\\/]/).pop();
  const dot = leaf.lastIndexOf('.');
  return dot > 0 && dot < leaf.length - 1 ? leaf.slice(dot + 1).toLowerCase() : '';
}

/** The type of one model record — always one of `TYPES`. */
function typeOf(record) {
  const r = record && typeof record === 'object' ? record : {};
  const sf = r.sourceFile && typeof r.sourceFile === 'object' && !Array.isArray(r.sourceFile) ? r.sourceFile : null;
  const names = [sf && sf.filename, sf && sf.originalName, r.archiveMember, r.externalPath]
    .map(text).filter(Boolean);
  if (!sf && !names.length) return 'nofile';
  const stated = text(sf && sf.ext).replace(/^\./, '').toLowerCase();
  const ext = stated || (names.length ? extOf(names[0]) : '');
  if (BY_EXT[ext] === 'gcode') return 'gcode';
  if (sf && text(sf.kind).toLowerCase() === 'gcode') return 'gcode';
  if (names.some((n) => /\.gcode\.3mf$/i.test(n))) return 'gcode';
  return BY_EXT[ext] || 'other';
}

const api = { TYPES, extOf, typeOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytModelFileType = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
