'use strict';
/**
 * A print that is made of several files.
 *
 * Spiderman is a head, a right arm, a left arm and a torso, and it is ONE
 * thing you print — not four. The library modelled a record as exactly one
 * file (`rec.sourceFile`), so a kit downloaded as ten STLs became ten entries
 * that nothing tied together, and the zip importer said so outright: "a
 * six-part pack becomes six records".
 *
 * ── THE SHAPE, AND WHY IT IS ADDITIVE ──────────────────────────────────────
 * `rec.files[]` is the list. `rec.sourceFile` STAYS, and stays equal to
 * `files[0]`.
 *
 * That redundancy is deliberate and is the whole safety property here.
 * `sourceFile` is read in twenty places — the icon, the size chip, which
 * actions a card offers, which file "Open in slicer" resolves — and a record
 * written before any of this existed has no `files` at all. Keeping the primary
 * where it has always been means every one of those readers keeps working,
 * unchanged, on old and new records alike, and there is no migration to get
 * wrong. A reader that wants the whole print asks for it; a reader that wants
 * "the file this card is about" carries on as before.
 *
 * ── WHAT THE PRIMARY IS FOR ────────────────────────────────────────────────
 * The first part answers the questions a card asks of one file: what kind of
 * file is this, what does it open in, what does its thumbnail look like. On a
 * multi-part print that is a choice rather than a fact, so it is the shop's:
 * the first file added is the primary until they say otherwise.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  const isFile = (f) => !!(f && typeof f === 'object' && f.filename);

  /**
   * Every file this print is made of, in order, primary first.
   *
   * @param {object} rec  a print-file record
   * @returns {object[]} never null; a record with no file on this computer —
   *   a legitimate state, made from a printer's own history — yields [].
   */
  function partsOf(rec) {
    if (!rec) return [];
    if (Array.isArray(rec.files) && rec.files.length) {
      const files = rec.files.filter(isFile);
      /* ── A WRITER THAT ONLY KNOWS `sourceFile` ────────────────────────────
       * `sourceFile` is kept equal to `files[0]` by everything in this app, so
       * on a record we wrote they agree. Two writers do not know that:
       *
       *   the older build's "Identify" (v3.7.0-beta.24 and before), which sets
       *   `rec.sourceFile` when a record has no file on this computer and never
       *   touches `files`;
       *
       *   the same call in this build — a gap the review found and I have not
       *   closed yet.
       *
       * Sync merges whole records last-writer-wins, so such a record travels
       * between machines intact and disagreeing. Preferring `files` blindly
       * dropped the file the shop had just chosen; preferring `sourceFile`
       * blindly would drop every other part of a multi-part print.
       *
       * Both are kept, primary first. Nothing is lost, and the file somebody
       * most recently pointed at is the one the card speaks for.
       */
      if (isFile(rec.sourceFile)
        && !files.some((f) => String(f.filename) === String(rec.sourceFile.filename))) {
        return [rec.sourceFile, ...files];
      }
      return files;
    }
    return isFile(rec.sourceFile) ? [rec.sourceFile] : [];
  }

  /** The one file a card speaks for. */
  function primaryOf(rec) {
    return partsOf(rec)[0] || null;
  }

  /** More than one file, so the card should say so. */
  function isMultiPart(rec) {
    return partsOf(rec).length > 1;
  }

  /** What the whole print weighs on disk, for the size chip. */
  function totalSize(rec) {
    return partsOf(rec).reduce((n, f) => n + (Number(f.size) || 0), 0);
  }

  /**
   * The fields to merge onto a record to add files to it.
   *
   * Returns a patch rather than mutating, so a caller decides when the record
   * changes — the save and the re-render are the caller's to sequence.
   *
   * A file already on the record (same vault filename) is not added twice: the
   * import path can be re-run over an archive, and a second copy of one part
   * would be indistinguishable on the card from a real second part.
   *
   * @param {object} rec
   * @param {object|object[]} incoming  file descriptor(s)
   * @returns {{files: object[], sourceFile: object|null}}
   */
  function addParts(rec, incoming) {
    const have = partsOf(rec);
    const seen = new Set(have.map((f) => String(f.filename)));
    const add = (Array.isArray(incoming) ? incoming : [incoming]).filter(isFile);
    const files = have.slice();
    for (const f of add) {
      if (seen.has(String(f.filename))) continue;
      seen.add(String(f.filename));
      files.push(f);
    }
    return { files, sourceFile: files[0] || null };
  }

  /**
   * Drop one file from a print.
   *
   * Removing the primary promotes the next one rather than leaving the record
   * pointing at a file that is gone — which is what every `sourceFile` reader
   * would then be looking at.
   */
  function removePart(rec, filename) {
    const files = partsOf(rec).filter((f) => String(f.filename) !== String(filename));
    return { files, sourceFile: files[0] || null };
  }

  /** Make one of the parts the one the card speaks for. */
  function makePrimary(rec, filename) {
    const parts = partsOf(rec);
    const i = parts.findIndex((f) => String(f.filename) === String(filename));
    if (i <= 0) return { files: parts, sourceFile: parts[0] || null };
    const files = [parts[i], ...parts.slice(0, i), ...parts.slice(i + 1)];
    return { files, sourceFile: files[0] };
  }

  const api = { partsOf, primaryOf, isMultiPart, totalSize, addParts, removePart, makePrimary };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintParts = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
