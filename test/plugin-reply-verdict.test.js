'use strict';
// A 2xx that is really a refusal, reply paths tried in order, a job with no
// customer, and an event the service turned down (Lamha E2E, Nov 10 2026).
// The contract every app calls: lib/plugin-payload.js replyRefusal /
// replyVerdict / usesCustomer, lib/plugin-host.js withFailed / withRetried /
// failedQueued.
const test = require('node:test');
const assert = require('node:assert');
for (const f of ['tax', 'business-scope', 'order-money']) require('../lib/' + f + '.js');
const M = require('../lib/plugin-manifest.js');
const P = require('../lib/plugin-payload.js');
const H = require('../lib/plugin-host.js');
const lamha = require('../plugins/samples/lamha-shipping.json');

const courier = {
  khayt: { manifest: 1 }, id: 'com.example.courier', name: { en: 'Courier' }, publisher: 'Example Ltd',
  version: '1.0.0', domains: ['api.example.com'],
  fields: [{ key: 'ref', label: { en: 'Courier ref' }, type: 'text', attach: 'order' }],
  actions: [
    { id: 'book', label: { en: 'Book' }, placement: 'order', kind: 'post', url: 'https://api.example.com/book',
      send: ['order.number', 'customer.phone'], response: { fields: { ref: ['order_id', 'data.id'] } } },
    { id: 'ping', label: { en: 'Ping' }, placement: 'order', kind: 'post', url: 'https://api.example.com/ping',
      send: ['order.number'] },
  ],
  events: [{ event: 'order_shipped', url: 'https://api.example.com/shipped', send: ['order.number'] }],
  scopes: ['fields.write'],
};
const entry = H.consentedEntry(null, courier);

test('success:false and status:false are refusals, with the service\'s own words', () => {
  assert.deepStrictEqual(P.replyRefusal(courier, { action: 'book' }, { success: false, msg: 'customer name is required' }),
    { message: 'customer name is required' });
  assert.deepStrictEqual(P.replyRefusal(courier, {}, { status: false, message: 'no' }), { message: 'no' });
  assert.deepStrictEqual(P.replyRefusal(courier, {}, { success: false, error: { message: ' line one\n  line two ' } }),
    { message: 'line one line two' }, 'one line');
  assert.deepStrictEqual(P.replyRefusal(courier, {}, { success: false }), { message: '' });
  // Only the boolean false: a missing key, true, or the string "false" is not a refusal.
  for (const r of [{}, { success: true }, { success: 'false' }, { status: 0 }, null, []]) {
    assert.strictEqual(P.replyRefusal(courier, {}, r), null, JSON.stringify(r));
  }
});

test('a long message is cut to 200 characters without splitting one', () => {
  const said = P.replyRefusal(courier, {}, { success: false, msg: '😀'.repeat(250) }).message;
  assert.strictEqual(Array.from(said).length, P.REFUSAL_MAX + 1, '200 and the ellipsis');
  assert.ok(said.endsWith('…'));
  assert.ok(!/\uD83D$/.test(said.slice(0, -1)), 'no half of a surrogate pair');
});

test('replyVerdict: refused, unconfirmed only for a button that declares reply fields, otherwise ok', () => {
  const ok = { ok: true };
  assert.deepStrictEqual(P.replyVerdict(courier, { action: 'book' }, { success: false, msg: 'x' }, entry, {}),
    { ok: false, kind: 'refused', message: 'x' });
  assert.deepStrictEqual(P.replyVerdict(courier, { action: 'book' }, { success: true }, entry, {}),
    { ok: false, kind: 'unconfirmed', fields: ['ref'] });
  const mapped = P.applyResponse(courier, { action: 'book' }, { data: { id: 77 } }, entry);
  assert.deepStrictEqual(P.replyVerdict(courier, { action: 'book' }, { data: { id: 77 } }, entry, mapped), ok);
  assert.deepStrictEqual(P.replyVerdict(courier, { action: 'ping' }, {}, entry, {}), ok, 'no reply fields declared');
  assert.deepStrictEqual(P.replyVerdict(courier, { event: 'order_shipped' }, {}, entry, {}), ok, 'an event stays ok');
  // Without fields.write nothing could be filled, so nothing is "unconfirmed".
  const noWrite = Object.assign({}, entry, { granted: Object.assign({}, entry.granted, { scopes: [] }) });
  assert.deepStrictEqual(P.replyVerdict(courier, { action: 'book' }, {}, noWrite, {}), ok);
  // A refusal wins even over a reply that would have filled a field.
  assert.strictEqual(P.replyVerdict(courier, { action: 'book' }, { success: false, order_id: 1 }, entry, { ref: '1' }).kind, 'refused');
});

