'use strict';
/**
 * Backing library models up into the Khayt Vault from Windows/Linux
 * (lib/main/vault-backup.js): the Mac's key, meta and versioning rules, and
 * nothing written to the book.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const VC = require('../lib/vault-crypto.js');
const VaultLinks = require('../lib/vault-links.js');
const { createVaultBackup, keyFor, kindOf } = require('../lib/main/vault-backup.js');

const DEK = new Uint8Array(32).fill(5);
const PREFIX = 'https://cloud.example/v1/shops/shop_1';

/** A small vault: uploads, parts, complete, and the files feed. */
function fakeVault() {
  const files = new Map(); const uploads = new Map(); const tags = new Map();
  let rev = 0, n = 0; const posts = [];
  globalThis.fetch = async (url, init) => {
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
    if (url.startsWith('https://store.example/')) {
      const [, id, i] = new URL(url).pathname.match(/^\/up\/([^/]+)\/(\d+)$/);
      uploads.get(id).parts.set(Number(i), Buffer.from(init.body));
      return new Response('', { status: 200 });
    }
    const tail = url.slice(PREFIX.length);
    const body = init.body ? JSON.parse(init.body) : null;
    let m;
    if (init.method === 'GET' && tail.startsWith('/vault/files')) {
      const since = Number(new URL(url).searchParams.get('since')) || 0;
      const rows = [...files.values()].filter((f) => f.rev > since).map((f) => ({ fileId: f.fileId, head: f.head, meta: f.meta, versions: f.versions }));
      return json(200, { rev, more: false, files: rows });
    }
    if (init.method === 'POST' && tail === '/vault/uploads') {
      posts.push(body);
      if (tags.has(body.tag)) return json(409, { reason: 'duplicate', ...tags.get(body.tag) });
      const fileId = body.fileId || `f${++n}`; const uploadId = `u${++n}`;
      const f = files.get(fileId); const version = f ? f.head + 1 : 1;
      uploads.set(uploadId, { fileId, version, tag: body.tag, sizes: body.sizes, parts: new Map() });
      return json(201, { uploadId, fileId, version, expiresAt: 'x', parts: body.sizes.map((size, index) => ({ index, size, url: `https://store.example/up/${uploadId}/${index}` })) });
    }
    if (init.method === 'POST' && (m = tail.match(/^\/vault\/uploads\/([^/]+)\/complete$/))) {
      const u = uploads.get(m[1]);
      let f = files.get(u.fileId);
      if (!f) { f = { fileId: u.fileId, versions: [], head: 0 }; files.set(u.fileId, f); }
      f.versions.push({ version: u.version, uploadId: m[1], wrappedKey: body.wrappedKey, versionMeta: body.versionMeta, chunks: u.sizes.length });
      f.head = u.version; if (body.meta) f.meta = body.meta; f.rev = ++rev;
      tags.set(u.tag, { fileId: u.fileId, version: u.version });
      return json(201, { fileId: u.fileId, version: u.version, rev, conflict: false });
    }
    throw new Error('unexpected ' + init.method + ' ' + url);
  };
  return { files, posts };
}

function setup() {
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'vb-ud-'));
  const lib = fs.mkdtempSync(path.join(os.tmpdir(), 'vb-lib-'));
  const book = { settings: { cloud: { enabled: true, shopId: 'shop_1', url: 'https://cloud.example', token: 'tok' } }, printFiles: [{ id: 'PF-1', name: 'Dragon' }] };
  const frozen = JSON.stringify(book);
  const vb = createVaultBackup({
    app: { getPath: () => userData }, readBook: () => book, getDek: () => DEK, cloudToken: (t) => t,
    isVaultOn: () => true, itemDir: (id) => path.join(lib, id), isModelFile: (n) => /\.(3mf|stl)$/i.test(n), deviceId: 'desktop', log: { warn() {} },
  });
  return { vb, lib, book, frozen };
}

test('the key and kind are the Mac\'s', () => {
  assert.equal(keyFor('PF-1', 'Dragon v2.3mf'), 'print-files/PF-1/Dragon v2.3mf');
  assert.equal(keyFor('a/b:c d', 'x.stl'), 'print-files/b_c_d/x.stl');
  assert.equal(keyFor('', 'x.stl'), 'print-files/unsorted/x.stl');
  assert.equal(kindOf('Model.3MF'), '3mf');
  assert.equal(kindOf('README'), '');
});

test('a model goes in as a new file with the Mac\'s meta, then a change is a new VERSION of it, and the book is never written', async () => {
  const cloud = fakeVault();
  const { vb, lib, book, frozen } = setup();
  fs.mkdirSync(path.join(lib, 'PF-1'));
  fs.writeFileSync(path.join(lib, 'PF-1', 'dragon.3mf'), Buffer.from('first bytes'));
  fs.writeFileSync(path.join(lib, 'PF-1', 'thumb.jpg'), Buffer.from('not a model'));
  let r = await vb.backUp(['PF-1']);
  assert.equal(r.ok, true);
  assert.equal(r.done.length, 1, 'only the model file, not the thumbnail');
  assert.equal(cloud.posts[0].fileId, undefined, 'a new file');
  const row = [...cloud.files.values()][0];
  const meta = await VaultLinks.openShopMeta(await VC.deriveVaultKey(DEK), row);
  assert.deepEqual({ key: meta.key, name: meta.name, path: meta.path, kind: meta.kind, seq: meta.seq },
    { key: 'print-files/PF-1/dragon.3mf', name: 'dragon.3mf', path: '', kind: '3mf', seq: 1 });
  assert.ok(!('recordId' in meta), 'the backup passes no recordId');

  fs.writeFileSync(path.join(lib, 'PF-1', 'dragon.3mf'), Buffer.from('changed bytes'));
  r = await vb.backUp(['PF-1']);
  assert.equal(r.ok, true);
  assert.equal(cloud.posts[1].fileId, row.fileId, 'the same key is a new version of the same file');
  assert.equal(cloud.posts[1].baseVersion, 1);
  const meta2 = await VaultLinks.openShopMeta(await VC.deriveVaultKey(DEK), cloud.files.get(row.fileId));
  assert.equal(meta2.seq, 2);
  assert.equal(JSON.stringify(book), frozen, 'a backup writes nothing to the book');
});

test('the same bytes again are adopted, not uploaded twice', async () => {
  const cloud = fakeVault();
  const { vb, lib } = setup();
  fs.mkdirSync(path.join(lib, 'PF-1'));
  fs.writeFileSync(path.join(lib, 'PF-1', 'a.stl'), Buffer.from('same'));
  await vb.backUp(['PF-1']);
  const r = await vb.backUp(['PF-1']);
  assert.equal(r.done[0].duplicate, true, 'the cloud said duplicate, and nothing was sent');
  assert.equal(r.done[0].fileId, [...cloud.files.keys()][0]);
  assert.equal(cloud.files.size, 1);
  assert.equal([...cloud.files.values()][0].versions.length, 1, 'no second version');
});

test('the desktop-backup fixture the Mac runs through VaultApply still describes what this code writes', () => {
  const r = require('child_process').spawnSync(process.execPath, [require('path').join(__dirname, '..', 'scripts', 'gen-vault-backup-fixture.js'), '--check'], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr || r.stdout);
});
