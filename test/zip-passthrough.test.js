/**
 * Copying a ZIP member across without recompressing it.
 *
 * A 3MF repackage rewrites a few kilobytes of config and not one byte of geometry, but
 * every member was being inflated and then deflated again at level 9 to reproduce bytes
 * the source already held. On a real 229 MB poster whose meshes inflate to 1168 MB that
 * was 106 seconds of frozen main process.
 *
 * These cover the mechanism: zip-read hands out a member as stored, zip-write puts it
 * back untouched, and anything less than a complete, coherent descriptor falls back to
 * compressing normally rather than writing a header it can't stand behind.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');

const { openZip, listEntries, readEntryRaw } = require('../lib/zip-read');
const { writeZip } = require('../lib/zip-write');

/** Compressible enough that DEFLATE genuinely beats STORE. */
const BIG = Buffer.from('<vertex x="1.0" y="2.0" z="3.0"/>'.repeat(4000), 'utf8');
const SMALL = Buffer.from('{"filament_colour":["#FF0000","#00FF00"]}', 'utf8');
const RANDOM = require('node:crypto').randomBytes(2048); // incompressible → stored

const source = () => writeZip([
  { name: 'Metadata/project_settings.config', data: SMALL },
  { name: '3D/Objects/object_1.model', data: BIG },
  { name: 'Metadata/plate_1.png', data: RANDOM },
]);

const entryOf = (buf, name) => listEntries(buf).find((e) => e.name === name);

test('a member comes back out as stored, with the descriptors needed to rewrite it', () => {
  const buf = source();
  const raw = readEntryRaw(buf, entryOf(buf, '3D/Objects/object_1.model'));
  assert.ok(raw, 'a DEFLATE member should be readable raw');
  assert.equal(raw.method, 8, 'the big compressible member should have been deflated');
  assert.equal(raw.size, BIG.length, 'size is the UNcompressed length');
  assert.ok(raw.comp.length < BIG.length, 'comp is the compressed payload');
  assert.equal(zlib.inflateRawSync(raw.comp).toString('utf8'), BIG.toString('utf8'));

  const stored = readEntryRaw(buf, entryOf(buf, 'Metadata/plate_1.png'));
  assert.equal(stored.method, 0, 'incompressible data is stored, not deflated');
  assert.deepEqual(Buffer.from(stored.comp), RANDOM);
});

test('a passed-through member is byte-identical and was never recompressed', () => {
  const buf = source();
  const mesh = entryOf(buf, '3D/Objects/object_1.model');
  const raw = readEntryRaw(buf, mesh);

  const out = writeZip([
    { name: 'Metadata/project_settings.config', data: Buffer.from('{"changed":true}', 'utf8') },
    { name: '3D/Objects/object_1.model', raw },
  ]);
  assert.ok(out, 'the archive should build');

  const z = openZip(out);
  assert.deepEqual(z.file('3D/Objects/object_1.model'), BIG, 'contents survive the copy');

  const copied = entryOf(out, '3D/Objects/object_1.model');
  assert.equal(copied.method, mesh.method);
  assert.equal(copied.size, mesh.size);
  assert.equal(copied.crc, mesh.crc, 'the source CRC is carried, not recomputed');
  assert.equal(copied.compSize, mesh.compSize,
    'the stored bytes are the same length — proof they were copied, not deflated again');
});

test('a descriptor that does not fully describe its payload is not trusted', () => {
  const buf = source();
  const good = readEntryRaw(buf, entryOf(buf, '3D/Objects/object_1.model'));
  const FALLBACK = Buffer.from('fallback content', 'utf8');

  const bad = [
    ['unsupported method', { ...good, method: 99 }],
    ['comp is not bytes', { ...good, comp: 'not a buffer' }],
    ['no uncompressed size', { ...good, size: undefined }],
    ['negative size', { ...good, size: -1 }],
    ['no crc', { ...good, crc: undefined }],
    // A STORE member's stored bytes ARE its contents, so a length that disagrees means
    // the descriptor belongs to some other payload.
    ['stored length disagrees with size', { method: 0, comp: Buffer.from('abc'), crc: 0, size: 99 }],
  ];

  for (const [why, raw] of bad) {
    const out = writeZip([{ name: 'm.model', raw, data: FALLBACK }]);
    assert.ok(out, why + ': should still produce an archive');
    assert.deepEqual(openZip(out).file('m.model'), FALLBACK,
      why + ': should fall back to compressing data, not write the bad descriptor');
  }
});

test('a member with neither usable raw nor data is empty, not corrupt', () => {
  const out = writeZip([{ name: 'empty.txt', raw: { method: 99 } }]);
  assert.ok(out);
  assert.deepEqual(openZip(out).file('empty.txt'), Buffer.alloc(0));
});

test('passthrough and recompression produce the same readable archive', () => {
  const buf = source();
  const names = ['Metadata/project_settings.config', '3D/Objects/object_1.model', 'Metadata/plate_1.png'];

  const viaRaw = writeZip(names.map((n) => ({ name: n, raw: readEntryRaw(buf, entryOf(buf, n)) })));
  const viaData = writeZip(names.map((n) => ({ name: n, data: openZip(buf).file(n) })));

  for (const n of names) {
    assert.deepEqual(openZip(viaRaw).file(n), openZip(viaData).file(n), n + ' reads the same either way');
  }
});
