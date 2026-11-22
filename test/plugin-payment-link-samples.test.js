'use strict';
/**
 * The unsigned Moyasar and Tap payment-link drafts (plugins/samples/unsigned).
 *
 * Request shapes are from each provider's published API reference:
 *   Moyasar  POST https://api.moyasar.com/v1/invoices — HTTP Basic with the
 *            secret key as the user name; amount in the smallest unit
 *            (halalas), at least 100; the reply's `url` is the checkout page.
 *   Tap      POST https://api.tap.company/v2/invoices/ — Bearer secret key;
 *            order.amount in major units; due/expiry in epoch MILLISECONDS
 *            (the reference's own examples and replies); reply `url`.
 * Fixtures only: the keys below are made-up test strings, never a real key.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const M = require('../lib/plugin-manifest');
const P = require('../lib/plugin-payload');
const H = require('../lib/plugin-host');
const S = require('../lib/main/plugin-send');

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const KEYS = [{ id: 'test-key', key: publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64') }];
const sign = (m) => Object.assign({}, m, { signature: crypto.sign(null, Buffer.from(M.canonicalJSON(m), 'utf8'), privateKey).toString('base64') });
const DLV = 'dlv_12345678-1234-4123-8123-123456789abc';
const NOW = Date.UTC(2026, 10, 10, 9, 0, 0);
const EXCLUSIVE = { currency: 'SAR', tax: { mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };

function fakePost(reply) {
  const calls = [];
  const fn = async (url, o) => { calls.push(Object.assign({ url }, o)); return reply || { ok: true, status: 201, text: '{}' }; };
  fn.calls = calls;
  return fn;
}
const customer = { id: 'c9', nameEn: 'Sara A.', email: 's@example.com', phone: '+966500000000' };
// A job in the shop's own currency carries no `currency` of its own.
const order = { id: 'INV-2026-0107-ab12', invoiceNumber: 'INV-2026-0107', project: 'Bracket set', clientId: 'c9',
  price: 100, paidAmount: 15, status: 'pending' };

for (const name of ['moyasar', 'tap']) {
  test(`${name} draft is a valid manifest that asks only for what a payment link needs`, () => {
    const m = require(`../plugins/samples/unsigned/${name}-payment-link.json`);
    assert.deepEqual(M.validateManifest(m).errors, []);
    const perm = M.permissionsOf(m);
    assert.deepEqual(perm.scopes, ['fields.write']);
    assert.ok(perm.fields.includes('order.amountDueCurrency'));
    assert.ok(!perm.fields.some((f) => f === 'order.total'), 'the bare price is never what a link charges');
    assert.ok(!JSON.stringify(m).match(/sk_(test|live)_[A-Za-z0-9]/), 'no key in a sample');
  });
}

test('Moyasar: Basic auth from the secret key, halalas of what is owed, and the link filled from url', async () => {
  const sample = sign(require('../plugins/samples/unsigned/moyasar-payment-link.json'));
  const entry = Object.assign(H.consentedEntry(null, sample), { secrets: { secretKey: 'sk_test_fixture' } });
  const reply = { id: 'inv_fixture', status: 'initiated', amount: 9500, currency: 'SAR', url: 'https://checkout.moyasar.com/invoices/inv_fixture' };
  const post = fakePost({ ok: true, status: 201, text: JSON.stringify(reply) });
  const r = await S.send({ entry, trigger: { action: 'paymentLink' }, records: { order, customer }, delivery: DLV, settings: EXCLUSIVE },
    { keys: KEYS, postPinned: post, now: () => NOW });
  assert.equal(r.ok, true, JSON.stringify(r));
  const call = post.calls[0];
  assert.equal(call.url, 'https://api.moyasar.com/v1/invoices');
  assert.equal(call.method, 'POST');
  assert.equal(call.headers.Authorization, 'Basic ' + Buffer.from('sk_test_fixture:').toString('base64'));
  const body = JSON.parse(call.body);
  // 100 + 15% VAT on top, less 15 paid = 100.00 SAR = 10000 halalas, a number.
  assert.strictEqual(body.amount, 10000);
  assert.equal(body.currency, 'SAR');
  assert.equal(body.description, 'INV-2026-0107 Bracket set');
  assert.ok(!call.body.includes('sk_test_fixture'));
  const values = P.applyResponse(sample, { action: 'paymentLink' }, r.reply, entry);
  assert.deepEqual(values, { paymentLinkUrl: 'https://checkout.moyasar.com/invoices/inv_fixture' });
});

test('Tap: Bearer key, major units, due now and expiry in 7 days in ms, link filled from url', async () => {
  const sample = sign(require('../plugins/samples/unsigned/tap-payment-link.json'));
  const entry = Object.assign(H.consentedEntry(null, sample), { secrets: { secretKey: 'sk_test_fixture' } });
  const kwd = Object.assign({}, order, { currency: 'KWD', price: 22.1594, paidAmount: 0 });
  const reply = { id: 'inv_fixture', status: 'CREATED', url: 'https://invoices.sandbox.tap.company/invoice/inv_fixture' };
  const post = fakePost({ ok: true, status: 200, text: JSON.stringify(reply) });
  const r = await S.send({ entry, trigger: { action: 'paymentLink' }, records: { order: kwd, customer }, delivery: DLV, settings: { currency: 'SAR' } },
    { keys: KEYS, postPinned: post, now: () => NOW });
  assert.equal(r.ok, true, JSON.stringify(r));
  const call = post.calls[0];
  assert.equal(call.url, 'https://api.tap.company/v2/invoices/');
  assert.equal(call.headers.Authorization, 'Bearer sk_test_fixture');
  const body = JSON.parse(call.body);
  assert.strictEqual(body.due, NOW);
  assert.strictEqual(body.expiry, NOW + 7 * 86400000);
  assert.strictEqual(body.draft, false);
  // KWD has three decimals: rounded to the fils.
  assert.strictEqual(body.order.amount, 22.159);
  assert.equal(body.order.currency, 'KWD');
  assert.deepEqual(body.order.items, [{ description: 'Bracket set', amount: 22.159, currency: 'KWD', quantity: 1 }]);
  assert.deepEqual(body.customer, { first_name: 'Sara A.', email: 's@example.com' });
  const values = P.applyResponse(sample, { action: 'paymentLink' }, r.reply, entry);
  assert.deepEqual(values, { paymentLinkUrl: 'https://invoices.sandbox.tap.company/invoice/inv_fixture' });
});

test('nothing is sent without the key, or without the shop settings that make the amount right', async () => {
  for (const name of ['moyasar', 'tap']) {
    const sample = sign(require(`../plugins/samples/unsigned/${name}-payment-link.json`));
    const entry = Object.assign(H.consentedEntry(null, sample), { secrets: { secretKey: 'sk_test_fixture' } });
    const p1 = fakePost();
    const noKey = await S.send({ entry: Object.assign({}, entry, { secrets: {} }), trigger: { action: 'paymentLink' }, records: { order, customer }, delivery: DLV, settings: EXCLUSIVE },
      { keys: KEYS, postPinned: p1, now: () => NOW });
    assert.deepEqual([noKey.refused, p1.calls.length], ['secret "secretKey" is not set', 0], name);
    const p2 = fakePost();
    const noSettings = await S.send({ entry, trigger: { action: 'paymentLink' }, records: { order, customer }, delivery: DLV },
      { keys: KEYS, postPinned: p2, now: () => NOW });
    assert.deepEqual([noSettings.ok, p2.calls.length], [false, 0], name);
  }
});

test('amountDueCurrency is the job\'s own, else the customer\'s, else the shop\'s', () => {
  const m = { id: 'x', fields: [] };
  const v = (o, c, s) => P.valueOf(m, 'order.amountDueCurrency', { order: o, customer: c, settings: s });
  assert.equal(v({ price: 1, currency: 'EUR' }, null, { currency: 'SAR' }), 'EUR');
  assert.equal(v({ price: 1, clientId: 'c1' }, { id: 'c1', currency: 'KWD' }, { currency: 'SAR' }), 'KWD');
  assert.equal(v({ price: 1 }, null, { currency: 'AED' }), 'AED');
});
