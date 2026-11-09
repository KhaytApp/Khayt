'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/number-prefixes');

test('one field while the two prefixes agree as used', () => {
  assert.deepEqual(P.prefixView({}), { shared: 'INV' });
  assert.deepEqual(P.prefixView(null), { shared: 'INV' });
  assert.deepEqual(P.prefixView({ invPrefix: 'INV', invNumPrefix: 'INV' }), { shared: 'INV' });
  // Blank reads as INV, as every numbering rule reads it.
  assert.deepEqual(P.prefixView({ invPrefix: 'INV' }), { shared: 'INV' });
  assert.deepEqual(P.prefixView({ invPrefix: '  ', invNumPrefix: 'INV' }), { shared: 'INV' });
  assert.deepEqual(P.prefixView({ invPrefix: ' ATH ', invNumPrefix: 'ATH' }), { shared: 'ATH' });
  // Not a string is blank.
  assert.deepEqual(P.prefixView({ invPrefix: 7, invNumPrefix: null }), { shared: 'INV' });
});

test('two honestly named fields when they differ', () => {
  assert.deepEqual(P.prefixView({ invPrefix: 'ATH', invNumPrefix: 'INV' }), { job: 'ATH', taxInvoice: 'INV' });
  assert.deepEqual(P.prefixView({ invPrefix: 'ATH' }), { job: 'ATH', taxInvoice: 'INV' });
  // Case matters: these are printed.
  assert.deepEqual(P.prefixView({ invPrefix: 'inv', invNumPrefix: 'INV' }), { job: 'inv', taxInvoice: 'INV' });
});

test('the shared field writes both keys and nothing else', () => {
  assert.deepEqual(P.prefixPatch({ shared: ' ATH ' }), { invPrefix: 'ATH', invNumPrefix: 'ATH' });
  assert.deepEqual(P.prefixPatch({ shared: '' }), { invPrefix: 'INV', invNumPrefix: 'INV' });
  assert.deepEqual(P.prefixPatch({ shared: 'ABCDEFGHIJKLMN' }), { invPrefix: 'ABCDEFGHIJ', invNumPrefix: 'ABCDEFGHIJ' });
});

test('split fields write only the key each one names', () => {
  assert.deepEqual(P.prefixPatch({ job: 'ATH', taxInvoice: 'INV' }), { invPrefix: 'ATH', invNumPrefix: 'INV' });
  assert.deepEqual(P.prefixPatch({ job: 'ATH' }), { invPrefix: 'ATH' });
  assert.deepEqual(P.prefixPatch({ taxInvoice: '' }), { invNumPrefix: 'INV' });
  assert.deepEqual(P.prefixPatch({}), {});
  assert.deepEqual(P.prefixPatch(null), {});
});

test('a cut never leaves half of a surrogate pair', () => {
  // 9 letters then an emoji (2 UTF-16 units): the cut at 10 would split it.
  assert.equal(P.clean('ABCDEFGHI\u{1F600}'), 'ABCDEFGHI');
  assert.equal(P.clean('ABCDEFGH\u{1F600}Z'), 'ABCDEFGH\u{1F600}');
});

test('the patch never carries the counter, the format or a year', () => {
  for (const input of [{ shared: 'X' }, { job: 'X', taxInvoice: 'Y' }]) {
    const keys = Object.keys(P.prefixPatch(input)).sort();
    assert.ok(keys.every((k) => k === 'invPrefix' || k === 'invNumPrefix'), keys.join());
  }
});
