'use strict';
/**
 * Moving a picture out of the store without ever losing one.
 *
 * A print-file record is 914 bytes; the same record carrying its thumbnail as a
 * base64 data URL is 14,900. At the store's 50 MB ceiling that is the difference
 * between 10,000 files costing 8.9 MB and 5,000 files not fitting at all — and
 * past the ceiling every save is refused, which is a shop losing its day's work
 * at the next launch rather than merely a slow app.
 *
 * So this is a data-safety module, and the tests are mostly about the one rule
 * that makes it safe: THE IN-STORE COPY IS NOT DROPPED UNTIL THE ON-DISK COPY
 * HAS BEEN READ BACK. A write that was merely attempted proves nothing — a full
 * disk, a permissions error and a vault folder that is not there all return
 * from a write without throwing anywhere the caller looks.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/thumb-store.js');

const DATA = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ';

test('only records still carrying a picture in the store are planned', () => {
  const plan = T.planMigration([
    { id: 'A', thumb: DATA },
    { id: 'B', thumbFile: 'thumb.jpg' },        // already moved
    { id: 'C' },                                 // never had one
    { id: 'D', thumb: '' },
    { id: 'E', thumb: 'https://example.com/x.jpg' },  // not ours to move
    null,
    { thumb: DATA },                             // no id — nowhere to put it
  ]);
  assert.deepEqual(plan.map((p) => p.id), ['A']);
  assert.equal(plan[0].dataUrl, DATA);
});

test('a verified write is what moves the record, and nothing else is', () => {
  const rec = { id: 'A', thumb: DATA };
  const patch = T.completeMigration(rec, { filename: 'thumb.jpg', verified: true });
  assert.equal(patch.migrated, true);
  assert.equal(patch.thumb, undefined, 'the store copy is dropped only now');
  assert.equal(patch.thumbFile, 'thumb.jpg');
});

test('an UNVERIFIED write leaves the picture exactly where it was', () => {
  // The rule the whole module exists for. A write that was attempted proves
  // nothing: a full disk, a permissions error, or a vault folder that is not
  // there all come back without throwing anywhere the caller looks.
  const rec = { id: 'A', thumb: DATA };
  for (const result of [
    { filename: 'thumb.jpg', verified: false },
    { filename: '', verified: true },
    { verified: true },
    {},
    null,
    undefined,
  ]) {
    const patch = T.completeMigration(rec, result);
    assert.equal(patch.migrated, false, JSON.stringify(result));
    assert.equal(patch.thumb, DATA, 'the in-store picture must survive a failed move');
    assert.equal(patch.thumbFile, undefined, 'and must not point at a file that may not be there');
  }
});

test('a card knows where its picture is coming from', () => {
  assert.deepEqual(T.thumbSource({ thumb: DATA }), { kind: 'store', src: DATA });
  assert.deepEqual(T.thumbSource({ thumbFile: 'thumb.jpg' }), { kind: 'disk', file: 'thumb.jpg' });
  assert.deepEqual(T.thumbSource({}), { kind: 'none' });
  assert.deepEqual(T.thumbSource(null), { kind: 'none' });
});

test('a record part-way through a move still shows its picture', () => {
  // Both fields set is the state between the write and the save. It must render
  // from the store copy, which is the one known to exist.
  const rec = { thumb: DATA, thumbFile: 'thumb.jpg' };
  assert.deepEqual(T.thumbSource(rec), { kind: 'store', src: DATA });
});

test("a shop's own photo is shown when the model has no preview", () => {
  assert.deepEqual(T.thumbSource({ userPhoto: DATA }), { kind: 'store', src: DATA });
});

test('the report can say how much of the store the pictures are using', () => {
  const used = T.storeBytesUsedByThumbs([{ id: 'A', thumb: DATA }, { id: 'B', thumb: DATA }, { id: 'C' }]);
  assert.equal(used, DATA.length * 2);
  assert.equal(T.storeBytesUsedByThumbs([]), 0);
  assert.equal(T.storeBytesUsedByThumbs(null), 0);
});

test('only image data URLs are treated as pictures to move', () => {
  assert.equal(T.isDataUrl(DATA), true);
  assert.equal(T.isDataUrl('data:image/png;base64,iVBOR'), true);
  assert.equal(T.isDataUrl('data:text/html;base64,PHN2Zz4='), false, 'not an image');
  assert.equal(T.isDataUrl('/vault/thumb.jpg'), false);
  assert.equal(T.isDataUrl(null), false);
});
