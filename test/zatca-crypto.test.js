const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { signInvoiceData } = require('../lib/zatca-crypto');

test('signInvoiceData signs SHA256(canonical) — signature verifies, hash matches', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'secp256k1' });
  const canonical = '<Invoice><cbc:ID>INV-0001</cbc:ID></Invoice>';

  const { hashBase64, signatureBase64 } = signInvoiceData(crypto, privateKey, canonical);

  // Reported hash is SHA256 of the canonical invoice.
  const expectedHash = crypto.createHash('SHA256').update(canonical).digest('base64');
  assert.equal(hashBase64, expectedHash);

  // ZATCA verifies the ECDSA signature over SHA256(canonical). crypto.verify
  // with 'SHA256' hashes the message once — must validate the signature.
  const sig = Buffer.from(signatureBase64, 'base64');
  assert.equal(crypto.verify('SHA256', Buffer.from(canonical), publicKey, sig), true);
});

test('signInvoiceData does NOT double-hash (regression guard)', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'secp256k1' });
  const canonical = '<Invoice>double-hash regression</Invoice>';
  const { signatureBase64 } = signInvoiceData(crypto, privateKey, canonical);
  const sig = Buffer.from(signatureBase64, 'base64');

  // The old (buggy) implementation signed SHA256(SHA256(canonical)); verifying
  // over the pre-computed digest must FAIL for the corrected single-hash output.
  const digest = crypto.createHash('SHA256').update(canonical).digest();
  assert.equal(crypto.verify('SHA256', digest, publicKey, sig), false);
});