test('a reply field can try a list of paths; the first with a value wins', () => {
  assert.deepStrictEqual(P.applyResponse(courier, { action: 'book' }, { order_id: 5, data: { id: 6 } }, entry), { ref: '5' });
  assert.deepStrictEqual(P.applyResponse(courier, { action: 'book' }, { data: { id: 6 } }, entry), { ref: '6' });
  assert.deepStrictEqual(P.applyResponse(courier, { action: 'book' }, { order_id: null, data: { id: 6 } }, entry), { ref: '6' });
  assert.deepStrictEqual(P.applyResponse(courier, { action: 'book' }, {}, entry), {});
});

test('the validator takes a path or a short list of paths, and nothing else', () => {
  assert.ok(M.validateManifest(courier, { unsigned: true }).ok);
  const bad = (paths) => {
    const m = JSON.parse(JSON.stringify(courier));
    m.actions[0].response.fields.ref = paths;
    return M.validateManifest(m, { unsigned: true });
  };
  for (const p of [[], ['a', 'b c'], [1], new Array(M.RESPONSE_PATHS_MAX + 1).fill('a'), { a: 1 }]) {
    assert.ok(!bad(p).ok, JSON.stringify(p));
  }
  assert.ok(bad(new Array(M.RESPONSE_PATHS_MAX).fill('a.b')).ok);
  const schema = M.manifestJsonSchema();
  assert.ok(JSON.stringify(schema).includes('"maxItems":' + M.RESPONSE_PATHS_MAX));
});

test('usesCustomer: a button that sends anything about the customer', () => {
  assert.strictEqual(P.usesCustomer(courier, { action: 'book' }), true);
  assert.strictEqual(P.usesCustomer(courier, 'ping'), false);
  assert.strictEqual(P.usesCustomer(lamha, { action: 'record' }), true, 'Lamha sends the customer\'s name, phone and city');
  assert.strictEqual(P.usesCustomer(courier, { action: 'nope' }), false);
});

test('an event the service turned down stays in the outbox as failed, never due, until Retry', () => {
  const item = { delivery: 'dlv_1', id: courier.id, event: 'order_shipped', orderId: 'J-1', attempt: 1 };
  let list = H.withQueued([], item, '2026-11-10T00:00:00.000Z');
  list = H.withFailed(list, item, '2026-11-10T00:01:00.000Z', 'customer name is required');
  assert.deepStrictEqual(list[0].failed, { at: '2026-11-10T00:01:00.000Z', message: 'customer name is required' });
  assert.strictEqual(list[0].nextAttemptAt, undefined);
  assert.strictEqual(H.dueQueued(list, Date.parse('2030-01-01')).length, 0, 'never retried on its own');
  assert.strictEqual(H.failedQueued(list).length, 1);
  list = H.withRetried(list, 'dlv_1', '2026-11-10T00:05:00.000Z');
  assert.strictEqual(list[0].failed, undefined);
  assert.strictEqual(H.dueQueued(list, Date.parse('2026-11-10T00:05:00.000Z')).length, 1, 'due again once retried');
  assert.strictEqual(H.failedQueued(list).length, 0);
  assert.strictEqual(H.withoutQueued(list, 'dlv_1').length, 0, 'Dismiss drops it');
});

test('the Lamha sample 1.1.1: signed, and its order number comes from order_id or data.id', () => {
  assert.strictEqual(lamha.version, '1.1.1');
  assert.ok(M.validateManifest(lamha).ok, 'validates with its signature');
  const record = lamha.actions.find(a => a.id === 'record');
  assert.deepStrictEqual(record.response.fields.lamhaOrderId, ['order_id', 'data.id']);
  // Lamha's 200 refusal is shown, not taken as sent.
  assert.strictEqual(P.replyVerdict(lamha, { action: 'record' }, { success: false, msg: 'The city field is required.' },
    H.consentedEntry(null, lamha), {}).kind, 'refused');
});
