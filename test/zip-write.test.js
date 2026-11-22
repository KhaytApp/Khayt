'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('zlib');
const { writeZip, crc32 } = require('../lib/zip-write');
const { openZip, listEntries } = require('../lib/zip-read');

test('crc32 matches zlib.crc32', () => {
  const b = Buffer.from('The quick brown fox\n');
  assert.equal(crc32(b), zlib.crc32(b) >>> 0);
});

test('writeZip → openZip round-trips STORE + DEFLATE members', () => {
  const bigText = 'colour '.repeat(500); // compresses well → DEFLATE chosen
  const members = [
    { name: '3D/3dmodel.model', data: '<model>geometry</model>' },
    { name: 'Metadata/project_settings.config', data: bigText },
    { name: '[Content_Types].xml', data: '<Types/>' },
  ];
  const buf = writeZip(members);
  assert.ok(Buffer.isBuffer(buf) && buf.length > 0);

  const zip = openZip(buf);
  assert.equal(zip.entries.length, 3);
  assert.equal(zip.file('3D/3dmodel.model').toString('utf8'), '<model>geometry</model>');
  assert.equal(zip.file('Metadata/project_settings.config').toString('utf8'), bigText);
  assert.equal(zip.file('[Content_Types].xml').toString('utf8'), '<Types/>');

  // The compressible member should have been stored with DEFLATE (method 8).
  const cfg = listEntries(buf).find((e) => e.name === 'Metadata/project_settings.config');
  assert.equal(cfg.method, 8);
});

test('writeZip preserves exact binary payloads (thumbnail PNG bytes)', () => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 250, 200, 0, 255]);
  const buf = writeZip([{ name: 'Metadata/thumbnail.png', data: png, store: true }]);
  const out = openZip(buf).file('Metadata/thumbnail.png');
  assert.deepEqual(out, png);
  // store:true keeps it uncompressed (method 0).
  assert.equal(listEntries(buf)[0].method, 0);
});

test('writeZip rejects bad input, never throws', () => {
  assert.equal(writeZip(null), null);
  assert.equal(writeZip([]), null);
  assert.equal(writeZip([{ data: 'no name' }]), null);
});
