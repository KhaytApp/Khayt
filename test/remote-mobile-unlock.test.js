/**
 * End-to-end proof of the remote-mobile unlock pipeline: the *browser-portable*
 * code (lib/scrypt-js.js + lib/sync-crypto-web.js) must unlock a keyset created
 * by the desktop and decrypt a desktop-encrypted store — using NO Node-only
 * crypto except PBKDF2 (which scrypt-js.test.js already proved matches the
 * browser's WebCrypto PBKDF2). This is exactly what the PWA will run.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const sc = require('../lib/sync-crypto.js');         // desktop encrypt (Node scrypt)
const web = require('../lib/sync-crypto-web.js');    // browser decrypt (WebCrypto AES-GCM)
const { scrypt } = require('../lib/scrypt-js.js');   // browser scrypt (pure JS)

// PBKDF2: Node here, WebCrypto in the PWA — proven equivalent in scrypt-js.test.js.
const pbkdf2 = (pw, salt, iters, len) =>
  new Uint8Array(crypto.pbkdf2Sync(Buffer.from(pw), Buffer.from(salt), iters, len, 'sha256'));
const browserScrypt = (secretBytes, saltBytes, kdf) => scrypt(secretBytes, saltBytes, kdf, pbkdf2);

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };
const STORE = { printLog: [{ id: 'o1', project: 'Phone stand', price: 75 }], clients: [{ id: 'c1', name: 'Sara' }] };

test('full PWA pipeline: desktop keyset+blob → browser scrypt+AES-GCM unlock+decrypt', async () => {
  // Desktop side (what the app + server hold):
  const { keyset } = sc.createKeyset('my sync passphrase', { kdf: FAST_KDF });
  const dek = sc.unlockWithPassphrase('my sync passphrase', keyset);
  const blob = sc.encryptStore(STORE, dek);

  // Browser side (what the PWA runs): scrypt-js + sync-crypto-web only.
  const webDek = await web.unlockDek({ keyset, passphrase: 'my sync passphrase', scrypt: browserScrypt });
  const store = await web.decryptStore(blob, webDek);

  assert.deepEqual(store, STORE, 'PWA reproduces the shop store from ciphertext');
});

test('wrong passphrase fails the full pipeline', async () => {
  const { keyset } = sc.createKeyset('right-one', { kdf: FAST_KDF });
  await assert.rejects(() => web.unlockDek({ keyset, passphrase: 'wrong-one', scrypt: browserScrypt }));
});
