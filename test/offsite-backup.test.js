'use strict';
/**
 * The off-site backup on Windows/Linux — the Mac's KhaytCore `OffsiteBackup`,
 * in JavaScript, to the SAME files, so a backup either app made restores on
 * the other.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const OB = require('../lib/offsite-backup.js');
const SC = require('../lib/sync-crypto.js');

const dek = crypto.randomBytes(32);
const book = Buffer.from(JSON.stringify({ printLog: [{ id: 'J1', price: 120 }], settings: { bizEn: 'Shop' } }));

/** A destination in memory, which can be told to mangle what it hands back. */
function memory({ mangle = false, failDelete = [] } = {}) {
  const files = new Map();
  return {
    files,
    put: async (n, d) => { files.set(n, Buffer.from(d)); },
    get: async (n) => (files.has(n) ? (mangle ? Buffer.concat([files.get(n), Buffer.from(' ')]) : files.get(n)) : null),
    delete: async (n) => { if (failDelete.includes(n)) throw new Error('no'); files.delete(n); },
    list: async () => [...files].map(([name, d]) => ({ name, bytes: d.length })),
  };
}

test('names are the Mac\'s: khayt-book-YYYY-MM-DD.khaytbak, under khayt-offsite-backups', () => {
  assert.equal(OB.filename('2026-11-05'), 'khayt-book-2026-11-05.khaytbak');
  assert.equal(OB.dayOf('khayt-book-2026-11-05.khaytbak'), '2026-11-05');
  for (const bad of ['khayt-book-2026-11.khaytbak', 'notes.txt', 'khayt-book-2026-11-05.json']) assert.equal(OB.dayOf(bad), null, bad);
  assert.equal(OB.key('/shop/', 'x'), 'shop/khayt-offsite-backups/x');
  assert.equal(OB.key('', 'x'), 'khayt-offsite-backups/x');
  assert.equal(OB.listedName('p/khayt-offsite-backups/a', 'p/khayt-offsite-backups/'), 'a');
  for (const k of ['p/khayt-offsite-backups/', 'p/khayt-offsite-backups/x/y', 'other/a', 'p/khayt-offsite-backups/..a']) {
    assert.equal(OB.listedName(k, 'p/khayt-offsite-backups/'), null, k);
  }
});

test('30 dailies, then one a month for 12 months; other files are never pruned', () => {
  const names = [];
  const d = new Date(Date.UTC(2026, 10, 5));
  for (let i = 0; i < 500; i++) { const x = new Date(d - i * 86400000); names.push(OB.filename(x.toISOString().slice(0, 10))); }
  names.push('somebody-elses.txt');
  const prune = OB.toPrune(names);
  const kept = names.filter((n) => !prune.includes(n));
  assert.ok(!prune.includes('somebody-elses.txt'));
  assert.equal(kept.filter((n) => OB.dayOf(n)).length, 30 + 12);
  assert.ok(kept.includes(OB.filename('2026-11-05')) && kept.includes(OB.filename('2026-10-07')));
});

test('sealed in the shape sync-crypto (and so the Mac\'s SyncCrypto) opens', () => {
  const sealed = OB.seal(book, dek, '2026-11-05T01:00:00.000Z');
  const env = JSON.parse(sealed);
  assert.deepEqual(Object.keys(env), ['blob', 'createdAt', 'format', 'v'], 'sorted keys, as .sortedKeys writes them');
  assert.equal(env.format, 'khayt-offsite-backup');
  assert.equal(env.v, 1);
  assert.equal(env.blob.z, 'gzip');
  assert.deepEqual(SC.decryptStore(env.blob, dek), JSON.parse(book));
  assert.ok(OB.open(sealed, dek).equals(book));
  // and the other direction: a blob sealed by sync-crypto opens here
  const theirs = Buffer.from(JSON.stringify({ format: 'khayt-offsite-backup', v: 1, createdAt: 'x', blob: SC.encryptStore(JSON.parse(book), dek) }));
  assert.deepEqual(JSON.parse(OB.open(theirs, dek)), JSON.parse(book));
});

test('no key, no upload; a wrong key, a stray file and a newer format are each refused by name', () => {
  assert.throws(() => OB.seal(book, null, 'x'), { code: 'noKey' });
  const sealed = OB.seal(book, dek, 'x');
  assert.throws(() => OB.open(sealed, crypto.randomBytes(32)), { code: 'wrongKey' });
  assert.throws(() => OB.open(Buffer.from('{"a":1}'), dek), { code: 'notABackup' });
  const env = JSON.parse(sealed); env.v = 9;
  assert.throws(() => OB.open(Buffer.from(JSON.stringify(env)), dek), { code: 'tooNew' });
});

test('a run seals, proves by reading back, and only then prunes', async () => {
  const dest = memory();
  // 40 distinct days before today: ten of them are past the 30 dailies, and
  // all in two months, so the newest of each month stays and the rest go.
  for (let i = 1; i <= 40; i++) dest.files.set(OB.filename(new Date(Date.UTC(2026, 10, 5) - i * 86400000).toISOString().slice(0, 10)), Buffer.from('old'));
  const out = await OB.run({ book, dek, day: '2026-11-05', createdAt: 'now', destination: dest });
  assert.equal(out.name, 'khayt-book-2026-11-05.khaytbak');
  assert.ok(dest.files.has(out.name));
  assert.equal(out.pruneFailures, 0);
  assert.ok(out.pruned.length > 0);
  assert.ok(OB.open(dest.files.get(out.name), dek).equals(book));
});

