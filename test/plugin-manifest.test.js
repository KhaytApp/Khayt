'use strict';
/**
 * A connector is data, and the data says everything it can send.
 *
 * These hold the promises the published privacy wording makes about
 * connectors: nothing leaves for a host the manifest does not declare, a field
 * the consent screen did not list is never sent, an update that asks for more
 * pauses the connector, and a secret never ends up in a link a browser keeps.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const M = require('../lib/plugin-manifest');
const P = require('../lib/plugin-payload');
const bus = require('../lib/webhook-bus');

const samplesDir = path.join(__dirname, '..', 'plugins', 'samples');
const samples = fs.readdirSync(samplesDir).filter(f => f.endsWith('.json'))
  .map(f => ({ file: f, m: JSON.parse(fs.readFileSync(path.join(samplesDir, f), 'utf8')) }));

const clone = (o) => JSON.parse(JSON.stringify(o));

function base() {
  return {
    khayt: { manifest: 1 },
    id: 'com.example.ship',
    name: { en: 'Example shipping', ar: 'شحن' },
    publisher: 'Example Ltd',
    version: '1.2.0',
    domains: ['api.example.com', 'track.example.com'],
    secrets: [{ name: 'apiKey', label: { en: 'API key' }, kind: 'apiKey' }],
    fields: [
      { key: 'awb', label: { en: 'Waybill' }, type: 'text', attach: 'order' },
      { key: 'service', label: { en: 'Service' }, type: 'enum', attach: 'order',
        options: [{ value: 'std', label: { en: 'Standard' } }, { value: 'exp', label: { en: 'Express' } }] },
      { key: 'vip', label: { en: 'VIP' }, type: 'bool', attach: 'customer' },
    ],
    actions: [
      { id: 'ship', label: { en: 'Create shipment' }, placement: 'order', kind: 'post',
        url: 'https://api.example.com/v1/shipments',
        send: ['order.number', 'customer.name', 'customer.phone', 'customer.address', 'field.service'],
        auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' },
        response: { fields: { awb: 'data.awb' } } },
      { id: 'track', label: { en: 'Track' }, placement: 'order', kind: 'open',
        url: 'https://track.example.com/t/{field.awb}' },
    ],
    scopes: ['fields.write'],
  };
}

const order = {
  id: 'INV-2026-0003-3y0z', invoiceNumber: 'INV-2026-0003', project: 'Rack & legs / v2', status: 'pending',
  price: 115.5, currency: 'SAR', client: 'Walk-in name', clientId: 'c1',
  plugins: { 'com.example.ship': { service: 'exp', awb: 'AWB 12/34' } },
};
const customer = { id: 'c1', name: 'Noura', phone: '+966500000000', address: 'Riyadh', email: 'n@example.com' };

test('the base manifest and every shipped sample pass', () => {
  assert.deepEqual(M.validateManifest(base()).errors, []);
  assert.ok(samples.length >= 3);
  for (const { file, m } of samples) assert.deepEqual(M.validateManifest(m).errors, [], file);
});

test('unknown keys are refused at every level, so nothing rides in unlisted', () => {
  for (const mutate of [
    m => { m.script = 'alert(1)'; },
    m => { m.actions[0].code = 'x'; },
    m => { m.fields[0].computed = 'a+b'; },
    m => { m.secrets[0].value = 'sk_live'; },
    m => { m.actions[0].auth.extra = 1; },
  ]) {
    const m = base(); mutate(m);
    const r = M.validateManifest(m);
    assert.equal(r.ok, false);
    assert.ok(r.errors.some(e => e.includes('unknown key')), r.errors.join('\n'));
  }
});

test('a URL may only reach a declared public host, fixed before anything is filled in', () => {
  const bad = [
    'http://api.example.com/v1',               // not https
    'https://evil.example.org/v1',             // not declared
    'https://{order.title}.example.com/x',      // a value would choose the host
    'https://API.example.com/v1',               // must be written as declared
  ];
  for (const url of bad) {
    const m = base(); m.actions[0].url = url;
    assert.equal(M.validateManifest(m).ok, false, url);
  }
  for (const d of ['192.168.1.10', 'localhost', 'printer.local', 'router.lan', 'https://x.com', 'x']) {
    const m = base(); m.domains.push(d);
    assert.equal(M.validateManifest(m).ok, false, d);
  }
});

test('a declared host nothing uses is refused — the consent screen would show it for no reason', () => {
  const m = base(); m.domains.push('spare.example.com');
  assert.ok(M.validateManifest(m).errors.some(e => e.includes('spare.example.com')));
});

test('only listed book fields can be sent, and only from where the button sits', () => {
  let m = base(); m.actions[0].send.push('order.internalNotes');
  assert.equal(M.validateManifest(m).ok, false);
  m = base(); m.actions[0].send.push('field.nope');
  assert.equal(M.validateManifest(m).ok, false);
  // A customer button has no order to read.
  m = base(); m.actions[0].placement = 'customer'; delete m.actions[0].response;
  assert.ok(M.validateManifest(m).errors.some(e => e.includes('not reachable')));
  // A template is held to the same list.
  m = base(); m.actions[0].body = { format: 'json-template', template: { a: '{order.cost}' } };
  assert.equal(M.validateManifest(m).ok, false);
});

test('a secret can sit in a POST URL but never in a link the browser opens or in a body', () => {
  let m = base(); m.actions[1].url = 'https://track.example.com/t/{secret.apiKey}';
  assert.equal(M.validateManifest(m).ok, false);
  m = base(); m.actions[0].body = { format: 'json-template', template: { k: '{secret.apiKey}' } };
  assert.equal(M.validateManifest(m).ok, false);
  m = base(); m.actions[0].send.push('secret.apiKey');
  assert.equal(M.validateManifest(m).ok, false);
  m = base(); m.actions[0].url = 'https://api.example.com/v1/{secret.apiKey}/shipments';
  assert.deepEqual(M.validateManifest(m).errors, []);
});

test('a reply can only fill the plugin\'s own fields, on the same record', () => {
  let m = base(); m.actions[0].response = { fields: { status: 'data.status' } };
  assert.equal(M.validateManifest(m).ok, false);
  m = base(); m.actions[0].response = { fields: { vip: 'data.vip' } };
  assert.equal(M.validateManifest(m).ok, false);
});

test('every sendable field has an Apple privacy category, and the developer cannot pick one', () => {
  // Exactly what the iPhone's App Privacy label declares (Turki added Other
  // User Contact Info for customer.company, Nov 8 2026). Adding a category
  // here means changing the label and the /privacy page first.
  const allowed = new Set(['contact.name', 'contact.phone', 'contact.email', 'contact.address', 'contact.other',
    'purchase.history', 'content.other']);
  assert.deepEqual(new Set(Object.values(M.SENDABLE_FIELDS).map(s => s.category).concat([M.OWN_FIELD_CATEGORY])), allowed);
  for (const [k, s] of Object.entries(M.SENDABLE_FIELDS)) {
    assert.ok(allowed.has(s.category), k);
    assert.ok(['order', 'customer'].includes(s.from), k);
  }
  const m = base(); m.fields[0].category = 'none';
  assert.equal(M.validateManifest(m).ok, false);
});

test('permissions are exactly what the triggers can send, and what consent shows per host', () => {
  const p = M.permissionsOf(base());
  assert.deepEqual(p.fields, ['customer.address', 'customer.name', 'customer.phone', 'field.awb', 'field.service', 'order.number']);
  assert.deepEqual(p.domains, ['api.example.com', 'track.example.com']);
  assert.deepEqual(p.categories, ['contact.address', 'contact.name', 'contact.phone', 'content.other', 'purchase.history']);
  const rows = M.consentRows(base());
  assert.deepEqual(rows.map(r => r.host), ['api.example.com', 'track.example.com']);
  assert.deepEqual(rows[1].fields, [{ key: 'field.awb', category: 'content.other' }]);
  // A secret in a URL is not a book field and is not listed.
  const slack = samples.find(s => s.file === 'slack-notifier.json').m;
  assert.ok(!M.permissionsOf(slack).fields.some(f => f.startsWith('secret.')));
});

test('an update that asks for more pauses the plugin; asking for less does not', () => {
  const granted = M.grantFor(base());
  assert.equal(M.diffPermissions(granted, base()).widened, false);
  assert.equal(M.diffPermissions(null, base()).widened, true);

  let m = base(); m.version = '1.3.0'; m.actions[0].send.push('customer.email');
  assert.deepEqual(M.diffPermissions(granted, m).fields, ['customer.email']);
  m = base(); m.domains.push('new.example.com'); m.actions[1].url = 'https://new.example.com/t/{field.awb}';
  m.domains = m.domains.filter(d => d !== 'track.example.com');
  assert.deepEqual(M.diffPermissions(granted, m).domains, ['new.example.com']);
  m = base();
  assert.deepEqual(M.diffPermissions(Object.assign({}, granted, { scopes: [] }), m).scopes, ['fields.write']);
  m = base(); m.actions[0].send = ['order.number'];
  assert.equal(M.diffPermissions(granted, m).widened, false);
});

test('v1 has one scope; reading the shop and moving jobs wait for the Cloud relay', () => {
  // A v1 connector cannot reach the shop, so a scope that would let it is
  // refused rather than shown on a consent sheet that promises nothing real.
  assert.deepEqual(M.SCOPES, ['fields.write']);
  assert.deepEqual(M.RESERVED_SCOPES.slice().sort(), ['customers.read', 'jobs.status', 'orders.read']);
  for (const s of M.RESERVED_SCOPES) {
    const m = base(); m.scopes.push(s);
    assert.ok(M.validateManifest(m).errors.some(e => e.includes(`"${s}"`) && e.includes('Cloud relay')), s);
  }
  assert.deepEqual(M.manifestJsonSchema().properties.scopes.items.enum, ['fields.write']);
});

test('plugin events are a subset of the event bus', () => {
  for (const e of M.EVENTS) assert.ok(bus.EVENTS.includes(e), e);
});

test('the signed bytes ignore key order and the signature itself', () => {
  const a = base();
  const reorder = (v) => Array.isArray(v) ? v.map(reorder)
    : (v && typeof v === 'object') ? Object.fromEntries(Object.keys(v).reverse().map(k => [k, reorder(v[k])])) : v;
  const b = reorder(a);
  assert.notEqual(JSON.stringify(a), JSON.stringify(b));
  b.signature = 'A'.repeat(86) + '==';
  assert.equal(M.canonicalJSON(a), M.canonicalJSON(b));
  assert.ok(!M.canonicalJSON(b).includes('signature'));
});

test('the JSON Schema states the same keys and enums as the validator', () => {
  const s = M.manifestJsonSchema();
  assert.deepEqual(Object.keys(s.properties).sort(), M.TOP_KEYS.slice().sort());
  assert.deepEqual(s.properties.scopes.items.enum, M.SCOPES);
  assert.deepEqual(s.properties.events.items.properties.event.enum, M.EVENTS);
  assert.deepEqual(s.properties.fields.items.properties.type.enum, M.FIELD_TYPES);
  assert.deepEqual(s.properties.actions.items.properties.send.items.anyOf[0].enum, Object.keys(M.SENDABLE_FIELDS));
  JSON.parse(JSON.stringify(s));
});

// ── payloads ─────────────────────────────────────────────────────────────

test('a POST sends exactly its `send` list, in canonical bytes', () => {
  const r = P.payloadFor(base(), { action: 'ship' }, { order, customer });
  assert.equal(r.ok, true);
  assert.equal(r.method, 'POST');
  assert.equal(r.url, 'https://api.example.com/v1/shipments');
  assert.deepEqual(r.auth, { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' });
  const body = JSON.parse(r.body);
  assert.deepEqual(Object.keys(body.data).sort(), base().actions[0].send.slice().sort());
  assert.equal(body.data['customer.phone'], '+966500000000');
  assert.equal(body.data['field.service'], 'exp');
  assert.deepEqual(body.trigger, { action: 'ship' });
  // Same input, same bytes — whichever device builds it.
  assert.equal(P.payloadFor(base(), { action: 'ship' }, { order: clone(order), customer: clone(customer) }).body, r.body);
  assert.ok(!r.body.includes('Walk-in'), 'customer.name comes from the customer record when there is one');
});

test('a job with no customer record still has a name', () => {
  const r = P.payloadFor(base(), { action: 'ship' }, { order, customer: null });
  assert.equal(JSON.parse(r.body).data['customer.name'], 'Walk-in name');
  assert.equal(JSON.parse(r.body).data['customer.phone'], null);
});

test('an open link encodes book values and cannot be steered off its host', () => {
  const r = P.payloadFor(base(), { action: 'track' }, { order });
  assert.deepEqual(r, { ok: true, method: 'OPEN', url: 'https://track.example.com/t/AWB%2012%2F34' });
  const m = base(); m.actions[1].url = 'https://track.example.com/{field.awb}';
  const evil = clone(order); evil.plugins['com.example.ship'].awb = '@evil.com/x';
  const u = P.urlFor(m, { action: 'track' }, { order: evil });
  assert.equal(u.ok, true);
  assert.equal(new URL(u.url).host, 'track.example.com');
});

test('a secret in a POST URL must be path-safe, and is never percent-mangled', () => {
  const slack = samples.find(s => s.file === 'slack-notifier.json').m;
  const ok = P.payloadFor(slack, { event: 'order_created' }, { order, customer, secrets: { webhookPath: 'T000/B000/XXXX' } });
  assert.equal(ok.url, 'https://hooks.slack.com/services/T000/B000/XXXX');
  assert.equal(JSON.parse(ok.body).text, 'New job INV-2026-0003: Rack & legs / v2 for Noura (115.5 SAR)');
  for (const bad of ['../../x', 'a/../b', 'x?y=1', 'x#y', 'a@b', '']) {
    assert.equal(P.urlFor(slack, { event: 'order_created' }, { order, secrets: { webhookPath: bad } }).ok, false, bad);
  }
});

test('a template keeps a lone value\'s type', () => {
  const m = base();
  m.actions[0].body = { format: 'json-template', template: { amount: '{order.total}', ref: 'Job {order.number}', items: [{ n: '{order.number}' }] } };
  assert.deepEqual(M.validateManifest(m).errors, []);
  const body = JSON.parse(P.payloadFor(m, { action: 'ship' }, { order, customer }).body);
  assert.deepEqual(body, { amount: 115.5, ref: 'Job INV-2026-0003', items: [{ n: 'INV-2026-0003' }] });
});

test('a reply fills only its own fields, of the right type', () => {
  const m = base();
  m.fields.push({ key: 'weight', label: { en: 'Weight' }, type: 'number', attach: 'order' });
  m.actions[0].response.fields.weight = 'data.kg';
  const entry = { id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m) };
  assert.deepEqual(P.applyResponse(m, 'ship', { data: { awb: 'A1', kg: '2.5', status: 'x' } }, entry), { awb: 'A1', weight: 2.5 });
  assert.deepEqual(P.applyResponse(m, 'ship', { data: { awb: { nested: 1 }, kg: 'heavy' } }, entry), {});
  assert.deepEqual(P.applyResponse(m, 'nope', { data: { awb: 'A1' } }, entry), {});
  // No fields.write granted, no entry, or a paused entry: nothing is written.
  const noWrite = Object.assign({}, entry, { granted: Object.assign({}, entry.granted, { scopes: [] }) });
  assert.deepEqual(P.applyResponse(m, 'ship', { data: { awb: 'A1' } }, noWrite), {});
  assert.deepEqual(P.applyResponse(m, 'ship', { data: { awb: 'A1' } }), {});
  const widened = clone(m); widened.version = '1.3.0'; widened.actions[0].send.push('customer.email');
  assert.deepEqual(P.applyResponse(widened, 'ship', { data: { awb: 'A1' } },
    Object.assign({}, entry, { manifest: widened, version: '1.3.0' })), {});
});

test('an unknown trigger builds nothing', () => {
  assert.equal(P.payloadFor(base(), { action: 'nope' }, { order }).ok, false);
  assert.equal(P.payloadFor(base(), { event: 'order_created' }, { order }).ok, false);
});

test('a reply that writes fields must ask for fields.write', () => {
  const m = base(); m.scopes = [];
  assert.ok(M.validateManifest(m).errors.some(e => e.includes('fields.write')));
});

test('a stored entry: the manifest travels whole, and a grant cannot exceed it', () => {
  const m = base();
  const entry = { id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m), config: {} };
  assert.deepEqual(M.checkEntry(entry), { ok: true, errors: [], paused: false });
  // A book edited to grant a host the signed manifest never named.
  const forged = clone(entry); forged.granted.domains.push('evil.example.org');
  const r = M.checkEntry(forged);
  assert.equal(r.ok, false); assert.equal(r.paused, true);
  assert.ok(r.errors.some(e => e.includes('evil.example.org')));
  // A stored "reviewed" flag is not a thing.
  assert.equal(M.checkEntry(Object.assign({}, entry, { reviewed: true })).ok, false);
  // Never granted: paused until the shop agrees.
  assert.equal(M.checkEntry(Object.assign({}, entry, { granted: undefined })).paused, true);
  // id/version must be the manifest's.
  assert.equal(M.checkEntry(Object.assign({}, entry, { version: '9.9.9' })).ok, false);
});

test('every shipped sample is signed by a published key, and tampering breaks it', () => {
  const { verify } = require('../scripts/sign-connector');
  for (const { file, m } of samples) {
    assert.ok(verify(m), `${file} is not signed by a key in SIGNING_KEYS`);
    const t = clone(m); (t.events || t.actions)[0].url += 'x';
    assert.equal(verify(t), null, `${file}: a changed URL still verified`);
    const w = clone(m); w.name.en += ' ';
    assert.equal(verify(w), null);
  }
  for (const k of M.SIGNING_KEYS) assert.equal(Buffer.from(k.key, 'base64').length, 32, k.id);
});

test('a customer as the editors save it: nameEn/nameAr and an address book', () => {
  const saved = { id: 'c2', nameEn: '', nameAr: 'نورة', phone: '+966511111111',
    addresses: [{ id: 'A1', label: 'Home', address: '' }, { id: 'A2', label: 'Work', address: 'Olaya St, Riyadh' }] };
  let data = JSON.parse(P.payloadFor(base(), { action: 'ship' }, { order, customer: saved }).body).data;
  assert.equal(data['customer.name'], 'نورة');
  assert.equal(data['customer.address'], 'Olaya St, Riyadh');
  // English first, then Arabic, then a CSV `name`; a plain address wins over the book.
  data = JSON.parse(P.payloadFor(base(), { action: 'ship' }, { order,
    customer: { nameEn: 'Noura', nameAr: 'نورة', name: 'old', address: 'Plain', addresses: [{ address: 'Book' }] } }).body).data;
  assert.equal(data['customer.name'], 'Noura');
  assert.equal(data['customer.address'], 'Plain');
  // A customer button has no order to fall back on, and still gets the name.
  const m = base();
  m.actions.push({ id: 'card', label: { en: 'Card' }, placement: 'customer', kind: 'post',
    url: 'https://api.example.com/v1/cards', send: ['customer.name'] });
  data = JSON.parse(P.payloadFor(m, { action: 'card' }, { customer: saved }).body).data;
  assert.equal(data['customer.name'], 'نورة');
});

// ── settings and the Lamha showcase ───────────────────────────────────────

test('settings: typed, kinded, capped; categories come from the kind', () => {
  const m = base();
  m.settings = [
    { key: 'sender', label: { en: 'Sender' }, type: 'text', kind: 'phone', required: true },
    { key: 'sheet', label: { en: 'Sheet' }, type: 'text' },
  ];
  m.actions[0].send.push('config.sender', 'config.sheet');
  assert.deepEqual(M.validateManifest(m).errors, []);
  const rows = M.consentRows(m).find(r => r.host === 'api.example.com').fields;
  assert.deepEqual(rows.filter(f => f.key.startsWith('config.')),
    [{ key: 'config.sender', category: 'contact.phone' }, { key: 'config.sheet', category: 'content.other' }]);
  for (const bad of [
    x => { x.settings[0].kind = 'contact.phone'; },        // categories are the lib's
    x => { x.settings[0].type = 'number'; },               // only text can be a phone
    x => { x.settings[1].secret = true; },
    x => { x.actions[0].send.push('config.nope'); },
  ]) { const c = clone(m); bad(c); assert.equal(M.validateManifest(c).ok, false); }
  // A config value in an open link is listed under that link's host.
  const o = clone(m); o.actions[1].url = 'https://track.example.com/t/{config.sheet}';
  assert.deepEqual(M.validateManifest(o).errors, []);
  assert.ok(M.consentRows(o).find(r => r.host === 'track.example.com').fields.some(f => f.key === 'config.sheet'));
});

test('a required setting left empty stops the request and says which', () => {
  const m = base();
  m.settings = [{ key: 'sender', label: { en: 'Sender' }, type: 'text', required: true }];
  m.actions[0].send.push('config.sender');
  assert.deepEqual(P.payloadFor(m, { action: 'ship' }, { order, customer, config: {} }),
    { ok: false, error: 'setting sender is not set' });
  // Over the cap is unset, not truncated.
  assert.equal(P.payloadFor(m, { action: 'ship' }, { order, customer, config: { sender: 'x'.repeat(501) } }).ok, false);
  const ok = P.payloadFor(m, { action: 'ship' }, { order, customer, config: { sender: 'Athar' } });
  assert.equal(JSON.parse(ok.body).data['config.sender'], 'Athar');
  // A stored value that is not a setting, or too long, fails the entry check.
  const entry = { id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m), config: { other: 1 } };
  assert.equal(M.checkEntry(entry).ok, false);
});

test('Lamha: the request is Lamha\'s create-order shape and books no shipment', () => {
  const lamha = samples.find(s => s.file === 'lamha-shipping.json').m;
  const customerRec = { id: 'c9', nameEn: 'Sara A.', phone: '+966500000000', email: 's@example.com',
    addresses: [{ label: 'Home', address: 'King Fahd Rd' }], plugins: { 'app.khayt.samples.lamha': { city: 'Riyadh' } } };
  const job = { id: 'INV-2026-0107-ab12', invoiceNumber: 'INV-2026-0107', date: '2026-11-08', project: 'Bracket set',
    price: 115.5, currency: 'SAR', qty: 2 };
  const config = { senderName: 'Athar Tuwaiq', senderPhone: '+966511111111', senderCity: 'Riyadh',
    senderAddress: 'Tuwaiq St', carrierId: '7' };
  const r = P.payloadFor(lamha, { action: 'record' }, { order: job, customer: customerRec, config });
  assert.equal(r.ok, true);
  assert.equal(r.url, 'https://app.lamha.sa/api/v2/create-order');
  assert.deepEqual(r.auth, { header: 'X-LAMHA-TOKEN', scheme: '', secret: 'apiToken' });
  const body = JSON.parse(r.body);
  assert.equal(body.create_shippment, false, 'the sample must never book a shipment');
  assert.equal(body.order_id, 'INV-2026-0107');
  assert.equal(body.total, 115.5);
  assert.deepEqual(body.shipper, { name: 'Athar Tuwaiq', phone: '+966511111111', Country: 'SA', City: 'Riyadh', AddressLine1: 'Tuwaiq St' });
  assert.deepEqual(body.customer, { name: 'Sara A.', phone: '+966500000000', phone1: '+966500000000',
    email: 's@example.com', Country: 'SA', City: 'Riyadh', AddressLine1: 'King Fahd Rd' });
  assert.deepEqual(body.items, [{ name: 'Bracket set', quantity: 2, amount: 115.5, weight: '1' }]);
  // Lamha's answer (fixture from the studio's integration): order_id → the job's own field.
  const entry = { id: lamha.id, version: lamha.version, enabled: true, manifest: lamha, granted: M.grantFor(lamha), config };
  assert.deepEqual(P.applyResponse(lamha, 'record', { success: true, order_id: 48213 }, entry), { lamhaOrderId: '48213' });
  // No sender set: nothing is sent.
  assert.equal(P.payloadFor(lamha, { action: 'record' }, { order: job, customer: customerRec, config: {} }).ok, false);
  // The consent screen files the sender's details as contact info.
  const cats = M.permissionsOf(lamha).categories;
  for (const c of ['contact.name', 'contact.phone', 'contact.address', 'contact.email']) assert.ok(cats.includes(c), c);
});
