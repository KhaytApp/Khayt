'use strict';
// lib/vault-links.js: a fake vault feed built with vault-crypto's own encrypt
// functions, a fake cloud, and the recipient's side opened with the link key.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const V = require('../lib/vault-crypto.js');
const L = require('../lib/vault-links.js');
const { createVaultClient } = require('../lib/vault-client.js');

const DEK = new Uint8Array(32).fill(7);
const hex64 = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');
const b64 = (u) => Buffer.from(u).toString('base64');
const unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));

/** One feed row the way the cloud lists it, sealed as the Mac seals it. */
async function feedRow(vk, n, { versions = 1 } = {}) {
  const fileId = 'file' + n;
  const row = { fileId, head: versions, metaRev: 1, versions: [], dks: {} };
  let lastMeta;
  for (let v = 1; v <= versions; v++) {
    const uploadId = `up${n}v${v}`;
    const size = 10 + n + v;
    const chunkHashes = [hex64(fileId + v)];
    const dk = V.newDataKey();
    const vm = await V.encryptVersionMeta(vk, fileId, uploadId, { size, chunkHashes, seq: v });
    const manifestHash = await V.manifestHash(size, chunkHashes);
    row.versions.push({ version: v, bytes: size + 16, chunks: 1, chunkBytes: V.CHUNK_BYTES, uploadId,
      wrappedKey: b64(await V.wrapDkForShop(vk, dk, fileId, uploadId)), manifestHash,
      versionMeta: b64(vm) });
    row.dks[v] = dk;
    lastMeta = await V.encryptMeta(vk, fileId, uploadId, { seq: v, uploadId, manifestHash, size,
      sha256: hex64('pt'), name: `Part ${n} v${v}.3mf`, path: '', kind: '3mf' });
  }
  row.meta = b64(lastMeta);
  return row;
}

async function feed(count, opts) {
  const vk = await V.deriveVaultKey(DEK);
  const rows = [];
  for (let i = 0; i < count; i++) rows.push(await feedRow(vk, i, opts));
  return rows;
}

/** A cloud that keeps grants; `onPost`/`onPatch` may override a reply. */
function fakeCloud({ onPost, onPatch } = {}) {
  const grants = new Map();
  const calls = [];
  const fetch = async (url, init) => {
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url, method: init.method, body, bytes: init.body ? Buffer.byteLength(init.body) : 0 });
    let reply;
    if (init.method === 'POST' && onPost) reply = onPost(body, calls);
    if (init.method === 'PATCH' && onPatch) reply = onPatch(body, calls);
    if (!reply) {
      if (init.method === 'POST') {
        grants.set(body.grantId, { ...body, items: [...body.items] });
        reply = [201, { createdAt: '2026-11-05T10:00:00Z' }];
      } else if (init.method === 'PATCH') {
        const id = url.split('/').pop();
        const g = grants.get(id);
        if (body.items) g.items.push(...body.items);
        if (body.revoke) g.revoked = true;
        reply = [200, { grantId: id, state: body.revoke ? 'revoked' : 'ok' }];
      }
    }
    return { status: reply[0], json: async () => reply[1] };
  };
  const client = createVaultClient({ baseUrl: 'https://cloud.example.com/', shopId: 'shop_1', token: 't', fetch });
  return { client, calls, grants };
}

test('a link round trip: what the cloud got opens with the link key alone', async () => {
  const files = await feed(3, { versions: 2 });
  const { client, calls, grants } = fakeCloud();
  const out = await L.createLink({ dek: DEK, files, fileIds: ['file0', 'file2'], client,
    options: { maxDownloads: 5, perFile: true, expiresAt: new Date('2026-12-01T00:00:00.123Z'), password: null } });

  assert.equal(out.itemCount, 2);
  assert.equal(out.requests, 1);
  assert.equal(out.createdAt, '2026-11-05T10:00:00Z');
  assert.equal(out.grantId.length, 22);
  assert.equal(out.url, `https://cloud.example.com/s/${out.grantId}#${out.secretB64u}`);
  assert.equal(calls.length, 1);
  const body = calls[0].body;
  assert.deepEqual(Object.keys(body), ['grantId', 'items', 'limits']);
  assert.deepEqual(body.limits, { maxDownloads: 5, perFile: true, expiresAt: '2026-12-01T00:00:00Z' });
  assert.equal(body.password, undefined);
  // Nothing secret on the wire.
  assert.ok(!JSON.stringify(body).includes(out.secretB64u));

  const g = grants.get(out.grantId);
  const linkKey = await V.deriveLinkKey(V.unb64url(out.secretB64u), out.grantId, null);
  for (const item of g.items) {
    assert.deepEqual(Object.keys(item), ['fileId', 'version', 'wrappedKey', 'linkMeta']);
    const row = files.find((f) => f.fileId === item.fileId);
    assert.equal(item.version, 2, 'the head version is shared');
    const meta = await V.decryptLinkMeta(linkKey, out.grantId, item.fileId, unb64(item.linkMeta));
    const head = row.versions[1];
    assert.equal(meta.uploadId, head.uploadId);
    assert.equal(meta.manifestHash, head.manifestHash);
    assert.equal(meta.name, `Part ${item.fileId.slice(4)} v2.3mf`);
    assert.equal(meta.kind, '3mf');
    assert.equal(meta.size, head.bytes - 16);
    const dk = await V.unwrapDkForGrant(linkKey, unb64(item.wrappedKey), out.grantId, item.fileId, meta.uploadId);
    assert.deepEqual(dk, row.dks[2]);
  }
  // A wrong key opens nothing.
  const wrong = await V.deriveLinkKey(V.newLinkSecret(), out.grantId, null);
  await assert.rejects(V.decryptLinkMeta(wrong, out.grantId, g.items[0].fileId, unb64(g.items[0].linkMeta)));
});

