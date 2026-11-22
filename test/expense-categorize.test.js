'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { suggestCategory } = require('../lib/expense-categorize.js');

test('maps notes to categories by keyword', () => {
  assert.equal(suggestCategory('2x PLA spool black'), 'filament');
  assert.equal(suggestCategory('Monthly electricity bill'), 'electricity');
  assert.equal(suggestCategory('Replaced nozzle + belt service'), 'maintenance');
  assert.equal(suggestCategory('Aramex courier shipping'), 'shipping');
  assert.equal(suggestCategory('Glue stick and spatula'), 'tools');
});

test('Arabic notes match too', () => {
  assert.equal(suggestCategory('فاتورة كهرباء'), 'electricity');
  assert.equal(suggestCategory('شحن أرامكس'), 'shipping');
  assert.equal(suggestCategory('بكرة خيط PLA'), 'filament');
});

test('no confident match → null; empty → null', () => {
  assert.equal(suggestCategory('lunch with a friend'), null);
  assert.equal(suggestCategory(''), null);
  assert.equal(suggestCategory(null), null);
});

test('most-hit category wins', () => {
  // "filament spool" has 2 filament hits vs 0 elsewhere
  assert.equal(suggestCategory('filament spool restock'), 'filament');
});
