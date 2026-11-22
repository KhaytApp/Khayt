const { test } = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/carriers.js');

test('registry exposes manual + the three Saudi carriers', () => {
  assert.deepEqual(Object.keys(C.CARRIERS).sort(), ['aramex', 'manual', 'smsa', 'spl']);
  assert.equal(C.getCarrier('smsa').label.en, 'SMSA Express');
  assert.equal(C.getCarrier('nope'), null);
});

test('advanceShippingStatus never regresses; exception always wins; delivered is terminal', () => {
  assert.equal(C.advanceShippingStatus('unshipped', 'in_transit'), 'in_transit');
  assert.equal(C.advanceShippingStatus('in_transit', 'label_created'), 'in_transit', 'no regress');
  assert.equal(C.advanceShippingStatus('delivered', 'in_transit'), 'delivered', 'delivered terminal');
  assert.equal(C.advanceShippingStatus('in_transit', 'exception'), 'exception');
  assert.equal(C.advanceShippingStatus('label_created', 'bogus'), 'label_created', 'unknown ignored');
  assert.equal(C.advanceShippingStatus(null, 'label_created'), 'label_created');
});

test('normalizeGeneric maps carrier phrasings, order-sensitive for out-for-delivery', () => {
  assert.equal(C.normalizeGeneric('Out for delivery'), 'out_for_delivery');
  assert.equal(C.normalizeGeneric('Shipment delivered'), 'delivered');
  assert.equal(C.normalizeGeneric('In Transit - Departed hub'), 'in_transit');
  assert.equal(C.normalizeGeneric('Label created'), 'label_created');
  assert.equal(C.normalizeGeneric('Returned to origin (RTO)'), 'exception');
  assert.equal(C.normalizeGeneric(''), null);
  assert.equal(C.normalizeGeneric('gibberish zzz'), null);
});

test('parseGenericWebhook tolerates varied field names', () => {
  assert.deepEqual(
    C.parseGenericWebhook({ awb: 'ABC1', status: 'in transit', at: '2026-07-19' }, C.normalizeGeneric),
    { trackingNumber: 'ABC1', shippingStatus: 'in_transit', at: '2026-07-19' });
  assert.deepEqual(
    C.parseGenericWebhook({ waybill: 'X9', event_code: 'DELIVERED' }, C.normalizeGeneric),
    { trackingNumber: 'X9', shippingStatus: 'delivered', at: null });
  assert.equal(C.parseGenericWebhook({ status: 'delivered' }, C.normalizeGeneric), null, 'no tracking number → null');
  assert.equal(C.parseGenericWebhook({ awb: 'X' }, C.normalizeGeneric), null, 'no status → null');
});

test('carrier adapters parse their webhooks via the normalizer', () => {
  const r = C.getCarrier('aramex').parseWebhook({ ShipmentNumber: 'AR1', status: 'Out for delivery' });
  assert.deepEqual(r, { trackingNumber: 'AR1', shippingStatus: 'out_for_delivery', at: null });
});

test('trackingUrl builds carrier deep links with encoded numbers', () => {
  assert.match(C.getCarrier('smsa').trackingUrl('12 34'), /smsaexpress\.com.*12%2034/);
  assert.match(C.getCarrier('aramex').trackingUrl('AR1'), /aramex\.com.*ShipmentNumber=AR1/);
  assert.match(C.getCarrier('spl').trackingUrl('SP1'), /splonline\.com\.sa.*SP1/);
  assert.equal(C.getCarrier('smsa').trackingUrl(''), null);
});

test('manual carrier records the typed number, never throws, no network', async () => {
  const r = await C.getCarrier('manual').createShipment({ id: 'O1' }, {}, { trackingNumber: 'HAND-1', service: 'pickup' });
  assert.deepEqual(r, { trackingNumber: 'HAND-1', labelUrl: null, service: 'pickup', meta: null });
  assert.equal(C.getCarrier('manual').parseWebhook({}), null);
});

test('API carrier createShipment throws when no proxy (caller falls back to manual)', async () => {
  await assert.rejects(() => C.getCarrier('smsa').createShipment({ id: 'O1' }, { apiKey: 'k' }), /carrier_api_unavailable/);
});

test('configuredCarriers = enabled API carriers with creds + Manual always last', () => {
  const list = C.configuredCarriers({ shipping: { smsa: { enabled: true, apiKey: 'k' }, aramex: { enabled: false, apiKey: 'x' } } });
  const ids = list.map(c => c.id);
  assert.deepEqual(ids, ['smsa', 'manual'], 'only enabled+cred carriers, manual appended');
  assert.deepEqual(C.configuredCarriers({}).map(c => c.id), ['manual'], 'manual always available');
});

