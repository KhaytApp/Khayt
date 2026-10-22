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
const { fileId, uploadId, grantId } = inputs;
const dk = H(inputs.dk);
const dek = H(inputs.shopDek);
const vk = H(vec.derived.vaultKey);

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

test('vault key, dedupe key (both from the DEK) and the per-upload chunk key', async () => {
  assert.equal(hx(await V.deriveVaultKey(dek)), vec.derived.vaultKey);
  assert.equal(hx(await V.deriveDedupeKey(dek)), vec.derived.dedupeKey);
  assert.notEqual(vec.derived.dedupeKey, vec.derived.vaultKey);
  assert.equal(hx(await V.deriveChunkKey(dk, uploadId)), vec.derived.chunkKey);
  assert.notEqual(hx(await V.deriveChunkKey(dk, 'u_other')), vec.derived.chunkKey);
});

test('every file case: chunks, chunk hashes, manifest, dedupe tag', async () => {
  for (const f of vec.files) {
    const pt = plaintext(f.size);
    assert.equal(V.chunkCount(f.size, f.chunkBytes), f.chunks.length, f.name);
    const out = await V.encryptFile(dk, fileId, uploadId, pt, { chunkBytes: f.chunkBytes });
    assert.equal(out.chunks.length, f.chunks.length, f.name);
    out.chunks.forEach((sealed, i) => {
      const c = f.chunks[i];
      assert.equal(sealed.length, c.plainBytes + 16, `${f.name} chunk ${i} length`);
      if (c.sealed) assert.equal(hx(sealed), c.sealed, `${f.name} chunk ${i}`);
      assert.equal(out.chunkHashes[i], c.sha256, `${f.name} chunk ${i} hash`);
    });
    assert.equal(V.manifestJson(f.size, out.chunkHashes, f.chunkBytes), f.manifestJson, f.name);
    assert.equal(out.manifestHash, f.manifestHash, f.name);
    assert.equal(await V.dedupeTag(dek, pt), f.dedupeTag, f.name);
    assert.equal(hx(await V.sha256(pt)), f.plaintextSha256, f.name);

    const back = await V.decryptFile(dk, fileId, uploadId, out.chunks,
      { size: f.size, chunks: out.chunkHashes }, f.manifestHash, { chunkBytes: f.chunkBytes });
    assert.deepEqual(back, pt, `${f.name} round trip`);
  }
});

test('the real 4 MiB case is cut at 4194304 by default', async () => {
  const f = vec.files.find((x) => x.name === 'real-4mib-plus-one');
  assert.equal(f.chunkBytes, V.CHUNK_BYTES);
  assert.equal(f.chunks[0].plainBytes, 4194304);
  const out = await V.encryptFile(dk, fileId, uploadId, plaintext(f.size));
  assert.equal(out.manifestHash, f.manifestHash);
});

test('key wraps: shop and both grant wraps, byte for byte, and back', async () => {
  const w = await V.wrapDkForShop(vk, dk, fileId, uploadId, { _nonce: H(vec.wraps.shop.nonce) });
  assert.equal(hx(w), vec.wraps.shop.wrapped);
  assert.equal(w.length, 60);
  assert.deepEqual(await V.unwrapDkForShop(vk, w, fileId, uploadId), dk);

  for (const [k, kk] of [['grantNoPassword', 'linkKeyNoPassword'], ['grantPassword', 'linkKeyPassword']]) {
    const lk = H(vec.derived[kk]);
    const g = await V.wrapDkForGrant(lk, dk, grantId, fileId, { _nonce: H(vec.wraps[k].nonce) });
    assert.equal(hx(g), vec.wraps[k].wrapped, k);
    assert.deepEqual(await V.unwrapDkForGrant(lk, g, grantId, fileId), dk, k);
  }
});

test('link keys: explicit null, and a non-NFC password at the real scrypt cost', async () => {
  const s = H(inputs.linkSecret);
  assert.equal(hx(await V.deriveLinkKey(s, grantId, null)), vec.derived.linkKeyNoPassword);
  assert.notEqual(inputs.password, inputs.password.normalize('NFC'), 'the vector password must not already be NFC');
  assert.equal(hx(new TextEncoder().encode(inputs.password.normalize('NFC'))), vec.derived.passwordNfcHex);
  assert.equal(hx(await V.deriveLinkKey(s, grantId, inputs.password)), vec.derived.linkKeyPassword);
  assert.equal(hx(await V.deriveLinkKey(s, grantId, inputs.password.normalize('NFC'))), vec.derived.linkKeyPassword);
  await assert.rejects(V.deriveLinkKey(s, grantId, ''), /non-empty/);
  await assert.rejects(V.deriveLinkKey(s, grantId), /must be null/, 'a forgotten argument is not "no password"');
  await assert.rejects(V.deriveLinkKey(s, grantId, undefined), /must be null/);
});

