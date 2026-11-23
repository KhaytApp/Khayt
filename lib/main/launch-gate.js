'use strict';
/**
 * The "Before you update" gate on the first launch after a version change,
 * the Windows/Linux side: `last-run-version.json` in userData and the IPC.
 * The rule itself (which items are still unread) is lib/launch-gate.js,
 * shared with the Mac, which bundles it; see there for why it exists and what
 * the file holds.
 */

const { pending, FILE, FLOOR } = require('../launch-gate.js');

/**
 * The main-process side: read and write the file, and register the IPC.
 * `deps`: { ipcMain, userDataDir, current, gates, text, hasBook(), isNewer, fs, path }
 * (`text`: release-gates.json `i18n.gates`, the items in each language)
 */
function registerLaunchGate(deps) {
  const { ipcMain, userDataDir, current, gates, hasBook, isNewer } = deps;
  const offered = typeof deps.offeredVersion === 'function' ? deps.offeredVersion : () => '';
  const fs = deps.fs || require('fs');
  const path = deps.path || require('path');
  const file = path.join(userDataDir(), FILE);
  const read = () => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; } };
  const write = (patch) => {
    const next = Object.assign({}, read() || {}, patch);
    try { fs.writeFileSync(file, JSON.stringify(next)); } catch (e) { console.error('launch gate: could not write', e && e.message); }
  };

  ipcMain.handle('hub:launch-gate', (_e, lang) => {
    // The window's language picks the items' text; anything else is English.
    const l = typeof lang === 'string' && /^[a-z]{2}(?:-[A-Z]{2})?$/.test(lang) ? lang : '';
    const p = pending({ current, seen: read(), gates, hasBook: !!hasBook(), isNewer, text: deps.text || null, lang: l });
    // Nothing to read: this version has been seen, from now on.
    if (!p.items.length) write({ lastRun: current });
    return { version: current, items: p.items };
  });
  ipcMain.handle('hub:launch-gate-accept', () => { write({ lastRun: current, acceptedFor: current }); return { ok: true }; });
  // The update dialog's gate was accepted for `version` before the download.
  ipcMain.handle('hub:launch-gate-accepted-in-update', (_e, version) => {
    const v = String(version || '').trim();
    if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?$/.test(v)) return { ok: false };
    // Only a version the updater itself offered (or older): never one the
    // window made up, which would silence every gate up to it.
    const top = String(offered() || '');
    if (!top || isNewer(v, top) || !isNewer(v, current)) return { ok: false, error: 'not_offered' };
    write({ acceptedFor: v });
    return { ok: true };
  });
}

module.exports = { pending, registerLaunchGate, FILE, FLOOR };
