'use strict';
/**
 * Where a print file's thumbnail lives — and why it stopped living in the store.
 *
 * ── THE MEASUREMENT THAT DECIDED THIS ──────────────────────────────────────
 * A realistic print-file record is 914 bytes. The same record carrying its
 * thumbnail as a base64 data URL is 14,900 bytes, so THE PICTURE IS 94% OF THE
 * RECORD. The store is one encrypted JSON document with a hard 50 MB ceiling on
 * both read and write (lib/store-io.js), which puts the wall here:
 *
 *      files    thumbs in store    thumbs on disk
 *      1,000          14.2 MB            0.9 MB
 *      3,000          42.7 MB            2.7 MB
 *      5,000          71.1 MB  ✗         4.4 MB
 *     10,000         142.2 MB  ✗         8.9 MB
 *
 * Past the ceiling `hub:save-store` returns {ok:false} and the renderer raises
 * "Save failed" on every edit — loudly, not silently, because that was fixed
 * once already. But an app that cannot save is a shop that loses its day's work
 * at the next launch, so the ceiling is a data-safety problem and not merely a
 * performance one.
 *
 * With the picture on disk, ten thousand files is 8.9 MB — a fifth of the
 * ceiling. NO DATABASE IS NEEDED; the store was never big, its images were.
 *
 * ── THE SAFETY RULE, WHICH IS THE WHOLE POINT ──────────────────────────────
 * A thumbnail already in the store is DATA. Moving it is a copy, a verified
 * read-back, and only then a delete — never a delete on the strength of a write
 * having been attempted. `planMigration` and `completeMigration` are separate
 * calls for exactly that reason: nothing here can drop the in-store copy
 * without being handed proof that the on-disk one reads back.
 *
 * The vault folder is per record already (userData/print-files-vault/<id>/), so
 * the picture ends up beside the model files it describes.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /** The name a record's thumbnail takes inside its own vault folder. */
  const THUMB_NAME = 'thumb.jpg';

  /** A data URL big enough to be worth moving out of the store. */
  const isDataUrl = (v) => typeof v === 'string' && /^data:image\/(png|jpe?g|webp);base64,/.test(v);

  /**
   * Which records still carry their picture in the store.
   *
   * @param {Array} records
   * @returns {Array<{id: string, dataUrl: string, bytes: number}>}
   */
  function planMigration(records) {
    const out = [];
    for (const r of (records || [])) {
      if (!r || !r.id || !isDataUrl(r.thumb)) continue;
      out.push({ id: String(r.id), dataUrl: r.thumb, bytes: r.thumb.length });
    }
    return out;
  }

  /**
   * Move one record onto its on-disk picture — ONLY when it has been read back.
   *
   * @param {object} rec
   * @param {{filename: string, verified: boolean}} result  what the write returned
   * @returns {{thumb: undefined|string, thumbFile: string|undefined, migrated: boolean}}
   *   a patch to merge. When `verified` is false the record is returned
   *   UNCHANGED and keeps its in-store picture: a failed move must cost nothing
   *   but the attempt.
   */
  function completeMigration(rec, result) {
    if (!rec || !result || !result.verified || !result.filename) {
      return { thumb: rec ? rec.thumb : undefined, migrated: false };
    }
    return { thumb: undefined, thumbFile: String(result.filename), migrated: true };
  }

  /**
   * What a card should show, and where it has to come from.
   *
   * `store` needs nothing further — the picture is already in hand. `disk`
   * means the caller must fetch it, which it should do in one batch for the
   * rows it is about to draw rather than once per card.
   *
   * @returns {{kind: 'store'|'disk'|'none', src?: string, file?: string}}
   */
  function thumbSource(rec) {
    if (!rec) return { kind: 'none' };
    if (isDataUrl(rec.thumb)) return { kind: 'store', src: rec.thumb };
    if (rec.userPhoto && isDataUrl(rec.userPhoto)) return { kind: 'store', src: rec.userPhoto };
    if (rec.thumbFile) return { kind: 'disk', file: String(rec.thumbFile) };
    return { kind: 'none' };
  }

  /** How much of the store a library's pictures are using, for the report. */
  function storeBytesUsedByThumbs(records) {
    return planMigration(records).reduce((n, x) => n + x.bytes, 0);
  }

  const api = { THUMB_NAME, planMigration, completeMigration, thumbSource, storeBytesUsedByThumbs, isDataUrl };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytThumbStore = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
