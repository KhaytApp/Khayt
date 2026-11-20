'use strict';
/**
 * The "Before you update" gate, on the FIRST LAUNCH after a version change.
 *
 * The update dialog holds a major-change download until the shop accepts it,
 * but only electron-updater installs pass through that dialog. A Microsoft
 * Store install is updated by the Store and a manual one by its installer, so
 * both arrived at 4.11.0's "update every computer before you use product
 * rates" without a word (Dev Hub, Nov 20). This shows the same items at the
 * first start of the new version and holds the window until they are read.
 *
 * WHAT IS REMEMBERED, AND WHERE. `last-run-version.json` in userData, per
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
 * before this existed: its starting version is unknown, so it is shown the
 * current version's items, the fail-safe the update dialog also takes for a
 * gap it cannot read.
 */

const FILE = 'last-run-version.json';

/**
 * @param {object} o
 * @param {string} o.current          this build's version
 * @param {object|null} o.seen        the parsed file, or null
 * @param {object} o.gates            { version: [items] } (release-gates.json `gates`)
 * @param {boolean} o.hasBook         a shop's book exists (an upgrade, not a fresh install)
 * @param {(a: string, b: string) => boolean} o.isNewer  a newer than b
 * @returns {{ items: string[], versions: string[] }}
 */
function pending({ current, seen, gates, hasBook, isNewer }) {
  const none = { items: [], versions: [] };
  const cur = String(current || '');
  if (!cur) return none;
  const g = gates && typeof gates === 'object' ? gates : {};
  const s = seen && typeof seen === 'object' ? seen : null;
  const accepted = s && typeof s.acceptedFor === 'string' ? s.acceptedFor : '';
  if (accepted && !isNewer(cur, accepted)) return none;   // read in the update dialog
  let versions;
  if (s && typeof s.lastRun === 'string' && s.lastRun) {
    if (!isNewer(cur, s.lastRun)) return none;             // same build, or an older one
    versions = Object.keys(g).filter((v) => isNewer(v, s.lastRun) && !isNewer(v, cur)
      && !(accepted && !isNewer(v, accepted)));
  } else {
    if (!hasBook) return none;                              // a fresh install
    versions = Object.prototype.hasOwnProperty.call(g, cur) ? [cur] : [];
  }
  versions.sort((a, b) => (isNewer(a, b) ? 1 : isNewer(b, a) ? -1 : 0));  // oldest first
  const items = [];
  const seenItems = new Set();
  for (const v of versions) {
    for (const it of Array.isArray(g[v]) ? g[v] : []) {
      const x = String(it);
      if (!seenItems.has(x)) { seenItems.add(x); items.push(x); }
    }
  }
  return { items, versions: items.length ? versions : [] };
}

/**
 * The main-process side: read and write the file, and register the IPC.
 * `deps`: { ipcMain, userDataDir, current, gates, hasBook(), isNewer, fs, path }
 */
function registerLaunchGate(deps) {
  const { ipcMain, userDataDir, current, gates, hasBook, isNewer } = deps;
  const fs = deps.fs || require('fs');
  const path = deps.path || require('path');
  const file = path.join(userDataDir(), FILE);
  const read = () => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } };
  const write = (patch) => {
    const next = Object.assign({}, read() || {}, patch);
    try { fs.writeFileSync(file, JSON.stringify(next)); } catch (e) { console.error('launch gate: could not write', e && e.message); }
  };

  ipcMain.handle('hub:launch-gate', () => {
    const p = pending({ current, seen: read(), gates, hasBook: !!hasBook(), isNewer });
    // Nothing to read: this version has been seen, from now on.
    if (!p.items.length) write({ lastRun: current });
    return { version: current, items: p.items };
  });
  ipcMain.handle('hub:launch-gate-accept', () => { write({ lastRun: current, acceptedFor: current }); return { ok: true }; });
  // The update dialog's gate was accepted for `version` before the download.
  ipcMain.handle('hub:launch-gate-accepted-in-update', (_e, version) => {
    const v = String(version || '').trim();
    if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/.test(v)) return { ok: false };
    write({ acceptedFor: v });
    return { ok: true };
  });
}

module.exports = { pending, registerLaunchGate, FILE };