test('prepareItems refuses, by id, files with no live vault copy', async () => {
  const files = await feed(3);
  files[1].trashedAt = '2026-11-01T00:00:00Z';
  files.push({ fileId: 'gone', purged: true });
  const e = await L.prepareItems(DEK, files, ['file0', 'file1', 'nope', 'gone']).catch((x) => x);
  assert.equal(e.reason, 'not-shareable');
  assert.deepEqual(e.fileIds, ['file1', 'nope', 'gone']);
  const ok = await L.prepareItems(DEK, files, ['file0', 'file2', 'file0']);
  assert.deepEqual(ok.map((p) => [p.fileId, p.name, p.kind]), [['file0', 'Part 0 v1.3mf', '3mf'], ['file2', 'Part 2 v1.3mf', '3mf']]);
});

test('prepareItems refuses a listing that disagrees with the sealed record', async () => {
  const files = await feed(1);
  files[0].versions[0].bytes += 1;
  const e = await L.prepareItems(DEK, files, ['file0']).catch((x) => x);
  assert.equal(e.reason, 'not-shareable');
  assert.match(e.message, /disagrees/);
});

test('more than 500 items: POST the first 500, PATCH {items} the rest, pending until done', async () => {
  const files = await feed(503);
  const { client, calls, grants } = fakeCloud();
  const saved = [];
  const secrets = { save: async (id, r) => { saved.push({ id, pending: r.pendingSince }); return true; }, forget: async () => {} };
  const out = await L.createLink({ dek: DEK, files, fileIds: files.map((f) => f.fileId), client, secrets,
    options: { password: null } });
  assert.equal(out.requests, 2);
  assert.equal(out.itemCount, 503);
  assert.equal(out.secretKept, true);
  assert.deepEqual(calls.map((c) => c.method), ['POST', 'PATCH']);
  assert.equal(calls[0].body.items.length, 500);
  assert.deepEqual(Object.keys(calls[1].body), ['items']);
  assert.equal(calls[1].body.items.length, 3);
  assert.equal(grants.get(out.grantId).items.length, 503);
  assert.equal(saved.length, 2);
  assert.ok(saved[0].pending instanceof Date, 'kept pending before the rest is sent');
  assert.equal(saved[1].pending, null, 'kept whole once the last batch landed');
});

test('batches honour the byte limit exactly as the body is serialised', () => {
  const item = (i) => ({ fileId: 'f' + i, version: 1, wrappedKey: 'A'.repeat(80), linkMeta: 'B'.repeat(200) });
  const items = Array.from({ length: 10 }, (_, i) => item(i));
  const n = Buffer.byteLength(JSON.stringify(item(0)));
  const env = Buffer.byteLength(JSON.stringify({ items: [] }));
  const max = env + 3 * n + 2; // three items and two commas fit; a fourth does not
  const parts = L.batches(items, env, env, 500, max);
  assert.deepEqual(parts.map((p) => p.length), [3, 3, 3, 1]);
  for (const p of parts) assert.ok(Buffer.byteLength(JSON.stringify({ items: p })) <= max);
  assert.throws(() => L.batches(items, env, env, 500, env + n - 1), (e) => e.reason === 'too-big');
});

test('a later batch failing revokes the half-made link and forgets its secret', async () => {
  const files = await feed(4);
  let patches = 0;
  const { client, calls } = fakeCloud({ onPatch: (body) => (body.items && ++patches === 1 ? [500, {}] : null) });
  const forgot = [];
  const secrets = { save: async () => true, forget: async (id) => forgot.push(id) };
  const e = await L.createLink({ dek: DEK, files, fileIds: files.map((f) => f.fileId), client, secrets,
    options: { password: null }, seams: { maxItems: 2 } }).catch((x) => x);
  assert.equal(e.reason, 'incomplete');
  assert.equal(e.sent, 2); assert.equal(e.total, 4); assert.equal(e.revoked, true);
  assert.deepEqual(calls.map((c) => [c.method, Object.keys(c.body)]),
    [['POST', ['grantId', 'items']], ['PATCH', ['items']], ['PATCH', ['revoke']]]);
  assert.deepEqual(forgot, [e.grantId]);
});

