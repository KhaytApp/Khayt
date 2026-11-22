'use strict';

/**
 * Salted PIN/recovery hashing with backward compatibility.
 *
 * New format (preferred):   "p2$<iterations>$<saltHex>$<derivedHex>"  (PBKDF2-SHA256)
 * Legacy format (verified):  64-char lowercase hex                    (unsalted SHA-256)
 *
 * verifyPin() accepts BOTH so existing operator/admin PINs keep working; new PINs
 * are written in the salted PBKDF2 format. Anything that is neither (e.g. the very
 * old base64 scheme) is treated as unrecognized and fails verification, so the UI
 * re-prompts to set a fresh PIN (it must NOT be silently wiped on the strength of a
 * length check — use isManagedHash() to decide that).
 */
const crypto = require('crypto');

const PREFIX = 'p2';
const PBKDF2_ITERS = 200000;
const KEYLEN = 32;
const DIGEST = 'sha256';

function isPbkdf2Hash(stored) {
  if (typeof stored !== 'string' || !stored.startsWith(PREFIX + '$')) return false;
  const parts = stored.split('$');
  return parts.length === 4 && /^\d+$/.test(parts[1]) && /^[0-9a-f]+$/i.test(parts[2]) && /^[0-9a-f]+$/i.test(parts[3]);
}

function isLegacySha256Hash(stored) {
  return typeof stored === 'string' && /^[0-9a-f]{64}$/i.test(stored);
}

/** True for any hash format this module can verify (PBKDF2 or legacy SHA-256). */
function isManagedHash(stored) {
  return isPbkdf2Hash(stored) || isLegacySha256Hash(stored);
}

/** Hash a PIN/secret into the salted PBKDF2 format. */
/**
 * A PIN as its digits, whichever keyboard typed them: Arabic-Indic (٠-٩) and
 * Persian (۰-۹) become 0-9. The Arabic macOS layout types the first, so the
 * same PIN typed on one Mac and another was two different PINs — refused when
 * set, and counted as WRONG at sign-in, towards the lockout (alpha.62 review).
 * The Mac's PinHash.swift does exactly this.
 */
function normalizePin(plain) {
  return String(plain == null ? '' : plain)
    .replace(/[\u0660-\u0669]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[\u06F0-\u06F9]/g, (d) => String(d.charCodeAt(0) - 0x06F0));
}

function hashPin(plain, iterations = PBKDF2_ITERS) {
  const salt = crypto.randomBytes(16);
  const dk = crypto.pbkdf2Sync(normalizePin(plain), salt, iterations, KEYLEN, DIGEST);
  return `${PREFIX}$${iterations}$${salt.toString('hex')}$${dk.toString('hex')}`;
}

/** Constant-time verify of a PIN against either format. Returns boolean. */
/**
 * The digits first; then, if they differ, the text as typed — a PIN set in
 * Arabic digits before `normalizePin` existed was hashed as those characters,
 * and must still open.
 */
function verifyPin(plain, stored) {
  const digits = normalizePin(plain);
  if (verifyExact(digits, stored)) return true;
  return digits !== String(plain == null ? '' : plain) && verifyExact(String(plain), stored);
}

function verifyExact(plain, stored) {
  if (isPbkdf2Hash(stored)) {
    const [, itersStr, saltHex, hashHex] = stored.split('$');
    const iters = parseInt(itersStr, 10);
    if (!iters) return false;
    const expected = Buffer.from(hashHex, 'hex');
    const dk = crypto.pbkdf2Sync(String(plain), Buffer.from(saltHex, 'hex'), iters, expected.length, DIGEST);
    return expected.length === dk.length && crypto.timingSafeEqual(expected, dk);
  }
  if (isLegacySha256Hash(stored)) {
    const h = crypto.createHash(DIGEST).update(String(plain)).digest();
    const expected = Buffer.from(stored, 'hex');
    return crypto.timingSafeEqual(h, expected);
  }
  return false;
}

/** Should this stored hash be upgraded to the salted format on next successful auth? */
function needsUpgrade(stored) {
  return isLegacySha256Hash(stored);
}

module.exports = { normalizePin, hashPin, verifyPin, isPbkdf2Hash, isLegacySha256Hash, isManagedHash, needsUpgrade, PBKDF2_ITERS };
