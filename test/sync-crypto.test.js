/**
 * Phase 1 E2E crypto tests. See docs/KHAYT-3.0-PHASE1-SPEC.md §3 / §11 and
 * docs/KHAYT-3.0-SECURITY-MODEL.md §4. Pure crypto — no network, no DOM.
 *
 * Uses low scrypt cost (FAST_KDF) so the suite stays quick; production keysets
 * carry their own params, so this only affects test speed, not the contract.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const sc = require('../lib/sync-crypto.js');
const crypto = require('node:crypto');

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };
const mk = (pass) => sc.createKeyset(pass, { kdf: FAST_KDF });
const STORE = { printLog: [{ id: 'o1', price: 100 }], clients: [{ id: 'c1', name: 'سارة' }] };

test('round-trip: passphrase unlocks the DEK and the store decrypts equal', () => {
  const { keyset } = mk('correct horse battery');
  const dek = sc.unlockWithPassphrase('correct horse battery', keyset);
  const blob = sc.encryptStore(STORE, dek);
  assert.deepEqual(sc.decryptStore(blob, dek), STORE);
});

test('recovery key unlocks the same DEK (Arabic content survives the round-trip)', () => {
  const { keyset, recoveryKey } = mk('pass-1');
  const dekP = sc.unlockWithPassphrase('pass-1', keyset);
  const dekR = sc.unlockWithRecovery(recoveryKey, keyset);
  assert.deepEqual(dekP, dekR, 'both paths recover the identical DEK');
  const blob = sc.encryptStore(STORE, dekP);
  assert.equal(sc.decryptStore(blob, dekR).clients[0].name, 'سارة');
});

test('wrong passphrase throws (GCM auth tag is the wrong-secret check)', () => {
  const { keyset } = mk('right');
  assert.throws(() => sc.unlockWithPassphrase('wrong', keyset));
});

test('wrong recovery key throws', () => {
  const { keyset } = mk('p');
  assert.throws(() => sc.unlockWithRecovery('AAAA-BBBB-CCCC-DDDD', keyset));
});

test('decrypting a store blob with the wrong DEK throws', () => {
  const a = mk('a'); const b = mk('b');
  const dekA = sc.unlockWithPassphrase('a', a.keyset);
  const dekB = sc.unlockWithPassphrase('b', b.keyset);
  const blob = sc.encryptStore(STORE, dekA);
  assert.throws(() => sc.decryptStore(blob, dekB));
});

test('tampering with ciphertext is detected (authenticated encryption)', () => {
  const { keyset } = mk('p');
  const dek = sc.unlockWithPassphrase('p', keyset);
  const blob = sc.encryptStore(STORE, dek);
  const ctBuf = Buffer.from(blob.ct, 'base64'); ctBuf[0] ^= 0x01;        // flip a bit
  const tampered = { ...blob, ct: ctBuf.toString('base64') };
  assert.throws(() => sc.decryptStore(tampered, dek));
});

test('changePassphrase: old fails, new works, recovery still works, blob still decrypts', () => {
  const { keyset, recoveryKey } = mk('old-pass');
  const dek0 = sc.unlockWithPassphrase('old-pass', keyset);
  const blob = sc.encryptStore(STORE, dek0);          // encrypted under the original DEK
  const rotated = sc.changePassphrase(keyset, 'old-pass', 'new-pass');

  assert.throws(() => sc.unlockWithPassphrase('old-pass', rotated), 'old passphrase no longer unlocks');
  const dekNew = sc.unlockWithPassphrase('new-pass', rotated);
  assert.deepEqual(dekNew, dek0, 'DEK unchanged across passphrase rotation');
  assert.deepEqual(sc.decryptStore(blob, dekNew), STORE, 'existing blob still decrypts (no re-encryption)');
  // recovery key is unaffected by a passphrase change
  assert.deepEqual(sc.unlockWithRecovery(recoveryKey, rotated), dek0);
});

test('recovery key encode/decode round-trips and is human-grouped', () => {
  const { recoveryKey } = mk('p');
  assert.match(recoveryKey, /^[A-Z2-7]{4}(-[A-Z2-7]{4})+/, 'grouped base32');
  // decode→encode is stable
  const raw = sc.decodeRecovery(recoveryKey);
  assert.equal(sc.encodeRecovery(raw), recoveryKey);
  // tolerant of spaces / lowercase / missing dashes on input
  const messy = recoveryKey.toLowerCase().replace(/-/g, ' ');
  assert.deepEqual(sc.decodeRecovery(messy), raw);
});

test('server-can\'t-decrypt by construction: the keyset carries no usable key', () => {
  const { keyset } = mk('super-secret-passphrase');
  // What the server would store. It must contain NO plaintext DEK/passphrase.
  const serverHas = JSON.stringify(keyset);
  assert.ok(!serverHas.includes('super-secret-passphrase'), 'passphrase never stored');
  // The DEK is only obtainable via a secret the server never has:
  assert.throws(() => sc.unlockWithPassphrase('', keyset));
  // wrapped entries are opaque {salt,iv,ct,tag} — no raw key field
  for (const w of [keyset.wrappedByPassphrase, keyset.wrappedByRecovery]) {
    assert.deepEqual(Object.keys(w).sort(), ['ct', 'iv', 'salt', 'tag']);
  }
});

test('two keysets for the same passphrase yield different DEKs (random DEK + salt)', () => {
  const a = mk('same'); const b = mk('same');
  const dekA = sc.unlockWithPassphrase('same', a.keyset);
  const dekB = sc.unlockWithPassphrase('same', b.keyset);
  assert.notDeepEqual(dekA, dekB, 'each connection gets an independent DEK');
});

/* ── compressed store blobs ────────────────────────────────────────────────── */

