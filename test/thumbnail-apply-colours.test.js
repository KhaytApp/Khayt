'use strict';
/**
 * KhaytThumb.applyColours: putting a colour re-read on a library record, the
 * rule renderer/printfiles.js applied on its own until Nov 16 2026. Synthetic
 * records only. Both apps re-read stale records with it (the Mac's sweep and
 * the desktop's), so these vectors are what the Mac's ColoursRereadTests run.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/thumbnail-extract.js');

const RED = { hex: '#E23D3D', grams: 12.5, label: 'Filament 1' };
const BLUE = { hex: '#2F6FE0', grams: null, label: 'Filament 2' };

test('a read naming the used slots replaces the loaded ones and stamps the reader', () => {
  const rec = { colors: [RED, BLUE, { hex: '#FFFFFF' }, { hex: '#000000' }], swapCount: 3, updatedAt: 'U' };
  const r = T.applyColours(rec, { colors: [{ hex: '#E23D3D', grams: null, label: 'Filament 1' }], swapCount: 0, slotsKnown: true, reader: 2 });
  assert.equal(r.changed, true);
  // The grams an earlier slice gave are kept for a colour still there.
  assert.deepEqual(rec.colors, [{ hex: '#E23D3D', grams: 12.5, label: 'Filament 1' }]);
  assert.equal(rec.swapCount, 0);
  assert.equal(rec.coloursReader, 2);
  assert.equal(rec.updatedAt, 'U', 'updatedAt is never touched');
});

test('a read that cannot name the slots stamps the reader and keeps the colours', () => {
  const rec = { colors: [RED, BLUE], swapCount: 1 };
  const r = T.applyColours(rec, { colors: [], swapCount: 0, slotsKnown: false, reader: 2 });
  assert.equal(r.changed, true, 'the stamp is a change');
  assert.deepEqual(rec.colors, [RED, BLUE]);
  assert.equal(rec.swapCount, 1);
  assert.equal(rec.coloursReader, 2);
});

test('an empty read never empties a record', () => {
  const rec = { colors: [RED], swapCount: 0, coloursReader: 2 };
  assert.equal(T.applyColours(rec, { colors: [], slotsKnown: true, reader: 2 }).changed, false);
  assert.deepEqual(rec.colors, [RED]);
});

test('the same read twice: the second changes nothing', () => {
  const rec = { colors: [RED, BLUE], swapCount: 2 };
  const read = { colors: [BLUE], swapCount: 0, slotsKnown: true, reader: 2 };
  assert.equal(T.applyColours(rec, read).changed, true);
  assert.equal(T.applyColours(rec, read).changed, false);
});

test('swapsKnown is copied when the read says', () => {
  const rec = { colors: [RED] };
  T.applyColours(rec, { colors: [RED], swapCount: 0, slotsKnown: true, swapsKnown: false, reader: 2 });
  assert.equal(rec.swapsKnown, false);
  assert.equal(T.applyColours(rec, { colors: [RED], swapCount: 4, slotsKnown: true, swapsKnown: true, reader: 2 }).changed, true);
  assert.equal(rec.swapsKnown, true);
  assert.equal(rec.swapCount, 4);
});

test('nothing to read, or no record: no change', () => {
  assert.deepEqual(T.applyColours(null, { colors: [RED] }), { changed: false });
  assert.deepEqual(T.applyColours({}, null), { changed: false });
});