test('an injected scrypt is always asked for the format\'s fixed cost', async () => {
  let asked;
  const fake = (pw, salt, kdf) => { asked = kdf; return new Uint8Array(32); };
  await V.deriveLinkKey(H(inputs.linkSecret), grantId, 'x', { scrypt: fake, _scryptN: 2, N: 2 });
  assert.deepEqual(asked, { N: 32768, r: 8, p: 1, keyLen: 32 });
});

test('linkPasswordOk: at least 10 Unicode scalars after NFC', () => {
  assert.equal(V.linkPasswordOk('123456789'), false);
  assert.equal(V.linkPasswordOk('1234567890'), true);
  // 9 letters + e + U+0301 is 11 scalars raw but 10 after NFC → ok
  assert.equal(V.linkPasswordOk('abcdefghié'), true);
  // 8 letters + e + U+0301 is 10 scalars raw but 9 after NFC → not ok
  assert.equal(V.linkPasswordOk('abcdefghé'), false);
  assert.equal(V.linkPasswordOk('\u{1F600}'.repeat(10)), true, 'astral scalars count once');
  assert.equal(V.linkPasswordOk(null), false);
  assert.equal(V.linkPasswordOk(undefined), false);
});

test('shop meta record: byte for byte, seq, and back', async () => {
  const sealed = await V.encryptMeta(vk, fileId, uploadId, vec.meta.json, { _nonce: H(vec.meta.nonce) });
  assert.equal(hx(sealed), vec.meta.sealed);
  assert.equal(await V.decryptMetaText(vk, fileId, uploadId, sealed), vec.meta.json);
  const m = await V.decryptMeta(vk, fileId, uploadId, sealed, 7);
  assert.equal(m.seq, 7);
  await assert.rejects(V.decryptMeta(vk, fileId, uploadId, sealed, 8), /rollback/);
  await rejects(V.decryptMeta(vk, 'f_other', uploadId, sealed), 'meta under another fileId');
  await rejects(V.decryptMeta(vk, fileId, 'u_other', sealed), 'meta under another uploadId');
  await assert.rejects(V.encryptMeta(vk, fileId, uploadId, { name: 'x' }), /seq/);
  await assert.rejects(V.encryptMeta(vk, fileId, uploadId, { seq: 1.5 }), /seq/);
});

test('checkMetaSeq: equal is fine, lower is a rollback, nothing remembered accepts', () => {
  assert.equal(V.checkMetaSeq(5, null), 5);
  assert.equal(V.checkMetaSeq(5, 5), 5);
  assert.equal(V.checkMetaSeq(6, 5), 6);
  assert.throws(() => V.checkMetaSeq(4, 5), /rollback/);
  assert.throws(() => V.checkMetaSeq(-1, null), /seq/);
  assert.throws(() => V.checkMetaSeq('5', null), /seq/);
  assert.equal(V.checkMetaSeq(2 ** 53 - 1, null), 2 ** 53 - 1);
  assert.throws(() => V.checkMetaSeq(2 ** 53, null), /2\^53-1/);
  assert.throws(() => V.checkMetaSeq(5, 2 ** 53), /2\^53-1/);
});

test('seq 2^53 is refused on write and on read (the shared vector)', async () => {
  await assert.rejects(V.encryptMeta(vk, fileId, uploadId, inputs.metaSeqTooBigJson), /2\^53-1/);
  await assert.rejects(V.encryptMeta(vk, fileId, uploadId, '{"seq":9007199254740993}'), /2\^53-1/);
  await V.encryptMeta(vk, fileId, uploadId, '{"seq":9007199254740991}');
  // sealed by node:crypto, so authentic: only the seq rule can refuse it
  await assert.rejects(V.decryptMeta(vk, fileId, uploadId, H(vec.meta.sealedSeqTooBig)), /2\^53-1/);
  await assert.rejects(V.decryptMetaText(vk, fileId, uploadId, H(vec.meta.sealedSeqTooBig)), /2\^53-1/);
});

