'use strict';
/**
 * An online order the desktop takes in from Order requests checks the SHELF
 * first, as the Mac's Online orders and both webhook paths always have: what
 * is already made comes off settings.storefront.stockQty, and only the rest is
 * printed. An order the shelf covers whole is a sale, recorded completed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/shelf-sale.js');
require('../lib/store-order-job.js');

const DRAGON = { id: 'P1', nameEn: 'Flexi dragon', price: 40, parts: [{ name: 'Dragon', printWeight: 30, printTime: 2, qty: 1, baseCost: 10 }] };
const CLOUD = { url: 'http://x', shopId: 'S', token: 't' };

function stub(stockQty) {
  global.window = global.window || {};
  global.window.hubAPI = { cloudIntakeDelete: async () => ({ ok: true }) };
  Object.assign(global, {
    printLog: [], clients: [], products: [DRAGON], inventory: [], consumables: [],
    settings: { storefront: { stockQty: { ...stockQty }, stockCountedAt: { P1: '2026-11-01T00:00:00.000Z' } } },
    saveAll() {}, toast() {}, switchTab() {},
    t: (k, v) => k + (v ? JSON.stringify(v) : ''), uid: (p) => `${p}-1`, localDateStr: () => '2026-11-05', nextQuoteSeq: () => '0001',
  });
}
const order = (n) => ({ id: 'IN9', payload: { title: 'Web order', name: 'Sara', contact: 'sara@example.com', description: `- Flexi dragon × ${n}` } });

test('an order the shelf covers whole is a sale: completed from stock, the count goes down and is re-dated', async () => {
  stub({ P1: 5 });
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote(order(3), CLOUD), true);
  const o = global.printLog[0];
  assert.equal(o.status, 'completed');
  assert.equal(o.fromStock, true);
  assert.ok(o.completedAt);
  assert.equal(o.shelfTaken, 3);
  assert.equal(global.settings.storefront.stockQty.P1, 2);
  assert.notEqual(global.settings.storefront.stockCountedAt.P1, '2026-11-01T00:00:00.000Z');
  // its parts are what the sale cost: every piece
  assert.equal(o.parts.reduce((s, p) => s + (+p.qty || 0), 0), 3);
});

test('a mixed order takes what the shelf holds and prints only the rest', async () => {
  stub({ P1: 2 });
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote(order(5), CLOUD), true);
  const o = global.printLog[0];
  assert.notEqual(o.status, 'completed');
  assert.equal(o.shelfTaken, 2);
  assert.equal(global.settings.storefront.stockQty.P1, 0);
  assert.equal(o.parts.reduce((s, p) => s + (+p.qty || 0), 0), 3, 'parts for the three to print, not all five');
  assert.match(o.notes, /2 off the shelf, 3 to print/);
});

test('a product the shop does not count is never deducted', async () => {
  stub({});
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote(order(2), CLOUD), true);
  const o = global.printLog[0];
  assert.equal(o.status, 'quote');
  assert.equal(o.shelfTaken, undefined);
  assert.deepEqual(global.settings.storefront.stockQty, {});
});
