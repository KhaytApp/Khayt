'use strict';

/**
 * Where the print-file library lives.
 *
 * The vault has always been one hardcoded folder inside the app's own data
 * directory. That is wrong for two shops in three: the models are the expensive
 * thing, they belong on the NAS everyone can reach, and a laptop's app-support
 * folder is the one place a backup regime never looks. On macOS a mounted share
 * and a synced folder (iCloud Drive, Dropbox, Google Drive, OneDrive) are both
 * just paths, so one setting covers "network drive" and "online provider"
 * without the app learning to speak any protocol.
 *
 * Two settings, deliberately separate:
 *
 *   root    where files are READ AND WRITTEN. Empty = this Mac, as before.
 *   mirror  a second copy written after every successful write. Never read from.
 *           A backup you read from is not a backup, it is a second primary, and
 *           the two drift.
 *
 * FAILS CLOSED. If a configured root is not there — share not mounted, laptop
 * away from the shop — every operation refuses and says which folder is missing.
 * It does NOT quietly fall back to the local vault: that produces two libraries
 * with no way to tell which holds what, and the shop finds out weeks later when
 * half their models are on the wrong machine.
 *
 * CONFINEMENT SPANS ROOTS. Handlers confine every path to the library, and a
 * record written before the location changed still points at the old folder. So
 * "inside the library" means inside ANY root this install knows about — the
 * configured one, the mirror, and always the built-in default — or moving the
 * library would make yesterday's files unreadable rather than merely relocated.
 *
 * Pure: no fs, no Electron. The caller supplies the default root and does the
 * probing, which is what keeps this testable.
 */

const { under } = require('./convert-paths');

const str = (v) => String(v == null ? '' : v).trim();

/**
 * The root of a disk — `/`, `C:\` — is never a library folder.
 *
 * Every root here comes out of settings, and settings arrive in a restored
 * backup and over cloud sync. A library "at /" would make insideLibrary() true
 * for every file on the machine, which is what printlib-delete confines itself
 * with, and would have a migration walk the whole disk as its source. Dropped
 * wherever it appears; a configured primary that is a drive root falls back to
 * the built-in folder, exactly as an empty one does.
 */
const path = require('path');
function isDriveRoot(p) {
  const s = str(p);
  if (!s) return false;
  const r = path.resolve(s);
  return path.parse(r).root === r;
}

/**
 * The folders this install considers part of its library.
 *
 * @param {{root?: string, mirror?: string}} settings  from settings.printLibrary
 * @param {string} defaultRoot                         the built-in vault path
 * @returns {{primary: string, mirror: string|null, isCustom: boolean, roots: string[]}}
 */
function resolveRoots(settings, defaultRoot) {
  const s = settings && typeof settings === 'object' ? settings : {};
  const base = str(defaultRoot);
  const configured = isDriveRoot(s.root) ? '' : str(s.root);
  const mirror = isDriveRoot(s.mirror) ? '' : str(s.mirror);
  const primary = configured || base;
  // The default is always a known root even when a custom one is set: files put
  // there before the move are still this library's files.
  //
  // So is every folder the library has previously lived in. Without the history
  // a SECOND move orphans the first custom folder — it drops out of this list,
  // insideLibrary() starts refusing paths inside it, and files that were merely
  // in the wrong place become unreadable. Recorded on the way out by
  // print-library-migrate's rememberRoot().
  const past = (Array.isArray(s.history) ? s.history : []).map(str).filter((r) => r && !isDriveRoot(r));
  const roots = [];
  for (const r of [primary, base, mirror, ...past]) {
    if (r && !roots.includes(r)) roots.push(r);
  }
  return {
    primary,
    mirror: mirror && mirror !== primary ? mirror : null,
    isCustom: !!configured && configured !== base,
    roots,
  };
}

/**
 * Is this path part of the library, wherever the library currently lives?
 * @param {string} p
 * @param {string[]} roots  from resolveRoots().roots
 */
function insideLibrary(p, roots) {
  const target = str(p);
  if (!target) return false;
  return (Array.isArray(roots) ? roots : []).some((r) => r && under(target, r));
}

/**
 * Turn a caller's fs probe into a verdict.
 *
 * Split from the probing itself so the decision is testable without a disk. The
 * caller answers three questions; this says what they mean together.
 *
 * @param {{exists: boolean, isDirectory: boolean, writable: boolean}} probe
 * @returns {{ok: boolean, reason: 'ok'|'missing'|'not-a-directory'|'not-writable'}}
 */
function verdict(probe) {
  const p = probe || {};
  if (!p.exists) return { ok: false, reason: 'missing' };
  if (!p.isDirectory) return { ok: false, reason: 'not-a-directory' };
  if (!p.writable) return { ok: false, reason: 'not-writable' };
  return { ok: true, reason: 'ok' };
}

/**
 * What to tell the shop when a location will not serve.
 *
 * Names the folder every time. "The library is unavailable" sends someone to the
 * app's preferences; "/Volumes/shop-nas/khayt is not mounted" sends them to the
 * Finder, which is where the problem actually is.
 */
function explain(reason, root) {
  const where = str(root) || 'the print library folder';
  switch (reason) {
    case 'missing':
      return `Print library folder not found: ${where}. If it is on a network drive or an external disk, connect it and try again.`;
    case 'not-a-directory':
      return `The print library location is not a folder: ${where}.`;
    case 'not-writable':
      return `No permission to write to the print library folder: ${where}.`;
    default:
      return '';
  }
}

/**
 * Where a record's files go under a given root. Mirrors main.js's own id
 * sanitising so a mirror lands beside the primary rather than in a differently
 * named folder.
 */
function itemDirName(id) {
  const base = str(id).split(/[\\/]/).pop() || '';
  return base.replace(/[^a-zA-Z0-9_-]/g, '_') || 'unsorted';
}

module.exports = { resolveRoots, insideLibrary, verdict, explain, itemDirName };
