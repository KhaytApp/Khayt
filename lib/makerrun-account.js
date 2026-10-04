'use strict';

/**
 * MakerRun account link (main-process). Stores the Supabase refresh token handed over by the website's
 * bedready:// deep link (see makerrun.com/app-link) and exchanges it for fresh access tokens via
 * /api/app-token, so the app stays signed in without embedding any Supabase creds.
 *
 * The library moved from bedready.io to makerrun.com in the 2026-08-21 product split; the Supabase
 * project behind it did NOT move. Same project, same anon key, same users, same tokens — a stored link
 * survives the host change, so this is a host swap and not a re-plumb of authentication. The
 * `bedready://` deep-link scheme is the OS protocol the app registered and is unrelated to the host.
 *
 * Separate from Khayt Cloud (E2E shop backup) and from lib/makerrun-library (which just fetches/downloads
 * given a token). Tokens live in userData/bedready-account.json (0600). Node-only.
 */
const fs = require('fs');
const MAINT = require('./makerrun-maintenance');
const path = require('path');

const { BASE } = require('./makerrun'); // one host constant, shared with lib/makerrun-library

const fileFor = (userDataDir) => path.join(userDataDir, 'bedready-account.json');

// Encrypt the tokens at rest with Electron's OS-backed safeStorage, mirroring the main store's
// `__enc__` + base64 scheme. safeStorage is required lazily and guarded: outside Electron (unit tests,
// or a plain-node context) `require('electron')` yields a string, so `.safeStorage` is undefined and we
// transparently fall back to plaintext. A legacy plaintext file (no `__enc__` prefix) still decrypts as-is.
function safeStorageApi() {
  try { const e = require('electron'); return (e && e.safeStorage) || null; } catch { return null; }
}
function encField(s) {
  if (s == null || s === '') return s;
  const ss = safeStorageApi();
  try {
    if (ss && ss.isEncryptionAvailable()) return '__enc__' + ss.encryptString(String(s)).toString('base64');
  } catch { /* fall through to plaintext */ }
  return s;
}
function decField(s) {
  if (typeof s !== 'string' || !s.startsWith('__enc__')) return s;
  const ss = safeStorageApi();
  try {
    if (ss && ss.isEncryptionAvailable()) return ss.decryptString(Buffer.from(s.slice(7), 'base64'));
  } catch { /* can't decrypt (moved machine / unavailable) — return the ciphertext, treated as unusable */ }
  return s;
}

/**
 * Normalize a Supabase `expires_at` to a Unix time in SECONDS. Supabase uses seconds, but guard
 * against contract drift where the value arrives in milliseconds (a ms timestamp today is > 1e12,
 * a seconds timestamp is ~1.7e9) — a ms value read as seconds would sit ~55000 years in the future
 * and the token would never be refreshed. Non-finite / ≤0 → 0 (caller treats as "unknown").
 */
function normExpiresSeconds(exp) {
  const n = Number(exp);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n > 1e12 ? Math.floor(n / 1000) : n;
}

function read(userDataDir) {
  try {
    const d = JSON.parse(fs.readFileSync(fileFor(userDataDir), 'utf8'));
    if (d && typeof d === 'object') {
      if ('access' in d) d.access = decField(d.access);
      if ('refresh' in d) d.refresh = decField(d.refresh);
    }
    return d;
  } catch {
    return null;
  }
}

function write(userDataDir, data) {
  try {
    // Write-then-rename so a crash mid-write can't leave a truncated token file (which would
    // break re-auth). rename() is atomic within the same directory. Tokens are encrypted at rest.
    const f = fileFor(userDataDir);
    const tmp = f + '.tmp';
    const onDisk = Object.assign({}, data, { access: encField(data.access), refresh: encField(data.refresh) });
    fs.writeFileSync(tmp, JSON.stringify(onDisk), { mode: 0o600 });
    fs.renameSync(tmp, f);
    return true;
  } catch {
    return false;
  }
}

function clear(userDataDir) {
  try { fs.unlinkSync(fileFor(userDataDir)); } catch { /* not linked */ }
}

/**
 * Parse a `bedready://auth#access_token=...&refresh_token=...&expires_at=...&state=...` deep link.
 * `state` echoes the per-handshake nonce the app minted when it opened the sign-in page; it's '' for
 * links from an older website that didn't round-trip it (caller degrades to the arm-window check only).
 */
