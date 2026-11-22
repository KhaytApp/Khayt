'use strict';

/**
 * Moving the library's existing files to wherever the library now lives.
 *
 * Changing the location only ever changed where the NEXT file went. Everything
 * already on disk stayed where it was — and because hub:printlib-list reads the
 * primary root and nothing else, those records go from "has three files" to
 * "empty" the moment the setting changes. Nothing was deleted, but from the
 * shop's side of the screen that is indistinguishable from having been.
 *
 * This plans the move. main.js does the disk work; the decisions live here so
 * they can be tested without a NAS, a full volume, or a half-copied file.
 *
 * THE RULE EVERYTHING ELSE FOLLOWS: a duplicate is recoverable, a deletion is
 * not. Every branch below resolves toward keeping bytes. The source is removed
 * in exactly one case — the destination has been read back and proven to hold
 * the same bytes — and never on the strength of a copy call returning without
 * throwing. A short read on a network share does that too.
 */

const path = require('path');
const { under } = require('./convert-paths');

/** A byte-for-byte duplicate has to be proven, not assumed from size alone. */
const SAME = 'duplicate';
const MOVE = 'move';
const COLLISION = 'collision';

/** Room left over after the move, so the destination is not filled to 0. */
const HEADROOM_BYTES = 256 * 1024 * 1024;

const str = (v) => String(v == null ? '' : v).trim();

/**
 * Which folders to scan for files the primary does not have.
 *
 * Every root this install has ever used, minus two:
 *
 *   the primary  — that is the destination; scanning it would plan a move onto
 *                  itself, and the first thing that goes wrong there is a file
 *                  deleted after being "copied" over itself.
 *   the mirror   — it is a backup. Moving files OUT of a backup is the one
 *                  operation guaranteed to leave the shop worse off than when
 *                  it started, and it would look like a successful migration.
 */
function sources(roots, primary, mirror) {
  const p = str(primary);
  const m = str(mirror);
  const out = [];
  for (const r of Array.isArray(roots) ? roots : []) {
    const root = str(r);
    if (!root || root === p || root === m) continue;
    // A root nested inside the primary is already where it needs to be, and a
    // root that CONTAINS the primary would have us walk the destination as if
    // it were a source.
    if (under(root, p) || under(p, root)) continue;
    if (!out.includes(root)) out.push(root);
  }
  return out;
}

/**
 * What to do with one file, given what is already at its destination.
 *
 * @param {{destExists: boolean, srcHash: string|null, destHash: string|null}} item
 * @returns {'move'|'duplicate'|'collision'}
 */
function decide(item) {
  const it = item || {};
  if (!it.destExists) return MOVE;
  // Same name, and the bytes agree: this file has already been migrated, so the
  // source is provably redundant and can go. This is the ONLY path that ends in
  // a deletion without a fresh copy first.
  if (it.srcHash && it.destHash && it.srcHash === it.destHash) return SAME;
  // Same name, different bytes. Two real files. Overwriting picks a winner on
  // the shop's behalf and destroys the loser; both are kept instead.
  return COLLISION;
}

/**
 * A name that is free at the destination.
 *
 * Suffixed before the extension, so the file still opens in a slicer — a name
 * ending in ".stl (2)" is a file macOS will not associate with anything.
 */
function collisionName(filename, taken) {
  const name = str(filename) || 'file';
  const held = new Set((Array.isArray(taken) ? taken : []).map((t) => str(t)));
  if (!held.has(name)) return name;
  const dot = name.lastIndexOf('.');
  const stem = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : '';
  for (let n = 2; n < 1000; n += 1) {
    const candidate = `${stem} (moved${n > 2 ? ` ${n}` : ''})${ext}`;
    if (!held.has(candidate)) return candidate;
  }
  return `${stem} (moved ${Date.now().toString(36)})${ext}`;
}

