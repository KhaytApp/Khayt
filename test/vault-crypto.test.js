/**
 * lib/vault-crypto.js against the shared vectors.
 *
 * The vectors are produced by scripts/gen-vault-crypto-vectors.js from
 * node:crypto primitives — NOT from the module under test — so a pass here
 * means WebCrypto and node:crypto agree on docs/vault-format.md. The Swift twin
 * (VaultCryptoTests) reads the same file.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const V = require('../lib/vault-crypto.js');
const { build } = require('../scripts/gen-vault-crypto-vectors.js');

const FIX = path.join(__dirname, 'fixtures', 'vault-crypto-vectors.json');
const vec = JSON.parse(fs.readFileSync(FIX, 'utf8'));
const { inputs } = vec;
const H = V.unhex;
const hx = V.hex;

function plaintext(n) {
  const b = new Uint8Array(n);
  for (let k = 0; k < n; k++) b[k] = (k * 31 + 7) & 0xff;
  return b;
}
async function rejects(p, what) {
  await assert.rejects(p, /vault: authentication failed/, what);
}

test('the fixture is what the generator writes (not hand-edited, not stale)', () => {
  assert.deepEqual(vec, JSON.parse(JSON.stringify(build())));
});

test('vault key and dedupe key', async () => {
  const vk = await V.deriveVaultKey(H(inputs.shopDek));
  assert.equal(hx(vk), vec.derived.vaultKey);
  assert.equal(hx(await V.deriveDedupeKey(vk)), vec.derived.dedupeKey);
});

test('every file case: chunks, chunk hashes, manifest, dedupe tag', async () => {
  const vk = H(vec.derived.vaultKey);
  const dk = H(inputs.dk);
  for (const f of vec.files) {
    const pt = plaintext(f.size);
    assert.equal(V.chunkCount(f.size, f.chunkBytes), f.chunks.length, f.name);
    const out = await V.encryptFile(dk, inputs.fileId, inputs.uploadId, pt, { chunkBytes: f.chunkBytes });
    assert.equal(out.chunks.length, f.chunks.length, f.name);
    out.chunks.forEach((sealed, i) => {
      const c = f.chunks[i];
      assert.equal(sealed.length, c.plainBytes + 16, `${f.name} chunk ${i} length`);
      if (c.sealed) assert.equal(hx(sealed), c.sealed, `${f.name} chunk ${i}`);
      assert.equal(out.chunkHashes[i], c.sha256, `${f.name} chunk ${i} hash`);
    });
    assert.equal(V.manifestJson(f.size, out.chunkHashes, f.chunkBytes), f.manifestJson, f.name);
    assert.equal(out.manifestHash, f.manifestHash, f.name);
    assert.equal(await V.dedupeTag(vk, pt), f.dedupeTag, f.name);
    assert.equal(hx(await V.sha256(pt)), f.plaintextSha256, f.name);

    const back = await V.decryptFile(dk, inputs.fileId, inputs.uploadId, out.chunks,
      { size: f.size, chunks: out.chunkHashes }, f.manifestHash, { chunkBytes: f.chunkBytes });
    assert.deepEqual(back, pt, `${f.name} round trip`);
  }
});

test('the real 4 MiB case is cut at 4194304 by default', async () => {
  const f = vec.files.find((x) => x.name === 'real-4mib-plus-one');
  assert.equal(f.chunkBytes, V.CHUNK_BYTES);
  assert.equal(f.chunks[0].plainBytes, 4194304);
  const out = await V.encryptFile(H(inputs.dk), inputs.fileId, inputs.uploadId, plaintext(f.size));
  assert.equal(out.manifestHash, f.manifestHash);
});

test('key wraps: shop and both grant wraps, byte for byte, and back', async () => {
  const vk = H(vec.derived.vaultKey);
  const dk = H(inputs.dk);
  const w = await V.wrapDkForShop(vk, dk, inputs.fileId, inputs.uploadId, { _nonce: H(vec.wraps.shop.nonce) });
  assert.equal(hx(w), vec.wraps.shop.wrapped);
  assert.equal(w.length, 60);
  assert.deepEqual(await V.unwrapDkForShop(vk, w, inputs.fileId, inputs.uploadId), dk);

  for (const [k, kk] of [['grantNoPassword', 'linkKeyNoPassword'], ['grantPassword', 'linkKeyPassword']]) {
    const lk = H(vec.derived[kk]);
    const g = await V.wrapDkForGrant(lk, dk, inputs.grantId, inputs.fileId, { _nonce: H(vec.wraps[k].nonce) });
    assert.equal(hx(g), vec.wraps[k].wrapped, k);
    assert.deepEqual(await V.unwrapDkForGrant(lk, g, inputs.grantId, inputs.fileId), dk, k);
  }
});

test('link keys: without a password, and with a non-NFC password at the real scrypt cost', async () => {
  const s = H(inputs.linkSecret);
  assert.equal(hx(await V.deriveLinkKey(s, inputs.grantId, null)), vec.derived.linkKeyNoPassword);
  assert.notEqual(inputs.password, inputs.password.normalize('NFC'), 'the vector password must not already be NFC');
  assert.equal(hx(new TextEncoder().encode(inputs.password.normalize('NFC'))), vec.derived.passwordNfcHex);
  // Default path: lib/scrypt-js.js over WebCrypto PBKDF2, N = 2^15.
  assert.equal(hx(await V.deriveLinkKey(s, inputs.grantId, inputs.password)), vec.derived.linkKeyPassword);
  // The already-composed spelling gives the same key.
  assert.equal(hx(await V.deriveLinkKey(s, inputs.grantId, inputs.password.normalize('NFC'))), vec.derived.linkKeyPassword);
  await assert.rejects(V.deriveLinkKey(s, inputs.grantId, ''), /non-empty/);
});

test('meta record: byte for byte, and back', async () => {
  const vk = H(vec.derived.vaultKey);
  const sealed = await V.encryptMeta(vk, inputs.fileId, vec.meta.json, { _nonce: H(vec.meta.nonce) });
  assert.equal(hx(sealed), vec.meta.sealed);
  assert.equal(await V.decryptMetaText(vk, inputs.fileId, sealed), vec.meta.json);
  assert.deepEqual(await V.decryptMeta(vk, inputs.fileId, sealed), JSON.parse(vec.meta.json));
  await rejects(V.decryptMeta(vk, 'f_other', sealed), 'meta under another fileId');
});

// ── tamper rejection ───────────────────────────────────────────────────

const f25 = vec.files.find((x) => x.name === 'two-and-a-half-chunks');
const sealedOf = (i) => H(f25.chunks[i].sealed);
const dk = H(inputs.dk);
const { fileId, uploadId } = inputs;

test('decryptChunk opens each chunk only at its own position', async () => {
  for (const c of f25.chunks) {
    const pt = await V.decryptChunk(dk, fileId, uploadId, c.index, c.last, H(c.sealed));
    assert.deepEqual(pt, plaintext(f25.size).subarray(c.index * 16, c.index * 16 + c.plainBytes));
  }
});

test('rejects a wrong index', async () => {
  await rejects(V.decryptChunk(dk, fileId, uploadId, 1, false, sealedOf(0)));
  await rejects(V.decryptChunk(dk, fileId, uploadId, 0, false, sealedOf(1)));
});

test('rejects truncation: a non-last chunk presented as last', async () => {
  await rejects(V.decryptChunk(dk, fileId, uploadId, 1, true, sealedOf(1)));
  // and the last chunk presented as not-last (an appended chunk)
  await rejects(V.decryptChunk(dk, fileId, uploadId, 2, false, sealedOf(2)));
});

test('rejects a wrong file id, a wrong upload id, a wrong key, a flipped bit', async () => {
  await rejects(V.decryptChunk(dk, 'f_other', uploadId, 0, false, sealedOf(0)), 'file id');
  await rejects(V.decryptChunk(dk, fileId, 'u_other', 0, false, sealedOf(0)), 'upload id');
  await rejects(V.decryptChunk(V.newDataKey(), fileId, uploadId, 0, false, sealedOf(0)), 'key');
  const bad = sealedOf(0); bad[3] ^= 1;
  await rejects(V.decryptChunk(dk, fileId, uploadId, 0, false, bad), 'ciphertext bit');
  const badTag = sealedOf(0); badTag[badTag.length - 1] ^= 0x80;
  await rejects(V.decryptChunk(dk, fileId, uploadId, 0, false, badTag), 'tag bit');
});

test('decryptFile rejects reordering, a dropped last chunk, and a forged manifest', async () => {
  const chunks = f25.chunks.map((c) => H(c.sealed));
  const hashes = f25.chunks.map((c) => c.sha256);
  const opt = { chunkBytes: 16 };
  // reordered chunks with the honest manifest → hash mismatch
  await assert.rejects(V.decryptFile(dk, fileId, uploadId, [chunks[1], chunks[0], chunks[2]],
    { size: f25.size, chunks: hashes }, f25.manifestHash, opt), /does not match the manifest/);
  // reordered chunks AND a manifest rewritten to match → its hash is not the pinned one
  const swapped = [hashes[1], hashes[0], hashes[2]];
  await assert.rejects(V.decryptFile(dk, fileId, uploadId, [chunks[1], chunks[0], chunks[2]],
    { size: f25.size, chunks: swapped }, f25.manifestHash, opt), /manifest does not match/);
  // even if an attacker could pin the forged manifest, the AAD index still refuses it
  await rejects(V.decryptFile(dk, fileId, uploadId, [chunks[1], chunks[0], chunks[2]],
    { size: f25.size, chunks: swapped }, await V.manifestHash(f25.size, swapped, 16), opt));
  // truncated: last chunk dropped and the manifest shortened consistently
  const tSize = 32; const tHashes = hashes.slice(0, 2);
  await rejects(V.decryptFile(dk, fileId, uploadId, chunks.slice(0, 2),
    { size: tSize, chunks: tHashes }, await V.manifestHash(tSize, tHashes, 16), opt));
  // chunk count disagreeing with size is refused before any decrypt
  await assert.rejects(V.decryptFile(dk, fileId, uploadId, chunks.slice(0, 2),
    { size: f25.size, chunks: tHashes }, f25.manifestHash, opt), /chunk count/);
});

test('wraps refuse a wrong aad, a wrong kek and a tampered byte', async () => {
  const vk = H(vec.derived.vaultKey);
  const w = H(vec.wraps.shop.wrapped);
  await rejects(V.unwrapDkForShop(vk, w, fileId, 'u_other'));
  await rejects(V.unwrapDkForShop(vk, w, 'f_other', uploadId));
  await rejects(V.unwrapDkForShop(H(vec.derived.dedupeKey), w, fileId, uploadId));
  const t = H(vec.wraps.shop.wrapped); t[0] ^= 1; // the nonce
  await rejects(V.unwrapDkForShop(vk, t, fileId, uploadId));
  // a shop wrap is not a grant wrap even under the same key bytes
  await rejects(V.unwrapDkForGrant(vk, w, inputs.grantId, fileId));
  // password grant does not open with the no-password key
  await rejects(V.unwrapDkForGrant(H(vec.derived.linkKeyNoPassword), H(vec.wraps.grantPassword.wrapped), inputs.grantId, fileId));
});

test('ids containing "|" are refused (they would make AADs ambiguous)', async () => {
  await assert.rejects(V.encryptChunk(dk, 'a|b', 'c', 0, true, new Uint8Array(0)), /must not contain/);
  await assert.rejects(V.wrapDkForShop(dk, dk, 'a', 'b|c'), /must not contain/);
  await assert.rejects(V.encryptChunk(dk, fileId, uploadId, 0, 1, new Uint8Array(0)), /boolean/);
});

test('random paths: fresh data keys and nonces differ, and round-trip', async () => {
  const a = V.newDataKey(); const b = V.newDataKey();
  assert.equal(a.length, 32); assert.notDeepEqual(a, b);
  const vk = H(vec.derived.vaultKey);
  const w1 = await V.wrapDkForShop(vk, a, fileId, uploadId);
  const w2 = await V.wrapDkForShop(vk, a, fileId, uploadId);
  assert.notDeepEqual(w1.subarray(0, 12), w2.subarray(0, 12));
  assert.deepEqual(await V.unwrapDkForShop(vk, w1, fileId, uploadId), a);
  const s = V.newLinkSecret();
  assert.deepEqual(V.unb64url(V.b64url(s)), s);
  assert.doesNotMatch(V.b64url(s), /[+/=]/);
});
