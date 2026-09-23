/**
 * `lib/storefront-webhook.js` — what a signed Salla or Zid order does to the
 * book, by behaviour.
 *
 * The rule was lifted out of `lib/lan-server.js` so the Mac's LAN server can run
 * it. The Node server's wiring over real HTTP is proved by
 * `an-online-order-comes-off-the-shelf.test.js`, which passed unchanged across
 * the lift; this file holds the rule itself to what those handlers did.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/storefront-webhook.js');

const CTX = { id: 'salla-1-ab', day: '2026-09-23', at: '2026-09-23T06:00:00.000Z' };

const book = () => ({
  printLog: [{ id: 'old', project: 'Walk-in', status: 'completed' }],
  products: [
    { id: 'PRD-A', nameEn: 'Flexi Dragon' },
    { id: 'PRD-B', nameEn: 'Falcon hood' },
  ],
  settings: {
    currency: 'SAR',
    storefront: {
      stockQty: { 'PRD-A': 12, 'PRD-B': 4 },
      stockCountedAt: { 'PRD-A': '2026-09-01T00:00:00Z', 'PRD-B': '2026-09-01T00:00:00Z' },
    },
  },
});

const salla = (ref, items) => ({
  event: 'order.created',
  data: {
    reference_id: ref,
    customer: { first_name: 'Nora', last_name: 'A' },
    amounts: { total: { amount: 380, currency: 'SAR' } },
    items,
  },
});

test('an order for nothing on the shelf is pending work, priced, and carries its own id', () => {
  const cur = book();
  const r = W.record('salla', salla('SL-1', [{ name: 'Custom bracket', quantity: 1 }]), cur, CTX);
  assert.equal(r.duplicate, false);
  assert.equal(r.store.printLog.length, 2);
  assert.equal(r.store.printLog[0], r.order, 'the new order goes to the TOP of the log');
  assert.deepEqual(r.order, {
    id: 'salla-1-ab',
    project: 'Salla: Custom bracket',
    client: 'Nora A',
    status: 'pending',
    date: '2026-09-23',
    price: 380,
    notes: r.order.notes,
    source: 'salla',
    sourceOrderId: 'SL-1',
  });
  assert.match(r.order.notes, /SL-1/);
  assert.equal(r.store.settings, cur.settings, 'a basket off nothing on the shelf touched the settings');
  assert.equal(cur.printLog.length, 1, 'the book it was handed was changed in place');
});

test('the same order delivered twice is one order, and the second leaves the book alone', () => {
  const first = W.record('salla', salla('SL-2', [{ name: 'Custom bracket' }]), book(), CTX);
  const again = W.record('salla', salla('SL-2', [{ name: 'Custom bracket' }]), first.store,
    { ...CTX, id: 'salla-2-cd' });
  assert.equal(again.duplicate, true);
  assert.equal(again.order, null);
  assert.equal(again.store, first.store, 'a duplicate must return the book untouched');
  assert.equal(W.alreadyRecorded('salla', salla('SL-2', []), first.store.printLog), true);
  assert.equal(W.alreadyRecorded('salla', salla('SL-3', []), first.store.printLog), false);
});

test('a sale the shelf answers in full comes off it and is already done', () => {
  const r = W.record('salla', salla('SL-4', [{ name: 'Flexi Dragon', quantity: 2 }]), book(), CTX);
  assert.equal(r.store.settings.storefront.stockQty['PRD-A'], 10);
  assert.equal(r.store.settings.storefront.stockCountedAt['PRD-A'], CTX.at,
    'the count moved and the date it was taken did not — or was not the caller\'s moment');
  assert.equal(r.order.status, 'completed');
  assert.equal(r.order.fromStock, true);
  assert.equal(r.order.completedAt, CTX.at);
  assert.deepEqual(r.order.statusHistory, [{ status: 'completed', at: CTX.at }]);
  assert.equal(r.order.shelfTaken, 2);
  assert.match(r.order.notes, /2 off the shelf$/);
});

test('a sale the shelf answers in part still has work in it', () => {
  const r = W.record('salla', salla('SL-5', [{ name: 'Falcon hood', quantity: 6 }]), book(), CTX);
  assert.equal(r.store.settings.storefront.stockQty['PRD-B'], 0);
  assert.equal(r.order.status, 'pending');
  assert.equal(r.order.fromStock, undefined);
  assert.match(r.order.notes, /4 off the shelf, 2 to print$/);
});

test('an order the platform sent no id for is recorded without one, not with an empty one', () => {
  const r = W.record('salla', { data: { amounts: { total: { amount: 5 } } } }, book(), CTX);
  assert.equal('sourceOrderId' in r.order, false);
  assert.equal(r.order.price, 5);
});

test('Zid is recorded the same way, under its own name', () => {
  const r = W.record('zid', { order: { reference_id: 'ZD-9', id: 9, total: 120 } },
    book(), { ...CTX, id: 'zid-1' });
  assert.equal(r.order.source, 'zid');
  assert.equal(r.order.sourceOrderId, 'ZD-9');
  assert.match(r.order.project, /^Zid: /);
});

test('a storefront this does not answer for is refused, not guessed at', () => {
  assert.throws(() => W.record('shopify', {}, book(), CTX), /not a storefront/);
});

test('the module reaches its two dependencies without require, as JavaScriptCore loads it', () => {
  // The Mac evaluates lib/ modules as scripts, in order, with no `require`. A
  // module that only found its dependencies through require would load there
  // and then throw on the first order.
  const fs = require('node:fs');
  const vm = require('node:vm');
  const path = require('node:path');
  const ctx = { console };
  vm.createContext(ctx);
  for (const m of ['storefront-orders', 'shelf-sale', 'storefront-webhook']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', `${m}.js`), 'utf8'), ctx);
  }
  const r = vm.runInContext(
    `KhaytStorefrontWebhook.record('salla', ${JSON.stringify(salla('SL-6', [{ name: 'Flexi Dragon' }]))},
       ${JSON.stringify(book())}, ${JSON.stringify(CTX)})`, ctx);
  assert.equal(r.order.shelfTaken, 1);
});