/** What the shop is agreeing to before anything is touched. */
function summarize(items) {
  const list = Array.isArray(items) ? items : [];
  const byRoot = new Map();
  let bytes = 0;
  for (const it of list) {
    const size = Number(it && it.size) || 0;
    bytes += size;
    const root = str(it && it.root);
    const cur = byRoot.get(root) || { root, files: 0, bytes: 0 };
    cur.files += 1;
    cur.bytes += size;
    byRoot.set(root, cur);
  }
  return { files: list.length, bytes, roots: [...byRoot.values()] };
}

/**
 * Is there room? Checked BEFORE the first copy, not discovered at file 400 of
 * 500 with the volume full and half a library in two places.
 *
 * An unknown free figure is not a refusal — statfs is not available everywhere,
 * and blocking a migration on a number we could not read would be worse than
 * letting the copies fail individually and be reported.
 */
function enoughSpace(bytes, free, headroom) {
  const need = Number(bytes) || 0;
  if (!Number.isFinite(free) || free == null) return { ok: true, unknown: true };
  const spare = Number.isFinite(headroom) ? headroom : HEADROOM_BYTES;
  const ok = free >= need + spare;
  return { ok, unknown: false, need, free, shortBy: ok ? 0 : need + spare - free };
}

/**
 * Fold a location the library is leaving into the roots it remembers.
 *
 * Without this, a SECOND move orphans the first custom folder: it stops being a
 * known root, so printLibContains() starts refusing paths inside it, and files
 * that were merely in the wrong place become unreadable. History is what keeps
 * "we can still find it" true across any number of moves.
 *
 * The built-in default is always a root, so it is never worth recording.
 */
function rememberRoot(settings, nextRoot, defaultRoot) {
  const s = settings && typeof settings === 'object' ? settings : {};
  const leaving = str(s.root);
  const base = str(defaultRoot);
  const next = str(nextRoot);
  const history = (Array.isArray(s.history) ? s.history : []).map(str).filter(Boolean);
  if (leaving && leaving !== base && leaving !== next && !history.includes(leaving)) {
    history.push(leaving);
  }
  // A folder we have moved back to is a current root, not a past one.
  return { ...s, root: next, history: history.filter((h) => h !== next) };
}

/**
 * Move one file, and prove it arrived before removing the original.
 *
 * This is the only code in the feature that deletes anything, so it is the only
 * code worth being paranoid in — and it takes its filesystem as an argument so
 * that paranoia can actually be tested. A copy that silently truncates is not a
 * hypothetical: it is what a network share does when it drops mid-transfer, and
 * it is indistinguishable from success at the call site.
 *
 * Not fs.rename: across volumes it fails outright (EXDEV), and where it does
 * work it leaves no window in which to check that the bytes arrived.
 *
 * @param {{hash, exists, readdir, mkdir, copy, unlink}} io  all promise-returning
 * @returns {Promise<{action: string, name: string}>}
 * @throws if the copy could not be verified — with the source left untouched
 */
async function moveOne(io, src, destDir, filename) {
  const target = path.join(destDir, filename);
  const destExists = await io.exists(target);
  const srcHash = await io.hash(src);
  const destHash = destExists ? await io.hash(target) : null;
  const action = decide({ destExists, srcHash, destHash });

  if (action === SAME) {
    // Already at the destination, byte for byte. The only removal that does not
    // need a fresh copy behind it, because the copy is already proven.
    await io.unlink(src);
    return { action, name: filename };
  }

  const name = action === COLLISION ? collisionName(filename, await io.readdir(destDir)) : filename;
  const dest = path.join(destDir, name);
  await io.mkdir(destDir);
  await io.copy(src, dest);
  if (await io.hash(dest) !== srcHash) {
    // Take the bad copy back out, so a retry does not read it as a collision
    // and keep it forever under a suffixed name. The SOURCE stays.
    try { await io.unlink(dest); } catch (_) { /* best effort; the source is what matters */ }
    throw new Error('the copy did not match the original');
  }
  await io.unlink(src);
  return { action, name };
}

module.exports = {
  sources, decide, collisionName, summarize, enoughSpace, rememberRoot, moveOne,
  MOVE, SAME, COLLISION, HEADROOM_BYTES,
};
