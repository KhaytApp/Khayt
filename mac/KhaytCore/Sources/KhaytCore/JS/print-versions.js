'use strict';
/**
 * The versions of a print — big and small, coloured and plain.
 *
 * Three relationships hide behind the word "related", and the library needs all
 * three because they are "and", "or" and "with":
 *
 *   PARTS     head, arms, torso        printed TOGETHER — lib/print-file-parts.js
 *   VERSIONS  big, small, coloured     printed INSTEAD OF each other — this file
 *   GROUP     the Saudi Kings          kept WITH each other
 *
 * A version is not a part and not a group member. It is an alternative, and the
 * thing that makes it worth modelling rather than filing as two prints is that
 * IT HAS ITS OWN TIME AND WEIGHT. Small Spiderman and Big Spiderman cost
 * different amounts, and a shop quoting from one estimate would be wrong for
 * both — which is the whole reason Khayt measures anything.
 *
 * ── THIS IS `converted[]` GROWN UP ─────────────────────────────────────────
 * `rec.converted[]` already holds other files in the same record's vault, each
 * with its own name and size, rendered as rows on the card. It was built for
 * one case — a 3MF retargeted to another printer — but that is structurally a
 * versions list, and a second parallel list would be the fourth vocabulary for
 * one idea. `fromConverted` folds those entries in as versions named after the
 * printer they were made for.
 *
 * ── THE MIRROR, AGAIN ──────────────────────────────────────────────────────
 * The record's own `files` / `sourceFile` / `parsed` stay equal to the SELECTED
 * version's, exactly as `sourceFile` mirrors `files[0]`. Every existing reader
 * — the icon, the chips, the estimate, Open in slicer — keeps working unchanged
 * on a record that has never heard of versions and on one that has five. The
 * cost is a little redundancy; the saving is no migration to get wrong.
 *
 * Pure: no DOM, no fs.
 */
