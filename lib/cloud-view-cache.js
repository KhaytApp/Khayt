'use strict';

/**
 * The retained server view, kept ACROSS RESTARTS — the warm-launch half of
 * [docs/KHAYT-CLOUD-DELTA-SYNC.md](../docs/KHAYT-CLOUD-DELTA-SYNC.md) §7.
 *
 * `cloudBackend` is rebuilt on every unlock, so without this the view starts
 * empty and the first pull of every session fetches the base and the whole
 * chain — the one pull that costs the most, paid every launch. This file is
 * what lets that pull ask `?since=` instead.
 *
 * It is a CACHE in the strict sense: every failure path returns null, and null
 * simply means a cold pull, which is always correct and merely dearer. Nothing
 * in here may throw into the sync path — a shop whose disk is full or whose
 * cache was written by a different build must still sync, just coldly.
 *
 * ## Encrypted with the DEK, and that is not only about confidentiality
 *
 * The view is a copy of the whole store, so it is written as `encryptStore`
 * ciphertext — the same envelope the wire uses. Two things fall out of that
 * beyond secrecy at rest:
 *
 * - a keyset rotation invalidates the cache for free. The new DEK cannot
 *   decrypt the old file, `load()` returns null, and the session goes cold —
 *   which is exactly what a device that can no longer read the server's old
 *   view should do.
 * - the file is useless to anything that does not hold the DEK, so it is no
 *   weaker than the sync it accelerates.
 *
 * The store is tens to hundreds of KB in practice, so one encrypt per view
 * movement is not worth optimising away — and the alternative (mirroring the
 * server's base + chain locally to avoid re-encrypting) would put the server's
 * compaction semantics in a second place, which is exactly where a silent
 * divergence would hide.
 *
 * ## What is NOT decided here
 *
 * Whether a loaded view may be *adopted* is the backend's call, not this
 * module's: see `viewSafeForLocal` in cloud-backend.js. This module answers
 * only "what was written, and can it still be read".
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/** Bump when the on-disk shape changes; an older file then loads as null. */
const CACHE_VERSION = 1;

/**
 * Ciphertext is base64 and inflates over the 50 MB store cap, so allow headroom
 * — but not unbounded, because this is read synchronously at unlock and a
 * runaway file must not stall the app instead of simply being ignored.
 */
const MAX_CACHE_BYTES = 80_000_000;

/**
 * Shop ids come from the server, so they are not this process's to trust as a
 * path component. Hashing gives a fixed, filesystem-safe name that still keys
 * one file per shop — and the id itself is stored INSIDE the file, where a
 * mismatch is checked rather than assumed.
 */
function fileFor(dir, shopId) {
  const h = crypto.createHash('sha256').update(String(shopId || '')).digest('hex').slice(0, 16);
  return path.join(dir, `cloud-view-${h}.json`);
}

/**
 * @param {object} opts
 * @param {string} opts.dir        directory to keep the file in (userData/…)
 * @param {string} opts.shopId     the shop this view belongs to
 * @param {object} opts.crypto     sync-crypto (encryptStore / decryptStore)
 * @param {function} opts.getDek   () => Buffer, the session DEK
 */
function createViewCache({ dir, shopId, crypto: sc, getDek }) {
  if (!dir) throw new Error('view cache: dir required');
  if (!shopId) throw new Error('view cache: shopId required');
  if (!sc || typeof sc.encryptStore !== 'function') throw new Error('view cache: crypto required');
  if (typeof getDek !== 'function') throw new Error('view cache: getDek() required');

  const file = fileFor(dir, shopId);

  /**
   * @returns {{rev:number, view:object, baseWireBytes:number, chainWireBytes:number,
   *            chainCount:number} | null} null on anything at all going wrong.
   */
  function load() {
    try {
      const st = fs.statSync(file);
      if (!st.isFile() || st.size > MAX_CACHE_BYTES) return null;
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!raw || raw.v !== CACHE_VERSION) return null;
      // A file whose name hashes to this shop but whose body names another one
      // has been moved or hand-edited. Refuse it: folding a slice of THIS shop
      // onto ANOTHER shop's store is the one outcome worth being paranoid about.
      if (String(raw.shopId) !== String(shopId)) return null;
      const rev = Number(raw.rev);
      if (!Number.isFinite(rev) || rev <= 0) return null;
      // Throws on a wrong key or a tampered blob — both mean "cannot be used",
      // which is the same answer as a missing file.
      const view = sc.decryptStore(raw.ciphertext, getDek());
      if (!view || typeof view !== 'object' || Array.isArray(view)) return null;
      const n = (x) => (Number.isFinite(Number(x)) && Number(x) >= 0 ? Number(x) : 0);
      return {
        rev,
        view,
        baseWireBytes: n(raw.baseWireBytes),
        chainWireBytes: n(raw.chainWireBytes),
        chainCount: n(raw.chainCount),
      };
    } catch (e) {
      return null;
    }
  }

  /**
   * Persist a view and its rev TOGETHER. The two must agree — see the invariant
   * on `serverView` in cloud-backend.js — so they are written in one file by one
   * atomic rename, and there is no path that writes only one of them.
   *
   * The chain counters ride along because they are not decoration: `baseWireBytes`
   * is only learned from a cold reply or from this device's own full push. Warm
   * every launch and a backend that dropped the counters would never know the
   * base size, the byte ratio in §6 would stop applying, and the chain would be
   * bounded only by MAX_CHAIN_DELTAS — a real regression, visible to nobody.
   *
   * Best effort by design: returns false rather than throwing.
   */
  function save({ rev, view, baseWireBytes, chainWireBytes, chainCount } = {}) {
    try {
      if (!view || typeof view !== 'object') return false;
      if (!Number.isFinite(Number(rev)) || Number(rev) <= 0) return false;
      fs.mkdirSync(dir, { recursive: true });
      const body = JSON.stringify({
        v: CACHE_VERSION,
        shopId: String(shopId),
        rev: Number(rev),
        baseWireBytes: Number(baseWireBytes) || 0,
        chainWireBytes: Number(chainWireBytes) || 0,
        chainCount: Number(chainCount) || 0,
        savedAt: new Date().toISOString(),
        ciphertext: sc.encryptStore(view, getDek()),
      });
      // Write-then-rename: a crash mid-write must not leave a half-file that
      // parses. rename() is atomic within a directory.
      const tmp = file + '.tmp';
      fs.writeFileSync(tmp, body, { mode: 0o600 });
      fs.renameSync(tmp, file);
      return true;
    } catch (e) {
      return false;
    }
  }

  function clear() {
    try { fs.unlinkSync(file); } catch (e) { /* nothing cached */ }
    try { fs.unlinkSync(file + '.tmp'); } catch (e) { /* no partial write */ }
  }

  return { load, save, clear, file };
}

module.exports = { createViewCache, fileFor, CACHE_VERSION };
