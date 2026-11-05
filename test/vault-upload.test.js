'use strict';
// lib/vault-upload.js against a fake Khayt Cloud + fake object storage (no
// network): the wire (routes, bodies, headers), dedupe, parts paging,
// parts-missing re-PUTs, abandon on failure, resume from a spool, a pinned
// byte-for-byte fixture, and a round trip that decrypts what the cloud kept.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const VC = require('../lib/vault-crypto.js');
const { createVaultClient } = require('../lib/vault-client.js');
const { uploadFile, sealedSizes, memorySpool } = require('../lib/vault-upload.js');
const { prepareItems } = require('../lib/vault-links.js');

const CB = VC.CHUNK_BYTES;
const FIX = path.join(__dirname, 'fixtures', 'vault-upload-fixture');
const BASE = 'https://cloud.example.com';
const PREFIX = BASE + '/v1/shops/shop_1';
const DEK = new Uint8Array(32).map((_, i) => i);
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const b64 = (u) => Buffer.from(u).toString('base64');
const unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));

function pattern(n, mul = 31, add = 7) {
  const b = new Uint8Array(n);
  for (let k = 0; k < n; k++) b[k] = (k * mul + add) & 0xff;
  return b;
}

/**
 * The cloud and its object storage in one fetch. `opts`: pageSize (parts per
 * page), ids (fixed uploadId/fileId), dropOnce (part indexes whose first PUT
 * is accepted but not kept), failPut (index → status, every time), failPutOnce.
 */
