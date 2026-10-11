/**
 * The Mac's `.online` marker, read by the desktop (#1828 on the Mac side).
 *
 * A model the shop put in its storage bucket by hand is adopted by the Mac
 * without being downloaded: a record, and `<model>.online` in its vault folder
 * holding {v, key, size, etag, bucket, provider, at}. The desktop lists it as
 * in the cloud, downloads it when it is opened (checked by size and a plain-MD5
 * ETag), removes the marker, and reads the model the way an import does.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const T = require('../lib/print-library-tier.js');
const { itemDirName } = require('../lib/print-library-location.js');

const md5 = (b) => crypto.createHash('md5').update(b).digest('hex');
const MARKER = { v: 1, key: 'models/Dragon.3mf', size: 5, etag: `"${md5(Buffer.from('hello'))}"`,
  bucket: 'shop-models', provider: 'r2', at: '2026-10-11T12:00:00Z' };

test('a marker is read as the Mac writes it, and refused when it cannot say what to fetch', () => {
  const m = T.parseOnlineMarker(JSON.stringify(MARKER));
  assert.deepEqual(m, { ...MARKER });
  assert.equal(T.parseOnlineMarker(JSON.stringify({ ...MARKER, etag: '' })).etag, '', 'a listing may omit the ETag');
  assert.equal(T.parseOnlineMarker('not json'), null);
  assert.equal(T.parseOnlineMarker(JSON.stringify({ ...MARKER, v: 2 })), null);
  assert.equal(T.parseOnlineMarker(JSON.stringify({ ...MARKER, key: '' })), null);
  assert.equal(T.parseOnlineMarker(JSON.stringify({ ...MARKER, size: 0 })), null);
  assert.equal(T.onlineBaseName('Dragon.3mf.online'), 'Dragon.3mf');
  assert.equal(T.onlineBaseName('Dragon.3mf'), 'Dragon.3mf');
});

test('a download is checked by size, and by the ETag when it is a plain MD5', () => {
  const m = T.parseOnlineMarker(JSON.stringify(MARKER));
  assert.equal(T.verifyOnlineDownload(m, 5, md5(Buffer.from('hello'))).ok, true);
  assert.equal(T.verifyOnlineDownload(m, 4, md5(Buffer.from('hell'))).ok, false, 'wrong size');
  assert.equal(T.verifyOnlineDownload(m, 5, md5(Buffer.from('jello'))).ok, false, 'different bytes');
  // Multipart: the ETag proves nothing, so the size is the check (as on the Mac).
  const multi = { ...m, etag: '"9b2cf535f27731c974343645a3985328-3"' };
  assert.equal(T.verifyOnlineDownload(multi, 5, md5(Buffer.from('jello'))).ok, true);
  assert.equal(T.verifyOnlineDownload({ ...m, etag: '' }, 5, md5(Buffer.from('x'))).ok, true);
  assert.equal(T.verifyOnlineDownload(null, 5, 'x').ok, false);
});

test('the listing shows the model as online, not as missing, and never lists the marker', () => {
  const entries = [{ filename: 'Dragon.3mf.online', fullPath: '/v/PF1/Dragon.3mf.online', size: 180 },
    { filename: 'thumb.jpg', fullPath: '/v/PF1/thumb.jpg', size: 900 }];
  const markers = new Map([['Dragon.3mf', { ...MARKER, size: 7340032, fullPath: '/v/PF1/Dragon.3mf' }]]);
  const out = T.mergeListing(entries, new Map(), markers);
  assert.deepEqual(out.map((e) => e.filename).sort(), ['Dragon.3mf', 'thumb.jpg']);
  const d = out.find((e) => e.filename === 'Dragon.3mf');
  assert.equal(d.tiered, true);
  assert.equal(d.online, true);
  assert.equal(d.size, 7340032);
  assert.equal(d.fullPath, '/v/PF1/Dragon.3mf');
  // Once downloaded, the local file is what is listed, even if a marker lingered.
  const local = T.mergeListing([{ filename: 'Dragon.3mf', fullPath: '/v/PF1/Dragon.3mf', size: 7340032 }], new Map(), markers);
  assert.equal(local.length, 1);
  assert.equal(local[0].tiered, false);
  // The two-argument call is unchanged.
  assert.deepEqual(T.mergeListing([{ filename: 'a.stl', fullPath: '/a.stl', size: 1 }], new Map()), [{ filename: 'a.stl', fullPath: '/a.stl', size: 1, tiered: false }]);
});

/* ── Wiring in main.js and preload.js ───────────────────────────────────── */

