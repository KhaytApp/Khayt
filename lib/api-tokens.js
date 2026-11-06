'use strict';
/**
 * Scoped API tokens for the local HTTP API (`/v1`). Implements §1 auth of
 * docs/KHAYT-3.0-PUBLIC-API-SPEC.md.
 *
 * Security posture (mirrors the PIN/webhook-secret handling already in lan-server.js):
 *  - The plaintext token is shown to the owner exactly ONCE at mint time and never stored.
 *  - Only a SHA-256 hash is persisted, so a leaked store/backup cannot be replayed.
 *  - Verification is constant-time over the hash to avoid a timing oracle.
 *  - A token grants ONLY its scopes; a read token on a write is 403, never silently allowed.
 *
 * The scope RULES are `lib/api-token-scopes.js`, which the native Mac runs too;
 * this file is the Node crypto around them. The Mac mints and hashes in Swift
 * (`ApiTokens.swift`) to the same format — `khayt_` + 32 random bytes
 * base64url, a SHA-256 hex of the whole token — and `ApiTokensParityTests`
 * pins its hash against a vector computed here.
 */
const crypto = require('crypto');
const Scopes = require('./api-token-scopes.js');

const { SCOPES, TOKEN_PREFIX, isValidScope, bearerFromHeader, hasScope, requiredScope, redactTokens } = Scopes;

/** SHA-256 hex of a presented token. The only form we ever persist. */
function hashToken(token) {
  return crypto.createHash('sha256').update(String(token || ''), 'utf8').digest('hex');
}

/**
 * Mint a token. Returns { token, record } — `token` is the ONLY time the plaintext
 * exists; `record` is what gets persisted (no plaintext).
 */
function generateToken({ label, scopes, nowIso } = {}) {
  const raw = crypto.randomBytes(32).toString('base64url');
  const token = TOKEN_PREFIX + raw;
  const clean = (Array.isArray(scopes) ? scopes : []).filter(isValidScope);
  return {
    token,
    record: {
      id: 'tok_' + crypto.randomBytes(8).toString('hex'),
      label: String(label || '').slice(0, 60),
      hash: hashToken(token),
      scopes: clean,
      createdAt: nowIso || new Date().toISOString(),
      lastUsedAt: null,
    },
  };
}

/**
 * Find the token record matching a presented plaintext token. Constant-time compare
 * against each stored hash; returns null for unknown/revoked tokens.
 */
function verifyToken(presented, tokens) {
  if (!presented || !String(presented).startsWith(TOKEN_PREFIX)) return null;
  const want = Buffer.from(hashToken(presented), 'utf8');
  for (const rec of (Array.isArray(tokens) ? tokens : [])) {
    if (!rec || typeof rec.hash !== 'string' || rec.hash.length !== want.length) continue;
    const got = Buffer.from(rec.hash, 'utf8');
    let equal = false;
    try { equal = crypto.timingSafeEqual(got, want); } catch (_) { equal = false; }
    if (equal) return rec;
  }
  return null;
}

/** How often a token's `lastUsedAt` is written: a busy integration is not a write per request. */
const LAST_USED_EVERY_MS = 60 * 60 * 1000;

/**
 * The token list with `id`'s `lastUsedAt` set to `nowMs`, or null when nothing
 * should be written: no such token, or it was stamped less than
 * `LAST_USED_EVERY_MS` ago. Pure; the caller writes it, inside the write chain.
 */
function markUsed(tokens, id, nowMs, everyMs = LAST_USED_EVERY_MS) {
  if (!Array.isArray(tokens) || !id) return null;
  const i = tokens.findIndex((t) => t && t.id === id);
  if (i === -1) return null;
  const last = typeof tokens[i].lastUsedAt === 'string' ? Date.parse(tokens[i].lastUsedAt) : NaN;
  if (Number.isFinite(last) && nowMs - last < everyMs && nowMs >= last) return null;
  const next = tokens.slice();
  next[i] = { ...tokens[i], lastUsedAt: new Date(nowMs).toISOString() };
  return next;
}

/**
 * Whether the operator signed in on this book may create or revoke API tokens:
 * rbac `security` `edit`, the Mac's rule (owner only under the staff lock;
 * everyone when the lock is off, as for every other permission). Read from
 * the BOOK, so main can ask it without trusting the window. An active id that
 * names nobody under the lock is refused, not read as the owner.
 */
function mayManageTokens(store) {
  const settings = (store && store.settings) || {};
  if (!settings.operatorLockEnabled) return true;
  let Rbac;
  try { Rbac = require('./rbac.js'); } catch (_) { return false; }
  const ops = Array.isArray(store && store.operators) ? store.operators : [];
  const op = settings.activeOperatorId ? ops.find((o) => o && o.id === settings.activeOperatorId) : null;
  if (!op) return false;
  const role = op.roleKey || Rbac.roleFromLegacy(op.role, { hasLock: true });
  return Rbac.can(role, 'security', 'edit', { lockEnabled: true });
}

/** The token list a save may write: its own when allowed, else the one on disk. */
function guardTokenSave(incoming, disk) {
  if (!incoming || !incoming.settings) return incoming;
  const tokensOf = (s) => (s && s.settings && s.settings.lanApi && Array.isArray(s.settings.lanApi.apiTokens) ? s.settings.lanApi.apiTokens : []);
  const ids = (list) => list.map((t) => (t && t.id) || '').sort().join('|');
  const inT = tokensOf(incoming);
  const diskT = tokensOf(disk);
  if (ids(inT) === ids(diskT)) return incoming;
  if (mayManageTokens(disk || incoming)) return incoming;
  return { ...incoming, settings: { ...incoming.settings, lanApi: { ...(incoming.settings.lanApi || {}), apiTokens: diskT } } };
}

module.exports = {
  SCOPES, TOKEN_PREFIX, LAST_USED_EVERY_MS, mayManageTokens, guardTokenSave,
  isValidScope, hashToken, generateToken, bearerFromHeader,
  verifyToken, hasScope, requiredScope, redactTokens, markUsed,
};
