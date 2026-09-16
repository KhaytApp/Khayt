/**
 * What a stranger's uploaded model has to survive before it is written down
 * and handed to a slicer.
 *
 * The old bargain was that a customer's file was read in memory and dropped —
 * nothing written, nothing executed. Slicing changes that, so the file is
 * inspected first. These tests are the inspection, and they also pin what it
 * does NOT claim: a parser bug in somebody else's C++ is not something a
 * structural check can see.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/upload-scan.js');

const zip = (entries, size = 2000) => ({ ext: '3mf', size, header: '504b0304140000', entries });
const member = (name, size = 1000, compressedSize = 400) => ({ name, size, compressedSize });

test('a plain, honest file is cleared', () => {
  assert.deepEqual(S.verdict(zip([member('3D/3dmodel.model'), member('_rels/.rels', 200, 120)])),
    { ok: true, reason: null });
  assert.deepEqual(S.verdict({ ext: 'stl', size: 84_000, header: '0000000000' }), { ok: true, reason: null });
  assert.deepEqual(S.verdict({ ext: 'stl', size: 900, header: '736f6c696420637562' }), { ok: true, reason: null });
  assert.deepEqual(S.verdict({ ext: 'obj', size: 900, header: '76202d31' }), { ok: true, reason: null });
  assert.deepEqual(S.verdict({ ext: 'gcode', size: 900, header: '3b2047' }), { ok: true, reason: null });
});

test('an archive may not name a member outside where it will be opened', () => {
  for (const name of ['../secrets', 'a/../../b', '/etc/passwd', '\\\\server\\share', 'C:\\Windows\\x',
                      'C:/Windows/x', 'a\\..\\b', '', 'has\u0000nul']) {
    assert.equal(S.unsafeName(name), true, JSON.stringify(name));
    assert.equal(S.verdict(zip([member(name)])).reason, 'unsafe-path', JSON.stringify(name));
  }
  // A name that merely CONTAINS dots is fine; only a `..` segment is not.
  for (const name of ['3D/3dmodel.model', 'a..b/c', 'Metadata/thumbnail.png', 'x/..y/z']) {
    assert.equal(S.unsafeName(name), false, name);
  }
});

test('a file that expands out of all proportion is refused', () => {
  // A classic bomb: a kilobyte that becomes a gigabyte.
  assert.equal(S.verdict(zip([member('a', 1024 * 1024 * 1024, 900)], 1024)).reason, 'expands-too-far');
  // The ratio is measured against what ARRIVED, so an archive lying about its
  // own compressed sizes does not talk its way past it.
  assert.equal(S.verdict(zip([member('a', 600 * 1024 * 1024, 600 * 1024 * 1024)], 2000)).reason,
    'expands-too-far');
  // And real 3MF compression is nowhere near the limit.
  assert.equal(S.verdict(zip([member('3D/3dmodel.model', 14 * 1024 * 1024, 1024 * 1024)], 1024 * 1024)).ok,
    true, 'an ordinary well-compressed 3MF was refused');
});

test('a file that is not what its name says is refused', () => {
  // A PNG called a 3MF.
  assert.equal(S.verdict({ ext: '3mf', size: 5000, header: '89504e470d0a1a0a' }).reason, 'not-what-it-says');
  // A 3MF with a zip header and no members at all.
  assert.equal(S.verdict({ ext: '3mf', size: 5000, header: '504b0304', entries: [] }).reason, 'not-what-it-says');
  // Something binary called an OBJ.
  assert.equal(S.verdict({ ext: 'obj', size: 5000, header: '0000ffff' }).reason, 'not-what-it-says');
  // Too short to be a binary STL, and not ASCII either.
  assert.equal(S.verdict({ ext: 'stl', size: 20, header: 'ffeeddcc' }).reason, 'not-what-it-says');
  // An extension with no reader here.
  assert.equal(S.verdict({ ext: 'exe', size: 5000, header: '4d5a' }).reason, 'not-what-it-says');
});

test('size is answered before anything else is looked at', () => {
  assert.equal(S.verdict({ ext: 'stl', size: 0, header: '' }).reason, 'empty');
  assert.equal(S.verdict({ ext: 'stl', size: S.MAX_BYTES + 1, header: '00' }).reason, 'too-large');
  assert.equal(S.verdict({ ext: 'stl', size: S.MAX_BYTES, header: '00' }).ok, true);
  // The caller may tighten it, never loosen it past its own route's cap.
  assert.equal(S.verdict({ ext: 'stl', size: 5000, header: '00' }, { maxBytes: 1000 }).reason, 'too-large');
});

test('an archive with absurdly many members is refused', () => {
  const many = Array.from({ length: S.MAX_ENTRIES + 1 }, (_, i) => member('p' + i, 10, 10));
  assert.equal(S.verdict(zip(many)).reason, 'too-many-parts');
});

test('nothing at all is refused rather than cleared by accident', () => {
  for (const facts of [null, undefined, {}, { ext: '3mf' }, { size: 10 }]) {
    assert.equal(S.verdict(facts).ok, false, JSON.stringify(facts));
  }
});
