'use strict';
/**
 * A colour's plain name, never its code (lib/colour-name.js), against the
 * shared vectors the Mac reads too (test/fixtures/colour-name-vectors.json).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/colour-name');
const V = require('./fixtures/colour-name-vectors.json');

for (const c of V.cases) {
  test('colourName: ' + c.why, () => {
    assert.equal(C.colourName(c.hex, c.lang, c.known ? { known: c.known } : undefined), c.want);
  });
}

test('every language names every palette colour, and no name is a code', () => {
  const keys = C.PALETTE.map(([k]) => k);
  for (const lang of C.LANGS) {
    for (const [key, ref] of C.PALETTE) {
      const n = C.colourName(ref, lang);
      assert.ok(typeof n === 'string' && n.length > 0, `${lang} ${key}`);
      assert.ok(!/#?[0-9a-f]{6}/i.test(n), `${lang} ${key}: ${n}`);
    }
  }
  assert.equal(new Set(keys).size, keys.length, 'palette keys are unique');
});

test("each palette colour is its own nearest name (no reference sits nearer another's)", () => {
  for (const [key, ref] of C.PALETTE) assert.equal(C.nearestKey(ref).key, key, key);
});
