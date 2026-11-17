'use strict';
/**
 * A zip cannot write far more than it says by lying about a STORED member's
 * size, or by pointing many members at the same bytes (beta.40 security
 * review, C). A stored member is copied out byte for byte, so it writes its
 * compressed size whatever its declared size says; the upload scan
 * (lib/upload-scan.js verdict, the Mac's archive import) and the desktop's
 * zip import budget (lib/zip-intake.js plan) now count the larger of the two,
 * and the scan refuses members whose data adds up to more than the file.
 * Built from a real archive's own directory, read by lib/zip-read.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/upload-scan.js');
const I = require('../lib/zip-intake.js');
const Z = require('../lib/zip-read.js');
const { makeZip } = require('./helpers/make-zip');

const MB = 1024 * 1024;
const header = (buf) => buf.subarray(0, 16).toString('hex');

/** A zip of one stored member whose central directory says it is 1 byte. */
function lyingZip(bytes) {
  const zip = Buffer.from(makeZip([{ name: 'a.3mf', data: Buffer.alloc(bytes, 7), method: 0 }]));
  const cd = zip.lastIndexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  zip.writeUInt32LE(1, cd + 24);                         // uncompressed size: "1 byte"
  return zip;
}
const facts = (zip, entries) => ({ ext: 'zip', size: zip.length, header: header(zip),
  entries: entries.map((e) => ({ name: e.name, size: e.size, compressedSize: e.compSize })) });

test('a stored member declaring 1 byte over 20 MB is counted as 20 MB', () => {
  const zip = lyingZip(20 * MB);
  const entries = Z.listEntries(zip);
  assert.equal(entries[0].size, 1);
  assert.equal(entries[0].compSize, 20 * MB);
  // One of them is a normal archive of what it holds.
  assert.equal(S.verdict(facts(zip, entries)).ok, true);
  // The importer's budget charges the 20 MB it will write.
  assert.equal(I.plan(entries).bytes, 20 * MB);
});

test('many members pointing at the same bytes: refused by the scan, capped by the import', () => {
  const zip = lyingZip(20 * MB);
  const one = Z.listEntries(zip)[0];
  const many = Array.from({ length: 2000 }, (_, k) => Object.assign({}, one, { name: `p${k}.3mf` }));
  // Their data adds up to 40 GB in a 20 MB file: they overlap.
  const v = S.verdict(facts(zip, many));
  assert.equal(v.ok, false);
  assert.equal(v.reason, 'expands-too-far');
  // Before: 2000 bytes declared, all taken. Now the 2 GiB budget stops it, loudly.
  const p = I.plan(many);
  assert.ok(p.bytes <= 2 * 1024 * MB, `${p.bytes}`);
  assert.equal(p.truncated, true);
  assert.ok(p.take.length < 120, `${p.take.length} taken`);
});

test('an honest archive is unchanged: declared and compressed sizes as written', () => {
  const zip = Buffer.from(makeZip([{ name: 'a.3mf', data: require('node:crypto').randomBytes(MB), method: 8 }, { name: 'b.stl', data: 'solid x', method: 0 }]));
  const entries = Z.listEntries(zip);
  assert.equal(S.verdict(facts(zip, entries)).ok, true);
  const p = I.plan(entries);
  assert.equal(p.bytes, MB + 'solid x'.length);
  assert.equal(p.truncated, false);
});