function parseDeepLink(url) {
  const s = String(url || '');
  const i = s.indexOf('#');
  if (i < 0) return null;
  const p = new URLSearchParams(s.slice(i + 1));
  const refresh = p.get('refresh_token');
  if (!refresh) return null;
  const exp = parseInt(p.get('expires_at') || '', 10);
  return { access: p.get('access_token') || '', refresh, expires: normExpiresSeconds(exp), state: p.get('state') || '' };
}

/** Persist tokens from a successful link. Returns true on success. */
function link(userDataDir, tokens) {
  if (!tokens || !tokens.refresh) return false;
  return write(userDataDir, { access: tokens.access || '', refresh: tokens.refresh, expires: tokens.expires || 0 });
}

const isLinked = (userDataDir) => !!(read(userDataDir) || {}).refresh;

// A single in-flight refresh, shared across concurrent callers. Supabase rotates the refresh token
// on every /api/app-token call and its reuse-detection REVOKES the whole session if a rotated token
// is replayed — so two overlapping refreshes (e.g. a double-clicked "Sync") that both POST the same
// token would sign the user out. Collapsing them to one request avoids the replay entirely.
let refreshInFlight = null;

/**
 * Return a valid access token, refreshing via /api/app-token when it's expired or within 60s of expiry.
 * A rotated refresh token (if the server returns one) is stored. Throws (and clears a dead link on 401).
 * Concurrent refreshes are single-flighted so the rotating refresh token is never replayed.
 */
async function getAccessToken(userDataDir, now = Math.floor(Date.now() / 1000), opts) {
  const d = read(userDataDir);
  if (!d || !d.refresh) {
    const e = new Error('Not linked. Connect the app from makerrun.com/app-link.');
    e.code = 'not_linked';
    throw e;
  }
  // `force` is for a caller that was just told 401 by a /v1 endpoint while the stored access token
  // still looked valid by its clock (revoked, or a clock skewed past the 60s margin). It skips ONLY
  // the "still fresh" shortcut — it still joins an in-flight refresh rather than starting a second
  // one, because a second POST of the same refresh token is the replay that revokes the session.
  const force = !!(opts && opts.force);
  if (!force && d.access && d.expires && d.expires - now > 60) return d.access;

  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = doRefresh(userDataDir, d.refresh, now).finally(() => { refreshInFlight = null; });
  return refreshInFlight;
}

async function doRefresh(userDataDir, usedRefresh, now) {
  const res = await fetch(BASE + '/api/app-token', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ refresh_token: usedRefresh }),
    signal: AbortSignal.timeout(30000),
  });
  if (res.status === 401) {
    // Only wipe the link if the token we just tried is still the stored one. A refresh that raced
    // ahead of us may have already rotated in a fresh token — don't clobber a live session.
    const cur = read(userDataDir);
    if (!cur || cur.refresh === usedRefresh) clear(userDataDir);
    const e = new Error('Your MakerRun link expired — reconnect from makerrun.com/app-link.');
    e.code = 'relink';
    throw e;
  }
  const j = await res.json().catch(() => null);
  // The downtime gate closes /api/app-token too. A refresh that fails during it
  // has NOT invalidated anything — the stored token is untouched above (only a
  // 401 clears the link), so retrying after Retry-After picks up where it left off.
  if (MAINT.isMaintenance(res.status, j)) {
    throw MAINT.maintenanceError(MAINT.retryAfterSeconds(res.headers.get('retry-after'), Date.now()));
  }
  if (!res.ok) throw new Error('Could not refresh your MakerRun session (HTTP ' + res.status + ').');
  if (!j || !j.access_token) throw new Error('Could not refresh your MakerRun session.');
  // Normalize the new expiry; if the server omits it, assume a 1h TTL so we don't refresh on every call.
  const expires = normExpiresSeconds(j.expires_at) || (now + 3600);
  write(userDataDir, { access: j.access_token, refresh: j.refresh_token || usedRefresh, expires });
  return j.access_token;
}

module.exports = { parseDeepLink, link, isLinked, getAccessToken, clear, read, fileFor, BASE };