test('link meta record: byte for byte under both link keys, validated, and back', async () => {
  const want = JSON.parse(vec.linkMeta.json);
  for (const [kk, sk] of [['linkKeyNoPassword', 'sealedNoPassword'], ['linkKeyPassword', 'sealedPassword']]) {
    const lk = H(vec.derived[kk]);
    // From an object (canonical key order) and from the exact string: same bytes.
    const a = await V.encryptLinkMeta(lk, grantId, fileId, { kind: want.kind, size: want.size, name: want.name,
      manifestHash: want.manifestHash, uploadId: want.uploadId }, { _nonce: H(vec.linkMeta.nonce) });
    const b = await V.encryptLinkMeta(lk, grantId, fileId, vec.linkMeta.json, { _nonce: H(vec.linkMeta.nonce) });
    assert.equal(hx(a), vec.linkMeta[sk], kk);
    assert.equal(hx(b), vec.linkMeta[sk], kk);
    assert.deepEqual(await V.decryptLinkMeta(lk, grantId, fileId, a), want);
    await rejects(V.decryptLinkMeta(lk, 'g_other', fileId, a));
    await rejects(V.decryptLinkMeta(lk, grantId, 'f_other', a));
  }
  // The share page's whole path: link meta → pinned manifestHash → file.
  const f25 = vec.files.find((x) => x.name === 'two-and-a-half-chunks');
  const lm = await V.decryptLinkMeta(H(vec.derived.linkKeyNoPassword), grantId, fileId, H(vec.linkMeta.sealedNoPassword));
  const gdk = await V.unwrapDkForGrant(H(vec.derived.linkKeyNoPassword), H(vec.wraps.grantNoPassword.wrapped), grantId, fileId);
  const pt = await V.decryptFile(gdk, fileId, lm.uploadId, f25.chunks.map((c) => H(c.sealed)),
    { size: lm.size, chunks: f25.chunks.map((c) => c.sha256) }, lm.manifestHash, { chunkBytes: 16 });
  assert.deepEqual(pt, plaintext(40));
  await assert.rejects(V.encryptLinkMeta(vk, grantId, fileId, { ...want, manifestHash: 'nope' }), /manifestHash/);
  await assert.rejects(V.encryptLinkMeta(vk, grantId, fileId, { ...want, uploadId: 'a|b' }), /uploadId/);
});

// ── tamper rejection ───────────────────────────────────────────────────

const f25 = vec.files.find((x) => x.name === 'two-and-a-half-chunks');
const sealedOf = (i) => H(f25.chunks[i].sealed);
const hashes25 = f25.chunks.map((c) => c.sha256);

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
  const hashes = hashes25;
  const opt = { chunkBytes: 16 };
  await assert.rejects(V.decryptFile(dk, fileId, uploadId, [chunks[1], chunks[0], chunks[2]],
    { size: f25.size, chunks: hashes }, f25.manifestHash, opt), /does not match the manifest/);
  const swapped = [hashes[1], hashes[0], hashes[2]];
  await assert.rejects(V.decryptFile(dk, fileId, uploadId, [chunks[1], chunks[0], chunks[2]],
    { size: f25.size, chunks: swapped }, f25.manifestHash, opt), /manifest does not match/);
  await rejects(V.decryptFile(dk, fileId, uploadId, [chunks[1], chunks[0], chunks[2]],
    { size: f25.size, chunks: swapped }, await V.manifestHash(f25.size, swapped, 16), opt));
  const tSize = 32; const tHashes = hashes.slice(0, 2);
  await rejects(V.decryptFile(dk, fileId, uploadId, chunks.slice(0, 2),
    { size: tSize, chunks: tHashes }, await V.manifestHash(tSize, tHashes, 16), opt));
  await assert.rejects(V.decryptFile(dk, fileId, uploadId, chunks.slice(0, 2),
    { size: f25.size, chunks: tHashes }, f25.manifestHash, opt), /chunk count/);
});

test('streaming reader: succeeds only after the last chunk, refuses early end and extra chunks', async () => {
  const man = { size: f25.size, chunks: hashes25 };
  const opt = { chunkBytes: 16 };
  const r = await V.createReader(dk, fileId, uploadId, man, f25.manifestHash, opt);
  await r.push(sealedOf(0));
  await r.push(sealedOf(1));
  assert.equal(r.done, false);
  assert.throws(() => r.finish(), /ended before the last chunk/);
  await r.push(sealedOf(2));
  assert.equal(r.done, true);
  assert.deepEqual(r.finish(), { size: 40, chunks: 3 });
  await assert.rejects(r.push(sealedOf(2)), /after the last chunk/);
  assert.throws(() => r.finish(), /failed/);

  // A failed chunk poisons the reader: no later success.
  const r2 = await V.createReader(dk, fileId, uploadId, man, f25.manifestHash, opt);
  await assert.rejects(r2.push(sealedOf(1)), /does not match the manifest/);
  await assert.rejects(r2.push(sealedOf(0)), /already failed/);
  assert.throws(() => r2.finish(), /failed/);

  // Empty stream for an empty file still has to see its one (empty) last chunk.
  const e = vec.files.find((x) => x.name === 'empty');
  const r3 = await V.createReader(dk, fileId, uploadId, { size: 0, chunks: [e.chunks[0].sha256] }, e.manifestHash, opt);
  assert.throws(() => r3.finish(), /ended before the last chunk/);
  assert.equal((await r3.push(H(e.chunks[0].sealed))).length, 0);
  assert.deepEqual(r3.finish(), { size: 0, chunks: 1 });
});