test('projectShipping exposes only customer-safe fields (never meta/cost)', () => {
  const order = {
    carrier: 'smsa', trackingNumber: 'TN1', shippingStatus: 'in_transit',
    shippingHistory: [{ status: 'label_created', at: '2026-07-18', note: 'internal', source: 'manual' }],
    shipmentMeta: { cost: 25, zone: 'A' },
  };
  const p = C.projectShipping(order);
  assert.equal(p.shippingStatus, 'in_transit');
  assert.equal(p.trackingNumber, 'TN1');
  assert.match(p.trackingUrl, /smsaexpress/);
  assert.equal(p.carrierLabel.en, 'SMSA Express');
  // history projected without note/source; no meta/cost anywhere
  assert.deepEqual(p.history, [{ status: 'label_created', at: '2026-07-18' }]);
  assert.equal(JSON.stringify(p).includes('cost'), false);
  assert.equal(JSON.stringify(p).includes('internal'), false);
  assert.equal(C.projectShipping({}), null, 'nothing to show → null');
});

/**
 * What a carrier actually sends, and what happens when Khayt cannot read it.
 *
 * There is no public documentation for SMSA, Aramex or SPL webhooks — it is
 * partner-gated — so this parser cannot be verified field-for-field the way a
 * printer's or Salla's could. What CAN be fixed without it is how the parser
 * fails: nesting is an ordinary shape, and reading only the top level made a
 * nested payload produce nothing at all.
 */
test('a nested carrier payload is read, not silently dropped', () => {
  const smsa = C.getCarrier('smsa');

  // The shape this used to miss entirely. Both are ordinary carrier envelopes.
  const arrayNested = { Shipments: [{ ShipmentNumber: 'SM123', Status: 'delivered' }] };
  const objectNested = { data: { awb: 'SM123', status: 'delivered' } };
  for (const [label, body] of [['array', arrayNested], ['object', objectNested]]) {
    const evt = smsa.parseWebhook(body, {}, {});
    assert.ok(evt, `${label}-nested payload produced no event`);
    assert.equal(evt.trackingNumber, 'SM123', label);
    assert.equal(evt.shippingStatus, 'delivered', label);
  }

  // Top level still wins and is tried first.
  const top = smsa.parseWebhook({ trackingNumber: 'TOP1', status: 'delivered', data: { awb: 'NESTED', status: 'delivered' } }, {}, {});
  assert.equal(top.trackingNumber, 'TOP1');
});

test('the descent cannot invent an event', () => {
  const smsa = C.getCarrier('smsa');
  // A container is only used if it carries BOTH a tracking number and a status
  // that normalises. Half of one is not an event.
  assert.equal(smsa.parseWebhook({ data: { awb: 'SM1' } }, {}, {}), null, 'no status');
  assert.equal(smsa.parseWebhook({ data: { status: 'delivered' } }, {}, {}), null, 'no tracking number');
  assert.equal(smsa.parseWebhook({ data: { awb: 'SM1', status: 'zzz-unknown' } }, {}, {}), null, 'unknown status');
  assert.equal(smsa.parseWebhook({ meta: { note: 'hello' } }, {}, {}), null, 'unrelated container');
  // One level only — a tracking number buried two deep is not fished out.
  assert.equal(smsa.parseWebhook({ a: { b: { awb: 'SM1', status: 'delivered' } } }, {}, {}), null, 'two levels deep');
});

test('the event timestamp is actually read', () => {
  // `eventTime` was in the fallback chain and could never match: every key is
  // lowercased before lookup, so a camelCase read is always undefined. A dead
  // branch in a fallback chain reads as a handled case and is not one.
  const smsa = C.getCarrier('smsa');
  const evt = smsa.parseWebhook({ awb: 'SM1', status: 'delivered', eventTime: '2026-08-27T10:00:00Z' }, {}, {});
  assert.equal(evt.at, '2026-08-27T10:00:00Z', 'eventTime is read case-insensitively');
  // The other spellings still work.
  assert.equal(smsa.parseWebhook({ awb: 'SM1', status: 'delivered', timestamp: 'T' }, {}, {}).at, 'T');
  assert.equal(smsa.parseWebhook({ awb: 'SM1', status: 'delivered' }, {}, {}).at, null, 'absent stays null');
});
