'use strict';
/**
 * Fill a part in from the print file it will be printed from.
 *
 * A catalog part was created with `printWeight: 0, printTime: 0` and the shop
 * typed both in by hand — while the print library sat beside it holding exactly
 * those numbers, parsed out of the g-code at import.
 *
 * The order editor is only half a step ahead: it has a print-file picker, and
 * picking a file fills in THE FILENAME and nothing else:
 *
 *     if (rec && ref && !ref.value) ref.value = rec.originalName || rec.name;
 *
 * Weight, time, material, layer height and nozzle were all sitting in the record
 * and none of them moved.
 *
 * ── Two sources, and they answer different questions ────────────────────────
 * `parsed` is what the SLICER said: print time and filament grams for that
 * exact g-code. It is the authority on the numbers, and it is empty for any file
 * the library only has metadata about — a record made from a printer's own
 * history has no file on disk to parse, which is a legitimate state and not a
 * failure.
 *
 * `setups[]` is what the SHOP found: which machine, which material, which layer
 * height, and how many of those runs came out. It is the authority on how the
 * file is actually printed, and it exists for files with no g-code at all.
 *
 * So this reads both and says WHERE EACH FIELD CAME FROM, because a weight from
 * the slicer and a weight somebody typed are not the same claim, and a shop
 * pricing a job deserves to know which it has.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  const num = (v) => {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? n : null;
  };

  /**
   * @param {object} rec     a print-file record
   * @param {string} setupId which of its setups to prefer, if any
   * @returns {{fields: object, from: object, missing: string[], setup: object|null}}
   *   `fields` is a patch to merge onto a part — only keys with a real value.
   *   `from` maps each field to 'slicer' or 'setup', so the UI can say so.
   *   `missing` names what could not be filled, so the UI can say THAT too
   *   rather than silently leaving zeros the shop believes were filled in.
   */
  function partPatch(rec, setupId) {
    const fields = {};
    const from = {};
    const missing = [];
    if (!rec) return { fields, from, missing: ['printWeight', 'printTime', 'material'], setup: null };

    const parsed = rec.parsed || {};
    const setups = Array.isArray(rec.setups) ? rec.setups : [];
    // The named setup, else the one the shop has had most success with, else the
    // first. "Most ok runs" beats "most recent": a setup that worked eleven
    // times is a better default than one tried once yesterday.
    const setup = (setupId && setups.find((s) => s.id === setupId))
      || [...setups].sort((a, b) => (b.ok || 0) - (a.ok || 0))[0]
      || null;

    const grams = num(parsed.filamentGrams);
    if (grams) { fields.printWeight = grams; from.printWeight = 'slicer'; }
    else missing.push('printWeight');

    // parsed keeps MINUTES; a part keeps HOURS. Getting this wrong by a factor
    // of sixty would not look like an error, it would look like a very fast
    // printer — so the conversion lives here, once, next to the field it feeds.
    const mins = num(parsed.printTimeMins);
    if (mins) { fields.printTime = Math.round((mins / 60) * 10000) / 10000; from.printTime = 'slicer'; }
    else missing.push('printTime');

    // Material: the setup knows what the shop actually ran, the slicer knows
    // what the file was sliced for, and the record's own field is the fallback.
    const material = (setup && setup.material) || parsed.filamentType || rec.material || '';
    if (material) {
      fields.material = material;
      from.material = (setup && setup.material) ? 'setup' : 'slicer';
    } else missing.push('material');

    if (setup) {
      const lh = num(setup.layerHeightMm);
      if (lh) { fields.layerHeight = lh; from.layerHeight = 'setup'; }
      if (setup.colour) { fields.colour = setup.colour; from.colour = 'setup'; }
      if (setup.machineId) { fields.machineId = setup.machineId; from.machineId = 'setup'; }
    }

    // Always, so the part and the file stay joined and a re-slice can be
    // followed back to the listing it feeds.
    fields.printFileId = rec.id;
    if (setup) fields.setupId = setup.id;
    if (!fields.fileRef) fields.fileRef = rec.originalName || rec.name || '';

    return { fields, from, missing, setup };
  }

  /**
   * A one-line summary of what a fill actually did, for the shop to read.
   * Deliberately says what was NOT filled: a silent partial fill leaves zeros
   * that look typed.
   */
  function describe(patch, t) {
    const tr = typeof t === 'function' ? t : () => '';
    if (!patch) return '';
    const got = Object.keys(patch.from || {}).length;
    if (!got) {
      return tr('pf.fill_none')
        || 'That file has no slicer data and no recorded setup — nothing to fill in yet.';
    }
    const parts = [];
    if (patch.from.printWeight === 'slicer' || patch.from.printTime === 'slicer') {
      parts.push(tr('pf.fill_slicer') || 'weight and time from the slicer');
    }
    if (patch.setup) {
      parts.push((tr('pf.fill_setup') || 'material and layer height from the setup')
        + (patch.setup.name ? ` "${patch.setup.name}"` : ''));
    }
    let s = (tr('pf.filled') || 'Filled in') + ' ' + parts.join(', ');
    if (patch.missing && patch.missing.length) {
      s += ' — ' + (tr('pf.fill_missing') || 'still needs') + ': ' + patch.missing.join(', ');
    }
    return s;
  }

  /**
   * Apply a patch to a part WITHOUT overwriting anything already filled in.
   *
   * Linking a print file used to record the link and nothing else: the weight
   * and the time sat at zero until the shop noticed a separate "fill" button and
   * pressed it. The numbers were one click away and looked like numbers somebody
   * had entered, which is the worst of both.
   *
   * Filling only the EMPTY fields is the same rule the nozzle threshold settled
   * on: suggest, never rewrite. A shop that weighed the part itself and typed
   * 41.5 keeps 41.5 when it links the file the part is printed from — the slicer
   * is an estimate and the scale is not.
   *
   * @returns {{applied: string[], kept: string[]}} what was filled, and what was
   *          left alone because it already had a value.
   */
  function autoFill(part, patch) {
    const out = { applied: [], kept: [] };
    if (!part || !patch || !patch.fields) return out;
    for (const [key, value] of Object.entries(patch.fields)) {
      const cur = part[key];
      // 0 and '' are "not filled in yet" for every field this touches: a part
      // that weighs nothing or takes no time is not a part.
      const empty = cur === undefined || cur === null || cur === '' || cur === 0;
      if (empty) { part[key] = value; out.applied.push(key); }
      else if (cur !== value) out.kept.push(key);
    }
    return out;
  }

  const api = { partPatch, describe, autoFill };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPartFromPrintFile = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