test('sizes above 2^53 are refused before anything else runs', async () => {
  const huge = 2 ** 60;
  assert.throws(() => V.chunkCount(huge), /2\^53/);
  assert.throws(() => V.chunkCount(2 ** 53 + 2), /2\^53/);
  assert.equal(V.chunkCount(2 ** 53), 2 ** 53 / V.CHUNK_BYTES);
  assert.equal(V.chunkCount(2 ** 53 - 1, 3), Math.ceil((2 ** 53 - 1) / 3));
  // a huge-size manifest with junk hashes: the size check fires first
  assert.throws(() => V.manifestJson(huge, ['junk']), /2\^53/);
  await assert.rejects(V.manifestHash(huge, ['junk']), /2\^53/);
  await assert.rejects(V.createReader(dk, fileId, uploadId, { size: huge, chunks: ['junk'] }, 'x'), /2\^53/);
  await assert.rejects(V.createReader(dk, fileId, uploadId, { size: -1, chunks: [] }, 'x'), /2\^53/);
  await assert.rejects(V.createReader(dk, fileId, uploadId, { size: 1.5, chunks: [] }, 'x'), /2\^53/);
});

test('wraps refuse a wrong aad, a wrong kek and a tampered byte', async () => {
  const w = H(vec.wraps.shop.wrapped);
  await rejects(V.unwrapDkForShop(vk, w, fileId, 'u_other'));
  await rejects(V.unwrapDkForShop(vk, w, 'f_other', uploadId));
  await rejects(V.unwrapDkForShop(H(vec.derived.dedupeKey), w, fileId, uploadId));
  const t = H(vec.wraps.shop.wrapped); t[0] ^= 1;
  await rejects(V.unwrapDkForShop(vk, t, fileId, uploadId));
  await rejects(V.unwrapDkForGrant(vk, w, grantId, fileId));
  await rejects(V.unwrapDkForGrant(H(vec.derived.linkKeyNoPassword), H(vec.wraps.grantPassword.wrapped), grantId, fileId));
});

test('ids: only [A-Za-z0-9_-]{1,64} is accepted', async () => {
  const bad = ['a|b', 'a|́b', '\uD800', 'a\uD800b', '', 'x'.repeat(65), 'café', 'a b', 'a.b', 'a/b',
    '١', 'a\u0000'];
  for (const b of bad) {
    await assert.rejects(V.encryptChunk(dk, b, uploadId, 0, true, new Uint8Array(0)), /1-64/, JSON.stringify(b));
    await assert.rejects(V.encryptChunk(dk, fileId, b, 0, true, new Uint8Array(0)), /1-64/, JSON.stringify(b));
    await assert.rejects(V.wrapDkForGrant(vk, dk, b, fileId), /1-64/, JSON.stringify(b));
  }
  await assert.rejects(V.encryptChunk(dk, 42, uploadId, 0, true, new Uint8Array(0)), /1-64/);
  await V.encryptChunk(dk, 'x'.repeat(64), 'A-z_0', 0, true, new Uint8Array(0));
  await assert.rejects(V.encryptChunk(dk, fileId, uploadId, 0, 1, new Uint8Array(0)), /boolean/);
});

test('random paths: fresh data keys and nonces differ, and round-trip', async () => {
  const a = V.newDataKey(); const b = V.newDataKey();
  assert.equal(a.length, 32); assert.notDeepEqual(a, b);
  const w1 = await V.wrapDkForShop(vk, a, fileId, uploadId);
  const w2 = await V.wrapDkForShop(vk, a, fileId, uploadId);
  assert.notDeepEqual(w1.subarray(0, 12), w2.subarray(0, 12));
  assert.deepEqual(await V.unwrapDkForShop(vk, w1, fileId, uploadId), a);
  const s = V.newLinkSecret();
  assert.deepEqual(V.unb64url(V.b64url(s)), s);
  assert.doesNotMatch(V.b64url(s), /[+/=]/);
});