test('a destination that hands back something else fails the night and prunes nothing', async () => {
  const dest = memory({ mangle: true });
  dest.files.set('khayt-book-2020-01-01.khaytbak', Buffer.from('old'));
  await assert.rejects(OB.run({ book, dek, day: '2026-11-05', createdAt: 'now', destination: dest, keepDaily: 0, keepMonthly: 0 }), { code: 'readBackDiffers' });
  assert.ok(dest.files.has('khayt-book-2020-01-01.khaytbak'));
});

test('the folder destination writes whole files, keeps names inside it, and restores', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'offsite-'));
  try {
    const dest = OB.folderDestination(root);
    await OB.run({ book, dek, day: '2026-11-05', createdAt: 'now', destination: dest });
    assert.deepEqual(fs.readdirSync(root), ['khayt-book-2026-11-05.khaytbak']);
    await dest.put('../escape.khaytbak', Buffer.from('x'));
    assert.ok(!fs.existsSync(path.join(root, '..', 'escape.khaytbak')));
    const list = await OB.available(dest);
    assert.deepEqual(list.map((e) => e.name), ['khayt-book-2026-11-05.khaytbak']);
    assert.ok((await OB.fetchBook(list[0].name, dest, dek)).equals(book));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('the bucket destination lists through ListObjectsV2 and keeps to its folder', async () => {
  const S3 = require('../lib/s3-client.js');
  const xml = '<ListBucketResult><IsTruncated>false</IsTruncated>'
    + '<Contents><Key>shop/khayt-offsite-backups/khayt-book-2026-11-05.khaytbak</Key><Size>10</Size><LastModified>2026-11-05T01:00:00Z</LastModified></Contents>'
    + '<Contents><Key>shop/khayt-offsite-backups/nested/khayt-book-2026-11-04.khaytbak</Key><Size>10</Size></Contents>'
    + '</ListBucketResult>';
  const seen = [];
  const s3 = S3.createS3({ endpoint: 'https://s3.example.com', bucket: 'b', accessKeyId: 'a', secretAccessKey: 's', region: 'auto' },
    { fetch: async (url) => { seen.push(url); return { status: 200, text: async () => xml }; } });
  const dest = OB.bucketDestination(s3, 'shop');
  assert.deepEqual((await dest.list()).map((e) => e.name), ['khayt-book-2026-11-05.khaytbak']);
  assert.match(seen[0], /\/b\?list-type=2&prefix=shop%2Fkhayt-offsite-backups%2F$/);
});

test('the main-process job: settings stay on this computer, and nothing is sent while Khayt Cloud is locked', async () => {
  const { registerOffsiteBackup } = require('../lib/main/offsite-backup.js');
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'offsite-ud-'));
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'offsite-dest-'));
  const handlers = {};
  let key = null;
  const job = registerOffsiteBackup({
    app: { getPath: () => userData }, ipcMain: { handle: (n, f) => { handlers[n] = f; } },
    dialog: {}, BrowserWindow: {}, getDek: () => key, readBookBytes: () => book,
    decryptForWindow: async (b) => Buffer.from(b).toString('utf8'),
    libraryBucket: () => null, libraryDrive: () => null, log: { warn() {} },
  });
  try {
    assert.equal((await handlers['hub:offsite-get']()).problem, 'folder_missing');
    await handlers['hub:offsite-set'](null, { enabled: true, destination: 'folder', folderPath: root });
    let r = await handlers['hub:offsite-run']();
    assert.equal(r.code, 'needs_unlock');
    assert.deepEqual(fs.readdirSync(root), []);
    key = dek;
    r = await handlers['hub:offsite-run']();
    assert.equal(r.ok, true);
    assert.equal(fs.readdirSync(root).length, 1);
    const st = await handlers['hub:offsite-get']();
    assert.equal(st.status.lastName, r.name);
    assert.equal(st.status.failingSince, null);
    const restored = await handlers['hub:offsite-restore']({}, r.name);
    assert.deepEqual(JSON.parse(restored.json), JSON.parse(book));
    // the bucket, chosen but not set up, says so by code
    await handlers['hub:offsite-set'](null, { destination: 'bucket' });
    assert.equal((await handlers['hub:offsite-get']()).problem, 'bucket_missing');
    assert.ok(fs.existsSync(path.join(userData, 'offsite-backup.json')), 'kept in userData, not in the book');
  } finally {
    job.stop();
    fs.rmSync(userData, { recursive: true, force: true }); fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the committed fixture the Mac opens still opens here (the cross-app promise)', () => {
  const dir = path.join(__dirname, 'fixtures', 'offsite-backup');
  const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
  const sealed = fs.readFileSync(path.join(dir, 'khayt-book-2026-11-05.khaytbak'));
  assert.ok(OB.open(sealed, key).equals(fs.readFileSync(path.join(dir, 'book.json'))));
});
