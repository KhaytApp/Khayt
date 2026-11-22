const { test } = require('node:test');
const assert = require('node:assert/strict');
const { searchScore, rankByQuery } = require('../lib/search-utils');

test('searchScore prefers exact and prefix matches', () => {
  assert.ok(searchScore('PLA Red', 'pla') > searchScore('Sparkle PLA', 'pla'));
  assert.equal(searchScore('hello', 'xyz'), 0);
});

test('searchScore matches all tokens out of order', () => {
  assert.ok(searchScore('John Smith Studio', 'smith john') > 0);
});

test('rankByQuery returns top matches sorted by score', () => {
  const items = [{ id: 'a', name: 'PLA Red' }, { id: 'b', name: 'PETG Blue' }, { id: 'c', name: 'PLA Black' }];
  const ranked = rankByQuery(items, 'pla', (i) => i.name, 2);
  assert.equal(ranked.length, 2);
  assert.equal(ranked[0].id, 'a');
});
