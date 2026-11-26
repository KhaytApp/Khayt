'use strict';
/**
 * The "Before you update" gate on the FIRST LAUNCH after a version change:
 * which items a computer has not read yet. Shared by the Windows/Linux app
 * (lib/main/launch-gate.js, which keeps the file and the IPC) and the Mac's
 * first-launch "Khayt was updated" sheet (Figma Mac page 28), which bundles
 * this file and runs it under JavaScriptCore: no require, no I/O.
 *
 * The update dialog holds a major-change download until the shop accepts it,
 * but only electron-updater installs pass through that dialog. A Microsoft
 * Store install is updated by the Store and a manual one by its installer, so
 * both arrived at 4.11.0's "update every computer before you use product
 * rates" without a word (Dev Hub, Nov 20). This shows the same items at the
 * first start of the new version and holds the window until they are read.
 *
 * WHAT IS REMEMBERED, AND WHERE. On Windows/Linux, `last-run-version.json` in userData, per
 * COMPUTER, never in the book: the book syncs, and the whole point is that
 * one computer can be on a newer build than another.
 *
 *   { lastRun: '4.10.3', acceptedFor: '4.11.0' }
 *
 * `acceptedFor` is written when the update dialog's gate is accepted before
 * the download, so a shop that already read the items there is not asked
 * twice. The gate's items come from lib/release-gates.json (generated from
 * CHANGELOG.md by scripts/write-release-gates.js), since the CHANGELOG does
 * not ship inside the app.
 *
 * WHEN NOTHING IS REMEMBERED. A brand-new install (no book yet) has nothing
 * to be warned about. A book with no file is a shop updating from a version
 * before this existed, so it counts as coming from FLOOR, the last version
 * that shipped without the file's writer under it on every channel: every gate
 * after it, up to and including this build, is shown. Showing only this
 * build's gate (the first draft) showed NOTHING on any version without a gate
 * of its own, 4.11.1 or 4.12.0, while 4.11.0's items were still unread
 * (security and correctness reviews of #2610). A shop that already read
 * 4.11.0's items in the update dialog is asked once more; that is the safe way
 * to be wrong. The Mac passes its own `floor` (its versions are its own).
 */

