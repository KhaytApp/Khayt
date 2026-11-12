'use strict';
// lib/top-lists.js topSellers: the Simple Analytics "Top products this month"
// list. It ranked order TAGS, so a book whose jobs were all tagged "sample"
// showed "1. sample" as its best product (Nov 11 desktop UI review, X14).
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/content-languages.js');
const { topSellers } = require('../lib/top-lists.js');

const settings = { currency: 'SAR', lang: 'en' };
const ctx = (products = []) => ({ settings, products, clients: [], currencies: require('../lib/currencies.js').CURRENCIES, language: 'en' });
const job = (o) => ({ status: 'completed', currency: 'SAR', date: '2026-11-05', tags: ['sample'], ...o });

test('ranks by product or job name, never by tag', () => {
  const rows = topSellers([
    job({ project: 'Phone stand', price: 100 }),
    job({ project: ' phone STAND ', price: 50 }),
    job({ project: 'Helmet build', price: 320 }),
    job({ productId: 'P1', project: 'Gear (custom name)', price: 60 }),
    job({ productId: 'P1', project: 'Gear again', price: 60 }),
  ], ctx([{ id: 'P1', name: 'Gear set' }]), { limit: 5 });
  assert.deepEqual(rows.map((r) => [r.name, r.count]), [
    ['Helmet build', 1], ['Phone stand', 2], ['Gear set', 2],
  ]);
  assert.ok(!rows.some((r) => r.name === 'sample'));
  assert.equal(rows[1].revenue, 150);
});

test('ties go to the one sold more often; limit is honoured', () => {
  const rows = topSellers([
    job({ project: 'A', price: 100 }),
    job({ project: 'B', price: 50 }), job({ project: 'B', price: 50 }),
    job({ project: 'C', price: 10 }),
  ], ctx(), { limit: 2 });
  assert.deepEqual(rows.map((r) => r.name), ['B', 'A']);
});

test('a product with no name falls back to the job name; nameless jobs are skipped', () => {
  const rows = topSellers([
    job({ productId: 'P2', project: 'Lamp', price: 40 }),
    job({ project: '   ', price: 999 }),
    null,
  ], ctx([{ id: 'P2' }]));
  assert.deepEqual(rows.map((r) => r.name), ['Lamp']);
});

test('empty input gives an empty list', () => {
  assert.deepEqual(topSellers([], ctx()), []);
  assert.deepEqual(topSellers(undefined, ctx()), []);
});
