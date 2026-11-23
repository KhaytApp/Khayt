'use strict';
/**
 * The pre-download "Before you update" items in the shop's language, from
 * the NEW release's own release-gates.json (Dev Hub, Nov 23).
 *
 * The update dialog reads the new release's notes from GitHub, in English:
 * the installed build cannot carry translations of a version that did not
 * exist when it was built. So every release publishes its generated
 * lib/release-gates.json as a release asset (.github/workflows/release.yml),
 * and the dialog looks its English items up in that file's `i18n`. The Mac's
 * update sheet (frame C) reads the same asset, so this is pure and loads
 * under JavaScriptCore.
 *
 * MATCHED BY THE ENGLISH TEXT, not by version or position: the dialog's items
 * come from the release notes since this build (lib/updater.js notesSince),
 * which may span several versions. Each English item is found in the asset's
 * English lists and its translation at the same index is taken. An item the
 * asset does not hold, a language it does not have, or an asset that is not
 * what it should be: that item, or every item, stays English. Never blocks:
 * a bad asset is simply no translation.
 */
(function (global) {
  const LANG = /^[a-z]{2}(?:-[A-Z]{2})?$/;

  /**
   * @param {string[]} items     the dialog's English items
   * @param {object} asset       the parsed release-gates.json, or anything
   * @param {string} lang        the app's language
   * @param {'gates'|'mac'} [product]
   * @returns {string[]|null}    the items in `lang` (English where missing), or null when nothing is translated
   */
  function translateItems(items, asset, lang, product) {
    const key = product === 'mac' ? 'mac' : 'gates';
    const l = String(lang || '');
    if (!Array.isArray(items) || !items.length || !LANG.test(l) || l === 'en') return null;
    if (!asset || typeof asset !== 'object' || !asset.i18n || typeof asset.i18n !== 'object') return null;
    const en = asset[key], tr = asset.i18n[key];
    if (!en || typeof en !== 'object' || !tr || typeof tr !== 'object') return null;
    const lookup = new Map();
    for (const v of Object.keys(en)) {
      const eng = en[v], arr = tr[v] && tr[v][l];
      if (!Array.isArray(eng) || !Array.isArray(arr) || arr.length !== eng.length) continue;
      eng.forEach((e, i) => {
        if (typeof e === 'string' && typeof arr[i] === 'string' && arr[i].trim() && !lookup.has(e)) lookup.set(e, arr[i]);
      });
    }
    let any = false;
    const out = items.map((it) => {
      const t = lookup.get(String(it));
      if (t) { any = true; return t; }
      return String(it);
    });
    return any ? out : null;
  }

  const api = { translateItems, ASSET_NAME: 'release-gates.json', MAX_BYTES: 512 * 1024 };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytUpdateGateText = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