(function (global) {
  const FILE = 'last-run-version.json';
  const FLOOR = '4.10.3';

  // ── Version order, for a caller with none of its own (the Mac) ──────────
  // The same order as lib/updater.js isVersionNewer (a test holds them
  // together): numbers first, then a release outranks its prereleases, and
  // prerelease identifiers compare as semver says (beta.9 < beta.10).
  const parts = (v) => String(v || '').split('-')[0].split('.').map((n) => parseInt(n, 10) || 0);
  const tag = (v) => { const s = String(v || ''); const i = s.indexOf('-'); return i < 0 ? '' : s.slice(i + 1); };
  function comparePre(a, b) {
    if (a === b) return 0;
    const pa = a.split('.'), pb = b.split('.');
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const x = pa[i], y = pb[i];
      if (x === undefined) return -1;
      if (y === undefined) return 1;
      const xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
      if (xn && yn) { const d = parseInt(x, 10) - parseInt(y, 10); if (d !== 0) return d < 0 ? -1 : 1; }
      else if (xn !== yn) return xn ? -1 : 1;
      else if (x !== y) return x < y ? -1 : 1;
    }
    return 0;
  }
  /** <0, 0 or >0 as `a` is older than, the same as, or newer than `b`. */
  function compareVersions(a, b) {
    const x = parts(a), y = parts(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
      if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0) ? 1 : -1;
    }
    const ta = tag(a), tb = tag(b);
    if (ta === tb) return 0;
    if (!ta) return 1;
    if (!tb) return -1;
    return comparePre(ta, tb);
  }
  const isNewer = (a, b) => compareVersions(a, b) > 0;

  /**
   * One version's items in `lang`, aligned by index with its English, or null
   * (English). An array of another length is not trusted at all: it was made
   * for different English, and a shifted item would warn about the wrong thing.
   */
  function translated(text, version, lang, length) {
    const l = String(lang || '');
    if (!l || l === 'en' || !text || typeof text !== 'object') return null;
    const byLang = text[version];
    const arr = byLang && typeof byLang === 'object' ? byLang[l] : null;
    return Array.isArray(arr) && arr.length === length ? arr : null;
  }

  /**
   * @param {object} o
   * @param {string} o.current          this build's version
   * @param {object|null} o.seen        the parsed file, or null
   * @param {object} o.gates            { version: [items] } (release-gates.json `gates`)
   * @param {boolean} o.hasBook         a shop's book exists (an upgrade, not a fresh install)
   * @param {(a: string, b: string) => boolean} o.isNewer  a newer than b
   * @param {string} [o.floor]        where a book with no record counts as coming from (default FLOOR, the desktop's)
 * @param {object} [o.text]         the product's translations (release-gates.json `i18n.gates` or `i18n.mac`):
 *                                   { version: { lang: [items aligned with the English] } }
 * @param {string} [o.lang]         the app's language; English when absent or not translated
   * @returns {{ items: string[], versions: string[] }}
   */
  function pending({ current, seen, gates, hasBook, isNewer, floor, text, lang, lastKnown }) {
    const none = { items: [], versions: [] };
    const cur = String(current || '');
    if (!cur) return none;
    const g = gates && typeof gates === 'object' ? gates : {};
    const s = seen && typeof seen === 'object' ? seen : null;
    const accepted = s && typeof s.acceptedFor === 'string' ? s.acceptedFor : '';
    // What the update dialog actually SHOWED when it was accepted, item by
    // item (review of 4.12.0, LOW-7). Its text came from the release, which
    // this build cannot verify, so a version mark alone would let a replaced
    // text stand in for the items this build carries. With marks, an item up
    // to `acceptedFor` counts as read only if its text here (in the language
    // it is shown in, or its English) is one the person was shown. Without
    // marks (a record from before this, the Mac's, or the first-launch
    // sheet's own accept): the version mark alone, as before.
    const marks = s && Array.isArray(s.acceptedItems) ? new Set(s.acceptedItems.filter((x) => typeof x === 'string')) : null;
    if (accepted && !marks && !isNewer(cur, accepted)) return none;   // read in the update dialog
    let from;
    if (s && typeof s.lastRun === 'string' && s.lastRun) from = s.lastRun;
    else if (!hasBook) return none;                           // a fresh install
    // No record of this file's own, but the host knows which version last
    // opened the book (the desktop's `last-app-version`, written by every
    // build since 3.11.6): count from there, so a 4.11.x book is not asked
    // about 4.11.0 again (review of 4.12.0, L1). Only a plain version is
    // believed; anything else falls back to the floor, the safe way.
    else if (typeof lastKnown === 'string' && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/.test(lastKnown.trim())) from = lastKnown.trim();
    else from = typeof floor === 'string' && floor ? floor : FLOOR;
    if (!isNewer(cur, from)) return none;                     // same build, or an older one
    const versions = Object.keys(g).filter((v) => isNewer(v, from) && !isNewer(v, cur)
      && !(accepted && !marks && !isNewer(v, accepted)));
    versions.sort((a, b) => (isNewer(a, b) ? 1 : isNewer(b, a) ? -1 : 0));  // oldest first
    const items = [];
    const seenItems = new Set();
    for (const v of versions) {
      const en = Array.isArray(g[v]) ? g[v] : [];
      const tr = translated(text, v, lang, en.length);
      const coveredByDialog = !!(marks && accepted && !isNewer(v, accepted));
      en.forEach((it, i) => {
        const x = String(it);
        const shown = tr && typeof tr[i] === 'string' && tr[i].trim() ? tr[i] : x;
        if (coveredByDialog && (marks.has(shown) || marks.has(x))) return;   // read, in these words
        // Once per ENGLISH item: the same item in two versions shows once.
        if (!seenItems.has(x)) { seenItems.add(x); items.push(shown); }
      });
    }
    // Every item already read: nothing pending for any version.
    if (!items.length) return none;
    return { items, versions: items.length ? versions : [] };
  }

  const api = { pending, translated, compareVersions, isNewer, FILE, FLOOR };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLaunchGate = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
