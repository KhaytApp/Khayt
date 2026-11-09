'use strict';
/**
 * Connector `refresh` (v1.1) and replies to events.
 *
 * The /privacy wording promises three things about refresh, and these hold
 * them: it sends only the fields the manifest declares (listed on the consent
 * sheet like a button's), its reply fills only the connector's own job fields,
 * and it checks no more often than the shop agreed to — never under 15
 * minutes, at most 50 open jobs a run.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const M = require('../lib/plugin-manifest');
const P = require('../lib/plugin-payload');
const H = require('../lib/plugin-host');

const clone = (o) => JSON.parse(JSON.stringify(o));

function base() {
  return {
    khayt: { manifest: 1 },
    id: 'com.example.courier',
    name: { en: 'Courier', ar: 'مندوب' },
    publisher: 'Example Ltd',
    version: '1.1.0',
    domains: ['api.example.com'],
    secrets: [{ name: 'apiKey', label: { en: 'API key' }, kind: 'apiKey' }],
    fields: [
      { key: 'courierId', label: { en: 'Courier order', ar: 'طلب المندوب' }, type: 'text', attach: 'order' },
      { key: 'courierStatus', label: { en: 'Courier status' }, type: 'text', attach: 'order' },
      { key: 'vip', label: { en: 'VIP' }, type: 'bool', attach: 'customer' },
    ],
    actions: [
      { id: 'ship', label: { en: 'Ship' }, placement: 'order', kind: 'post',
        url: 'https://api.example.com/v1/orders', send: ['order.number'],
        auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' },
        response: { fields: { courierId: 'data.id' } } },
    ],
    refresh: {
      every: 30, when: 'courierId', method: 'GET',
      url: 'https://api.example.com/v1/orders/{field.courierId}',
      auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' },
      response: { fields: { courierStatus: 'data.status' } },
    },
    scopes: ['fields.write'],
  };
}

const entryOf = (m) => ({ id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m), config: {} });
const errs = (m) => M.validateManifest(m).errors;
const has = (m, bit) => errs(m).some(e => e.includes(bit));

test('a refresh manifest passes', () => {
  assert.deepEqual(errs(base()), []);
});

test('every is whole minutes from 15 to 1440', () => {
  for (const bad of [14, 0, -1, 1441, 30.5, '30', null]) {
    const m = base(); m.refresh.every = bad;
    assert.ok(has(m, 'refresh.every'), String(bad));
  }
  for (const ok of [15, 1440]) { const m = base(); m.refresh.every = ok; assert.deepEqual(errs(m), [], String(ok)); }
});

test('when is one of the connector\'s own JOB fields', () => {
  const m = base(); m.refresh.when = 'nope';
  assert.ok(has(m, 'refresh.when'));
  const c = base(); c.refresh.when = 'vip';
  assert.ok(has(c, 'refresh checks jobs'));
  const s = base(); s.refresh.when = 'order.number';
  assert.ok(has(s, 'refresh.when'));
});

test('a GET has no body; a POST sends only what it declares', () => {
  const g = base(); g.refresh.send = ['order.number'];
  assert.ok(has(g, 'refresh.send: a GET has no body'));
  const gb = base(); gb.refresh.body = { format: 'khayt-v1' };
  assert.ok(has(gb, 'refresh.body: a GET has no body'));
  const p = base(); p.refresh.method = 'POST'; p.refresh.send = ['order.number', 'field.courierId'];
  assert.deepEqual(errs(p), []);
  const bad = base(); bad.refresh.method = 'PUT';
  assert.ok(has(bad, 'refresh.method'));
  // Anything not sendable is refused, in the URL or the list.
  const u = base(); u.refresh.url = 'https://api.example.com/v1/orders/{order.secretSauce}';
  assert.ok(has(u, 'not a field a connector can send'));
  const l = base(); l.refresh.method = 'POST'; l.refresh.send = ['customer.password'];
  assert.ok(has(l, 'not a field a connector can send'));
  // A secret may sit in the URL (never shown to a browser) but not in a body.
  const sb = base(); sb.refresh.method = 'POST'; sb.refresh.send = ['secret.apiKey'];
  assert.ok(has(sb, 'a secret cannot appear here'));
});

test('a refresh reaches only a declared host, and the host must be fixed', () => {
  const m = base(); m.refresh.url = 'https://evil.example.org/x';
  assert.ok(has(m, 'is not in domains'));
  const h = base(); h.refresh.url = 'https://{field.courierId}.example.com/x';
  assert.ok(has(h, 'no placeholder in the host'));
  // A host used only by refresh counts as used.
  const only = base(); only.actions = [];
  assert.deepEqual(errs(only), []);
});

test('the reply is required, fills only own JOB fields, and needs fields.write', () => {
  const none = base(); delete none.refresh.response;
  assert.ok(has(none, 'refresh.response: required'));
  const empty = base(); empty.refresh.response = { fields: {} };
  assert.ok(has(empty, 'name at least one field'));
  const foreign = base(); foreign.refresh.response.fields = { status: 'data.status' };
  assert.ok(has(foreign, 'a reply can only fill the plugin\'s own fields'));
  const cust = base(); cust.refresh.response.fields = { vip: 'data.vip' };
  assert.ok(has(cust, 'is on a customer'));
  const scope = base(); scope.scopes = []; scope.actions = [];
  assert.ok(has(scope, '"refresh" needs "fields.write"'));
  const unknown = base(); unknown.refresh.extra = 1;
  assert.ok(has(unknown, 'refresh: unknown key "extra"'));
});

test('what a refresh sends is on the consent sheet, by host, like a button', () => {
  const m = base(); m.actions = [];
  assert.deepEqual(M.consentRows(m), [{ host: 'api.example.com', fields: [{ key: 'field.courierId', category: 'content.other' }] }]);
  const p = M.permissionsOf(m);
  assert.deepEqual(p.fields, ['field.courierId']);
  assert.deepEqual(p.domains, ['api.example.com']);
  assert.equal(p.refresh, 30);
  assert.deepEqual(M.refreshConsent(m, 'ar'), { every: 30, host: 'api.example.com', field: 'courierId', fieldLabel: 'طلب المندوب' });
  assert.deepEqual(M.refreshConsent(m, 'fr').fieldLabel, 'Courier order');
  delete m.refresh;
  assert.equal(M.refreshConsent(m, 'en'), null);
  assert.equal(M.permissionsOf(m).refresh, undefined);
});

test('adding a refresh, or checking more often, asks again; checking less often does not', () => {
  const v1 = base(); delete v1.refresh;
  const granted = M.grantFor(v1);
  assert.equal(granted.refresh, undefined);
  const v2 = base();
  const d = M.diffPermissions(granted, v2);
  assert.equal(d.refresh, true); assert.equal(d.widened, true);
  const g30 = M.grantFor(v2);
  assert.equal(g30.refresh, 30);
  assert.equal(M.diffPermissions(g30, v2).widened, false);
  const faster = base(); faster.refresh.every = 15;
  assert.equal(M.diffPermissions(g30, faster).widened, true);
  const slower = base(); slower.refresh.every = 60;
  assert.equal(M.diffPermissions(g30, slower).widened, false);
  // Paused until agreed, through the same rule every device keeps.
  assert.equal(M.checkEntry(Object.assign(entryOf(v2), { granted })).paused, true);
  assert.equal(M.checkEntry(entryOf(v2)).paused, false);
  // A stored grant with a refresh that is not whole minutes is damaged.
  const forged = entryOf(v2); forged.granted.refresh = 1;
  assert.equal(M.checkEntry(forged).ok, false);
});

test('the payload: a GET is its URL and Khayt\'s headers; a POST carries its send list', () => {
  const m = base();
  const order = { id: 'j1', invoiceNumber: 'INV-1', plugins: { [m.id]: { courierId: 'A/7 9' } } };
  const g = P.payloadFor(m, { refresh: true }, { order, secrets: { apiKey: 'k' } });
  assert.deepEqual(g, { ok: true, method: 'GET', url: 'https://api.example.com/v1/orders/A%2F7%209', body: '',
    auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' }, signWith: null });
  const p = base(); p.refresh.method = 'POST'; p.refresh.url = 'https://api.example.com/v1/status';
  p.refresh.send = ['field.courierId'];
  const post = P.payloadFor(p, { refresh: true }, { order });
  assert.equal(post.method, 'POST');
  assert.deepEqual(JSON.parse(post.body).data, { 'field.courierId': 'A/7 9' });
  assert.deepEqual(JSON.parse(post.body).trigger, { refresh: true });
  const none = base(); delete none.refresh;
  assert.equal(P.payloadFor(none, { refresh: true }, { order }).ok, false);
});

test('a refresh reply and an event reply fill only their own job fields', () => {
  const m = base();
  m.events = [{ event: 'order_shipped', url: 'https://api.example.com/v1/hook', send: ['order.number'],
    response: { fields: { courierId: 'id' } } }];
  assert.deepEqual(errs(m), []);
  const entry = entryOf(m);
  assert.deepEqual(P.applyResponse(m, { refresh: true }, { data: { status: 'out for delivery', vip: true } }, entry),
    { courierStatus: 'out for delivery' });
  assert.deepEqual(P.applyResponse(m, { event: 'order_shipped' }, { id: 'C-9' }, entry), { courierId: 'C-9' });
  assert.deepEqual(P.applyResponse(m, { event: 'order_created' }, { id: 'C-9' }, entry), {});
  // The pre-v1.1 call, a button's id alone, still works.
  assert.deepEqual(P.applyResponse(m, 'ship', { data: { id: 'C-1' } }, entry), { courierId: 'C-1' });
  // Without fields.write granted, nothing.
  const noWrite = clone(entry); noWrite.granted.scopes = [];
  assert.deepEqual(P.applyResponse(m, { refresh: true }, { data: { status: 'x' } }, noWrite), {});
  // An event reply onto a customer field is refused at validation.
  const bad = clone(m); bad.events[0].response.fields = { vip: 'vip' };
  assert.ok(has(bad, 'is on a customer'));
  const noScope = clone(m); noScope.scopes = []; delete noScope.refresh; noScope.actions = [];
  assert.ok(has(noScope, 'an event with a "response" needs "fields.write"'));
});

test('due: never under 15 minutes, whatever the clock says', () => {
  const r = base().refresh;
  const t0 = Date.UTC(2026, 10, 10, 9, 0, 0);
  assert.equal(H.refreshDue(r, undefined, t0), true);
  assert.equal(H.refreshDue(r, t0, t0 + 29 * 60000), false);
  assert.equal(H.refreshDue(r, t0, t0 + 30 * 60000), true);
  // A hand-edited manifest under the floor still waits 15 minutes.
  assert.equal(H.refreshDue(Object.assign({}, r, { every: 1 }), t0, t0 + 14 * 60000), false);
  assert.equal(H.refreshDue(Object.assign({}, r, { every: 1 }), t0, t0 + 15 * 60000), true);
  // A clock set back does not freeze it.
  assert.equal(H.refreshDue(r, t0 + 86400000, t0), true);
  assert.equal(H.refreshDue(null, undefined, t0), false);
});

test('which jobs: open, with the field filled, least recently checked first, at most 50', () => {
  const m = base();
  const entry = entryOf(m);
  const job = (id, extra, val) => Object.assign({ id, status: 'in_progress',
    plugins: val === undefined ? undefined : { [m.id]: { courierId: val } } }, extra);
  const log = [
    job('a', {}, 'X1'),
    job('b', { status: 'cancelled' }, 'X2'),
    job('c', { archived: true }, 'X3'),
    job('d', { deliveredAt: '2026-11-09T10:00:00Z', status: 'completed' }, 'X4'),
    job('e', { status: 'delivered' }, 'X5'),
    job('f', { voidedAt: '2026-11-01' }, 'X6'),
    job('g', {}, ''),
    job('h', {}),
    job('i', { status: 'completed' }, 'X9'),
    job('j', {}, 'X10'),
  ];
  assert.deepEqual(H.refreshJobs(log, entry, {}).map(o => o.id), ['a', 'i', 'j']);
  assert.deepEqual(H.refreshJobs(log, entry, { a: 3, i: 1 }).map(o => o.id), ['j', 'i', 'a']);
  const many = Array.from({ length: 80 }, (_, n) => job('k' + String(n).padStart(2, '0'), {}, 'Y'));
  const first = H.refreshJobs(many, entry, {});
  assert.equal(first.length, 50);
  const checked = Object.fromEntries(first.map(o => [o.id, 100]));
  const second = H.refreshJobs(many, entry, checked);
  assert.deepEqual(second.slice(0, 30).map(o => o.id), many.slice(50).map(o => o.id));
  // Another connector's value does not count.
  assert.deepEqual(H.refreshJobs([{ id: 'z', status: 'pending', plugins: { other: { courierId: 'Q' } } }], entry, {}), []);
});

test('targets: only connectors that are on, granted and carry a refresh', () => {
  const m = base();
  const plain = base(); plain.id = 'com.example.plain'; delete plain.refresh;
  const off = base(); off.id = 'com.example.off';
  const ungranted = base(); ungranted.id = 'com.example.ungranted';
  const settings = { plugins: [
    entryOf(m), entryOf(plain), Object.assign(entryOf(off), { enabled: false }),
    Object.assign(entryOf(ungranted), { granted: M.grantFor(plain) }),
  ] };
  assert.deepEqual(H.refreshTargets(settings, () => true).map(t => t.entry.id), ['com.example.courier']);
  assert.deepEqual(H.refreshTargets(settings, () => false), []);
});

test('the JSON Schema knows refresh and event replies', () => {
  const s = M.manifestJsonSchema();
  assert.deepEqual(Object.keys(s.properties.refresh.properties).sort(),
    ['auth', 'body', 'every', 'method', 'response', 'send', 'signWith', 'url', 'when']);
  assert.equal(s.properties.refresh.properties.every.minimum, M.REFRESH.minEvery);
  assert.deepEqual(s.properties.refresh.properties.method.enum, M.REFRESH_METHODS);
  assert.ok(s.properties.events.items.properties.response);
});
