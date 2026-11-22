const { test } = require('node:test');
const assert = require('node:assert/strict');

const SI = require('../lib/storefront-insights.js');

test('no activity is empty, not a funnel of zeros', () => {
  assert.equal(SI.insights(null).empty, true);
  assert.equal(SI.insights({ views: 0, carts: 0, orders: 0, items: [] }).empty, true);
});

test('conversion is orders over views to one decimal, and the top five were carted or ordered', () => {
  const items = [
    { id: 'p1', name: 'Vase', orders: 3, carts: 5 },
    { id: 'p2', name: '', orders: 0, carts: 0 },
    { id: 'p3', orders: 0, carts: 2 },
    { id: 'p4', name: 'D', orders: 1 }, { id: 'p5', name: 'E', carts: 1 },
    { id: 'p6', name: 'F', carts: 1 }, { id: 'p7', name: 'G', carts: 1 },
  ];
  const s = SI.insights({ views: 300, carts: 20, orders: 7, items });
  assert.equal(s.empty, false);
  assert.equal(s.conversionPct, 2.3);
  assert.deepEqual(s.top.map((t) => t.id), ['p1', 'p3', 'p4', 'p5', 'p6']);
  assert.equal(s.top[1].name, 'p3', 'a product with no name is called by its id');
  assert.equal(SI.insights({ carts: 1 }).conversionPct, 0);
});

test('reviews: whole stars between none and five, the day, and only rows that can be deleted', () => {
  const rows = SI.reviewRows([
    { id: 7, rating: 4.6, comment: 'Great', name: ' Sara ', createdAt: '2026-11-02T08:00:00Z', verified: 1 },
    { id: 'r2', rating: 9, comment: null, createdAt: '' },
    { rating: 5, comment: 'no id' },
    null,
  ]);
  assert.deepEqual(rows, [
    { id: '7', stars: 5, comment: 'Great', name: 'Sara', day: '2026-11-02', verified: true },
    { id: 'r2', stars: 5, comment: '', name: '', day: '', verified: false },
  ]);
  assert.equal(SI.stars('x'), 0);
  assert.equal(SI.stars(-2), 0);
});

test('the review link is the cloud address, /review/, the shop', () => {
  assert.equal(SI.reviewLink('https://cloud.khaytapp.com/', 'shop_ab12'), 'https://cloud.khaytapp.com/review/shop_ab12');
  assert.equal(SI.reviewLink('', 'shop_1'), '');
  assert.equal(SI.reviewLink('https://c.example', ''), '');
});
