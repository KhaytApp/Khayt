(function (global) {
'use strict';
/**
 * Which library models still need their bytes hashed, so Library Health can
 * group duplicates the import never hashed.
 *
 * `contentHash` (SHA-256 of the bytes, lib/model-identity.js) is what makes
 * two files "the same file" in Library Health (lib/library-health.js), and a
 * rename does not change it. The desktop hashes a model when it is imported or
 * brought down from the cloud; models older than that, or added by another
 * device, carry none and never join a group. This plans a background run over
 * them: the app reads each file in chunks (lib/main/stream-hash.js) and writes
 * ONLY `contentHash` back. Nothing is merged, moved or removed here or there —
 * a duplicate group is shown, and deleting stays the library's own explicit
 * delete, on what the shop can see and has selected (the Sep 27 incident).
 *
 * RESUMABLE BY CONSTRUCTION: a model that has its hash is never planned again,
 * so a run that is stopped, or that the app quits during, picks up where it
 * left off the next time.
 *
 * PURE: facts in, a plan out. No disk, no clock, no store.
 */

/** The most bytes one file may be (main.js PRINT_FILE_MAX_BYTES). */
const MAX_FILE_BYTES = 1024 * 1024 * 1024;
/** Per run: at most this many files, and this many bytes in all. */
const RUN_MAX_FILES = 500;
const RUN_MAX_BYTES = 8 * 1024 * 1024 * 1024;

const str = (v) => (typeof v === 'string' ? v.trim() : '');

/**
 * @param {Array<{id:string, filename?:string, size?:number, presence?:string,
 *   contentHash?:string|null, archived?:boolean, linked?:boolean, addedAt?:number}>} models
 *   `presence` is what Library Health found: 'here' (the bytes are on this
 *   computer), 'online', 'missing', 'unreachable', 'web' or 'unknown'.
 *   `linked` is a record whose bytes live outside the library folder (the
 *   Mac's linked folders and archive members): not this computer's to read.
 * @param {{maxFileBytes?:number, maxFiles?:number, maxBytes?:number}} [opts]
 * @returns {{todo: Array<{id:string, filename:string, size:number}>,
 *   later: number, skipped: {tooBig:number, notHere:number, linked:number}}}
 *   `todo` is newest first; `later` counts what is due but past this run's caps.
 */
function plan(models, opts) {
  const o = opts || {};
  const maxFile = Number.isFinite(o.maxFileBytes) ? o.maxFileBytes : MAX_FILE_BYTES;
  const maxFiles = Number.isFinite(o.maxFiles) ? o.maxFiles : RUN_MAX_FILES;
  const maxBytes = Number.isFinite(o.maxBytes) ? o.maxBytes : RUN_MAX_BYTES;
  const skipped = { tooBig: 0, notHere: 0, linked: 0 };
  const due = [];
  const seen = new Set();
  for (const m of Array.isArray(models) ? models : []) {
    if (!m || typeof m !== 'object') continue;
    const id = str(m.id);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    if (str(m.contentHash) || m.archived) continue;
    if (m.linked) { skipped.linked++; continue; }
    const filename = str(m.filename);
    if (!filename) continue;                       // no file named: nothing to hash
    if (m.presence !== 'here') { skipped.notHere++; continue; }   // never fetch to hash
    const size = Number(m.size);
    if (!Number.isFinite(size) || size <= 0) continue;            // empty is not a model
    if (size > maxFile) { skipped.tooBig++; continue; }
    due.push({ id, filename, size, addedAt: Number(m.addedAt) || 0 });
  }
  due.sort((a, b) => (b.addedAt - a.addedAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const todo = [];
  let bytes = 0;
  let later = 0;
  for (const d of due) {
    if (todo.length >= maxFiles || bytes + d.size > maxBytes) { later++; continue; }
    bytes += d.size;
    todo.push({ id: d.id, filename: d.filename, size: d.size });
  }
  return { todo, later, skipped };
}

/** A hash as the library stores it: 64 lower-case hex, or nothing. */
function isHash(v) { return typeof v === 'string' && /^[0-9a-f]{64}$/.test(v); }

/**
 * What a finished hash writes to its record: `contentHash` and nothing else,
 * and only when the record still names the file that was read and has no hash
 * of its own yet (an import or another device may have set one meanwhile).
 * `null` means write nothing.
 */
function patchFor(record, read) {
  if (!record || !read || !isHash(read.contentHash)) return null;
  if (str(record.contentHash)) return null;
  const named = record.sourceFile && str(record.sourceFile.filename);
  if (!named || named !== str(read.filename)) return null;
  return { contentHash: read.contentHash };
}

const api = { MAX_FILE_BYTES, RUN_MAX_FILES, RUN_MAX_BYTES, plan, patchFor, isHash };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytLibraryHashPlan = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
