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

module.exports = {
  SCOPES, TOKEN_PREFIX,
  isValidScope, hashToken, generateToken, bearerFromHeader,
  verifyToken, hasScope, requiredScope, redactTokens,
};
