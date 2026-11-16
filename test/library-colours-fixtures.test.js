'use strict';
/**
 * The synthetic 3MFs in test/fixtures/library-colours/ read as expected.json
 * says, through lib/thumbnail-extract.js colours3mf. The Mac's ColourReadTests
 * reads the same files through its own path and must name the same colours.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const T = require('../lib/thumbnail-extract.js');

const dir = path.join(__dirname, 'fixtures', 'library-colours');
const expected = JSON.parse(fs.readFileSync(path.join(dir, 'expected.json'), 'utf8'));

for (const [name, want] of Object.entries(expected)) {
  test(`${name}: ${want.hexes.join(' ')}`, () => {
    const r = T.colours3mf(fs.readFileSync(path.join(dir, name)));
    assert.deepEqual(r.colors.map((c) => c.hex), want.hexes);
    assert.equal(r.swapCount, want.swapCount);
    assert.equal(r.slotsKnown, want.slotsKnown);
    assert.equal(r.reader, want.reader);
  });
}

test("the loaded spools are not the print's colours", () => {
  assert.deepEqual(expected['unpainted-slot4.3mf'].hexes, ['#444444'], 'four loaded, one used');
  assert.deepEqual(expected['painted-1-2-5.3mf'].hexes, ['#111111', '#222222', '#555555'], 'eight loaded, three used');
});
