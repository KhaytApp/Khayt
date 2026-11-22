/**
 * The pure-JS scrypt (lib/scrypt-js.js) must match Node's crypto.scryptSync
 * byte-for-byte — otherwise the browser would derive a different KEK and fail to
 * unlock. Inject Node's PBKDF2 here; the PWA injects WebCrypto's.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { scrypt } = require('../lib/scrypt-js.js');

const pbkdf2Node = (pw, salt, iters, len) =>
  new Uint8Array(crypto.pbkdf2Sync(Buffer.from(pw), Buffer.from(salt), iters, len, 'sha256'));

const nodeScrypt = (pw, salt, { N, r, p, keyLen }) =>
  new Uint8Array(crypto.scryptSync(Buffer.from(pw), Buffer.from(salt), keyLen, { N, r, p, maxmem: 256 * 1024 * 1024 }));

const enc = (s) => new TextEncoder().encode(s);

async function matches(pw, salt, kdf) {
  const mine = await scrypt(enc(pw), enc(salt), kdf, pbkdf2Node);
  const theirs = nodeScrypt(pw, salt, kdf);
  assert.deepEqual([...mine], [...theirs]);
}

test('matches Node scrypt — small params (N=16, r=1)', async () => {
  await matches('password', 'NaCl', { N: 16, r: 1, p: 1, keyLen: 32 });
});

test('matches Node scrypt — r=8 multi-block (N=1024, the test KDF)', async () => {
  await matches('correct horse battery staple', 'seasalt-1234', { N: 1024, r: 8, p: 1, keyLen: 32 });
});

test('matches Node scrypt — p>1', async () => {
  await matches('pleaseletmein', 'SodiumChloride', { N: 64, r: 8, p: 3, keyLen: 64 });
});

test('matches Node scrypt — production params (N=32768, r=8)', async () => {
  await matches('a-real-sync-passphrase', 'sixteen.byte.salt', { N: 32768, r: 8, p: 1, keyLen: 32 });
});

test('rejects non-power-of-two N', async () => {
  await assert.rejects(() => scrypt(enc('p'), enc('s'), { N: 1000, r: 8, p: 1, keyLen: 32 }, pbkdf2Node));
});
