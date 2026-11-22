'use strict';

// Unit tests for the pure clients-table comparator (Fix 3).
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { clientCompare } = require('../renderer/clients.js');

// rowOf maps a client object to its comparable display fields.
const rows = {
  a: { name: 'Alice', orders: 3, revenue: 300, outstanding: 0,  last: '2026-01-10' },
  b: { name: 'bob',   orders: 1, revenue: 900, outstanding: 50, last: '2026-03-01' },
  c: { name: 'Carol', orders: 3, revenue: 100, outstanding: 50, last: '2026-02-15' },
};
const rowOf = (c) => rows[c.id];
const sortIds = (col, dir) =>
  ['a', 'b', 'c'].map((id) => ({ id })).sort(clientCompare(col, dir, rowOf)).map((c) => c.id);

test('clientCompare exported as a function', () => {
  assert.equal(typeof clientCompare, 'function');
});

test('name sorts case-insensitively ascending', () => {
  assert.deepEqual(sortIds('name', 'asc'), ['a', 'b', 'c']); // Alice, bob, Carol
});

test('name descending reverses order', () => {
  assert.deepEqual(sortIds('name', 'desc'), ['c', 'b', 'a']);
});

test('orders sorts numerically with name tiebreak', () => {
  // a & c both have 3 orders; tiebreak on name keeps Alice before Carol.
  assert.deepEqual(sortIds('orders', 'desc'), ['a', 'c', 'b']);
  assert.deepEqual(sortIds('orders', 'asc'), ['b', 'a', 'c']);
});

test('revenue sorts numerically', () => {
  assert.deepEqual(sortIds('revenue', 'desc'), ['b', 'a', 'c']);
});

test('outstanding sorts numerically with name tiebreak', () => {
  // b & c both 50 -> name tiebreak (bob before Carol); a is 0 -> last on desc.
  assert.deepEqual(sortIds('outstanding', 'desc'), ['b', 'c', 'a']);
});

test('last-order date sorts lexically (ISO dates)', () => {
  assert.deepEqual(sortIds('last', 'desc'), ['b', 'c', 'a']);
});

test('unknown column falls back to name', () => {
  assert.deepEqual(sortIds('bogus', 'asc'), ['a', 'b', 'c']);
});
