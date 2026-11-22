'use strict';
/**
 * Connectors on the desktop: the host rules (lib/plugin-host.js) and the
 * main-process transport (lib/main/plugin-send.js), against manifests signed
 * here with a throwaway key passed in place of Khayt's.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const M = require('../lib/plugin-manifest.js');
const H = require('../lib/plugin-host.js');
const S = require('../lib/main/plugin-send.js');
const slack = require('../plugins/samples/slack-notifier.json');

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64');
const KEYS = [{ id: 'test-key', key: raw }];
const sign = (m) => Object.assign({}, m, {
  signature: crypto.sign(null, Buffer.from(M.canonicalJSON(m), 'utf8'), privateKey).toString('base64'),
});

const lamha = sign({
  khayt: { manifest: 1 },
  id: 'sa.lamha.ship',
  name: { en: 'Lamha shipping', ar: 'شحن لمحة' },
  publisher: 'Lamha',
  version: '1.0.0',
  domains: ['api.lamha.sa'],
  secrets: [
    { name: 'apiKey', label: { en: 'API key' }, kind: 'apiKey' },
    { name: 'sign', label: { en: 'Signing key' }, kind: 'signingKey' },
  ],
  fields: [{ key: 'awb', label: { en: 'Air waybill' }, type: 'text', attach: 'order' }],
  actions: [
    { id: 'ship', label: { en: 'Ship with Lamha' }, placement: 'order', kind: 'post',
      url: 'https://api.lamha.sa/v1/shipments', send: ['order.id', 'customer.phone'],
      auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' }, signWith: 'sign',
      response: { fields: { awb: 'shipment.awb' } } },
    { id: 'track', label: { en: 'Track' }, placement: 'order', kind: 'open',
      url: 'https://api.lamha.sa/track/{order.trackingNumber}' },
  ],
  events: [{ event: 'order_shipped', url: 'https://api.lamha.sa/v1/events', send: ['order.id'] }],
  scopes: ['fields.write'],
});

const entryOf = (m, extra) => Object.assign(H.consentedEntry(null, m), extra || {});
const UUID = '0b9a7c5e-1f2d-4c3b-9a8e-7d6c5b4a3f21';
const DLV = 'dlv_' + UUID;

test('the test manifests are valid', () => {
  assert.deepEqual(M.validateManifest(lamha).errors, []);
  assert.equal(M.checkEntry(entryOf(lamha)).ok, true);
});

// ── reviewed ───────────────────────────────────────────────────────────────

test('only a manifest signed by a Khayt key is reviewed', () => {
  assert.equal(S.reviewedBy(lamha, KEYS), 'test-key');
  assert.equal(S.reviewedBy(lamha), null, 'not by the real Khayt key');
  assert.equal(S.reviewedBy(Object.assign({}, lamha, { version: '1.0.1' }), KEYS), null, 'any change breaks it');
  assert.equal(S.reviewedBy(slack, KEYS), null, 'unsigned');
  assert.equal(S.checkInstall(slack, KEYS).error, 'unreviewed');
  assert.equal(S.checkInstall({ id: 'x' }, KEYS).error, 'invalid');
  assert.equal(S.checkInstall(lamha, KEYS).ok, true);
});

// ── host rules ─────────────────────────────────────────────────────────────

test('installing grants exactly what was shown, and keeps settings and keys on reinstall', () => {
  const e = H.consentedEntry(null, lamha);
  assert.deepEqual(e.granted, M.grantFor(lamha));
  assert.equal(e.enabled, true);
  const again = H.consentedEntry(Object.assign({}, e, { enabled: false, config: { a: 1 }, secrets: { apiKey: 'k' } }), lamha);
  assert.deepEqual([again.enabled, again.config, again.secrets], [false, { a: 1 }, { apiKey: 'k' }]);
});

test('an update that asks for more is paused until the shop agrees again', () => {
  const e = H.consentedEntry(null, lamha);
  const wider = sign(Object.assign({}, lamha, { version: '1.1.0', domains: ['api.lamha.sa', 'hooks.lamha.sa'],
    events: [{ event: 'order_created', url: 'https://hooks.lamha.sa/new', send: ['customer.email'] }] }));
  const updated = H.updatedEntry(e, wider);
  assert.equal(H.stateOf(updated, true), 'paused');
  assert.equal(H.stateOf(H.consentedEntry(updated, wider), true), 'on');
});

test('state: unreviewed never runs; off is off; a damaged entry is invalid', () => {
  const e = entryOf(lamha);
  assert.equal(H.stateOf(e, true), 'on');
  assert.equal(H.stateOf(e, false), 'unreviewed');
  assert.equal(H.stateOf(Object.assign({}, e, { enabled: false }), true), 'off');
  assert.equal(H.stateOf(Object.assign({}, e, { id: 'other.id' }), true), 'invalid');
  const settings = { plugins: [e] };
  assert.equal(H.actionsFor(settings, 'order', () => false).length, 0);
  assert.deepEqual(H.actionsFor(settings, 'order', () => true).map((a) => a.action.id), ['ship', 'track']);
  assert.deepEqual(H.eventTargets(settings, 'order_shipped', () => true).map((t) => t.entry.id), ['sa.lamha.ship']);
  assert.deepEqual(H.eventTargets(settings, 'low_stock', () => true), [], 'not a connector event');
});

test('plugin fields: only declared keys, coerced, and an empty value removes the key', () => {
  const e = entryOf(lamha);
  let rec = H.withFieldValues({ id: 'O1' }, e, 'order', { awb: '  AWB1 ', other: 'x' });
  assert.deepEqual(rec.plugins, { 'sa.lamha.ship': { awb: '  AWB1 ' } });
  rec = H.withFieldValues(rec, e, 'order', { awb: '' });
  assert.equal(rec.plugins, undefined);
  assert.equal(H.withFieldValues({ id: 'C1' }, e, 'customer', { awb: 'x' }).plugins, undefined, 'not a customer field');
  assert.deepEqual(H.fieldsFor({ plugins: [Object.assign({}, e, { enabled: false })] }, 'order', () => true).map((f) => f.editable), [false]);
});

test('a delivery id is dlv_ + a lowercase UUID, minted by the caller', () => {
  assert.equal(H.deliveryId(() => UUID.toUpperCase()), DLV);
  assert.match(H.deliveryId(() => crypto.randomUUID()), S.DELIVERY_RE);
});

// ── the send ───────────────────────────────────────────────────────────────

function fakePost(reply) {
  const calls = [];
  const fn = async (url, opts) => { calls.push({ url, ...opts }); return reply || { ok: true, status: 200, text: '{}' }; };
  fn.calls = calls;
  return fn;
}
const records = { order: { id: 'ORD-9', trackingNumber: 'TN 1' }, customer: { id: 'C1', phone: '+966500000000' } };

test('a POST sends payloadFor\'s body byte for byte, with the contract headers', async () => {
  const post = fakePost({ ok: true, status: 200, text: '{"shipment":{"awb":"AWB-77"}}' });
  const e = entryOf(lamha, { secrets: { apiKey: 'key-1', sign: 'sign-1' } });
  const r = await S.send({ entry: e, trigger: { action: 'ship' }, records, delivery: DLV }, { keys: KEYS, postPinned: post, now: () => 1_700_000_000_000 });
  assert.equal(r.ok, true);
  assert.deepEqual(r.reply, { shipment: { awb: 'AWB-77' } });
  const c = post.calls[0];
  const P = require('../lib/plugin-payload.js');
  const expected = P.payloadFor(lamha, { action: 'ship' }, { ...records, secrets: e.secrets });
  assert.equal(c.body, expected.body, 'the canonical string, not re-encoded or wrapped');
  assert.equal(c.url, 'https://api.lamha.sa/v1/shipments');
  assert.equal(c.timeoutMs, 15000);
  assert.equal(c.maxBytes, 65536);
  assert.equal(c.headers['X-Khayt-Event'], 'ship');
  assert.equal(c.headers['X-Khayt-Delivery'], DLV);
  assert.equal(c.headers.Authorization, 'Bearer key-1');
  const hmac = (s) => crypto.createHmac('sha256', 'sign-1').update(s).digest('hex');
  assert.equal(c.headers['X-Khayt-Signature'], hmac(c.body), 'bare hex, no sha256= prefix');
  assert.equal(c.headers['X-Khayt-Timestamp'], '1700000000');
  assert.equal(c.headers['X-Khayt-Signature-V2'], hmac('1700000000.' + c.body));
});

test('no signWith, no signature headers; an event sends its own name', async () => {
  const post = fakePost();
  await S.send({ entry: entryOf(lamha), trigger: { event: 'order_shipped' }, records, delivery: DLV }, { keys: KEYS, postPinned: post });
  const h = post.calls[0].headers;
  assert.equal(h['X-Khayt-Event'], 'order_shipped');
  assert.equal(h['X-Khayt-Signature'], undefined);
  assert.equal(h.Authorization, undefined);
});

test('an "open" button returns its URL and posts nothing', async () => {
  const post = fakePost();
  const r = await S.send({ entry: entryOf(lamha), trigger: { action: 'track' }, records }, { keys: KEYS, postPinned: post });
  assert.deepEqual(r, { ok: true, method: 'OPEN', url: 'https://api.lamha.sa/track/TN%201' });
  assert.equal(post.calls.length, 0);
});

test('nothing is sent when it may not be', async () => {
  const post = fakePost();
  const go = (entry, extra) => S.send(Object.assign({ entry, trigger: { action: 'ship' }, records, delivery: DLV }, extra), { keys: KEYS, postPinned: post });
  const keyed = { secrets: { apiKey: 'k', sign: 's' } };
  assert.equal((await go(undefined)).refused, 'not installed');
  assert.equal((await go(entryOf(lamha, keyed), {})).ok, true);
  post.calls.length = 0;
  assert.equal((await S.send({ entry: entryOf(lamha, keyed), trigger: { action: 'ship' }, records, delivery: DLV }, { postPinned: post })).refused, 'unreviewed');
  assert.equal((await go(entryOf(lamha, Object.assign({ enabled: false }, keyed)))).refused, 'off');
  assert.equal((await go(entryOf(lamha, Object.assign({ granted: { version: '1.0.0', fields: [], domains: [], scopes: [] } }, keyed)))).refused, 'paused');
  assert.match((await go(entryOf(lamha, { secrets: { sign: 's' } }))).refused, /apiKey/);
  assert.match((await go(entryOf(lamha, { secrets: { apiKey: 'k' } }))).refused, /sign/);
  assert.equal((await go(entryOf(lamha, keyed), { delivery: 'dlv_ORD-9' })).refused, 'delivery id', 'never derived from the order');
  assert.equal((await go(entryOf(lamha, { secrets: { apiKey: 'k\r\nX-Evil: 1', sign: 's' } }))).refused, 'auth header');
  assert.equal(post.calls.length, 0);
});

test('a reply that is not a JSON object, or too long to read whole, fills nothing', async () => {
  const keyed = entryOf(lamha, { secrets: { apiKey: 'k', sign: 's' } });
  for (const reply of [
    { ok: true, status: 200, text: '[1,2]' },
    { ok: true, status: 200, text: 'not json' },
    { ok: true, status: 200, text: '{"a":1', truncated: true },
    { ok: false, status: 500, text: '{"a":1}' },
  ]) {
    const r = await S.send({ entry: keyed, trigger: { action: 'ship' }, records, delivery: DLV }, { keys: KEYS, postPinned: fakePost(reply) });
    assert.equal(r.reply, null, JSON.stringify(reply));
  }
});

test('the secret in a Slack-style URL path reaches only the declared host', async () => {
  const signedSlack = sign(slack);
  const post = fakePost();
  const e = entryOf(signedSlack, { secrets: { webhookPath: 'T000/B000/xyz' } });
  const r = await S.send({ entry: e, trigger: { event: 'order_created' }, records: { order: { id: 'O1', invoiceNumber: 'INV-1' } }, delivery: DLV }, { keys: KEYS, postPinned: post });
  assert.equal(r.ok, true);
  assert.equal(post.calls[0].url, 'https://hooks.slack.com/services/T000/B000/xyz');
  const traversal = entryOf(signedSlack, { secrets: { webhookPath: '../../evil' } });
  assert.equal((await S.send({ entry: traversal, trigger: { event: 'order_created' }, records, delivery: DLV }, { keys: KEYS, postPinned: post })).ok, false);
});

// ── the Lamha showcase, as Khayt ships it ──────────────────────────────────
// The sample in plugins/samples is signed with Khayt's own key, so this runs
// against lib/plugin-manifest.js SIGNING_KEYS, not the throwaway one. It
// mirrors test/plugin-manifest.test.js "Lamha: the request is Lamha's
// create-order shape…" through the desktop's transport.

test('Lamha sample: installs, sends Lamha\'s create-order body as it is, and fills lamhaOrderId', async () => {
  const P = require('../lib/plugin-payload.js');
  const sample = require('../plugins/samples/lamha-shipping.json');
  assert.equal(S.checkInstall(sample).ok, true, 'the shipped sample verifies against Khayt\'s keys');
  assert.equal(S.checkInstall(Object.assign({}, sample, { version: '1.0.1' })).error, 'unreviewed');

  const customer = { id: 'c9', nameEn: 'Sara A.', phone: '+966500000000', email: 's@example.com',
    addresses: [{ label: 'Home', address: 'King Fahd Rd' }], plugins: { [sample.id]: { city: 'Riyadh' } } };
  const order = { id: 'INV-2026-0107-ab12', invoiceNumber: 'INV-2026-0107', date: '2026-11-08', project: 'Bracket set',
    price: 115.5, currency: 'SAR', qty: 2 };
  const config = { senderName: 'Athar Tuwaiq', senderPhone: '+966511111111', senderCity: 'Riyadh',
    senderAddress: 'Tuwaiq St', carrierId: '7' };
  const entry = Object.assign(H.consentedEntry(null, sample), { config, secrets: { apiToken: 'lamha-tok' } });
  assert.equal(H.stateOf(entry, true), 'on');
  const press = H.actionsFor({ plugins: [entry] }, 'order', () => true).map((a) => a.action.id);
  assert.deepEqual(press, ['record']);

  const post = fakePost({ ok: true, status: 200, text: JSON.stringify({ success: true, order_id: 48213 }) });
  const r = await S.send({ entry, trigger: { action: 'record' }, records: { order, customer }, delivery: DLV }, { postPinned: post });
  assert.equal(r.ok, true);
  const call = post.calls[0];
  assert.equal(call.url, 'https://app.lamha.sa/api/v2/create-order');
  // Lamha's own header, the token bare; no Khayt signature (no signWith).
  assert.equal(call.headers['X-LAMHA-TOKEN'], 'lamha-tok');
  assert.equal(call.headers['X-Khayt-Event'], 'record');
  assert.equal(call.headers['X-Khayt-Delivery'], DLV);
  assert.ok(!('X-Khayt-Signature' in call.headers) && !('Authorization' in call.headers));
  // The body is payloadFor's string, byte for byte.
  const expected = P.payloadFor(sample, { action: 'record' }, { order, customer, config, secrets: entry.secrets });
  assert.equal(call.body, expected.body);
  const body = JSON.parse(call.body);
  assert.equal(body.create_shippment, false, 'the sample must never book a shipment');
  assert.equal(body.order_id, 'INV-2026-0107');
  assert.deepEqual(body.shipper, { name: 'Athar Tuwaiq', phone: '+966511111111', Country: 'SA', City: 'Riyadh', AddressLine1: 'Tuwaiq St' });

  // The reply fills the job's own field, as the window does with it.
  const values = P.applyResponse(sample, 'record', r.reply, entry);
  assert.deepEqual(values, { lamhaOrderId: '48213' });
  const job = H.withFieldValues(order, entry, 'order', values);
  assert.equal(job.plugins[sample.id].lamhaOrderId, '48213');

  // Each required setting left empty: nothing is sent, and the refusal names it.
  for (const key of Object.keys(config)) {
    const partial = Object.assign({}, config); delete partial[key];
    const p2 = fakePost();
    const no = await S.send({ entry: Object.assign({}, entry, { config: partial }), trigger: { action: 'record' }, records: { order, customer }, delivery: DLV }, { postPinned: p2 });
    assert.deepEqual([no.ok, no.refused, p2.calls.length], [false, `setting ${key} is not set`, 0]);
  }
  // No token on this device: nothing is sent.
  const p3 = fakePost();
  const noKey = await S.send({ entry: Object.assign({}, entry, { secrets: {} }), trigger: { action: 'record' }, records: { order, customer }, delivery: DLV }, { postPinned: p3 });
  assert.deepEqual([noKey.refused, p3.calls.length], ['secret "apiToken" is not set', 0]);
});

// SMSA's header name and body come from the community client
// haniusif/smsaexpress (SMSA publishes no public API docs): unverified until
// SMSA confirms. The draft is unsigned, so it is signed here with the test key.
test('SMSA draft: sends SMSA\'s b2c shape with numbers as numbers, and fills smsaAwb from sawb', async () => {
  const P = require('../lib/plugin-payload.js');
  const sample = sign(Object.assign({}, require('../plugins/samples/unsigned/smsa-shipping.json')));
  const customer = { id: 'c9', nameEn: 'Sara A.', phone: '+966500000000', email: 's@example.com',
    addresses: [{ label: 'Home', address: 'King Fahd Rd' }], plugins: { [sample.id]: { city: 'Riyadh' } } };
  const order = { id: 'INV-2026-0107-ab12', invoiceNumber: 'INV-2026-0107', date: '2026-11-08', project: 'Bracket set',
    price: 115.5, currency: 'SAR', qty: 2 };
  const config = { senderName: 'Athar Tuwaiq', senderPhone: '+966511111111', senderCity: 'Riyadh',
    senderAddress: 'Tuwaiq St', parcelWeightKg: 1.5 };
  const entry = Object.assign(H.consentedEntry(null, sample), { config, secrets: { apiKey: 'smsa-test-key' } });
  assert.equal(H.stateOf(entry, true), 'on');
  assert.deepEqual(H.actionsFor({ plugins: [entry] }, 'order', () => true).map((a) => a.action.id), ['ship']);

  // A fixture of SMSA's reply: the label is a base64 PDF, so only the AWB is kept.
  const reply = { sawb: '231200021000', createDate: '2026-11-09T10:00:00',
    shipmentParcelsCount: 1, waybills: [{ awb: '231200021000', awbFile: 'JVBERi0xLjQK' }] };
  const post = fakePost({ ok: true, status: 200, text: JSON.stringify(reply) });
  const r = await S.send({ entry, trigger: { action: 'ship' }, records: { order, customer }, delivery: DLV }, { keys: KEYS, postPinned: post });
  assert.equal(r.ok, true);
  const call = post.calls[0];
  assert.equal(call.url, 'https://ecomapis.smsaexpress.com/api/shipment/b2c/new');
  assert.equal(call.headers.apikey, 'smsa-test-key', 'the key bare, in SMSA\'s apikey header');
  assert.ok(!('X-Khayt-Signature' in call.headers) && !('Authorization' in call.headers));
  const expected = P.payloadFor(sample, { action: 'ship' }, { order, customer, config, secrets: entry.secrets });
  assert.equal(call.body, expected.body);
  const body = JSON.parse(call.body);
  // SMSA refuses money and counts sent as strings.
  for (const k of ['DeclaredValue', 'CODAmount', 'Parcels', 'Weight']) assert.equal(typeof body[k], 'number', k);
  assert.deepEqual([body.DeclaredValue, body.CODAmount, body.Parcels, body.Weight], [115.5, 0, 1, 1.5]);
  assert.equal(body.OrderNumber, 'INV-2026-0107');
  assert.deepEqual(body.ConsigneeAddress, { ContactName: 'Sara A.', ContactPhoneNumber: '+966500000000',
    Country: 'SA', City: 'Riyadh', AddressLine1: 'King Fahd Rd' });
  assert.deepEqual(body.ShipperAddress, { ContactName: 'Athar Tuwaiq', ContactPhoneNumber: '+966511111111',
    Country: 'SA', City: 'Riyadh', AddressLine1: 'Tuwaiq St' });
  assert.ok(!JSON.stringify(body).includes('smsa-test-key'), 'the key never rides in the body');

  const values = P.applyResponse(sample, 'ship', r.reply, entry);
  assert.deepEqual(values, { smsaAwb: '231200021000' });
  assert.equal(H.withFieldValues(order, entry, 'order', values).plugins[sample.id].smsaAwb, '231200021000');

  for (const key of Object.keys(config)) {
    const partial = Object.assign({}, config); delete partial[key];
    const p2 = fakePost();
    const no = await S.send({ entry: Object.assign({}, entry, { config: partial }), trigger: { action: 'ship' }, records: { order, customer }, delivery: DLV }, { keys: KEYS, postPinned: p2 });
    assert.deepEqual([no.ok, no.refused, p2.calls.length], [false, `setting ${key} is not set`, 0]);
  }
  const p3 = fakePost();
  const noKey = await S.send({ entry: Object.assign({}, entry, { secrets: {} }), trigger: { action: 'ship' }, records: { order, customer }, delivery: DLV }, { keys: KEYS, postPinned: p3 });
  assert.deepEqual([noKey.refused, p3.calls.length], ['secret "apiKey" is not set', 0]);
});
