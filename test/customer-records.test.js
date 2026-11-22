'use strict';
/**
 * Customer records: the plaintext copy a shop's storefront may read, built
 * from the book only when the shop turns it on (khayt-cloud "Customer records").
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const CR = require('../lib/customer-records.js');

const clients = [
  { id: 'c1', nameEn: 'Noura', email: ' Noura@Example.com ', phone: '+966500000001' },
  { id: 'c2', nameAr: 'ريم', email: '' },
  { id: 'c3', nameEn: 'Copy of Noura', email: 'noura@example.com' },
  { id: 'c4', nameEn: 'Sami', email: 'sami@example.com' },
];
const printLog = [
  { id: 'ORD-1', clientId: 'c1', client: 'Noura', date: '2026-10-01', project: 'Vase', status: 'completed',
    shippedAt: '2026-10-03T10:00:00Z', price: 100, currency: 'sar', productId: 'p-vase', qty: 2,
    notes: 'secret', cost: 12 },
  { id: 'ORD-2', clientId: 'c1', date: '2026-10-05', project: 'Quote only', status: 'quote', price: 50 },
  { id: 'ORD-3', clientId: 'c1', date: '2026-10-06', project: 'Lamp', status: 'printing', price: 0 },
  { id: 'ORD-4', client: 'Sami', date: '2026-10-07', project: 'Name only', status: 'pending', price: 10 },
  { id: 'ORD-5', clientId: 'c4', date: '2026-10-08', project: 'Parent', status: 'split', price: 80 },
  { id: 'ORD-6', clientId: 'c4', date: '2026-10-09', project: 'Own', status: 'completed', nonBusiness: true },
];

test('ready: the privacy policy covers the copy, and the shop still turns it on itself', () => {
  assert.equal(CR.READY, true);
  assert.equal(CR.enabled({ customerRecords: { enabled: true } }), true);
  assert.equal(CR.enabled({ customerRecords: { enabled: 'yes' } }), false);
  assert.equal(CR.enabled({}), false, 'off unless the shop turns it on');
  assert.equal(CR.enabled(undefined), false);
});

// khaytapp.com/privacy/#customer-records-en promises exactly these fields. A
// key that is not here is a change to the published policy: tell the website
// lane BEFORE adding it. No addresses: the policy says the Mac sends none.
const POLICY = {
  customer: ['email', 'name', 'phone', 'orders'],
  order: ['orderId', 'ref', 'at', 'title', 'status', 'total', 'currency', 'lines'],
  line: ['productId', 'name', 'qty'],
};

test('the body holds only what the privacy policy names', () => {
  const book = clients.concat([{ id: 'c5', nameEn: 'Huda', email: 'huda@example.com', phone: '1',
    address: 'Riyadh', addresses: [{ line1: 'x' }], notes: 'private', company: 'Co' }]);
  const log = printLog.concat([{ id: 'ORD-7', clientId: 'c5', date: '2026-10-10', project: 'Cup', status: 'completed',
    price: 20, currency: 'SAR', productId: 'p-cup', qty: 1, source: 'salla', sourceOrderId: '99',
    cost: 5, margin: 15, notes: 'n', files: ['a.3mf'], filamentCost: 2, shippingAddress: 'Riyadh' }]);
  const { customers } = CR.build(book, log, { currency: 'SAR' }).body;
  assert.ok(customers.length >= 3);
  let orders = 0, lines = 0;
  for (const c of customers) {
    for (const k of Object.keys(c)) assert.ok(POLICY.customer.includes(k), `customer.${k} is not in the policy`);
    for (const o of c.orders || []) {
      orders++;
      for (const k of Object.keys(o)) assert.ok(POLICY.order.includes(k), `order.${k} is not in the policy`);
      for (const l of o.lines || []) {
        lines++;
        for (const k of Object.keys(l)) assert.ok(POLICY.line.includes(k), `line.${k} is not in the policy`);
      }
    }
    assert.ok(!c.orders || c.orders.length <= 100, 'the newest 100 orders at most');
  }
  assert.ok(orders >= 3 && lines >= 2, 'the sample reaches orders and lines');
  assert.ok(customers.some((c) => c.orders && c.orders.some((o) => o.ref)), 'the sample reaches a web store ref');
});

test('only customers with an email, lower-cased, first in the book wins a shared email', () => {
  const r = CR.build(clients, printLog, { currency: 'SAR' });
  assert.deepEqual(r.body.customers.map((c) => c.email), ['noura@example.com', 'sami@example.com']);
  assert.equal(r.withoutEmail, 1);
  assert.equal(r.sharedEmail, 1);
  assert.equal(r.body.customers[0].name, 'Noura');
});

test('orders are linked by clientId only, newest first, never quotes, split parents or own prints', () => {
  const [noura, sami] = CR.build(clients, printLog, {}).body.customers;
  assert.deepEqual(noura.orders.map((o) => o.orderId), ['ORD-3', 'ORD-1']);
  assert.equal(sami.orders, undefined, 'a job named "Sami" with no clientId is not his');
});

test('an order carries what a storefront shows, and nothing the shop keeps to itself', () => {
  const o = CR.build(clients, printLog, {}).body.customers[0].orders[1];
  assert.deepEqual(o, {
    orderId: 'ORD-1', at: '2026-10-01', title: 'Vase', status: 'shipped',
    total: 100, currency: 'SAR', lines: [{ productId: 'p-vase', name: 'Vase', qty: 2 }],
  });
  const unpriced = CR.build(clients, printLog, {}).body.customers[0].orders[0];
  assert.equal(unpriced.total, undefined, 'no price is not a total of 0');
  assert.equal(unpriced.status, 'printing');
});

test('the total is what the customer pays: tax added on top is included', () => {
  const settings = { tax: { mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  const o = CR.build(clients, printLog, settings).body.customers[0].orders[1];
  assert.equal(o.total, 115);
});

test('next: put when changed or a day old, delete once after turning off', () => {
  const now = '2026-10-18T12:00:00Z';
  assert.equal(CR.next(true, 'a', null, now), 'put');
  assert.equal(CR.next(true, 'a', { fingerprint: 'a', at: '2026-10-18T01:00:00Z' }, now), 'none');
  assert.equal(CR.next(true, 'b', { fingerprint: 'a', at: '2026-10-18T01:00:00Z' }, now), 'put');
  assert.equal(CR.next(true, 'a', { fingerprint: 'a', at: '2026-10-17T11:00:00Z' }, now), 'put');
  assert.equal(CR.next(false, 'a', { fingerprint: 'a', at: now }, now), 'delete');
  assert.equal(CR.next(false, 'a', null, now), 'none');
});

test("a web-store order's ref is spelt exactly as order-status sends it; a shop order has none", () => {
  const W = require('../lib/webstore-order.js');
  const web = { id: 'ORD-9', clientId: 'c1', date: '2026-10-10', project: 'Web vase', status: 'printing',
    source: 'medusa', sourceOrderId: '#1042', price: 20 };
  const [noura] = CR.build(clients, [web, printLog[0]], {}).body.customers;
  const byId = Object.fromEntries(noura.orders.map((o) => [o.orderId, o]));
  assert.equal(byId['ORD-9'].ref, W.statusFor(web).ref);
  assert.equal(byId['ORD-9'].ref, 'medusa:#1042');
  assert.equal('ref' in byId['ORD-1'], false);
});

test('a quantity is sent whole, 1 to 100,000, as the cloud keeps it', () => {
  const mk = (qty) => CR.build([clients[0]], [{ id: 'q', clientId: 'c1', date: '2026-10-01', status: 'pending',
    productId: 'p', qty }], {}).body.customers[0].orders[0].lines[0].qty;
  assert.equal(mk(2.6), 3);
  assert.equal(mk(0.2), 1);
  assert.equal(mk(500000), 100000);
  assert.equal(mk(undefined), 1);
});

test('over 4 MB, the oldest orders go first, then customers from the end, and it says how many', () => {
  const many = [];
  for (let i = 0; i < 3; i++) {
    many.push({ email: `c${i}@x.co`, orders: Array.from({ length: 100 }, (_, k) =>
      ({ orderId: `o${i}-${k}`, at: '2026-10-01', title: 'x'.repeat(200) })) });
  }
  const tiny = CR.utf8Bytes(JSON.stringify({ customers: many })) / 3;
  const left = CR.fit(many, tiny);
  assert.ok(CR.utf8Bytes(JSON.stringify({ customers: many })) <= tiny);
  assert.ok(left.orders > 0);
  assert.equal(left.people, 0, 'trimming orders was enough');
  assert.equal(many[0].orders[0].orderId, 'o0-0', 'the newest order stays');
  assert.equal(CR.utf8Bytes('غ'), 2);
  assert.equal(CR.utf8Bytes('😀'), 4);
});

test('a book that fits is sent untouched', () => {
  const r = CR.build(clients, printLog, {});
  assert.deepEqual(r.trimmed, { orders: 0, people: 0 });
});