/**
 * push() sends the WHOLE store every time, base64'd in a JSON body and
 * uncompressed: a real 55,593-byte store went out as 74,124 bytes where gzip
 * would have sent 7,556. Bandwidth is the binding cost of running the cloud
 * (docs/KHAYT-CLOUD-COST-PER-SHOP.md), so the payload gets compressed.
 *
 * The rollout constraint these tests exist to protect: nothing reads `blob.v`,
 * so a client older than this change ignores `z` as well, JSON.parses gzip
 * bytes and throws on every pull. Readers must ship a release before writers.
 */

test('a compressed blob round-trips', () => {
  const dek = crypto.randomBytes(32);
  const store = { printLog: [{ id: 'A', client: 'x'.repeat(500) }], settings: { a: 1 } };
  const blob = sc.encryptStore(store, dek, { compress: true });
  assert.deepEqual(sc.decryptStore(blob, dek), store);
});

test('compression is ON — writers now emit gzip', () => {
  // Phase two. beta.17 taught every client to READ both shapes; this is the
  // release where writers start producing the smaller one. Measured on a real
  // store: 59,148 bytes on the wire became 9,563.
  const dek = crypto.randomBytes(32);
  const blob = sc.encryptStore({ a: 1 }, dek);
  assert.equal(blob.z, 'gzip', 'the marker rides on every blob a writer produces');
});

test('a client can still be told explicitly NOT to compress', () => {
  // The option survives the flip, so reverting is a constant rather than a
  // rewrite — and so a caller with a reason can opt out without one.
  const dek = crypto.randomBytes(32);
  assert.equal(sc.encryptStore({ a: 1 }, dek, { compress: false }).z, undefined);
});

test('an uncompressed blob still decrypts — every shop in the field has one', () => {
  const dek = crypto.randomBytes(32);
  const store = { printLog: [], settings: {} };
  assert.deepEqual(sc.decryptStore(sc.encryptStore(store, dek), dek), store);
});

test('the marker is on the envelope, outside the encryption', () => {
  // A reader has to know how to treat the payload BEFORE it can decrypt it, so
  // `z` cannot live inside the ciphertext.
  const dek = crypto.randomBytes(32);
  const blob = sc.encryptStore({ a: 1 }, dek, { compress: true });
  assert.equal(blob.z, 'gzip');
  assert.ok(blob.iv && blob.ct && blob.tag, 'and the envelope is otherwise unchanged');
});

test('compression actually shrinks a realistic store', () => {
  // A tiny object can gzip LARGER than its input, so assert the property on
  // something store-shaped — repetitive records are what actually travels.
  const dek = crypto.randomBytes(32);
  const store = { printLog: Array.from({ length: 200 }, (_, i) => ({
    id: 'ORD-' + i, status: 'completed', client: 'Acme Robotics', material: 'PLA',
    date: '2026-08-11', price: 120, parts: [{ name: 'Bracket', material: 'PLA', printTime: 6 }],
  })) };
  // Both sides EXPLICIT. This used to take the default as its uncompressed
  // baseline, which silently became a gzip-vs-gzip comparison the moment
  // COMPRESS_ON_WRITE flipped — the assertion would have passed forever while
  // measuring nothing.
  const plain = JSON.stringify(sc.encryptStore(store, dek, { compress: false })).length;
  const gz = JSON.stringify(sc.encryptStore(store, dek, { compress: true })).length;
  assert.ok(gz < plain / 4, `expected a large saving, got ${gz} vs ${plain}`);
});

test('a wrong key still fails on a compressed blob, rather than yielding junk', () => {
  // GCM authenticates before this decompresses, so the failure must stay a
  // crypto failure and not become a gunzip error that reads like corruption.
  const dek = crypto.randomBytes(32);
  const blob = sc.encryptStore({ a: 1 }, dek, { compress: true });
  assert.throws(() => sc.decryptStore(blob, crypto.randomBytes(32)));
});
