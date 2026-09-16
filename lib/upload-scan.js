'use strict';

/**
 * Is a stranger's uploaded model safe to write down and hand to a slicer?
 *
 * ── WHAT CHANGED TO MAKE THIS NECESSARY ───────────────────────────────────
 *
 * The intake form used to read a customer's file in memory, measure it, and
 * drop it. Nothing was written and nothing was executed. Pricing a model by
 * SLICING it is a different bargain: the bytes go to disk and a native binary
 * is pointed at them, on a file anyone who can reach the shop's Wi‑Fi may
 * send. So the file is inspected first, and a shop that has not turned
 * slicing on never reaches any of this.
 *
 * ── WHAT THIS CAN AND CANNOT PROMISE ──────────────────────────────────────
 *
 * IT CAN say the file is what its name claims, that an archive does not name
 * members outside the folder it will be opened in, and that it does not
 * expand to a size out of all proportion to what arrived.
 *
 * IT CANNOT vouch for what a slicer does with a WELL-FORMED file. A parser
 * bug in somebody else's C++ is not something a structural check can see, and
 * claiming otherwise would be worse than claiming nothing — a shop would
 * trust the word "scanned" further than it deserves. The honest summary is
 * "this is a model of the shape it says it is, and it is not a trap door or a
 * bomb", and the wording a shop is shown says exactly that much.
 *
 * ── WHY THE JUDGEMENT IS HERE AND THE READING IS NOT ──────────────────────
 *
 * Reading a zip's central directory is plumbing, and both hosts already have
 * it — `Zip.swift` on the Mac, `mf-convert` under Node. Thirty‑two megabytes
 * of a stranger's file has no business crossing into JavaScriptCore just to
 * be judged. So the host gathers the facts and this decides, which keeps the
 * decision one rule in one place for both apps.
 */
(function (global) {

  /** The most that may arrive at all. Matches the intake route's own cap. */
  const MAX_BYTES = 32 * 1024 * 1024;
  /** The most an archive may become once opened. */
  const MAX_UNPACKED = 512 * 1024 * 1024;
  /** Unpacked ÷ arrived. A 3MF of mesh XML compresses hard, so this is loose
   *  on purpose; a bomb is three orders of magnitude past it, not one. */
  const MAX_RATIO = 250;
  /** A 3MF has a handful of parts. Thousands is somebody making a point. */
  const MAX_ENTRIES = 2048;

  const num = (v) => (Number.isFinite(+v) ? +v : 0);

  /**
   * A member name an archive may not have.
   *
   * Zip stores names verbatim, and a slicer extracting `../../../etc/x` writes
   * where the name says. Backslashes are checked because Windows treats them
   * as separators and a name is not required to use forward slashes.
   */
  function unsafeName(raw) {
    const name = String(raw == null ? '' : raw);
    if (!name) return true;
    if (name.includes('\u0000')) return true;
    if (name.startsWith('/') || name.startsWith('\\')) return true;
    if (/^[a-zA-Z]:[\\/]/.test(name)) return true;          // C:\ and C:/
    const parts = name.split(/[\\/]/);
    return parts.some((p) => p === '..');
  }

  /**
   * What a file's first bytes must look like for the name it arrived under.
   *
   * `header` is the first bytes as lower-case hex — a short string rather than
   * the file, because that is all this needs.
   */
  function looksLikeItsName(ext, header, size) {
    const hex = String(header || '').toLowerCase();
    const text = () => !hex.startsWith('0000') && !/^(.{2})*00/.test(hex.slice(0, 16));
    switch (ext) {
      // A 3MF is a zip, always.
      case '3mf': return hex.startsWith('504b0304');
      // An STL is either ASCII beginning `solid`, or binary: 80 bytes of
      // anything, then a triangle count. There is no magic for the binary
      // kind, so "not obviously something else" is the honest test.
      case 'stl': return hex.startsWith('736f6c6964') || size >= 84;
      // Text formats: a NUL in the opening bytes means it is not text.
      case 'obj':
      case 'gcode':
      case 'gco': return text();
      default: return false;
    }
  }

  /**
   * @param {object} facts  { ext, size, header, entries?: [{name, size, compressedSize}] }
   * @returns {{ok: boolean, reason: string|null}}
   */
  function verdict(facts, opts) {
    const f = facts || {};
    const o = opts || {};
    const maxBytes = num(o.maxBytes) || MAX_BYTES;
    const size = num(f.size);
    const ext = String(f.ext || '').toLowerCase();

    if (size <= 0) return refuse('empty');
    if (size > maxBytes) return refuse('too-large');
    if (!looksLikeItsName(ext, f.header, size)) return refuse('not-what-it-says');

    // Only an archive has the rest of these to answer for.
    const entries = Array.isArray(f.entries) ? f.entries : null;
    if (ext === '3mf') {
      if (!entries || entries.length === 0) return refuse('not-what-it-says');
      if (entries.length > MAX_ENTRIES) return refuse('too-many-parts');
      let unpacked = 0;
      let packed = 0;
      for (const e of entries) {
        if (unsafeName(e && e.name)) return refuse('unsafe-path');
        unpacked += Math.max(0, num(e && e.size));
        packed += Math.max(0, num(e && e.compressedSize));
      }
      if (unpacked > MAX_UNPACKED) return refuse('expands-too-far');
      // Against what ARRIVED, not against the compressed total the archive
      // reports about itself — a bomb is free to lie about the second.
      if (unpacked / Math.max(1, Math.min(packed || size, size)) > MAX_RATIO) {
        return refuse('expands-too-far');
      }
    }
    return { ok: true, reason: null };
  }

  function refuse(reason) { return { ok: false, reason }; }

  const api = { verdict, unsafeName, looksLikeItsName,
                MAX_BYTES, MAX_UNPACKED, MAX_RATIO, MAX_ENTRIES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytUploadScan = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
