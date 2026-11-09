'use strict';
/**
 * Connector lib additions for payment links (L1–L3):
 *   L1  order.amountDue / order.amountDueMinor — what is still owed, mode-aware
 *   L2  auth.encode: "basic"                   — HTTP Basic from one secret
 *   L3  {now.epochMs} / {now.plusDays.N.epochMs} — an expiry, N ≤ 90, from a
 *       clock the platform hands in (lib/ never reads one)
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const M = require('../lib/plugin-manifest');
const P = require('../lib/plugin-payload');
const send = require('../lib/main/plugin-send');

const NOW = Date.UTC(2026, 10, 10, 12, 0, 0);
const DLV = 'dlv_12345678-1234-4123-8123-123456789abc';
const EXCLUSIVE = { currency: 'SAR', tax: { mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
const INCLUSIVE = { currency: 'SAR', tax: { mode: 'inclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };

function base() {
  return {
    khayt: { manifest: 1 },
    id: 'com.example.paylink',
    name: { en: 'Pay link' },
    publisher: 'Example Ltd',
    version: '1.0.0',
    domains: ['api.example.com'],
    secrets: [{ name: 'apiKey', label: { en: 'Secret key' }, kind: 'apiKey' }],
    fields: [{ key: 'linkUrl', label: { en: 'Payment link' }, type: 'text', attach: 'order' }],
    actions: [{
      id: 'link', label: { en: 'Payment link' }, placement: 'order', kind: 'post',
      url: 'https://api.example.com/v1/invoices',
      body: { format: 'json-template', template: {
        amount: '{order.amountDueMinor}', currency: '{order.currency}',
        expires_at: '{now.plusDays.7.epochMs}', created: '{now.epochMs}',
      } },
      auth: { header: 'Authorization', secret: 'apiKey', encode: 'basic' },
      response: { fields: { linkUrl: 'url' } },
    }],
    scopes: ['fields.write'],
  };
}
const errs = (m) => M.validateManifest(m).errors;
const order = (o) => Object.assign({ id: 'o1', price: 100, status: 'pending', currency: 'SAR' }, o);
const body = (p) => JSON.parse(p.body);

test('the payment-link manifest passes', () => {
  assert.deepEqual(errs(base()), []);
});

// ── L1 ────────────────────────────────────────────────────────────────────

test('amountDue is the bill less what was paid: exclusive VAT is added on top', () => {
  const d = P.amountDue({ order: order({ paidAmount: 20 }), settings: EXCLUSIVE });
  assert.deepEqual(d, { amount: 95, minor: 9500, currency: 'SAR' });
});

test('amountDue on an inclusive shop is the price, which already holds the VAT', () => {
  assert.equal(P.amountDue({ order: order(), settings: INCLUSIVE }).amount, 100);
});

test('amountDue nets gift cards and credit notes, and is never negative', () => {
  assert.equal(P.amountDue({ order: order({ giftCardDiscount: 30 }), settings: INCLUSIVE }).amount, 70);
  assert.equal(P.amountDue({ order: order({ paidAmount: 500 }), settings: INCLUSIVE }).amount, 0);
});

test('a quote, a cancelled job or a voided invoice owes nothing', () => {
  for (const o of [{ status: 'quote' }, { status: 'cancelled' }, { voidedAt: '2026-11-01' }]) {
    assert.equal(P.amountDue({ order: order(o), settings: INCLUSIVE }).minor, 0, JSON.stringify(o));
  }
});

test('minor units use the currency\'s own exponent', () => {
  assert.equal(P.amountDue({ order: order({ currency: 'KWD', price: 1.2345 }), settings: INCLUSIVE }).minor, 1235);
  assert.equal(P.amountDue({ order: order({ currency: 'JPY', price: 1500 }), settings: INCLUSIVE }).minor, 1500);
  assert.equal(P.amountDue({ order: order({ currency: 'SAR', price: 10.005 }), settings: INCLUSIVE }).minor, 1001);
  assert.equal(P.minorExponent('BHD'), 3);
  assert.equal(P.minorExponent('EUR'), 2);
});

test('the job\'s currency falls back to its customer\'s, then the shop\'s', () => {
  const o = order({ currency: undefined, clientId: 'c1' });
  assert.equal(P.amountDue({ order: o, customer: { id: 'c1', currency: 'JPY' }, settings: INCLUSIVE }).currency, 'JPY');
  assert.equal(P.amountDue({ order: o, settings: { currency: 'KWD' } }).currency, 'KWD');
});

test('amountDue goes out as a JSON number', () => {
  const p = P.payloadFor(base(), { action: 'link' }, { order: order(), settings: EXCLUSIVE, nowMs: NOW });
  assert.equal(p.ok, true, p.error);
  assert.strictEqual(body(p).amount, 11500);
});

test('without the shop settings, an amount due is refused rather than sent pre-tax', () => {
  const p = P.payloadFor(base(), { action: 'link' }, { order: order(), nowMs: NOW });
  assert.equal(p.ok, false);
  assert.match(p.error, /settings/);
});

test('amountDue is declared on the consent sheet like any job field', () => {
  const perm = M.permissionsOf(base());
  assert.ok(perm.fields.includes('order.amountDueMinor'));
  assert.ok(perm.categories.includes('purchase.history'));
});

// ── L2 ────────────────────────────────────────────────────────────────────

test('encode "basic" is base64 of key + ":" with the Basic scheme', () => {
  const p = P.payloadFor(base(), { action: 'link' }, { order: order(), settings: INCLUSIVE, nowMs: NOW });
  assert.deepEqual(p.auth, { header: 'Authorization', scheme: 'Basic', secret: 'apiKey', encode: 'basic' });
  assert.equal(P.authHeaderValue(p.auth, 'sk_test_abc'), 'Basic ' + Buffer.from('sk_test_abc:').toString('base64'));
  assert.equal(P.authHeaderValue(p.auth, 'user:pässword'), 'Basic ' + Buffer.from('user:pässword').toString('base64'));
});

test('without encode the secret goes as it is', () => {
  assert.equal(P.authHeaderValue({ scheme: 'Bearer' }, 'tok'), 'Bearer tok');
  assert.equal(P.authHeaderValue({ scheme: '' }, 'tok'), 'tok');
  assert.equal(P.authHeaderValue({ scheme: 'Bearer' }, 'a\nb'), null);
});

test('the base64 is right for every UTF-8 width', () => {
  for (const s of ['', 'a', 'ab', 'abc', 'ü', '€', '😀', 'سر:x']) {
    assert.equal(P.base64Utf8(s), Buffer.from(s, 'utf8').toString('base64'), s);
  }
});

test('encode is "basic" or absent', () => {
  const m = base(); m.actions[0].auth.encode = 'base64';
  assert.ok(errs(m).some(e => e.includes('encode')));
});

test('the desktop sender puts the encoded value in the header, with disk settings and its clock', async () => {
  const crypto = require('node:crypto');
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const keys = [{ id: 'test-key', key: publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64') }];
  const unsigned = base();
  const m = Object.assign({}, unsigned, { signature: crypto.sign(null, Buffer.from(M.canonicalJSON(unsigned), 'utf8'), privateKey).toString('base64') });
  const entry = { id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m), config: {}, secrets: { apiKey: 'sk_test_abc' } };
  let seen = null;
  const out = await send.send({ entry, trigger: { action: 'link' }, records: { order: order() }, delivery: DLV, settings: EXCLUSIVE }, {
    keys, now: () => NOW,
    postPinned: async (url, o) => { seen = o; return { ok: true, status: 200, text: '{"url":"https://pay.example.com/x"}' }; },
  });
  assert.equal(out.ok, true, JSON.stringify(out));
  assert.equal(seen.headers.Authorization, 'Basic c2tfdGVzdF9hYmM6');
  assert.strictEqual(JSON.parse(seen.body).amount, 11500);
  assert.strictEqual(JSON.parse(seen.body).expires_at, NOW + 7 * 86400000);
});

// ── L3 ────────────────────────────────────────────────────────────────────

test('{now.epochMs} and {now.plusDays.N.epochMs} come from the clock handed in', () => {
  const p = P.payloadFor(base(), { action: 'link' }, { order: order(), settings: INCLUSIVE, nowMs: NOW });
  assert.strictEqual(body(p).created, NOW);
  assert.strictEqual(body(p).expires_at, NOW + 7 * 86400000);
  const later = P.payloadFor(base(), { action: 'link' }, { order: order(), settings: INCLUSIVE, nowMs: NOW + 1000 });
  assert.strictEqual(body(later).created, NOW + 1000);
});

test('no clock handed in: refused, never read from inside lib/', () => {
  const realNow = Date.now;
  Date.now = () => { throw new Error('lib read the clock'); };
  try {
    const p = P.payloadFor(base(), { action: 'link' }, { order: order(), settings: INCLUSIVE });
    assert.equal(p.ok, false);
    assert.match(p.error, /clock/);
    const ok = P.payloadFor(base(), { action: 'link' }, { order: order(), settings: INCLUSIVE, nowMs: NOW });
    assert.equal(ok.ok, true);
  } finally { Date.now = realNow; }
});

test('N runs from 1 to 90', () => {
  for (const [ref, ok] of [['now.epochMs', true], ['now.plusDays.1.epochMs', true], ['now.plusDays.90.epochMs', true],
    ['now.plusDays.91.epochMs', false], ['now.plusDays.0.epochMs', false], ['now.plusDays.07.epochMs', false],
    ['now.plusDays.100.epochMs', false], ['now.seconds', false]]) {
    const m = base(); m.actions[0].body.template.expires_at = `{${ref}}`;
    assert.equal(errs(m).length === 0, ok, `${ref}: ${errs(m).join('; ')}`);
  }
});

test('the clock is not a field the shop grants', () => {
  const perm = M.permissionsOf(base());
  assert.ok(!perm.fields.some(f => f.startsWith('now.')), perm.fields.join(','));
});

test('the JSON schema accepts what the validator accepts', () => {
  const s = JSON.stringify(M.manifestJsonSchema());
  assert.ok(s.includes('basic'));
  assert.ok(s.includes('plusDays'));
});

// ── Refresh goes out as the Mac sends it ─────────────────────────────────

function signed(m) {
  const crypto = require('node:crypto');
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const keys = [{ id: 'test-key', key: publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64') }];
  return { keys, m: Object.assign({}, m, { signature: crypto.sign(null, Buffer.from(M.canonicalJSON(m), 'utf8'), privateKey).toString('base64') }) };
}
function courier(method) {
  const m = base();
  m.id = 'com.example.courier';
  m.fields.push({ key: 'awb', label: { en: 'AWB' }, type: 'text', attach: 'order' }, { key: 'state', label: { en: 'State' }, type: 'text', attach: 'order' });
  m.refresh = { every: 30, when: 'awb', method, url: 'https://api.example.com/v1/track/{field.awb}',
    auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' }, response: { fields: { state: 'status' } } };
  if (method === 'POST') m.refresh.send = ['order.number'];
  return m;
}

for (const method of ['GET', 'POST']) {
  test(`a ${method} refresh: method, body, Content-Type and X-Khayt-Event as the Mac sends them`, async () => {
    const { m, keys } = signed(courier(method));
    assert.deepEqual(errs(m), []);
    const entry = { id: m.id, version: m.version, enabled: true, manifest: m, granted: M.grantFor(m), config: {}, secrets: { apiKey: 'k' } };
    let seen = null;
    const out = await send.send({ entry, trigger: { refresh: true }, records: { order: order({ plugins: { [m.id]: { awb: 'A1' } } }) }, delivery: DLV, settings: INCLUSIVE }, {
      keys, now: () => NOW, postPinned: async (url, o) => { seen = Object.assign({ url }, o); return { ok: true, status: 200, text: '{"status":"out"}' }; },
    });
    assert.equal(out.ok, true, JSON.stringify(out));
    assert.equal(seen.url, 'https://api.example.com/v1/track/A1');
    assert.equal(seen.method, method);
    assert.equal(seen.headers['X-Khayt-Event'], 'refresh');
    assert.equal(seen.headers['X-Khayt-Delivery'], DLV);
    assert.equal(seen.headers.Authorization, 'Bearer k');
    if (method === 'GET') {
      assert.equal(seen.body, '');
      assert.ok(!('Content-Type' in seen.headers), 'a GET has no Content-Type');
    } else {
      assert.equal(seen.headers['Content-Type'], 'application/json');
      assert.deepEqual(JSON.parse(seen.body).trigger, { refresh: true });
    }
  });
}

test('postPinned sends a GET with no body and no Content-Length', async () => {
  const W = require('../lib/webhook-send');
  const { EventEmitter } = require('node:events');
  let opts = null; let ended = null;
  const request = (o, cb) => {
    opts = o;
    const req = new EventEmitter();
    req.end = (b) => { ended = b; const res = new EventEmitter(); res.statusCode = 200; cb(res); res.emit('data', Buffer.from('{}')); res.emit('end'); };
    return req;
  };
  const r = await W.postPinned('https://api.example.com/x', { method: 'GET', headers: { 'X-Khayt-Event': 'refresh' }, body: 'ignored' },
    { request, lookupAll: async () => [{ address: '93.184.216.34', family: 4 }] });
  assert.equal(r.ok, true);
  assert.equal(opts.method, 'GET');
  assert.ok(!('Content-Length' in opts.headers));
  assert.equal(ended, undefined);
  const p = await W.postPinned('https://api.example.com/x', { body: 'abc' }, { request, lookupAll: async () => [{ address: '93.184.216.34', family: 4 }] });
  assert.equal(p.ok, true);
  assert.equal(opts.method, 'POST');
  assert.equal(opts.headers['Content-Length'], 3);
});