function fakeCloud(opts = {}) {
  const pageSize = opts.pageSize || 256;
  const calls = [];
  const uploads = new Map();
  const files = new Map();
  const tags = new Map(opts.tags || []);
  let rev = 0, nUpload = 0, nFile = 0;
  const failPut = new Map(Object.entries(opts.failPut || {}).map(([k, v]) => [Number(k), v]));
  const failPutOnce = new Map(Object.entries(opts.failPutOnce || {}).map(([k, v]) => [Number(k), v]));
  const dropOnce = new Set(opts.dropOnce || []);
  let inFlight = 0, maxInFlight = 0;

  const page = (u, from) => {
    const out = [];
    for (let i = from; i < Math.min(u.sizes.length, from + pageSize); i++) {
      out.push({ index: i, size: u.sizes[i], url: `https://store.example/up/${u.uploadId}/${i}?sig=x` });
    }
    return out;
  };

  async function fetch(url, init) {
    const headers = init.headers || {};
    const isPut = url.startsWith('https://store.example/');
    const call = { url, method: init.method, headers, redirect: init.redirect,
      body: isPut ? init.body : (init.body === undefined ? undefined : JSON.parse(init.body)) };
    calls.push(call);
    const reply = (status, body) => ({ status, json: async () => { if (body === undefined) throw new Error('no body'); return body; } });
    if (isPut) {
      inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setImmediate(r));
      inFlight--;
      const [, uploadId, idx] = new URL(url).pathname.match(/^\/up\/([^/]+)\/(\d+)$/);
      const i = Number(idx);
      if (failPutOnce.has(i)) { const s = failPutOnce.get(i); failPutOnce.delete(i); return reply(s); }
      if (failPut.has(i)) return reply(failPut.get(i));
      const u = uploads.get(uploadId);
      assert.ok(u && !u.abandoned, 'PUT to a live upload');
      assert.equal(Number(headers['content-length']), init.body.length);
      assert.equal(init.body.length, u.sizes[i]);
      if (dropOnce.has(i)) { dropOnce.delete(i); return reply(200); }
      u.parts.set(i, Uint8Array.from(init.body));
      return reply(200);
    }
    assert.equal(headers.authorization, 'Bearer tok');
    assert.equal(headers['x-delta-capable'], '1');
    const tail = url.slice(PREFIX.length);
    let m;
    if (init.method === 'POST' && tail === '/vault/uploads') {
      const b = call.body;
      if (tags.has(b.tag)) return reply(409, { reason: 'duplicate', ...tags.get(b.tag) });
      const fileId = b.fileId || (opts.ids && opts.ids.fileId) || `f_${++nFile}`;
      const uploadId = (opts.ids && opts.ids.uploadId) || `u_${++nUpload}`;
      const f = files.get(fileId);
      const version = f ? Math.max(...f.versions.map((v) => v.version)) + 1 : ((opts.ids && opts.ids.version) || 1);
      const u = { uploadId, fileId, version, sizes: b.sizes, tag: b.tag, parts: new Map(), abandoned: false };
      uploads.set(uploadId, u);
      return reply(201, { uploadId, fileId, version, expiresAt: '2026-11-07T00:00:00Z', parts: page(u, 0) });
    }
    if (init.method === 'GET' && (m = tail.match(/^\/vault\/uploads\/([^/]+)\/parts\?from=(\d+)$/))) {
      const u = uploads.get(m[1]);
      if (!u || u.abandoned) return reply(404, { reason: 'unknown-upload' });
      return reply(200, { parts: page(u, Number(m[2])) });
    }
    if (init.method === 'POST' && (m = tail.match(/^\/vault\/uploads\/([^/]+)\/complete$/))) {
      const u = uploads.get(m[1]);
      if (!u || u.abandoned) return reply(404, { reason: 'unknown-upload' });
      const missing = u.sizes.map((_, i) => i).filter((i) => !u.parts.has(i));
      if (missing.length) return reply(409, { reason: 'parts-missing', indexes: missing });
      const b = call.body;
      const chunks = u.sizes.map((_, i) => u.parts.get(i));
      let f = files.get(u.fileId);
      if (!f) { f = { fileId: u.fileId, versions: [], meta: null }; files.set(u.fileId, f); }
      f.versions.push({ version: u.version, uploadId: u.uploadId, wrappedKey: b.wrappedKey, versionMeta: b.versionMeta,
        chunks: chunks.length, bytes: u.sizes.reduce((a, n) => a + n, 0), sealed: chunks });
      f.head = u.version;
      if (b.meta) f.meta = b.meta;
      tags.set(u.tag, { fileId: u.fileId, version: u.version });
      u.done = true;
      return reply(201, { fileId: u.fileId, version: u.version, rev: ++rev, conflict: false });
    }
    if (init.method === 'DELETE' && (m = tail.match(/^\/vault\/uploads\/([^/]+)$/))) {
      const u = uploads.get(m[1]);
      if (!u) return reply(404, { reason: 'unknown-upload' });
      u.abandoned = true;
      return reply(200, {});
    }
    throw new Error('unexpected ' + init.method + ' ' + url);
  }
  const client = createVaultClient({ baseUrl: BASE, shopId: 'shop_1', token: 'tok', fetch });
  const feedRow = (fileId) => {
    const f = files.get(fileId);
    return { fileId, head: f.head, meta: f.meta,
      versions: f.versions.map(({ sealed, ...v }) => v) };
  };
  return { fetch, client, calls, uploads, files, feedRow,
    puts: () => calls.filter((c) => c.method === 'PUT'),
    route: (method, re) => calls.filter((c) => c.method === method && re.test(c.url)),
    get maxInFlight() { return maxInFlight; } };
}

const putIndex = (c) => Number(new URL(c.url).pathname.split('/').pop());

test('sealedSizes: plaintext + 16 per chunk, an empty file is one 16-byte chunk', () => {
  assert.deepEqual(sealedSizes(0), [16]);
  assert.deepEqual(sealedSizes(5), [21]);
  assert.deepEqual(sealedSizes(CB), [CB + 16]);
  assert.deepEqual(sealedSizes(CB + 1), [CB + 16, 17]);
});

