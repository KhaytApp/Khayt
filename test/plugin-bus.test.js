'use strict';
/**
 * Plugins v1, the desktop's share of the shared lib/:
 *
 *  - the event webhook folded into the bus as a subscription DERIVED at read
 *    time (lib/webhook-bus.js effectiveSubscriptions), never stored, deduped
 *    by URL and event;
 *  - the event catalogue khaytapp.com builds its docs from, every example made
 *    by the writer that sends it;
 *  - per-plugin secrets: sealed and masked like every other secret, and per
 *    DEVICE — never in a cloud push, an export or a restore from elsewhere,
 *    and only ever sent to a host the shop granted.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const Bus = require('../lib/webhook-bus.js');
const Hooks = require('../lib/webhooks.js');
const Paths = require('../lib/store-secret-paths.js');
const SecretDestination = require('../lib/secret-destination.js');
globalThis.KhaytStoreSecretPaths = Paths;
const Outbox = require('../lib/cloud-outbox.js');
const Store = require('../lib/store.js');
const { harness, MASK } = require('./helpers/store-io-harness.js');

const EV = (extra) => ({ eventWebhooks: { enabled: true, url: 'https://erp.example.com/hook', secret: 'ev-secret', ...extra } });

// ── the fold ───────────────────────────────────────────────────────────────

test('the event webhook is a derived subscription with its own envelope', () => {
  const sub = Bus.eventWebhookSubscription(EV());
  assert.deepEqual(sub, {
    id: 'event:legacy', url: 'https://erp.example.com/hook', enabled: true, format: 'order-envelope-v1',
    events: ['order_created', 'status_changed', 'payment_received'],
  });
  assert.equal(sub.secret, undefined, 'the secret stays in eventWebhooks.secret, sealed');
  assert.ok(Bus.isEventWebhook(sub));
});

test('its switches, an http URL and "off" all read as they always have', () => {
  assert.deepEqual(Bus.eventWebhookSubscription(EV({ events: { paid: false } })).events, ['order_created', 'status_changed']);
  assert.equal(Bus.eventWebhookSubscription(EV({ events: { created: false, status: false, paid: false } })), null);
  assert.equal(Bus.eventWebhookSubscription(EV({ url: 'http://erp.example.com/hook' })), null);
  assert.equal(Bus.eventWebhookSubscription(EV({ enabled: false })), null);
  assert.equal(Bus.eventWebhookSubscription({}), null);
});

test('it does not depend on the subscriptions switch, and is never written into the store', () => {
  const settings = { ...EV(), webhooks: { enabled: false, events: { order_created: 'https://x.example/h' } } };
  const before = JSON.stringify(settings);
  const subs = Bus.effectiveSubscriptions(settings);
  assert.deepEqual(subs.map((s) => s.id), ['event:legacy'], 'the bus is off; the event webhook is not');
  assert.equal(JSON.stringify(settings), before, 'reading must not persist anything (subscriptions[] stays absent)');
});

test('one URL listening in both systems gets each moment once', () => {
  const settings = {
    ...EV(),
    webhooks: { enabled: true, subscriptions: [
      { id: 's1', url: 'https://ERP.example.com/hook/', events: ['status_changed'], enabled: true },
      { id: 's2', url: 'https://other.example/h', events: ['order_created'], enabled: true },
    ] },
  };
  const ev = Bus.effectiveSubscriptions(settings).find(Bus.isEventWebhook);
  assert.deepEqual(ev.events, ['order_created', 'payment_received'], 'status goes once, by the bus subscription');
  // A switched-off subscription delivers nothing, so it shadows nothing.
  settings.webhooks.subscriptions[0].enabled = false;
  assert.deepEqual(Bus.effectiveSubscriptions(settings).find(Bus.isEventWebhook).events.length, 3);
  // Covering every event leaves the event webhook out entirely.
  settings.webhooks.subscriptions[0] = { id: 's1', url: 'https://erp.example.com/hook', enabled: true,
    events: ['order_created', 'status_changed', 'payment_received'] };
  assert.equal(Bus.effectiveSubscriptions(settings).find(Bus.isEventWebhook), undefined);
});

test('a retry or resend of the event webhook may keep the "event:" id', () => {
  const kept = Bus.withSubscriptions({ pending: [{ id: 'p1', subscriptionId: 'event:legacy' }] }, []);
  assert.deepEqual(kept.pending.map((p) => p.id), ['p1']);
});

// ── the catalogue ──────────────────────────────────────────────────────────

test('every catalogue event is listed once, in the bus order', () => {
  const c = Bus.eventCatalogue();
  assert.deepEqual(c.events.map((e) => e.event), Bus.EVENTS);
});

test('each example is the bytes the sender builds, and the fields are its keys', () => {
  for (const e of Bus.eventCatalogue().events) {
    if (!e.sent) { assert.equal(e.example, null, `${e.event}: no invented example`); continue; }
    assert.equal(e.example.event, e.event);
    assert.equal(e.example.version, 1);
    assert.deepEqual(e.fields.map((f) => f.key), Object.keys(e.example.payload), e.event);
    for (const f of e.fields) assert.equal(typeof f.type, 'string');
  }
  const created = Bus.eventCatalogue().events.find((e) => e.event === 'order_created');
  assert.deepEqual(Object.keys(created.example.payload), ['orderId', 'project', 'status', 'price']);
  const paid = Bus.eventCatalogue().events.find((e) => e.event === 'payment_received');
  assert.deepEqual(Object.keys(paid.example.payload), ['orderId', 'amount', 'paymentStatus', 'client']);
});

test('the order envelope examples are lib/webhooks.js buildWebhookEvent output', () => {
  const env = Bus.eventCatalogue().orderEnvelope;
  assert.deepEqual(env.map((e) => e.event), ['order.created', 'order.status', 'order.paid']);
  for (const e of env) {
    assert.equal(e.format, 'order-envelope-v1');
    assert.deepEqual(Object.keys(e.example), Object.keys(Hooks.buildWebhookEvent('status', {}, {})));
  }
});

test('the moved payloads keep their key order (consumers verify the bytes)', () => {
  const o = { id: 'O1', project: 'P', status: 'pending', price: 5, paidAmount: 5, paymentStatus: 'paid', client: 'C' };
  assert.equal(JSON.stringify(Bus.statusPayload('order_created', o)),
    JSON.stringify({ orderId: 'O1', project: 'P', status: 'pending', price: 5 }));
  assert.equal(JSON.stringify(Bus.statusPayload('payment_received', o)),
    JSON.stringify({ orderId: 'O1', amount: 5, paymentStatus: 'paid', client: 'C' }));
  assert.deepEqual(Object.keys(Bus.printerAlertPayload({ machineId: 'm' }, 'T')),
    ['machineId', 'type', 'state', 'filename', 'progress', 'message', 'at']);
});

// ── per-plugin secrets ─────────────────────────────────────────────────────

const plugin = (secrets, domains = ['api.lamha.sa']) => ({
  id: 'sa.lamha', version: '1.0.0', enabled: true, config: { account: '42' }, secrets,
  granted: { version: '1.0.0', fields: ['customer.phone'], domains, scopes: [] },
});

test('every plugin secret is visited, whatever its name', () => {
  const store = { settings: { plugins: [plugin({ apiKey: 'k', signing: 's' }), plugin({ token: 't' })] } };
  const seen = [];
  Paths.forEachSecret(store, (v, set) => { seen.push(v); set(MASK); });
  assert.deepEqual(seen.sort(), ['k', 's', 't']);
  assert.equal(store.settings.plugins[0].config.account, '42', 'settings are not secrets');
});

test('a cloud push carries no plugin secret, not even a mask', () => {
  const out = Outbox.forCloud({ settings: { plugins: [plugin({ apiKey: 'k' })] } });
  assert.equal('secrets' in out.settings.plugins[0], false);
  assert.deepEqual(out.settings.plugins[0].granted.domains, ['api.lamha.sa'], 'the plugin and its consent do sync');
  assert.equal('secrets' in Outbox.forPhone({ settings: { plugins: [plugin({ apiKey: 'k' })] } }).settings.plugins[0], false);
});

test('an export file carries no plugin secret', () => {
  const out = Store.redactSettingsForExport({ plugins: [plugin({ apiKey: 'k' })] });
  assert.equal('secrets' in out.plugins[0], false);
});

test('a restore or cloud snapshot keeps THIS device\'s plugin secrets, by id', () => {
  const local = { settings: { plugins: [plugin({ apiKey: 'mine' })] } };
  const fromElsewhere = { settings: { plugins: [plugin({ apiKey: 'theirs' }), { id: 'other', secrets: { x: 'y' } }] } };
  const out = Paths.keepMachineLocal(local, fromElsewhere, MASK);
  assert.deepEqual(out.settings.plugins[0].secrets, { apiKey: 'mine' });
  assert.equal('secrets' in out.settings.plugins[1], false, 'a plugin not set up here arrives with none');
  // Without a mask argument too (a plain local restore).
  const plain = Paths.keepMachineLocal(local, { settings: { plugins: [plugin({ apiKey: 'theirs' })] } });
  assert.deepEqual(plain.settings.plugins[0].secrets, { apiKey: 'mine' });
});

test('saving puts a masked plugin secret back from disk, and drops it when the grant moved', () => {
  const io = harness();
  io.putOnDisk({ settings: { plugins: [plugin({ apiKey: 'real', signing: 'sig' })] } });
  const same = io.mergeStoreSecretsFromDisk({ settings: { plugins: [plugin({ apiKey: MASK, signing: 'typed-new' })] } });
  assert.deepEqual(same.settings.plugins[0].secrets, { apiKey: 'real', signing: 'typed-new' });
  const moved = io.mergeStoreSecretsFromDisk({ settings: { plugins: [plugin({ apiKey: MASK }, ['api.lamha.sa', 'evil.example'])] } });
  assert.deepEqual(moved.settings.plugins[0].secrets, {}, 'a new domain means entering the secret again');
});

test('a plugin secret goes only to exactly an https host the shop granted', () => {
  const p = plugin({}, ['lamha.sa']);
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'https://lamha.sa/v1/ship'), true);
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'https://LAMHA.sa./v1'), true);
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'https://api.lamha.sa/v1'), false, 'a subdomain is another host');
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'https://user:pw@lamha.sa/'), false, 'no userinfo');
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'http://lamha.sa/v1'), false);
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'https://notlamha.sa/'), false);
  assert.equal(SecretDestination.pluginDestinationAllowed(p, 'https://lamha.sa.evil.example/'), false);
  assert.equal(SecretDestination.pluginDestinationAllowed(plugin({}, []), 'https://lamha.sa/'), false);
  assert.equal(SecretDestination.pluginKey(plugin({}, ['B.example.', 'a.example', 'a.example'])), 'a.example,b.example');
});
