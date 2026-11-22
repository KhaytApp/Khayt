/**
 * Browser decrypt path (lib/sync-crypto-web.js) must be byte-compatible with the
 * desktop encryption (lib/sync-crypto.js). We encrypt with the desktop module,
 * then decrypt with the web module using WebCrypto subtle + Node scrypt as the
 * injected KDF (the PWA will inject scrypt-js with the same params).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const sc = require('../lib/sync-crypto.js');
const web = require('../lib/sync-crypto-web.js');

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };
// Node scrypt as the injected KDF (same params ⇒ same KEK as scrypt-js will give).
const scryptNode = (secretBytes, saltBytes, kdf) =>
  new Uint8Array(crypto.scryptSync(Buffer.from(secretBytes), Buffer.from(saltBytes), kdf.keyLen,
    { N: kdf.N, r: kdf.r, p: kdf.p, maxmem: 96 * 1024 * 1024 }));

const STORE = { printLog: [{ id: 'o1', project: 'Vase', price: 120 }], settings: { bizEn: 'Acme' } };

test('web module unlocks the same DEK the desktop wrapped', async () => {
  const { keyset } = sc.createKeyset('correct horse', { kdf: FAST_KDF });
  const desktopDek = sc.unlockWithPassphrase('correct horse', keyset); // Buffer
  const webDek = await web.unlockDek({ keyset, passphrase: 'correct horse', scrypt: scryptNode });
  assert.deepEqual([...webDek], [...desktopDek], 'same DEK bytes across implementations');
});

test('web module decrypts a desktop-encrypted store blob', async () => {
  const { keyset } = sc.createKeyset('s3cret-pass', { kdf: FAST_KDF });
  const dek = sc.unlockWithPassphrase('s3cret-pass', keyset);
  const blob = sc.encryptStore(STORE, dek);

  const webDek = await web.unlockDek({ keyset, passphrase: 's3cret-pass', scrypt: scryptNode });
  const out = await web.decryptStore(blob, webDek);
  assert.deepEqual(out, STORE, 'browser decrypt reproduces the store exactly');
});

test('wrong passphrase fails (GCM auth) in the web path', async () => {
  const { keyset } = sc.createKeyset('right', { kdf: FAST_KDF });
  await assert.rejects(() => web.unlockDek({ keyset, passphrase: 'wrong', scrypt: scryptNode }));
});

test('web ENCRYPT is desktop-readable (phone writes → desktop reads)', async () => {
  const { keyset } = sc.createKeyset('w-pass', { kdf: FAST_KDF });
  const dek = sc.unlockWithPassphrase('w-pass', keyset);
  const edited = { printLog: [{ id: 'o1', status: 'printing', rev: 3 }] };

  // Phone encrypts with WebCrypto…
  const blob = await web.encryptStore(edited, dek);
  assert.ok(blob.v && blob.iv && blob.ct && blob.tag, 'matches the desktop envelope shape');
  // …desktop decrypts it.
  const back = sc.decryptStore(blob, dek);
  assert.deepEqual(back, edited);
});

test('web encrypt → web decrypt round-trips', async () => {
  const { keyset } = sc.createKeyset('rt', { kdf: FAST_KDF });
  const dek = await web.unlockDek({ keyset, passphrase: 'rt', scrypt: scryptNode });
  const blob = await web.encryptStore(STORE, dek);
  assert.deepEqual(await web.decryptStore(blob, dek), STORE);
});

test('tampered store blob is rejected', async () => {
  const { keyset } = sc.createKeyset('p', { kdf: FAST_KDF });
  const dek = sc.unlockWithPassphrase('p', keyset);
  const blob = sc.encryptStore(STORE, dek);
  const webDek = await web.unlockDek({ keyset, passphrase: 'p', scrypt: scryptNode });
  const tampered = { ...blob, ct: blob.ct.slice(0, -4) + (blob.ct.slice(-4) === 'AAAA' ? 'BBBB' : 'AAAA') };
  await assert.rejects(() => web.decryptStore(tampered, webDek));
});

/* ── compressed store blobs (two-release rollout) ──────────────────────────── */

/**
 * Sync is blob-first and was uncompressed: a measured 55,593-byte store went out
 * as 74,124 bytes where gzip would have sent 7,556. Bandwidth is what running
 * the cloud actually costs, so the desktop will start writing gzipped blobs.
 *
 * Nothing reads `blob.v`, so a client that predates this ignores `z` too and
 * JSON.parses gzip bytes. Every reader therefore has to learn the new shape a
 * release BEFORE any writer emits it — including this one, which is what the
 * phone and the portal run.
 */

test('the browser reads a gzipped blob the desktop wrote', async () => {
  const node = require('../lib/sync-crypto.js');
  const dek = require('node:crypto').randomBytes(32);
  const store = { printLog: [{ id: 'A', price: 10 }], settings: { bizEn: 'Shop' } };
  const blob = node.encryptStore(store, dek, { compress: true });
  assert.equal(blob.z, 'gzip', 'the marker travels on the envelope, in the clear');
  assert.deepEqual(await web.decryptStore(blob, dek), store);
});

test('the browser still reads an uncompressed blob', async () => {
  // Every shop's cloud copy is this shape today; it must keep working forever.
  const node = require('../lib/sync-crypto.js');
  const dek = require('node:crypto').randomBytes(32);
  const store = { printLog: [], settings: {} };
  // Explicitly uncompressed — writers emit gzip by default now, and the point of
  // this test is the OLD shape, which every shop that has not yet re-synced still
  // has sitting in the cloud.
  const blob = node.encryptStore(store, dek, { compress: false });
  assert.equal(blob.z, undefined, 'no marker means no compression');
  assert.deepEqual(await web.decryptStore(blob, dek), store);
});

test('the two implementations agree on the marker string', async () => {
  // They are separate constants in separate files; a typo in either would make
  // the desktop write blobs the phone silently treats as uncompressed.
  const src = require('node:fs').readFileSync(require.resolve('../lib/sync-crypto-web.js'), 'utf8');
  const nodeSrc = require('node:fs').readFileSync(require.resolve('../lib/sync-crypto.js'), 'utf8');
  const pick = (s) => (s.match(/STORE_COMPRESSION = '([^']+)'/) || [])[1];
  assert.equal(pick(src), pick(nodeSrc));
  assert.equal(pick(src), 'gzip');
});