test('pinned fixture: the exact bytes expected.json names (node:crypto, not this code)', async () => {
  const inp = JSON.parse(fs.readFileSync(path.join(FIX, 'inputs.json'), 'utf8'));
  const exp = JSON.parse(fs.readFileSync(path.join(FIX, 'expected.json'), 'utf8'));
  const cloud = fakeCloud({ ids: { fileId: inp.fileId, uploadId: inp.uploadId, version: inp.version } });
  const bytes = pattern(inp.plaintext.size, inp.plaintext.mul, inp.plaintext.add);
  const r = await uploadFile({
    dek: Buffer.from(inp.shopDek, 'hex'), bytes, name: inp.name, path: inp.path, kind: inp.kind,
    key: inp.key, recordId: inp.recordId, lastSeq: inp.lastSeq, deviceId: inp.deviceId, client: cloud.client,
    _test: { dataKey: Buffer.from(inp.dataKey, 'hex'), wrapNonce: Buffer.from(inp.nonces.wrap, 'hex'),
      versionMetaNonce: Buffer.from(inp.nonces.versionMeta, 'hex'), metaNonce: Buffer.from(inp.nonces.meta, 'hex') },
  });
  assert.equal(r.duplicate, false);
  assert.equal(r.fileId, inp.fileId);
  assert.equal(r.sha256, exp.plaintextSha256);
  assert.equal(r.manifestHash, exp.manifestHash);
  const [start] = cloud.route('POST', /\/vault\/uploads$/);
  assert.deepEqual(start.body, { ...exp.startBody, deviceId: inp.deviceId });
  const [complete] = cloud.route('POST', /\/complete$/);
  assert.deepEqual(complete.body, exp.completeBody);
  const puts = cloud.puts().sort((a, b) => putIndex(a) - putIndex(b));
  assert.deepEqual(puts.map((p) => sha(p.body)), exp.chunks.map((c) => c.sha256));
  assert.deepEqual(puts.map((p) => p.body.length), exp.sizes);
  // The sealed records hold exactly the JSON the fixture names.
  const vk = await VC.deriveVaultKey(Buffer.from(inp.shopDek, 'hex'));
  assert.equal(await VC.decryptMetaText(vk, inp.fileId, inp.uploadId, unb64(exp.meta)), exp.metaJson);
  assert.equal((await VC.decryptVersionMeta(vk, inp.fileId, inp.uploadId, unb64(exp.versionMeta))).manifestHash, exp.manifestHash);
  assert.deepEqual(r.meta, JSON.parse(exp.metaJson));
  assert.equal(r.meta.seq, inp.lastSeq + 1);
});

test('wire: routes, auth only to the cloud, presigned PUT bare with exact Content-Length, ≤3 in flight', async () => {
  const cloud = fakeCloud();
  const bytes = pattern(4 * CB + 10);
  const r = await uploadFile({ dek: DEK, bytes, name: 'a.stl', kind: 'stl', client: cloud.client, deviceId: 'd'.repeat(80) });
  assert.equal(r.version, 1);
  assert.equal(r.rev, 1);
  const order = cloud.calls.map((c) => c.method + ' ' + (c.method === 'PUT' ? 'part' : c.url.slice(PREFIX.length)));
  assert.equal(order[0], 'POST /vault/uploads');
  assert.equal(order.at(-1), `POST /vault/uploads/${r.uploadId}/complete`);
  assert.equal(cloud.puts().length, 5);
  for (const p of cloud.puts()) {
    assert.equal(p.headers.authorization, undefined);
    assert.equal(Object.keys(p.headers).some((k) => /auth|delta/i.test(k)), false);
    assert.equal(p.headers['content-length'], String(p.body.length));
    assert.equal(p.redirect, 'manual');
  }
  assert.ok(cloud.maxInFlight <= 3 && cloud.maxInFlight >= 2, `in flight ${cloud.maxInFlight}`);
  const [start] = cloud.route('POST', /\/vault\/uploads$/);
  assert.equal(start.body.chunkBytes, CB);
  assert.equal(start.body.deviceId.length, 64);
  assert.equal(start.body.fileId, undefined);
  assert.deepEqual(start.body.sizes, sealedSizes(bytes.length));
  assert.equal(start.body.tag, await VC.dedupeTagFromDigest(DEK, crypto.createHash('sha256').update(bytes).digest()));
  // A new version names its file and base.
  const r2 = await uploadFile({ dek: DEK, bytes: pattern(20, 3, 1), name: 'a.stl', client: cloud.client,
    fileId: r.fileId, baseVersion: 1, lastSeq: 1 });
  const s2 = cloud.route('POST', /\/vault\/uploads$/)[1];
  assert.equal(s2.body.fileId, r.fileId);
  assert.equal(s2.body.baseVersion, 1);
  assert.equal(r2.version, 2);
  assert.equal(r2.meta.seq, 2);
});