const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

test('main lists markers, downloads on open, and a delete trashes the marker but not the object', () => {
  const main = read('main.js');
  assert.match(main, /PLT\.mergeListing\(entries, await printLibSidecarMap\(dir\), await printLibOnlineMap\(dir\)\)/);
  assert.match(main, /if \(PLT\.isSidecar\(f\) \|\| PLT\.isOnlineMarker\(f\)\) continue;/);
  assert.match(main, /if \(fs\.existsSync\(p \+ PLT\.ONLINE_MARKER_EXT\)\) return printLibBringDown\(p\);/);
  assert.match(main, /for \(const p of \[safe \+ PLT\.SIDECAR_EXT, safe \+ PLT\.ONLINE_MARKER_EXT, safe\]\)/);
  const fn = main.slice(main.indexOf('async function printLibBringDown'), main.indexOf('async function printLibBringDown') + 4000);
  assert.match(fn, /PLT\.verifyOnlineDownload\(m, buf\.length, crypto\.createHash\('md5'\)/);
  // The marker goes only after the model is whole on disk.
  assert.ok(fn.indexOf('fs.promises.rename(tmp, p)') < fn.indexOf('fs.promises.unlink(markerPath)'));
  assert.match(fn, /'hub:printlib-brought-down'/);
  assert.ok(!/client\.(delete|del|remove|rm)\b|deleteObject/.test(fn), 'the object is never deleted from the bucket');
  assert.match(read('preload.js'), /onPrintLibBroughtDown: .*'hub:printlib-brought-down'/);
});

/* ── The window reads a downloaded model like an import ─────────────────── */

test('a brought-down model gets its size and hash, and a duplicate is named', async () => {
  const said = [];
  global.t = (k, v) => k + (v ? ' ' + JSON.stringify(v) : '');
  global.toast = (msg, kind) => said.push([msg, kind]);
  global.saveAll = () => {};
  const pf = require('../renderer/printfiles.js');
  global.printFiles = [
    { id: 'PF-a/b', name: 'Dragon', sourceFile: { filename: 'Dragon.3mf', ext: '3mf', size: 0 }, contentHash: null },
    { id: 'PF-old', name: 'Old dragon', contentHash: 'h1' },
  ];
  await pf.onBroughtDown({ dirName: itemDirName('PF-a/b'), filename: 'Dragon.3mf', fullPath: '/v/x/Dragon.3mf', size: 7340032, contentHash: 'h1' });
  const rec = global.printFiles[0];
  assert.equal(rec.sourceFile.size, 7340032);
  assert.equal(rec.contentHash, 'h1');
  assert.equal(said[0][1], 'warning');
  assert.match(said[0][0], /plib\.brought_down_dup .*Old dragon/);

  said.length = 0;
  global.printFiles = [{ id: 'PF9', name: 'Vase', sourceFile: { filename: 'Vase.stl', ext: 'stl', size: 0 } }];
  await pf.onBroughtDown({ dirName: 'PF9', filename: 'Vase.stl', fullPath: '/v/PF9/Vase.stl', size: 10, contentHash: 'h2' });
  assert.match(said[0][0], /^plib\.brought_down /);
  await pf.onBroughtDown({ dirName: 'nobody', filename: 'x.stl', fullPath: '/x', size: 1 });   // no record: nothing happens
  assert.equal(said.length, 1);
});
