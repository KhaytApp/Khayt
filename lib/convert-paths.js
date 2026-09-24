'use strict';
/**
 * Where the 3MF converter may read from, and where it may write to.
 *
 * These are two different questions and they were being answered by one function.
 * Reading is broad on purpose: a maker downloads a model and expects the converter to
 * open it, so the app's own folders plus Documents/Downloads/Desktop are all fair game,
 * along with any file picked through our own open dialog.
 *
 * Writing is not. A write needs consent for that destination — either the user typed the
 * path into our save dialog (in which case nothing here is consulted; their choice is the
 * authority) or it sits under a folder they chose in the output-folder picker, which
 * exists so batch conversion can produce many files without a dialog per file.
 *
 * Using the READ list to authorise writes let the renderer name any path under userData,
 * Documents, Downloads, Desktop or temp — any filename, any extension — and have the main
 * process write there with no dialog shown, including next to the app's own store. The
 * renderer is sandboxed and context-isolated, so that needs a renderer compromise first;
 * but keeping file writes in the main process is precisely so a compromised renderer
 * still cannot choose where they land.
 *
 * Pure: no fs, no Electron. The caller resolves symlinks and supplies the real directories
 * (see main.js), which is what keeps this testable.
 */
const path = require('path');

/** Windows compares paths case-insensitively; comparing raw strings there refuses valid paths. */
function norm(p) {
  const r = path.resolve(String(p || ''));
  return process.platform === 'win32' ? r.toLowerCase() : r;
}

/**
 * Is `child` the directory `dir` itself, or something inside it?
 *
 * Compares resolved paths and requires a separator after the prefix, so `/home/user-data`
 * is not treated as living under `/home/user`.
 */
function under(child, dir) {
  const c = norm(child);
  const d = norm(dir);
  // A drive root already ends in the separator — `/`, `C:\` — so appending one
  // made `//` and `C:\\`, and nothing was ever under the root of a disk. In
  // print-library-migrate's sources() that failed OPEN: a root that contains
  // the library was not recognised as containing it.
  const base = d.endsWith(path.sep) ? d : d + path.sep;
  return c === d || c.startsWith(base);
}

/**
 * @param {string} p
 * @param {{approvedSources?: Iterable<string>, approvedDirs?: Iterable<string>, appDirs?: Iterable<string>}} ctx
 */
function readAllowed(p, ctx = {}) {
  if (!p) return false;
  const safe = norm(p);
  for (const s of ctx.approvedSources || []) if (norm(s) === safe) return true;
  for (const d of ctx.approvedDirs || []) if (under(safe, d)) return true;
  for (const d of ctx.appDirs || []) if (under(safe, d)) return true;
  return false;
}

/**
 * May we write here WITHOUT asking? Only under a folder the user picked as an output
 * folder. Deliberately does not consult appDirs or approvedSources: being allowed to
 * read a folder is not permission to put files in it.
 *
 * @param {string} p
 * @param {{approvedDirs?: Iterable<string>}} ctx
 */
function writeAllowed(p, ctx = {}) {
  if (!p) return false;
  const safe = norm(p);
  for (const d of ctx.approvedDirs || []) if (under(safe, d)) return true;
  return false;
}

module.exports = { under, readAllowed, writeAllowed };