test('duplicate: bytes the shop already has (from either app) upload nothing', async () => {
  const cloud = fakeCloud();
  const bytes = pattern(1000);
  const first = await uploadFile({ dek: DEK, bytes, name: 'x.stl', client: cloud.client });
  const n = cloud.calls.length;
  const again = await uploadFile({ dek: DEK, bytes: Uint8Array.from(bytes), name: 'other-name.stl', client: cloud.client });
  assert.deepEqual([again.duplicate, again.fileId, again.version, again.rev], [true, first.fileId, 1, null]);
  assert.deepEqual(cloud.calls.slice(n).map((c) => c.method), ['POST']);
  // A tag the Mac registered: the same HMAC of the same sha256 under the same DEK.
  const macTag = await VC.dedupeTagFromDigest(DEK, crypto.createHash('sha256').update(pattern(77)).digest());
  const cloud2 = fakeCloud({ tags: [[macTag, { fileId: 'f_mac', version: 3 }]] });
  const d = await uploadFile({ dek: DEK, readChunk: async (o, l) => pattern(77).subarray(o, o + l), size: 77,
    name: 'm.3mf', client: cloud2.client });
  assert.deepEqual([d.duplicate, d.fileId, d.version], [true, 'f_mac', 3]);
  assert.equal(cloud2.puts().length, 0);
});

test('parts paging: URLs past the first page come from parts?from=', async () => {
  const cloud = fakeCloud({ pageSize: 2 });
  const r = await uploadFile({ dek: DEK, bytes: pattern(4 * CB + 1), name: 'p.stl', client: cloud.client, concurrency: 1 });
  const pages = cloud.route('GET', /\/parts\?from=/).map((c) => new URL(c.url).searchParams.get('from'));
  assert.deepEqual(pages, ['2', '4']);
  assert.deepEqual(cloud.puts().map(putIndex), [0, 1, 2, 3, 4]);
  assert.equal(cloud.files.get(r.fileId).versions[0].chunks, 5);
});

for (const mode of ['bytes', 'readChunk']) {
  test(`parts-missing (${mode}): re-PUTs byte-identical ciphertext`, async () => {
    const cloud = fakeCloud({ dropOnce: [1] });
    const bytes = pattern(2 * CB + 5);
    const src = mode === 'bytes' ? { bytes } : { readChunk: async (o, l) => bytes.slice(o, o + l), size: bytes.length };
    const r = await uploadFile({ dek: DEK, ...src, name: 'm.stl', client: cloud.client });
    assert.equal(r.duplicate, false);
    const ones = cloud.puts().filter((c) => putIndex(c) === 1);
    assert.equal(ones.length, 2);
    assert.deepEqual(Buffer.from(ones[1].body), Buffer.from(ones[0].body));
    assert.equal(cloud.route('POST', /\/complete$/).length, 2);
    assert.equal(cloud.route('DELETE', /./).length, 0);
  });
}

