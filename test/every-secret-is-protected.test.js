'use strict';
/**
 * Every credential in the store gets all five protections — checked by doing them.
 *
 * There were four hand-written lists of which fields hold secrets (encrypt on
 * save, decrypt on load, mask for the renderer, restore on merge) plus a fifth
 * for the keychain explanation. Thirty paths, five lists, kept in step by care.
 * Being on four of them was a distinct bug each time, and each one is quiet:
 *
 *   not encrypted → cleartext in the file people copy around and email to us
 *   not decrypted → the app uses "__enc__AAAA…" as the credential
 *   not masked    → the renderer holds it; so does any screenshot or bug report
 *   not restored  → saving an unrelated setting writes the mask over it, and the
 *                   credential is destroyed with no way back
 *
 * All of that has happened here. `eventWebhooks.secret` was redacted on export
 * but written in the clear. `smsConfig.*`, `accountingSync.secret`, `ai.apiKey`
 * and `cloud.token` were masked on load and not restored on save — one
 * load→save round trip wrote the literal mask to disk and destroyed the
 * owner's off-site backup token.
 *
 * The lists are one list now (lib/store-secret-paths.js). This is what makes
 * that safe: it walks that list and proves each protection by performing it,
 * so a path added there is covered the moment it is added — and a path that
 * somehow escapes one of the five fails here rather than in a shop.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SECRET_PATHS } = require('../lib/store-secret-paths.js');
const { harness, storeWith, valueAt, assertProtected, MASK } = require('./helpers/store-io-harness.js');

test('every listed secret is encrypted, decrypted, masked, restored and counted', () => {
  assert.ok(SECRET_PATHS.length >= 30, `only ${SECRET_PATHS.length} paths listed; secrets have gone missing`);
  for (const p of SECRET_PATHS) assertProtected(assert, p, p);
});

test('nothing that is not a secret gets masked', () => {
  // The mirror of the bug above: masking an ordinary setting means the renderer
  // writes "__KHAYT_MASKED__" back as the shop's VAT number.
  const io = harness();
  const store = {
    settings: { shopName: 'Khayt', vatNumber: '300000000000003', currency: 'SAR',
                lanApi: { port: 7777, enabled: true } },
    machines: [{ id: 'M1', name: 'U1', printerApi: { host: '192.168.1.9', type: 'snapmaker' } }],
  };
  const masked = io.maskStoreSecretsForRenderer(JSON.parse(JSON.stringify(store)));
  assert.deepEqual(masked, store, 'a non-secret field was masked');
});

test('an empty secret is left alone, not encrypted into something', () => {
  // '' must stay '' — encrypting it produces a non-empty __enc__ blob, and then
  // "is a bucket configured?" answers yes for a shop that configured nothing.
  const io = harness();
  for (const p of SECRET_PATHS) {
    assert.equal(valueAt(io.encryptForDisk(storeWith(p, '')), p), '',
      `${p}: an empty value was turned into a secret`);
  }
});

test('an already-encrypted value is not encrypted twice', () => {
  // Double encryption is unrecoverable: the inner __enc__ is decrypted once on
  // load and handed to the API as ciphertext.
  const io = harness();
  for (const p of SECRET_PATHS) {
    const once = io.encryptForDisk(storeWith(p, 'S3CR3T'));
    const twice = io.encryptForDisk(once);
    assert.equal(valueAt(twice, p), valueAt(once, p), `${p} was encrypted twice`);
  }
});

test('the mask is never written to disk as if it were the secret', () => {
  // The exact shape of the round trip that destroyed the cloud token.
  const io = harness();
  for (const p of SECRET_PATHS) {
    io.putOnDisk(storeWith(p, 'S3CR3T-' + p));
    const shownToRenderer = io.maskStoreSecretsForRenderer(storeWith(p, 'S3CR3T-' + p));
    assert.equal(valueAt(shownToRenderer, p), MASK);
    const savedBack = io.mergeStoreSecretsFromDisk(shownToRenderer);
    const onDisk = io.encryptForDisk(savedBack);
    const decrypted = io.decryptStoreSecrets(JSON.parse(JSON.stringify(onDisk)));
    assert.equal(valueAt(decrypted, p), 'S3CR3T-' + p,
      `${p}: a load→save round trip destroyed the credential`);
  }
});

test('hasPlaintextSecrets answers no when everything is already encrypted', () => {
  // It gates the one-time keychain explanation. Answering yes always would show
  // it forever; answering no always would show it after the first touch.
  const io = harness();
  for (const p of SECRET_PATHS) {
    assert.equal(io.hasPlaintextSecrets(io.encryptForDisk(storeWith(p, 'S3CR3T'))), false,
      `${p}: an encrypted store still reports plaintext secrets`);
    assert.equal(io.hasPlaintextSecrets(storeWith(p, MASK)), false,
      `${p}: a masked value was mistaken for a plaintext secret`);
  }
  assert.equal(io.hasPlaintextSecrets({ settings: { shopName: 'Khayt' } }), false);
});

test('every field a carrier marks secret is on the list', () => {
  // `carriers.js` has declared `apiKey` and `webhookSecret` as `secret: true`
  // since it was written, and neither was here — so a shop's SMSA key sat in
  // the store in the clear and reached the renderer unmasked. The carrier
  // module is where a new secret field would be added, so it is read directly.
  const { listCarriers, getCarrier } = require('../lib/carriers.js');
  const ids = (typeof listCarriers === 'function' ? listCarriers() : ['smsa', 'aramex', 'spl'].map(getCarrier))
    .map((c) => (typeof c === 'string' ? c : c.id));
  let checked = 0;
  for (const id of ids) {
    const carrier = getCarrier(id);
    for (const f of (carrier && carrier.configFields) || []) {
      if (!f.secret) continue;
      checked += 1;
      assert.ok(SECRET_PATHS.includes(`settings.shipping.${id}.${f.key}`),
        `settings.shipping.${id}.${f.key} is marked secret by carriers.js and is not protected`);
    }
  }
  assert.ok(checked >= 6, `only ${checked} carrier secrets were found to check — the carrier list moved`);
});