test('grant-exists: a new id and secret, up to three tries', async () => {
  const files = await feed(1);
  let posts = 0;
  const ids = ['A'.repeat(22), 'B'.repeat(22), 'C'.repeat(22), 'D'.repeat(22)];
  const { client, calls } = fakeCloud({ onPost: () => (++posts < 3 ? [409, { reason: 'grant-exists' }] : null) });
  const out = await L.createLink({ dek: DEK, files, fileIds: ['file0'], client, options: { password: null },
    seams: { newGrantId: () => ids.shift() } });
  assert.equal(out.grantId, 'C'.repeat(22));
  assert.deepEqual(calls.map((c) => c.body.grantId), ['A'.repeat(22), 'B'.repeat(22), 'C'.repeat(22)]);
  // The items were sealed again for each id.
  assert.notEqual(calls[0].body.items[0].wrappedKey, calls[2].body.items[0].wrappedKey);

  const always = fakeCloud({ onPost: () => [409, { reason: 'grant-exists' }] });
  const e = await L.createLink({ dek: DEK, files, fileIds: ['file0'], client: always.client, options: {} }).catch((x) => x);
  assert.equal(e.reason, 'no-free-grant-id');
  assert.equal(always.calls.length, 3);
});

test('a password link: weak passwords refused; a strong one needs the password to open', async () => {
  const files = await feed(1);
  const fastScrypt = async (pw, salt, kdf) => {
    assert.deepEqual(kdf, { ...V.LINK_SCRYPT });
    return new Uint8Array(crypto.scryptSync(Buffer.from(pw), Buffer.from(salt), 32, { N: 16, r: 8, p: 1 }));
  };
  const weak = fakeCloud();
  const e = await L.createLink({ dek: DEK, files, fileIds: ['file0'], client: weak.client,
    options: { password: 'short' } }).catch((x) => x);
  assert.equal(e.reason, 'weak-password');
  assert.equal(weak.calls.length, 0);

  const { client, calls } = fakeCloud();
  const pw = 'correct horse battery';
  const out = await L.createLink({ dek: DEK, files, fileIds: ['file0'], client, options: { password: pw },
    seams: { scrypt: fastScrypt } });
  assert.equal(calls[0].body.password, true);
  assert.ok(!JSON.stringify(calls[0].body).includes(pw));
  const item = calls[0].body.items[0];
  const secret = V.unb64url(out.secretB64u);
  const lk = await V.deriveLinkKey(secret, out.grantId, pw, { scrypt: fastScrypt });
  const meta = await V.decryptLinkMeta(lk, out.grantId, 'file0', unb64(item.linkMeta));
  assert.equal(meta.name, 'Part 0 v1.3mf');
  const noPw = await V.deriveLinkKey(secret, out.grantId, null);
  await assert.rejects(V.decryptLinkMeta(noPw, out.grantId, 'file0', unb64(item.linkMeta)));
});

test('a note goes in sealed under the vault key, and only the shop opens it', async () => {
  const files = await feed(1);
  const { client, calls } = fakeCloud();
  const out = await L.createLink({ dek: DEK, files, fileIds: ['file0'], client, options: { note: 'for Sara' } });
  const sent = calls.find((c) => c.method === 'POST').body;
  assert.ok(sent.ownerNote && !sent.ownerNote.includes('Sara'), 'sealed, not in the clear');
  const vk = await V.deriveVaultKey(DEK);
  assert.equal(await V.decryptGrantNote(vk, out.grantId, sent.ownerNote), 'for Sara');
});

test('revoke, extend and addDownloads send the PATCH the Mac sends', async () => {
  const { client, calls } = fakeCloud({ onPatch: () => [200, { grantId: 'G'.repeat(22), state: 'ok' }] });
  const id = 'G'.repeat(22);
  await L.revokeLink(client, id);
  await L.extendLink(client, id, new Date('2027-01-02T03:04:05.678Z'));
  await L.extendLink(client, id, null);
  await L.addDownloads(client, id, 3);
  await assert.rejects(L.addDownloads(client, id, 0));
  assert.deepEqual(calls.map((c) => [c.method, c.url.endsWith('/vault/grants/' + id), c.body]), [
    ['PATCH', true, { revoke: true }],
    ['PATCH', true, { expiresAt: '2027-01-02T03:04:05Z' }],
    ['PATCH', true, { expiresAt: null }],
    ['PATCH', true, { addDownloads: 3 }],
  ]);
});

test('a listing whose chunkBytes contradicts the sealed record is refused', async () => {
  const files = await feed(1);
  const head = files[0].versions.find((v) => v.version === files[0].head);
  head.chunkBytes = 1234;
  const e = await L.prepareItems(DEK, files, ['file0']).catch((x) => x);
  assert.equal(e.reason, 'not-shareable');
  // the sealed record's own size is what a link uses; a matching listing is fine
  head.chunkBytes = 4194304;
  const ok = await L.prepareItems(DEK, files, ['file0']);
  assert.equal(ok[0].linkMeta.manifest.chunkBytes, 4194304);
});
