'use strict';

/**
 * Has this signed webhook delivery been seen before?
 *
 * Salla, Zid and the carriers (SMSA, Aramex, SPL) sign the BODY and nothing
 * else — no timestamp, no delivery id we can window on. So a captured delivery
 * stays valid for ever, and the only defence against replaying it is
 * remembering that it arrived.
 *
 * This used to be a 500-entry, ten-minute, in-memory map in lib/lan-server.js,
 * which forgot a delivery after ten minutes, after 500 newer ones, or when the
 * app restarted — so a replay only had to wait (SEC-010, found by the Mac's
 * scan; the Mac now keeps the same rule). It keeps SHA-256(signature), not the
 * signature, for THIRTY DAYS, up to 10,000 entries, in a file beside the book,
 * so a restart does not reset it.
 *
 * Pure: the file is read and written through `io`, so tests need no disk, and
 * a store that cannot be read or written degrades to in-memory rather than
 * refusing deliveries — a webhook the shop needs is worth more than the
 * persistence of this list.
 */
const crypto = require('crypto');

const TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX = 10000;

/**
 * @param {{ load?: () => (string|null), save?: (text: string) => void,
 *           ttlMs?: number, max?: number }} [io]
 */
function createReplayGuard(io = {}) {
  const ttl = Number.isFinite(io.ttlMs) ? io.ttlMs : TTL_MS;
  const max = Number.isFinite(io.max) ? io.max : MAX;
  const seen = new Map(); // sha256 hex -> expiry epoch ms, oldest first
  let loaded = false;

  function load(now) {
    if (loaded) return;
    loaded = true;
    try {
      const raw = typeof io.load === 'function' ? io.load() : null;
      const data = raw ? JSON.parse(raw) : null;
      const entries = data && Array.isArray(data.entries) ? data.entries : [];
      entries
        .filter((e) => Array.isArray(e) && typeof e[0] === 'string' && Number.isFinite(e[1]) && e[1] > now)
        .sort((a, b) => a[1] - b[1])
        .slice(-max)
        .forEach(([h, exp]) => seen.set(h, exp));
    } catch (_) { /* unreadable: start empty, keep taking deliveries */ }
  }

  function persist() {
    if (typeof io.save !== 'function') return;
    try { io.save(JSON.stringify({ v: 1, entries: [...seen] })); } catch (_) { /* in-memory still protects */ }
  }

  /** True if `signature` was seen within the window; records it if not. */
  function isReplay(signature, now = Date.now()) {
    const sig = String(signature || '');
    if (!sig) return false; // unsigned requests are rejected upstream by the HMAC check
    load(now);
    for (const [k, exp] of seen) { if (exp <= now) seen.delete(k); else break; }
    const h = crypto.createHash('sha256').update(sig).digest('hex');
    if (seen.has(h)) return true;
    seen.set(h, now + ttl);
    while (seen.size > max) seen.delete(seen.keys().next().value);
    persist();
    return false;
  }

  return { isReplay, size: () => seen.size };
}

module.exports = { createReplayGuard, TTL_MS, MAX };
