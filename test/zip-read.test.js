'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { listEntries, readEntry, openZip } = require('../lib/zip-read');
const { makeZip } = require('./helpers/make-zip');

test('lists entries and reads STORED members', () => {
  const zip = makeZip([{ name: 'a.txt', data: 'hello', method: 0 }]);
  const entries = listEntries(zip);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].name, 'a.txt');
  assert.equal(readEntry(zip, entries[0]).toString('utf8'), 'hello');
});

test('reads DEFLATE members (round-trip)', () => {
  const body = 'x'.repeat(5000) + 'the quick brown fox';
  const zip = makeZip([{ name: 'big.txt', data: body, method: 8 }]);
  const o = openZip(zip);
  assert.equal(o.file('big.txt').toString('utf8'), body);
});

test('openZip.file is path/case tolerant and match() works', () => {
  const zip = makeZip([
    { name: 'Metadata/thumbnail.png', data: Buffer.from([1, 2, 3]), method: 0 },
    { name: '3D/3dmodel.model', data: '<model/>', method: 8 },
  ]);
  const o = openZip(zip);
  assert.deepEqual([...o.file('metadata/thumbnail.png')], [1, 2, 3]);
  assert.ok(o.match(/\.model$/i).toString('utf8').includes('<model'));
  assert.equal(o.file('does-not-exist'), null);
});

test('malformed / truncated input returns empty, never throws', () => {
  assert.deepEqual(listEntries(Buffer.from('not a zip at all')), []);
  assert.deepEqual(listEntries(Buffer.alloc(0)), []);
  assert.deepEqual(listEntries(null), []);
  // Valid zip with the tail chopped off — no EOCD.
  const zip = makeZip([{ name: 'a', data: 'b' }]);
  assert.deepEqual(listEntries(zip.subarray(0, zip.length - 10)), []);
});

test('accepts ArrayBuffer / TypedArray input', () => {
  const zip = makeZip([{ name: 'a.txt', data: 'hi', method: 0 }]);
  const ab = zip.buffer.slice(zip.byteOffset, zip.byteOffset + zip.byteLength);
  assert.equal(openZip(ab).file('a.txt').toString('utf8'), 'hi');
  assert.equal(openZip(new Uint8Array(ab)).file('a.txt').toString('utf8'), 'hi');
});

/* ── ZIP64 ───────────────────────────────────────────────────────────────── */

test('a zip64 archive lists and reads, however small it is', () => {
  // Some writers emit zip64 for every archive. Thirteen of one shop's 3MFs
  // were such files — the smallest 34 KB — and every one listed as empty.
  const buf = makeZip([
    { name: '3D/3dmodel.model', data: '<model/>', method: 8 },
    { name: 'Metadata/thumbnail.png', data: Buffer.from([0x89, 0x50, 0x4e, 0x47]) },
  ], { zip64: true });
  assert.ok(buf.includes(Buffer.from('PK\x06\x06', 'latin1')), 'the fixture is not zip64');
  const entries = listEntries(buf);
  assert.deepEqual(entries.map((e) => e.name), ['3D/3dmodel.model', 'Metadata/thumbnail.png']);
  assert.equal(entries[0].size, 8, 'the real size came from the zip64 extra, not the marker');
  assert.equal(readEntry(buf, entries[0]).toString('utf8'), '<model/>');
  assert.equal(openZip(buf).file('Metadata/thumbnail.png').length, 4);
});

test('a zip64 archive whose locator is broken is empty, never a guess', () => {
  const buf = makeZip([{ name: 'a.txt', data: 'hello' }], { zip64: true });
  const loc = buf.lastIndexOf(Buffer.from('PK\x06\x07', 'latin1'));
  const broken = Buffer.from(buf);
  broken.writeBigUInt64LE(BigInt(buf.length + 4096), loc + 8);   // points past the file
  assert.deepEqual(listEntries(broken), []);
});
