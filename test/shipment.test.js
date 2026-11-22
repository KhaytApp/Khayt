/**
 * `lib/shipment.js` — the Ship dialog's rules, lifted out of the renderer so
 * the Mac's Ship sheet runs the same ones.
 *
 * Held to the ORIGINAL: the dialog's code as it stood before the lift is
 * reproduced below verbatim (with its clock injected), and every case is run
 * through both. A difference here is the lift changing what a shop's book
 * holds, which is the one thing it must not do.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/carriers.js');
const OS = require('../lib/order-status.js');
const S = require('../lib/shipment.js');

const AT = '2026-09-23T10:00:00.000Z';

/* ── the dialog before the lift, verbatim bar the clock ─────────────────── */
function origPush(order, status, source, note) {
  if (!Array.isArray(order.shippingHistory)) order.shippingHistory = [];
  order.shippingHistory.push({ status, at: AT, source: source || 'manual', note: note || '' });
  if (order.shippingHistory.length > 100) order.shippingHistory = order.shippingHistory.slice(-100);
}
function origApply(order, next, source) {
  const advanced = C.advanceShippingStatus(order.shippingStatus, next);
  if (advanced === order.shippingStatus) return false;
  order.shippingStatus = advanced;
  origPush(order, advanced, source);
  OS.stampFromShipping(order, advanced, AT);
  return true;
}
function origCreate(order, carrierId, service, trackingNumber, source, labelUrl, meta) {
  const carrier = C.getCarrier(carrierId);
  order.carrier = carrierId;
  order.trackingNumber = trackingNumber || null;
  order.shippingService = service;
  order.labelUrl = labelUrl;
  order.shipmentMeta = meta;
  order.shippedAt = AT;
  order.shippingStatus = 'label_created';
  order.courierName = carrier ? ((carrier.label && carrier.label.en) || carrierId) : carrierId;
  origPush(order, 'label_created', source);
}
function origUpdate(order, next, typedTn) {
  if (typedTn) order.trackingNumber = typedTn;
  if (next) origApply(order, next, 'manual');
}

const job = (extra) => ({ id: 'J-1', status: 'completed', price: 100, ...extra });
const clone = (o) => JSON.parse(JSON.stringify(o));

test('creating a shipment writes exactly what the dialog wrote', () => {
  const cases = [
    ['smsa', 'dom_exp', 'SM123', 'manual', null, null],
    ['aramex', 'intl', 'AX9', 'api', 'https://label', { ref: 1 }],
    ['manual', null, '', 'manual', null, null],
    ['spl', 'domestic', 'SPL1', 'manual', null, null],
  ];
  for (const [carrier, service, tn, source, labelUrl, meta] of cases) {
    const a = job(); const b = job();
    origCreate(a, carrier, service, tn, source, labelUrl, meta);
    S.create(b, { carrier, service, trackingNumber: tn, source, labelUrl, meta }, AT);
    assert.deepEqual(b, a, `${carrier}: the lift wrote something different`);
  }
});

test('a tracking number is trimmed, and blank is null, not empty', () => {
  const o = job();
  S.create(o, { carrier: 'smsa', trackingNumber: '  SM5  ' }, AT);
  assert.equal(o.trackingNumber, 'SM5');
  const p = job();
  S.create(p, { carrier: 'smsa', trackingNumber: '   ' }, AT);
  assert.equal(p.trackingNumber, null);
});

test('updating a shipment moves it exactly as the dialog did', () => {
  const base = job();
  origCreate(base, 'smsa', 'dom_exp', 'SM1', 'manual', null, null);
  const steps = [
    ['in_transit', ''], ['out_for_delivery', 'SM1-B'], ['in_transit', ''],   // backwards: ignored
    ['delivered', ''], ['exception', ''], ['label_created', ''],
  ];
  const a = clone(base); const b = clone(base);
  for (const [status, tn] of steps) {
    origUpdate(a, status, tn);
    S.update(b, { status, trackingNumber: tn }, AT);
    assert.deepEqual(b, a, `after ${status}: the lift moved differently`);
  }
});

test('update says whether anything changed', () => {
  const o = job();
  S.create(o, { carrier: 'smsa', trackingNumber: 'SM1' }, AT);
  assert.equal(S.update(o, { status: 'label_created', trackingNumber: 'SM1' }, AT), false);
  assert.equal(S.update(o, { status: 'in_transit' }, AT), true);
  assert.equal(S.update(o, { trackingNumber: 'SM2' }, AT), true);
});

test('delivered stamps both dates, and the job stays completed', () => {
  const o = job();
  S.create(o, { carrier: 'smsa' }, AT);
  delete o.shippedAt;
  S.advance(o, 'delivered', 'manual', AT);
  assert.equal(o.status, 'completed');
  assert.equal(o.deliveredAt, AT);
  assert.equal(o.shippedAt, AT);
});

test('the trail is capped, keeping the newest', () => {
  const o = job({ shippingHistory: Array.from({ length: 100 }, (_, i) => ({ status: 'in_transit', at: String(i) })) });
  S.pushHistory(o, 'delivered', 'webhook', AT);
  assert.equal(o.shippingHistory.length, S.HISTORY_MAX);
  assert.equal(o.shippingHistory.at(-1).status, 'delivered');
  assert.equal(o.shippingHistory[0].at, '1');
});

test('the renderer calls the shared rule rather than a copy of it', () => {
  // The Mac and this dialog must not drift apart again. A copy of the field
  // list written back into the dialog would pass every test above.
  const fs = require('node:fs');
  const path = require('node:path');
  const flows = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'order-flows.js'), 'utf8');
  assert.match(flows, /KhaytShipment\.create\(order,/);
  assert.match(flows, /KhaytShipment\.update\(order,/);
  assert.ok(!/order\.shippingStatus = 'label_created'/.test(flows),
    'the dialog writes a shipment by hand again');
  const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
  assert.ok(html.indexOf('lib/shipment.js') > html.indexOf('lib/carriers.js'),
    'shipment.js is not loaded, or loads before the carriers it reads');
  assert.ok(html.indexOf('lib/shipment.js') > html.indexOf('lib/order-status.js'));
});
