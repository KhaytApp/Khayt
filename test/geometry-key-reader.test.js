'use strict';
/**
 * Which reader wrote a record's key, and when it is due to be read again.
 *
 * A reader fault fixed in the code reaches only the files imported after it;
 * every record the old reader wrote keeps its wrong number. So a record names
 * its reader, and whichever app next opens the book reads the due ones again.
 * The rule is one function shared with the Mac app; the renderer's importers
 * must write the marker beside every key, or the book they write is due for
 * ever.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const GK = require('../lib/geometry-key');
const MI = require('../lib/model-identity');

test('a record below the current reader, or naming none, is due', () => {
  assert.equal(typeof GK.READER, 'number');
  assert.ok(GK.READER >= 2, 'reader 2 is the one-plate, every-component, zip64 reader');
  assert.equal(GK.needsRemeasure({}), true, 'written before readers were numbered');
  assert.equal(GK.needsRemeasure(null), true);
  assert.equal(GK.needsRemeasure({ geometryReader: GK.READER - 1 }), true);
  assert.equal(GK.needsRemeasure({ geometryReader: GK.READER }), false);
  assert.equal(GK.needsRemeasure({ geometryReader: GK.READER + 1 }), false, 'a newer build measured it');
  assert.equal(GK.needsRemeasure({ geometryReader: String(GK.READER) }), false, 'a number kept as text still counts');
  assert.equal(GK.needsRemeasure({ geometryReader: 'soon' }), true);
});

test('model-identity hands the renderer the same rule, not a copy', () => {
  assert.equal(MI.READER, GK.READER);
  assert.equal(MI.needsRemeasure({ geometryReader: GK.READER }), false);
  assert.equal(MI.needsRemeasure({}), true);
});

test('every key the renderer writes carries the reader that wrote it', () => {
  const src = fs.readFileSync(path.join(__dirname, '../renderer/printfiles.js'), 'utf8');
  const writes = [...src.matchAll(/rec\.geometryKey = mi\./g)];
  assert.ok(writes.length >= 3, `expected the three import paths, found ${writes.length}`);
  for (const w of writes) {
    const after = src.slice(w.index, w.index + 1400);
    assert.ok(after.includes('rec.geometryReader = mi.READER'),
      `a key written at offset ${w.index} has no reader beside it:\n${after.slice(0, 200)}`);
  }
});
