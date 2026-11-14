'use strict';
/**
 * This computer's quote-link signing key (pay link v2, Ed25519).
 *
 * Design: ~/Khayt-proposals/pay-link-open-signing.md (approved 14 Nov 2026),
 * checked against contracts/quote-link-v2.vector.json. Each signing device
 * has its own key; the private half never syncs, and only the public half is
 * published to Khayt Cloud. lib/quote-pay-link.js builds every byte that is
 * signed (`signingInputV2`, `endorsementInput`) and takes no key; this file
 * is the only place the desktop holds one.
 *
 * The seed is stored at `settings.quoteLinkKey.seed`: sealed at rest
 * (SECRET_PATHS) and removed from everything that leaves this computer
 * (PER_DEVICE_PATHS) — /api/store, the cloud push and exports.
 *
 * Main process only.
 */
const crypto = require('crypto');
const PayLink = require('../quote-pay-link.js');

// PKCS#8 prefix for a raw 32-byte Ed25519 seed (RFC 8410).
const PKCS8_ED25519 = Buffer.from('302e020100300506032b657004220420', 'hex');
const B64URL_32 = /^[A-Za-z0-9_-]{43}$/;

const b64 = (bytes) => Buffer.from(bytes).toString('base64url');
const seedOk = (seed) => typeof seed === 'string' && B64URL_32.test(seed);

function privateKeyOf(seed) {
  return crypto.createPrivateKey({ key: Buffer.concat([PKCS8_ED25519, Buffer.from(seed, 'base64url')]), format: 'der', type: 'pkcs8' });
}

/** The key id: the RFC 7638 thumbprint (SHA-256, base64url) of the public key. */
function kidOf(x) {
  return b64(crypto.createHash('sha256').update(PayLink.thumbprintInput(x), 'utf8').digest());
}

/** The public half of a seed, as the JWK Khayt Cloud publishes. Null for a bad seed. */
function publicOf(seed) {
  if (!seedOk(seed)) return null;
  const jwk = crypto.createPublicKey(privateKeyOf(seed)).export({ format: 'jwk' });
  return { kty: 'OKP', crv: 'Ed25519', x: jwk.x, kid: kidOf(jwk.x), use: 'sig', alg: 'EdDSA' };
}

/** A fresh key: `{ seed, x, kid, createdAt }`. The seed is the private half — store it sealed. */
function generate(now = Date.now()) {
  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  const der = privateKey.export({ format: 'der', type: 'pkcs8' });
  const seed = b64(der.subarray(der.length - 32));
  const pub = publicOf(seed);
  return { seed, x: pub.x, kid: pub.kid, createdAt: new Date(now).toISOString() };
}

/** Ed25519 over the ASCII signing input: 64 bytes. Null when the seed or input is not usable. */
function sign(input, seed) {
  if (!seedOk(seed) || typeof input !== 'string' || !input) return null;
  return crypto.sign(null, Buffer.from(input, 'utf8'), privateKeyOf(seed));
}

/**
 * A v2 pay link for these claims (`PayLink.claimsForV2`), signed with this
 * computer's key. '' when anything is missing.
 */
function signLink(claims, seed) {
  const pub = publicOf(seed);
  if (!pub) return '';
  const input = PayLink.signingInputV2(claims, pub.kid);
  const sig = input ? sign(input, seed) : null;
  return sig ? PayLink.tokenFromV2(input, sig) : '';
}

/**
 * This computer's key vouching for another key of the same shop (a new
 * device, or its own replacement at rotation). `fields` is
 * `{ iss, new_kid, x, iat }`. '' when anything is missing.
 */
function endorse(fields, seed) {
  const pub = publicOf(seed);
  if (!pub) return '';
  const input = PayLink.endorsementInput(fields, pub.kid);
  const sig = input ? sign(input, seed) : null;
  return sig ? PayLink.endorsementFrom(input, sig) : '';
}

module.exports = { kidOf, publicOf, generate, sign, signLink, endorse, seedOk };