test('parts that never arrive: three /complete attempts, then give up and abandon', async () => {
  const cloud = fakeCloud();
  // Object storage says 200 but never keeps part 0.
  const orig = cloud.fetch;
  const client = createVaultClient({ baseUrl: BASE, shopId: 'shop_1', token: 'tok', fetch: async (url, init) => {
    if (init.method === 'PUT' && url.includes('/0?')) { cloud.calls.push({ url, method: 'PUT', headers: init.headers, body: init.body }); return { status: 200, json: async () => ({}) }; }
    return orig(url, init);
  } });
  const e = await uploadFile({ dek: DEK, bytes: pattern(100), name: 'n.stl', client }).catch((x) => x);
  assert.equal(e.reason, 'parts-still-missing');
  assert.deepEqual(e.indexes, [0]);
  assert.equal(cloud.route('POST', /\/complete$/).length, 3);
  assert.equal(cloud.route('DELETE', /\/vault\/uploads\//).length, 1);
});

test('a failed PUT abandons the upload (no spool: nothing could resume it)', async () => {
  const cloud = fakeCloud({ failPut: { 1: 500 } });
  const e = await uploadFile({ dek: DEK, bytes: pattern(CB + 9), name: 'f.stl', client: cloud.client }).catch((x) => x);
  assert.equal(e.reason, 'transfer');
  assert.equal(e.index, 1);
  assert.equal(e.status, 500);
  const del = cloud.route('DELETE', /\/vault\/uploads\//);
  assert.equal(del.length, 1);
  assert.equal(cloud.route('POST', /\/complete$/).length, 0);
  assert.ok([...cloud.uploads.values()][0].abandoned);
  // Nothing was PUT after the DELETE.
  assert.equal(cloud.calls.at(-1).method, 'DELETE');
});

test('a source that changes while sealing is refused and abandoned, nothing sent', async () => {
  const cloud = fakeCloud();
  let reads = 0;
  const e = await uploadFile({ dek: DEK, size: 50, name: 'c.stl', client: cloud.client,
    readChunk: async (o, l) => (reads++ === 0 ? pattern(50) : pattern(50, 5, 5)).subarray(o, o + l) }).catch((x) => x);
  assert.equal(e.reason, 'source-changed');
  assert.equal(cloud.puts().length, 0);
  assert.equal(cloud.route('DELETE', /\/vault\/uploads\//).length, 1);
});

test('no spool: a part re-sealed at SEND time from changed bytes is never sent, and the upload is abandoned', async () => {
  // Sealing reads each chunk once; the send pass reads them again. Here the
  // file changes in between. Two plaintexts under one DK and counter nonce
  // must never both reach the server.
  const cloud = fakeCloud();
  const size = CB + 20;
  const good = pattern(size);
  const bad = Buffer.from(good); bad[CB + 3] ^= 0xff;
  // One part at a time, and the file changes the moment the first part has
  // landed: chunk 1 is re-sealed at send time from the changed bytes.
  const e = await uploadFile({ dek: DEK, size, name: 'r.stl', client: cloud.client, concurrency: 1,
    readChunk: async (o, l) => (cloud.puts().length > 0 ? bad : good).subarray(o, o + l) }).catch((x) => x);
  assert.equal(e.reason, 'source-changed');
  assert.match(e.message, /changed since the upload started/);
  assert.deepEqual(cloud.puts().map(putIndex), [0], 'only the unchanged part 0 was sent (and the send pass did start)');
  assert.equal(cloud.route('POST', /\/complete$/).length, 0);
  assert.equal(cloud.route('DELETE', /\/vault\/uploads\//).length, 1, 'abandoned');
});

test('resume from a spool: same uploadId, only the parts not sent, the same sealed bytes', async () => {
  const cloud = fakeCloud({ failPutOnce: { 2: 503 } });
  const spool = memorySpool();
  const bytes = pattern(3 * CB + 3);
  const opts = { dek: DEK, readChunk: async (o, l) => bytes.slice(o, o + l), size: bytes.length,
    name: 'r.stl', client: cloud.client, spool, concurrency: 1 };
  const e = await uploadFile(opts).catch((x) => x);
  assert.equal(e.reason, 'transfer');
  // Kept for the next run, as the Mac keeps its spool: no DELETE.
  assert.equal(cloud.route('DELETE', /./).length, 0);
  const saved = spool.load();
  assert.equal(saved.sealed, true);
  assert.deepEqual(saved.sent.sort(), [0, 1]);
  const firstPuts = cloud.puts().filter((c) => putIndex(c) < 2).map((c) => Buffer.from(c.body));
  const n = cloud.calls.length;

  const r = await uploadFile(opts);
  const later = cloud.calls.slice(n);
  assert.equal(later.filter((c) => c.method === 'POST' && c.url.endsWith('/vault/uploads')).length, 0, 'no new upload');
  assert.deepEqual(later.filter((c) => c.method === 'GET').map((c) => new URL(c.url).searchParams.get('from')), ['2']);
  assert.deepEqual(later.filter((c) => c.method === 'PUT').map(putIndex), [2, 3]);
  assert.equal(r.uploadId, saved.uploadId);
  // What the cloud kept for parts 0-1 is exactly what the first run sent.
  const kept = cloud.uploads.get(saved.uploadId).parts;
  assert.deepEqual([Buffer.from(kept.get(0)), Buffer.from(kept.get(1))], firstPuts);
  for (let i = 0; i < 4; i++) assert.equal(await VC.chunkHash(kept.get(i)), saved.chunkHashes[i]);
  assert.equal(spool.load(), null, 'spool cleared on commit');
});

test('resume: an expired upload starts again; a spool of other bytes is abandoned', async () => {
  const cloud = fakeCloud({ failPutOnce: { 0: 503 } });
  const spool = memorySpool();
  await uploadFile({ dek: DEK, bytes: pattern(10), name: 'a', client: cloud.client, spool }).catch(() => {});
  const stale = spool.load().uploadId;
  const r = await uploadFile({ dek: DEK, bytes: pattern(11), name: 'a', client: cloud.client, spool });
  assert.notEqual(r.uploadId, stale);
  assert.ok(cloud.uploads.get(stale).abandoned);
});

test('round trip: what the cloud kept decrypts to the bytes and meta, and is shareable', async () => {
  const cloud = fakeCloud();
  const bytes = pattern(CB + 4321, 13, 2);
  const r = await uploadFile({ dek: DEK, bytes, name: 'vase.3mf', path: 'prints', kind: '3mf', key: 'prints/vase.3mf',
    recordId: 'rec_1', lastSeq: 6, client: cloud.client });
  const vk = await VC.deriveVaultKey(DEK);
  const f = cloud.files.get(r.fileId);
  const v = f.versions[0];
  const dk = await VC.unwrapDkForShop(vk, unb64(v.wrappedKey), r.fileId, v.uploadId);
  const vm = await VC.decryptVersionMeta(vk, r.fileId, v.uploadId, unb64(v.versionMeta));
  assert.equal(vm.seq, 7);
  assert.equal(vm.manifestHash, r.manifestHash);
  const parts = [];
  for (let i = 0; i < v.sealed.length; i++) {
    assert.equal(await VC.chunkHash(v.sealed[i]), vm.chunkHashes[i]);
    parts.push(await VC.decryptChunk(dk, r.fileId, v.uploadId, i, i === v.sealed.length - 1, v.sealed[i]));
  }
  assert.deepEqual(Buffer.concat(parts.map((p) => Buffer.from(p))), Buffer.from(bytes));
  const meta = await VC.decryptMeta(vk, r.fileId, v.uploadId, unb64(f.meta));
  assert.deepEqual(meta, { kind: '3mf', key: 'prints/vase.3mf', manifestHash: r.manifestHash, name: 'vase.3mf',
    path: 'prints', recordId: 'rec_1', seq: 7, sha256: sha(bytes), size: bytes.length, uploadId: v.uploadId });
  // The share-link path accepts it as it stands in the feed.
  const [item] = await prepareItems(DEK, [cloud.feedRow(r.fileId)], [r.fileId]);
  assert.equal(item.name, 'vase.3mf');
  assert.equal(item.size, bytes.length);
  assert.deepEqual(Buffer.from(item.dk), Buffer.from(dk));
  assert.equal(item.linkMeta.manifestHash, r.manifestHash);
});

test('an empty file is one 16-byte chunk and round-trips', async () => {
  const cloud = fakeCloud();
  const r = await uploadFile({ dek: DEK, bytes: new Uint8Array(0), name: 'empty', client: cloud.client });
  assert.deepEqual(cloud.puts().map((p) => p.body.length), [16]);
  const [item] = await prepareItems(DEK, [cloud.feedRow(r.fileId)], [r.fileId]);
  assert.equal(item.size, 0);
});

test('state.nextSeq overrides lastSeq', async () => {
  const cloud = fakeCloud();
  const seen = [];
  const r = await uploadFile({ dek: DEK, bytes: pattern(3), name: 's', client: cloud.client, lastSeq: 1,
    state: { nextSeq: (fid) => { seen.push(fid); return 42; } } });
  assert.equal(r.meta.seq, 42);
  assert.deepEqual(seen, [r.fileId]);
});

test('expected.json is what the node:crypto generator writes from inputs.json', () => {
  const { execFileSync } = require('node:child_process');
  execFileSync(process.execPath, [path.join(__dirname, '..', 'scripts', 'gen-vault-upload-fixture.js'), '--check'], { stdio: 'pipe' });
});
