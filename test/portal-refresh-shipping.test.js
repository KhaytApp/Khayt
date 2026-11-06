/**
 * The customer's order page shows shipping (Cloud #186): `payloadFor` carries
 * `payload.shipping = { carrier, status, trackingNumber, trackingUrl }` for an
 * ORDER, built from `KhaytCarriers.projectShipping`. The payload is public, so
 * each field is capped or filtered, and a field the order lacks is left out.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const Portal = require('../lib/portal-refresh.js');
const Carriers = require('../lib/carriers.js');

const shipped = {
  id: 'INV-1', status: 'completed', date: '2026-11-05', price: 0,
  carrier: 'smsa', trackingNumber: 'SMSA123', shippingStatus: 'in_transit',
  shippingHistory: [{ status: 'label_created', at: '2026-11-05T08:00:00Z' }],
};
const ship = (order, ctx) => Portal.payloadFor(order, ctx || { settings: { lang: 'en' } }).payload.shipping;

test('a shipped order carries all four fields, and no history', () => {
  const s = ship(shipped);
  assert.deepEqual(s, {
    carrier: 'SMSA Express',
    status: 'in_transit',
    trackingNumber: 'SMSA123',
    trackingUrl: 'https://www.smsaexpress.com/trackingdetails?tracknumbers=SMSA123',
  });
  assert.equal('history' in s, false);
});

test('the carrier is named in the customer\'s language', () => {
  // The shop reads Arabic and the customer is written down only in Arabic.
  const ar = Portal.payloadFor({ ...shipped, clientId: 'c1' },
    { settings: { lang: 'ar' }, clients: [{ id: 'c1', nameAr: 'سارة' }] }).payload.shipping;
  assert.equal(ar.carrier, 'سمسا إكسبريس');
  // The customer asked for English, in an Arabic shop.
  const en = Portal.payloadFor({ ...shipped, clientId: 'c1' },
    { settings: { lang: 'ar' }, clients: [{ id: 'c1', messageLang: 'en' }] }).payload.shipping;
  assert.equal(en.carrier, 'SMSA Express');
});

test('caps: the carrier at 60 characters, the tracking number at 100', () => {
  const was = Carriers.CARRIERS.smsa.label;
  Carriers.CARRIERS.smsa.label = { en: 'C'.repeat(80), ar: 'ع'.repeat(80) };
  try {
    assert.equal(ship(shipped).carrier, 'C'.repeat(60));
  } finally {
    Carriers.CARRIERS.smsa.label = was;
  }
  const long = ship({ ...shipped, carrier: 'aramex', trackingNumber: '9'.repeat(150) });
  assert.equal(long.trackingNumber, '9'.repeat(100));
});

test('status: only the five the card draws; anything else is left out', () => {
  for (const st of ['label_created', 'in_transit', 'out_for_delivery', 'delivered', 'exception']) {
    assert.equal(ship({ ...shipped, shippingStatus: st }).status, st);
  }
  for (const st of ['unshipped', 'lost', '<b>x</b>', 42]) {
    const s = ship({ ...shipped, shippingStatus: st });
    assert.equal('status' in s, false, `status ${st} must not reach the page`);
    assert.equal(s.trackingNumber, 'SMSA123', 'the rest still shows');
  }
});

test('a tracking link that is not https is dropped', () => {
  const was = Carriers.CARRIERS.spl.trackingUrl;
  try {
    for (const bad of ['http://track.example/1', 'javascript:alert(1)', '//track.example/1', '']) {
      Carriers.CARRIERS.spl.trackingUrl = () => bad;
      const s = ship({ ...shipped, carrier: 'spl' });
      assert.equal('trackingUrl' in s, false, `${bad} must not reach the page`);
      assert.equal(s.trackingNumber, 'SMSA123');
    }
  } finally {
    Carriers.CARRIERS.spl.trackingUrl = was;
  }
});

test('a field the order does not have is left out, never null', () => {
  // A status and nothing else: no carrier, no number, so no link either.
  const onlyStatus = ship({ id: 'J', status: 'completed', shippingStatus: 'delivered' });
  assert.deepEqual(onlyStatus, { status: 'delivered' });
  // A number typed by hand with no carrier: no carrier name, no link.
  const onlyNumber = ship({ id: 'J', status: 'completed', trackingNumber: 'X1' });
  assert.deepEqual(onlyNumber, { trackingNumber: 'X1' });
  for (const s of [onlyStatus, onlyNumber]) {
    for (const v of Object.values(s)) assert.notEqual(v, null);
  }
});

test('no shipping when projectShipping returns null', () => {
  const plain = { id: 'J', status: 'printing', carrier: 'smsa' };
  assert.equal(Carriers.projectShipping(plain), null);
  assert.equal('shipping' in Portal.payloadFor(plain, { settings: {} }).payload, false);
});

test('a quote never carries a shipping card', () => {
  const p = Portal.payloadFor({ ...shipped, status: 'quote' }, { settings: {} }).payload;
  assert.equal('shipping' in p, false);
});

test('without shipping, today\'s payload is unchanged', () => {
  const order = { id: 'J9', status: 'printing', date: '2026-11-01', dueDate: '2026-11-08' };
  const p = Portal.payloadFor(order, { settings: {}, shopName: 'Shop' }).payload;
  assert.deepEqual(Object.keys(p), [
    'shopName', 'ref', 'status', 'statusLabel', 'eta', 'issueDate', 'invoiceNo', 'seller', 'paid',
    'stages', 'stage',
  ]);
  assert.deepEqual(p, {
    shopName: 'Shop', ref: 'J9', status: 'printing', statusLabel: 'Printing', eta: '2026-11-08',
    issueDate: '2026-11-01', invoiceNo: 'J9', seller: { name: 'Shop', vat: '', address: '' }, paid: false,
    stages: ['Received', 'Printing', 'Finishing', 'Done', 'Ready for pickup'], stage: 1,
  });
});
