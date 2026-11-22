'use strict';
(function (global) {

/**
 * Planning what comes out of a dropped .zip.
 *
 * Model packs arrive as archives — a Google Drive download, a Patreon bundle, a
 * MakerWorld pack — and Khayt could not open one. Every file had to be unzipped
 * by hand first, into a folder, and dragged in one at a time.
 *
 * This decides WHAT to take. lib/zip-read.js does the reading (dependency-free,
 * central-directory driven, never throws) and main.js does the writing. Keeping
 * the decision here is what lets the nasty cases be tested without a real
 * archive on disk.
 *
 * The three that matter, in order of how badly they end:
 *
 *   ZIP SLIP     A member is named `../../../.ssh/authorized_keys`. Joining that
 *                onto a destination writes outside it. The defence here is not
 *                sanitising the path — it is refusing to use the member's path
 *                AT ALL. Only the basename survives, so there is nothing left to
 *                traverse with.
 *   ZIP BOMB     A few KB inflating to gigabytes. zip-read caps each member;
 *                this caps the CUMULATIVE total and the member count, the same
 *                way lib/mf-convert.js does for a multi-entry 3MF.
 *   SILENT LOSS  A budget that drops files without saying so. mf-convert learned
 *                this from a real 229 MB poster that lost an object to a limit
 *                nobody was told about. Everything not taken comes back in
 *                `skipped` with a reason, and hitting a cap sets `truncated`.
 *
 * Pure: no fs, no zlib, no DOM.
 */

/** What Khayt can actually do something with — the same set intake accepts. */
const PRINT_EXT = /\.(stl|3mf|obj|gcode|gco)$/i;

/**
 * Budgets. Deliberately generous: a model pack is big, and the failure mode of a
 * tight limit is a shop silently losing part of what they downloaded.
 */
const MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024;   // matches mf-convert's 2 GiB
/* What one member may actually inflate to, from the module that enforces it.
 * Read rather than repeated, because the bug this fixes was these two numbers
 * disagreeing. */
const MAX_INFLATED = (typeof require === 'function'
  ? require('./zip-read.js').MAX_INFLATED
  : (typeof globalThis !== 'undefined' && globalThis.KhaytZip && globalThis.KhaytZip.MAX_INFLATED)) || (400 * 1024 * 1024);
const MAX_MEMBERS = 512;                          // print files, not zip members

const str = (v) => String(v == null ? '' : v).trim();

/**
 * The name a member is allowed to be written as.
 *
 * Basename only. Not "strip leading ../", not "resolve and check it stayed
 * inside" — those are defences that have to be right every time. Taking the
 * basename leaves no path to traverse with in the first place.
 *
 * Backslashes count as separators too: a zip written on Windows uses them, and a
 * reader that only splits on "/" hands `..\..\evil` straight through.
 */
function safeName(raw, taken) {
  const base = str(raw).split(/[\\/]/).pop() || '';
  // A member called "..", "." or "" has no usable name of its own.
  let name = /^\.+$/.test(base) ? '' : base;
  name = name.replace(/[\u0000-\u001f\u007f]/g, '');   // control chars, incl. NUL
  if (!name) name = 'file';
  const held = new Set((Array.isArray(taken) ? taken : []).map((t) => str(t).toLowerCase()));
  if (!held.has(name.toLowerCase())) return name;
  // Two members can share a basename once their folders are gone (parts/a.stl
  // and spares/a.stl). Suffix before the extension so the file still opens.
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : '';
  for (let n = 2; n < 1000; n += 1) {
    const cand = `${stem} (${n})${ext}`;
    if (!held.has(cand.toLowerCase())) return cand;
  }
  return `${stem} (${Date.now().toString(36)})${ext}`;
}

/**
 * Decide what to extract from a zip's entry list.
 *
 * @param {Array} entries  from zipRead.listEntries() — {name, size, ...}
 * @param {{maxBytes?: number, maxMembers?: number}} [opts]
 * @returns {{take: Array, skipped: Array, bytes: number, truncated: boolean}}
 */
function plan(entries, opts) {
  const o = opts && typeof opts === 'object' ? opts : {};
  const maxBytes = Number.isFinite(o.maxBytes) ? o.maxBytes : MAX_TOTAL_BYTES;
  const maxMembers = Number.isFinite(o.maxMembers) ? o.maxMembers : MAX_MEMBERS;

  const take = [];
  const skipped = [];
  const taken = [];
  let bytes = 0;
  let truncated = false;

  for (const e of (Array.isArray(entries) ? entries : [])) {
    const raw = str(e && e.name);
    if (!raw) continue;
    // Directory entries carry a trailing slash and no content.
    if (/[\\/]$/.test(raw)) continue;
    // macOS archives carry a __MACOSX shadow tree of AppleDouble stubs. They
    // match no print extension anyway, but naming them keeps the skip list
    // readable instead of burying real skips under junk.
    if (/(^|[\\/])__MACOSX[\\/]/.test(raw) || /(^|[\\/])\._/.test(raw)) continue;
    if (!PRINT_EXT.test(raw)) { skipped.push({ name: raw, reason: 'not-a-print-file' }); continue; }

    /* CHARGE WHAT IT MAY COST, NOT WHAT IT CLAIMS.
     *
     * This charged the declared size and charged NOTHING when a member declared
     * none — while lib/zip-read.js lets exactly those members inflate to its
     * full per-member ceiling. So an archive of members all declaring `size: 0`
     * passed a 2 GiB budget "costing 0 MB" and then wrote as much as it liked:
     * measured at 480 MB out of a 0.47 MB file, and about 200 GB at the 512
     * member cap. A shop dropping a downloaded model pack is enough.
     *
     * An undeclared size is now charged the ceiling it is permitted, so five of
     * them fill the budget and the sixth is refused — and refused LOUDLY, since
     * it goes through the same `truncated` path as any other over-budget member. */
    const size = Number(e.size);
    const bytesFor = Number.isFinite(size) && size > 0 ? size : MAX_INFLATED;
    if (take.length >= maxMembers || bytes + bytesFor > maxBytes) {
      // Said out loud. A cap that drops files quietly is the bug mf-convert
      // shipped once and the reason `truncated` exists.
      truncated = true;
      skipped.push({ name: raw, reason: 'over-budget' });
      continue;
    }
    const name = safeName(raw, taken);
    taken.push(name);
    bytes += bytesFor;
    take.push({ entry: e, name, from: raw });
  }
  return { take, skipped, bytes, truncated };
}

/** A one-line summary of what a plan will do, for the caller to show. */
function summarize(p) {
  const plan_ = p || {};
  const take = Array.isArray(plan_.take) ? plan_.take : [];
  const skipped = Array.isArray(plan_.skipped) ? plan_.skipped : [];
  return {
    files: take.length,
    bytes: Number(plan_.bytes) || 0,
    skipped: skipped.length,
    overBudget: skipped.filter((s) => s.reason === 'over-budget').length,
    truncated: !!plan_.truncated,
    empty: take.length === 0,
  };
}

const api = { plan, safeName, summarize, PRINT_EXT, MAX_TOTAL_BYTES, MAX_MEMBERS };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytZipIntake = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
