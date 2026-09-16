'use strict';
(function (global) {
/**
 * The rules in front of the LAN server.
 *
 * A shop's LAN server is the one part of Khayt that answers to the network, and
 * behind a tunnel it answers to the internet. What stands in front of it is a
 * PIN, a per-caller lockout and two global gates — and those have to be the
 * SAME rules wherever the server runs. This file is them.
 *
 * ── WHAT IS DELIBERATELY NOT HERE ─────────────────────────────────────────
 *
 * The constant-time comparison. `safeTokenEqual` stays in the host — on Node's
 * `crypto.timingSafeEqual` there, and on the platform's own primitive
 * elsewhere. A constant-time compare is a PRIMITIVE, not a rule, and
 * reimplementing one in portable JavaScript to share it would mean replacing a
 * vetted implementation with a hand-rolled one, in the single place that would
 * matter most.
 *
 * Lifted out of `lib/lan-server.js`, which requires `node:http`, `node:os` and
 * `node:crypto` at module scope and so cannot be loaded anywhere else. None of
 * the arithmetic ever needed any of that. The end-to-end tests in
 * `test/lan-auth-lockout.test.js` and its siblings still drive the running
 * server over real HTTP, and they are what prove this lift changed nothing.
 *
 * Pure: no sockets, no crypto, no DOM.
 */

// How many failed attempts across ALL callers before everything is refused, and
// for how long. Only armed behind the tunnel — see `globalAuthThrottle`.
const GLOBAL_THROTTLE_LIMIT = 50;
const GLOBAL_THROTTLE_WINDOW_MS = 60_000;
const GLOBAL_THROTTLE_COOLDOWN_MS = 60_000;

// One caller's lockout: ten failures buys a minute of refusals.
const PER_IP_LIMIT = 10;
const LOCKOUT_MS = 60_000;
// The failed-attempt table cannot be allowed to grow without bound on a public
// tunnel, where the key is a header the caller controls.
const MAX_FAILED_ATTEMPT_KEYS = 5000;

function lanEscapeHtml(s) {
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

/**
 * Pure helper for the global failed-attempt backstop. Mutates and reads `state`
 * (a `{ count, windowStart, blockedUntil }` object) so it is trivially testable.
 *
 * @param {object} state    persistent throttle state
 * @param {number} now      current epoch ms
 * @param {boolean} failed  whether this attempt was a failed auth
 * @param {object} [opts]   { limit, windowMs, cooldownMs }
 * @returns {boolean} true when the request should be blocked (gate is tripped)
 */
/**
 * Drop expired lockout buckets, and hard-cap the map.
 *
 * failedAttempts entries were only ever deleted by a SUCCESSFUL auth on that exact key.
 * The key is a client id derived from X-Forwarded-For in tunnel mode, which the caller
 * controls — so rotating it left one permanent entry per request and grew the main
 * process without bound. Cheap: called only on a failed attempt.
 */
/**
 * Count one failed auth attempt into a rolling window and return the new record.
 *
 * THE BUG THIS REPLACES, because it is worth not reinventing: every lockout in
 * this file used to read
 *
 *   const count = (now >= rec.resetAt ? 0 : rec.count) + 1;
 *   set({ count, resetAt: count >= 10 ? now + LOCKOUT_MS : rec.resetAt });
 *
 * `resetAt` starts at 0, and it was only ever advanced once `count` reached the
 * limit — but `count` could never reach the limit, because `now >= 0` is always
 * true and reset it to 0 on every single attempt. The counter sat at 1 forever:
 * it could not lock out because it never counted, and it never counted because
 * it was not locked out. Every brute-force lockout in the LAN server was inert,
 * including the one on the owner PIN.
 *
 * The window therefore has to open on the FIRST failure, not on the last one.
 * Reaching the limit then restarts the clock from the offending attempt, so a
 * lockout is a full cooldown rather than whatever remained of the window.
 *
 * @param {object|undefined} prev  existing `{ count, resetAt }`, if any
 * @param {number} now             epoch ms
 * @param {object} [opts]          { limit, lockoutMs }
 * @returns {{count: number, resetAt: number}} the record to store
 */
function bumpFailure(prev, now, opts = {}) {
  const limit = Math.max(1, opts.limit ?? 10);
  const lockoutMs = Math.max(1, opts.lockoutMs ?? 60_000);
  const rec = prev || { count: 0, resetAt: 0 };
  const expired = now >= (rec.resetAt || 0);
  const count = (expired ? 0 : rec.count || 0) + 1;
  let resetAt = expired ? now + lockoutMs : rec.resetAt;
  if (count >= limit) resetAt = now + lockoutMs;
  return { count, resetAt };
}

/** Companion read for {@link bumpFailure}: is this bucket currently locked out? */
function isLockedOut(rec, now, limit = 10) {
  return !!rec && now < (rec.resetAt || 0) && (rec.count || 0) >= limit;
}

function sweepFailedAttempts(map, now, maxKeys = 5000) {
  for (const [k, v] of map) {
    if (!v || now >= (v.resetAt || 0)) map.delete(k);
  }
  // Still too big (a burst inside one lockout window): drop oldest-inserted first.
  if (map.size > maxKeys) {
    const excess = map.size - maxKeys;
    let i = 0;
    for (const k of map.keys()) {
      if (i++ >= excess) break;
      map.delete(k);
    }
  }
  return map.size;
}

/**
 * Rolling-window gate that counts EVERY call, not just failed ones.
 *
 * `globalAuthThrottle` above only counts failed auth. An estimate request is not
 * an auth attempt and it always succeeds, so it never touches that gate — yet it
 * is the most expensive thing an anonymous caller can ask this server to do
 * (read up to 32 MB, then parse a mesh on Electron's main thread). Behind the
 * tunnel the per-IP limit is keyed on X-Forwarded-For, so rotating that header
 * hands the caller a fresh hourly allowance on every request and the per-IP
 * bound stops being a bound at all. This gate is keyed on nothing, which is
 * precisely why a spoofed key cannot move it.
 *
 * No cooldown: unlike a brute-force gate there is nothing to punish here, so it
 * simply stops accepting until the window rolls.
 *
 * @param {object} state  persistent `{ count, windowStart }`
 * @param {number} now    epoch ms
 * @param {object} [opts] { limit, windowMs }
 * @returns {boolean} true when this call should be REFUSED
 */
function globalWindowGate(state, now, opts = {}) {
  const limit = Math.max(1, opts.limit ?? 120);
  const windowMs = Math.max(1, opts.windowMs ?? 3_600_000);
  if (now - state.windowStart > windowMs) {
    state.windowStart = now;
    state.count = 0;
  }
  if (state.count >= limit) return true;
  state.count += 1;
  return false;
}

function globalAuthThrottle(state, now, failed, opts = {}) {
  const limit = opts.limit ?? GLOBAL_THROTTLE_LIMIT;
  const windowMs = opts.windowMs ?? GLOBAL_THROTTLE_WINDOW_MS;
  const cooldownMs = opts.cooldownMs ?? GLOBAL_THROTTLE_COOLDOWN_MS;
  // Still inside an active cooldown → block regardless of this attempt.
  if (now < state.blockedUntil) return true;
  if (!failed) return false;
  // Reset the rolling window if it has elapsed.
  if (now - state.windowStart > windowMs) {
    state.windowStart = now;
    state.count = 0;
  }
  state.count += 1;
  if (state.count >= limit) {
    state.blockedUntil = now + cooldownMs;
    state.count = 0;
    state.windowStart = now;
    return true;
  }
  return false;
}

/**
 * Returns a human-readable warning when tunnel mode is on and the PIN is too
 * weak to expose to the public internet, or null when it is acceptable. Does
 * not block — callers surface this as advice only.
 */
function weakTunnelPinWarning(pin, tunnelActive) {
  if (!tunnelActive) return null;
  const p = String(pin || '');
  if (p.length < 6 || (/^\d+$/.test(p) && p.length < 8)) {
    return 'LAN PIN is weak for remote tunnel exposure — use at least 8 characters mixing letters and digits.';
  }
  return null;
}

/**
 * Resolve the effective client IP for rate-limiting / lockouts.
 * Behind the localtunnel every request arrives from a loopback socket, which
 * would collapse all remote users into a single bucket — so when the tunnel is
 * active we trust the tunnel hop's X-Forwarded-For first entry instead.
 */
function tunnelClientIp(directIp, xffHeader, tunnelActive) {
  const direct = String(directIp || '');
  if (tunnelActive && /^(::1|::ffff:127\.|127\.)/.test(direct)) {
    const xff = String(xffHeader || '').split(',')[0].trim();
    if (xff) return xff;
  }
  return direct;
}

/** JSON-encode a value for safe embedding inside an inline <script> block. */

function sanitizeLanHttpUrl(v) {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().slice(0, 500);
  if (!s) return undefined;
  try {
    const u = new URL(s);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return undefined;
    return u.href;
  } catch {
    return undefined;
  }
}

const api = {
  lanEscapeHtml,
  bumpFailure, isLockedOut, sweepFailedAttempts,
  globalWindowGate, globalAuthThrottle,
  weakTunnelPinWarning, tunnelClientIp, sanitizeLanHttpUrl,
  GLOBAL_THROTTLE_LIMIT, GLOBAL_THROTTLE_WINDOW_MS, GLOBAL_THROTTLE_COOLDOWN_MS,
  PER_IP_LIMIT, LOCKOUT_MS, MAX_FAILED_ATTEMPT_KEYS,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytLanAuth = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