(function (global) {

  const str = (v) => String(v == null ? '' : v);
  const isVersion = (v) => !!(v && typeof v === 'object' && v.id);

  /**
   * Every version of this print, in order.
   *
   * A record that has never had a second version returns ONE — itself. That
   * keeps callers free of "if it has versions" branching everywhere: a print
   * always has at least one version, it just usually has exactly one.
   */
  function versionsOf(rec) {
    if (!rec) return [];
    const list = Array.isArray(rec.versions) ? rec.versions.filter(isVersion) : [];
    if (list.length) return list;
    const files = Array.isArray(rec.files) && rec.files.length
      ? rec.files
      : (rec.sourceFile ? [rec.sourceFile] : []);
    if (!files.length && !rec.parsed) return [];
    return [{ id: 'v1', name: '', files, parsed: rec.parsed || {}, implicit: true }];
  }

  /** The one the card is showing, and the one an estimate is about. */
  function activeVersion(rec) {
    const all = versionsOf(rec);
    if (!all.length) return null;
    const want = rec && rec.activeVersionId;
    return all.find((v) => str(v.id) === str(want)) || all[0];
  }

  /** More than one, so the card should offer a choice. */
  function hasVersions(rec) {
    return versionsOf(rec).length > 1;
  }

  /** A version id that is not already taken on this record. */
  function nextVersionId(rec) {
    const taken = new Set(versionsOf(rec).map((v) => str(v.id)));
    for (let n = 1; ; n++) if (!taken.has('v' + n)) return 'v' + n;
  }

  /**
   * Add a version, and select it.
   *
   * Adding one to a print that had none makes the print's current files an
   * explicit first version rather than discarding them — otherwise adding "the
   * small one" would silently throw away the big one nobody had named yet.
   */
  function addVersion(rec, { name, files, parsed } = {}) {
    const existing = versionsOf(rec).map((v) => {
      const { implicit, ...rest } = v;
      return rest;
    });
    const id = nextVersionId({ versions: existing });
    const version = {
      id,
      name: str(name).trim(),
      files: Array.isArray(files) ? files : [],
      parsed: parsed || {},
    };
    const versions = existing.concat([version]);
    return Object.assign({ versions }, mirror(versions, id));
  }

  /**
   * Show a different version — the card, the estimate and Open in slicer all
   * follow it.
   *
   * An id that is not there selects nothing and changes nothing, rather than
   * pointing the record at a version it does not have.
   */
  function selectVersion(rec, id) {
    const versions = versionsOf(rec);
    if (!versions.some((v) => str(v.id) === str(id))) return {};
    return Object.assign({ versions: versions.map(({ implicit, ...v }) => v) }, mirror(versions, id));
  }

  /**
   * Drop a version. The last one is never removed — a print with no version is
   * a print with no files, and this is a rename away from being a delete.
   */
  function removeVersion(rec, id) {
    const versions = versionsOf(rec).map(({ implicit, ...v }) => v);
    if (versions.length <= 1) return {};
    const kept = versions.filter((v) => str(v.id) !== str(id));
    if (kept.length === versions.length) return {};
    const activeGone = str(rec && rec.activeVersionId) === str(id);
    const nextId = activeGone ? kept[0].id : (rec && rec.activeVersionId) || kept[0].id;
    return Object.assign({ versions: kept }, mirror(kept, nextId));
  }

  /**
   * Fold `converted[]` into versions.
   *
   * Each converted file was made FROM this print for a particular printer, so
   * it is an alternative to it — which is what a version is. The original stays
   * first and stays selected; nothing about which file the card shows changes
   * just because the list gained a name.
   */
  function fromConverted(rec) {
    if (!rec || !Array.isArray(rec.converted) || !rec.converted.length) return {};
    if (Array.isArray(rec.versions) && rec.versions.length) return {};   // already done
    const base = versionsOf(rec).map(({ implicit, ...v }) => v);
    const versions = base.slice();
    for (const c of rec.converted) {
      if (!c || !c.filename) continue;
      versions.push({
        id: nextVersionId({ versions }),
        name: str(c.targetName || c.targetId).trim(),
        files: [{ filename: c.filename, originalName: c.filename, size: c.size || 0, ext: str(c.ext || '3mf').toLowerCase(), kind: 'model' }],
        parsed: {},
        fromConverted: true,
      });
    }
    if (versions.length === base.length) return {};
    return Object.assign({ versions }, mirror(versions, versions[0].id));
  }

  /** The record fields that must equal the selected version's. */
  function mirror(versions, id) {
    const v = versions.find((x) => str(x.id) === str(id)) || versions[0];
    if (!v) return { activeVersionId: null, files: [], sourceFile: null };
    return {
      activeVersionId: v.id,
      files: v.files || [],
      sourceFile: (v.files && v.files[0]) || null,
      parsed: v.parsed || {},
    };
  }

  /**
   * Write the record's current files back into the version it is showing.
   *
   * The record MIRRORS the active version — that is the whole shape here — so a
   * change to `rec.files` IS a change to that version. Without this, adding a
   * part to a print that has versions worked, saved, and looked right, and then
   * the next press of a version chip called `mirror()`, restored the frozen
   * snapshot, and the added parts were gone from the record while their bytes
   * stayed orphaned in the vault. The same path resurrected a part that had been
   * removed AND deleted from disk, leaving a row that opens nothing.
   *
   * Called after any change to a print's parts. A no-op on a record with no
   * versions, which is nearly all of them.
   *
   * @returns {{versions?: object[]}} a patch, empty when there is nothing to do
   */
  function syncActive(rec) {
    if (!rec || !Array.isArray(rec.versions) || !rec.versions.length) return {};
    const id = str(rec.activeVersionId || (rec.versions[0] && rec.versions[0].id));
    let hit = false;
    const versions = rec.versions.map((v) => {
      if (str(v.id) !== id) return v;
      hit = true;
      return Object.assign({}, v, {
        files: Array.isArray(rec.files) ? rec.files.slice() : [],
        parsed: rec.parsed || {},
      });
    });
    return hit ? { versions } : {};
  }

  const api = { versionsOf, activeVersion, hasVersions, addVersion, selectVersion, removeVersion, fromConverted, syncActive, nextVersionId };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintVersions = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
