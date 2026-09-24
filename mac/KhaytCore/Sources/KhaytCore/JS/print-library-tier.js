'use strict';
// Wrapped so JavaScriptCore on the Mac can load it into its one shared
// context (top-level `const`s would collide there); Node still requires it.
(function (global) {

/**
 * Keeping the library bigger than the disk it lives on.
 *
 * The bucket that shipped before this was a MIRROR, and main.js says so plainly:
 * written after every save, never read from, because a backup you read from is a
 * second primary and the two drift. That is the right rule for a backup and it
 * is the wrong shape for the problem shops actually hit — a mirror does not free
 * a single byte. A 50 GB library with a mirror is 50 GB locally and 50 GB in the
 * bucket. At 500 GB it is still 500 GB locally, and the laptop is full.
 *
 * Tiering is the other thing you can do with the same bucket: a cold model lives
 * in the bucket ONLY, the local copy is deleted, and it comes back down the first
 * time anyone opens it. The library stays whole; the disk stops growing.
 *
 * ── Why this does not violate the mirror rule ───────────────────────────────
 * It does read from the cloud, so the "never read from the backup" rule has to
 * be re-stated rather than broken: the MIRROR is still never read from. Tiering
 * is a separate role for a separate bucket prefix, and the distinction that
 * makes it safe is that a tiered file is not a copy — it is THE file, and the
 * local disk is the cache. There is nothing to drift from.
 *
 * A shop can run both, and most should: mirror for "the building burned down",
 * tiering for "the disk is full". They are different jobs.
 *
 * ── The rule that keeps this from losing models ─────────────────────────────
 * EVICTION IS THE ONLY DESTRUCTIVE THING IN THIS FILE, and it deletes a
 * customer's paid-for model. So it is gated on proof, not on optimism:
 *
 *   nothing is deleted locally until the bucket has been asked, in a separate
 *   round trip, and has answered with a byte count that matches.
 *
 * Not "the upload returned 200" — that is the same call that would have failed,
 * and a proxy or a half-configured bucket can 200 an upload that stored nothing.
 * A HEAD afterwards is a different question to a different code path. main.js
 * does the asking; this module refuses to plan an eviction without the answer.
 *
 * ── The sidecar ─────────────────────────────────────────────────────────────
 * An evicted file leaves a `<name>.cloud` behind: a few hundred bytes of JSON
 * recording its size, its hash and its object key. It exists so that the
 * difference between "this model is in the bucket" and "this model is gone" is
 * answerable from the disk, with no network and no credentials.
 *
 * That matters more than it sounds. Without it, a shop whose bucket credentials
 * expire opens a library that looks EMPTY, and empty is indistinguishable from
 * lost. With it, every model is still listed, still has its size, and says where
 * it went — offline, on a plane, with the bucket unreachable.
 *
 * Pure: no fs, no network, no Electron. The caller probes and moves the bytes;
 * this decides what should happen and refuses what must not.
 */

const SIDECAR_EXT = '.cloud';
const SIDECAR_VERSION = 1;

const str = (v) => String(v == null ? '' : v).trim();
const DAY_MS = 86400000;

/**
 * Files that must never be evicted regardless of age or size.
 *
 * Thumbnails and photos are what the library GRID draws. Evict those and
 * browsing the library becomes a network operation — hundreds of round trips to
 * paint one screen, and a blank wall of placeholders when the bucket is away.
 * They are also tiny, so they free nothing worth having. The models are the
 * gigabytes; the pictures of them are not.
 */
const NEVER_EVICT_EXT = new Set(['.png', '.jpg', '.jpeg', '.webp', '.gif', '.svg', '.json', '.txt', '.md']);

/** Sensible defaults; every one is overridable from settings.printLibrary.tier. */
const DEFAULT_POLICY = {
  enabled: false,      // opt-in. It deletes local files; it does not get to be a default.
  keepDays: 90,        // a model reprinted quarterly never leaves the disk
  minBytes: 1048576,   // 1 MB — below this the request costs more than the space
};

const extOf = (name) => {
  const s = str(name).toLowerCase();
  const i = s.lastIndexOf('.');
  return i <= 0 ? '' : s.slice(i);
};

const isSidecar = (name) => extOf(name) === SIDECAR_EXT;

/** `model.3mf` → `model.3mf.cloud`. Appended, not replaced, so the real extension survives. */
const sidecarName = (filename) => `${str(filename)}${SIDECAR_EXT}`;

/** `model.3mf.cloud` → `model.3mf`; anything else comes back unchanged. */
const baseName = (name) => (isSidecar(name) ? str(name).slice(0, -SIDECAR_EXT.length) : str(name));

function normalisePolicy(raw) {
  const p = raw && typeof raw === 'object' ? raw : {};
  const num = (v, dflt, min) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= min ? n : dflt;
  };
  return {
    enabled: !!p.enabled,
    // Zero would mean "evict everything the moment it is written", which turns
    // every first open into a download. One day is the floor.
    keepDays: num(p.keepDays, DEFAULT_POLICY.keepDays, 1),
    minBytes: num(p.minBytes, DEFAULT_POLICY.minBytes, 0),
  };
}

/**
 * The JSON left behind in place of an evicted file.
 *
 * The hash is the point of the whole record: it is what lets a rehydrate prove
 * the bytes that came back are the bytes that went up. A size match alone would
 * accept a truncated-then-padded object, or somebody else's file of the same
 * length.
 */
function makeSidecar({ size, sha256, key, provider, at }) {
  return {
    v: SIDECAR_VERSION,
    size: Number(size) || 0,
    sha256: str(sha256),
    key: str(key),
    provider: str(provider),
    at: str(at),
  };
}

/**
 * Read a sidecar, refusing anything it cannot vouch for.
 *
 * A sidecar missing its size or hash cannot verify a download, and a sidecar
 * that cannot verify a download is worse than none: it would claim the model is
 * safely in the bucket while providing no way to notice it came back wrong.
 * Treating it as unreadable makes the file show as needing attention instead.
 *
 * @returns {object|null}
 */
function parseSidecar(text) {
  let o;
  try { o = JSON.parse(String(text || '')); } catch (_) { return null; }
  if (!o || typeof o !== 'object') return null;
  if (Number(o.v) !== SIDECAR_VERSION) return null;
  if (!(Number(o.size) > 0) || !str(o.sha256) || !str(o.key)) return null;
  return makeSidecar(o);
}

/**
 * Why a file may or may not be evicted. Returned as a reason rather than a
 * boolean so the UI can explain a library that will not shrink — "nothing is old
 * enough yet" and "your bucket is not configured" both look like a no-op button
 * otherwise.
 *
 * @param {{filename: string, size: number, mtimeMs: number}} file
 * @param {object} policy   already through normalisePolicy
 * @param {number} now      ms
 * @returns {{ok: boolean, reason: string}}
 */
function evictable(file, policy, now) {
  const f = file || {};
  const name = str(f.filename);
  if (!name) return { ok: false, reason: 'unnamed' };
  if (isSidecar(name)) return { ok: false, reason: 'already-tiered' };
  if (NEVER_EVICT_EXT.has(extOf(name))) return { ok: false, reason: 'preview' };
  const size = Number(f.size) || 0;
  if (size < policy.minBytes) return { ok: false, reason: 'too-small' };
  const ageDays = (Number(now) - (Number(f.mtimeMs) || 0)) / DAY_MS;
  if (!(ageDays >= policy.keepDays)) return { ok: false, reason: 'too-recent' };
  return { ok: true, reason: 'ok' };
}

/**
 * What a sweep would do, given everything currently on disk.
 *
 * Plans only — it never says a file IS evictable in the sense that matters,
 * because that needs the bucket's answer and this module has no network. The
 * caller HEADs each candidate and drops the ones that do not verify.
 *
 * @param {Array<{filename,size,mtimeMs,id?,rel?}>} files
 * @param {object} rawPolicy
 * @param {number} now
 * @returns {{candidates: Array, skipped: Object, bytes: number, policy: Object}}
 */
function plan(files, rawPolicy, now) {
  const policy = normalisePolicy(rawPolicy);
  const candidates = [];
  const skipped = {};
  let bytes = 0;
  for (const f of Array.isArray(files) ? files : []) {
    const v = evictable(f, policy, now);
    if (v.ok) { candidates.push(f); bytes += Number(f.size) || 0; continue; }
    skipped[v.reason] = (skipped[v.reason] || 0) + 1;
  }
  // Biggest first. A sweep interrupted halfway — the share goes away, the shop
  // quits the app — should have freed as much as it could by then, and the top
  // 10% of a print library is usually most of its bytes.
  candidates.sort((a, b) => (Number(b.size) || 0) - (Number(a.size) || 0));
  return { candidates, skipped, bytes, policy };
}

/**
 * Fold the sidecars into a directory listing so the UI sees one library.
 *
 * The whole promise of tiering is that the library does not appear to change.
 * A tiered model is listed exactly where it was, at its real size, marked
 * `tiered` so the row can show a cloud glyph — not missing, and not zero bytes.
 *
 * @param {Array<{filename,fullPath,size}>} entries  what readdir found
 * @param {Map<string,object>} sidecars              base filename → parsed sidecar
 * @returns {Array} the listing, sidecar files themselves removed
 */
function mergeListing(entries, sidecars) {
  const map = sidecars instanceof Map ? sidecars : new Map();
  const out = [];
  const seen = new Set();
  for (const e of Array.isArray(entries) ? entries : []) {
    const name = str(e && e.filename);
    if (!name || isSidecar(name)) continue;   // the sidecar is plumbing, not a file
    seen.add(name);
    // A local file AND a sidecar means a rehydrate landed and the sidecar was
    // not cleaned up. The local copy is authoritative — it is the bytes someone
    // is about to open — so report it as present.
    out.push({ ...e, tiered: false });
  }
  for (const [name, side] of map.entries()) {
    if (seen.has(name)) continue;
    out.push({
      filename: name,
      fullPath: str(side.fullPath),
      size: Number(side.size) || 0,
      tiered: true,
      key: str(side.key),
      sha256: str(side.sha256),
    });
  }
  return out;
}

/**
 * Does the bucket hold THESE bytes, or merely this many?
 *
 * This is the gate in front of the only destructive operation here, so it is
 * deliberately three-valued. A boolean would have to collapse "the bucket
 * disagrees" and "the bucket answered in a form I cannot read" into the same
 * `false`, and those want opposite handling: the first is a corrupt upload to
 * retry, the second is a perfectly good object uploaded by some other tool as
 * multipart, whose `<hash>-<parts>` etag is not an MD5 of anything.
 *
 * 'unusable' is not a failure. It means this cheap check cannot decide, and the
 * caller must fall back to downloading the object and hashing it before it is
 * allowed to delete anything.
 *
 * @returns {'match'|'mismatch'|'unusable'}
 */
function etagVerdict(etag, localMd5) {
  const e = str(etag).replace(/^"|"$/g, '').toLowerCase();
  const m = str(localMd5).toLowerCase();
  if (!e || !m) return 'unusable';
  if (!/^[0-9a-f]{32}$/.test(e)) return 'unusable';   // multipart, or something else entirely
  return e === m ? 'match' : 'mismatch';
}

/**
 * Is a download the file we evicted?
 *
 * Both halves are checked because they fail differently: a size mismatch is a
 * truncated transfer, a hash mismatch with a matching size is the wrong object
 * entirely — a stale key, a prefix collision between two shops sharing a bucket.
 * The second is the one that would quietly hand a customer someone else's model.
 *
 * @returns {{ok: boolean, error: string}}
 */
function verifyRehydrate(side, gotSize, gotSha256) {
  if (!side) return { ok: false, error: 'No record of this file in the cloud.' };
  if (Number(gotSize) !== Number(side.size)) {
    return { ok: false, error: `Downloaded ${gotSize} bytes, expected ${side.size}.` };
  }
  if (str(gotSha256).toLowerCase() !== str(side.sha256).toLowerCase()) {
    return { ok: false, error: 'The file that came back does not match the one that was stored.' };
  }
  return { ok: true, error: '' };
}

/**
 * Human summary of a sweep. Bytes are meaningless to the person deciding whether
 * to run it; "frees 34.2 GB" is the entire decision.
 */
function formatBytes(n) {
  const b = Number(n) || 0;
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = b;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
  return `${i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}

const api = {
  SIDECAR_EXT,
  SIDECAR_VERSION,
  DEFAULT_POLICY,
  NEVER_EVICT_EXT,
  isSidecar,
  sidecarName,
  baseName,
  normalisePolicy,
  makeSidecar,
  parseSidecar,
  evictable,
  etagVerdict,
  plan,
  mergeListing,
  verifyRehydrate,
  formatBytes,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytPrintLibraryTier = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
