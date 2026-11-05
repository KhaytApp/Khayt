'use strict';
/**
 * Finishing a Tabby / Tamara payment the shop sent a link for.
 *
 * Khayt made the links and stopped. Tamara expires an approved order the merchant does
 * not authorise within 72 hours; Tabby does not settle a payment the merchant does not
 * capture for 21 days. Tamara was told to notify a static website. The app now asks the
 * provider about each open link, takes the step that is due, and records the payment.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const B = require('../lib/bnpl-confirm');

test('what each provider status asks of the shop', () => {
  const tam = (s) => B.nextStep('tamara', s);
  assert.equal(tam('new'), 'wait');
  assert.equal(tam('approved'), 'authorise', 'within 72 hours, or Tamara expires it');
  for (const s of ['authorised', 'partially_captured', 'fully_captured']) assert.equal(tam(s), 'paid', s);
  for (const s of ['expired', 'declined', 'canceled']) assert.equal(tam(s), 'closed', s);
  const tab = (s) => B.nextStep('tabby', s);
  assert.equal(tab('CREATED'), 'wait');
  assert.equal(tab('AUTHORIZED'), 'capture');
  assert.equal(tab('authorized'), 'capture', 'webhook spelling, case-blind');
  assert.equal(tab('CLOSED'), 'paid');
  for (const s of ['REJECTED', 'EXPIRED']) assert.equal(tab(s), 'closed', s);
});

test('a link is followed by the id each provider\'s later calls take', () => {
  const tam = B.linkRecord('tamara', { ok: true, url: 'u', checkoutId: 'chk-1', orderId: 'ord-12345678' }, { amount: 150, currency: 'sar', at: '2026-10-10T08:00:00Z' });
  assert.deepEqual(tam, { provider: 'tamara', id: 'ord-12345678', amount: 150, currency: 'SAR', createdAt: '2026-10-10T08:00:00Z', state: 'open' });
  const tab = B.linkRecord('tabby', { ok: true, url: 'u', checkoutId: 'sess-1', paymentId: 'pay-12345678' }, { amount: 99.999 });
  assert.equal(tab.id, 'pay-12345678', 'payment.id, not the session id');
  assert.equal(tab.amount, 100);
  assert.equal(B.linkRecord('tamara', { ok: true, checkoutId: 'chk-1' }, {}), null, 'no order_id, nothing to follow');
  assert.equal(B.linkRecord('stripe', { paymentId: 'x' }, {}), null);
  const order = {};
  B.addLink(order, tab); B.addLink(order, { ...tab, amount: 120 });
  assert.equal(order.bnplLinks.length, 1, 'the same payment is listed once');
  assert.equal(order.bnplLinks[0].amount, 120);
});

test('only open links inside the watch window are checked', () => {
  const now = '2026-10-10T12:00:00Z';
  const orders = [
    { id: 'A', bnplLinks: [{ provider: 'tamara', id: 'a', state: 'open', createdAt: '2026-10-10T11:00:00Z' }] },
    { id: 'B', bnplLinks: [{ provider: 'tabby', id: 'b', state: 'paid', createdAt: '2026-10-10T11:00:00Z' }] },
    { id: 'C', bnplLinks: [{ provider: 'tabby', id: 'c', state: 'open', createdAt: '2026-08-01T00:00:00Z' }] },
    { id: 'D' }, null,
  ];
  assert.deepEqual(B.linksToCheck(orders, now).map((x) => x.orderId), ['A']);
});

test('the payment recorded is what was already paid plus the link', () => {
  assert.deepEqual(B.paymentFor({ paidAmount: 50 }, { provider: 'tabby', amount: 100 }, '2026-10-10'),
    { amount: 150, method: 'Tabby', paidAt: '2026-10-10' });
  assert.equal(B.paymentFor({}, { provider: 'tamara', amount: 80 }).method, 'Tamara');
});

// ── the main process: what is sent to each provider ─────────────────────────
function mainHandlers(fetchImpl, key = 'sk_test_disk') {
  const handlers = new Map();
  const realFetch = global.fetch;
  global.fetch = fetchImpl;
  const { registerPaymentLinks } = require('../lib/main/payment-links.js');
  const seenKeys = [];
  registerPaymentLinks({
    ipcMain: { handle: (n, f) => handlers.set(n, f) },
    resolveStoreSecret: (incoming, getter) => { seenKeys.push(incoming); return key; },
  });
  return { check: (args) => handlers.get('hub:bnpl-check')(null, args), capture: (args) => handlers.get('hub:bnpl-capture')(null, args), restore: () => { global.fetch = realFetch; }, seenKeys };
}
const reply = (status, data) => ({ ok: status >= 200 && status < 300, status, json: async () => data });

test('Tamara: an approved order is authorised, and the key comes from disk', async () => {
  const calls = [];
  const h = mainHandlers(async (url, init) => {
    calls.push(`${init.method} ${url}`);
    if (init.method === 'GET') return reply(200, { status: 'approved' });
    return reply(200, { status: 'authorised' });
  });
  try {
    const r = await h.check({ provider: 'tamara', id: 'ord-12345678', apiKey: 'from-the-window' });
    assert.deepEqual(r, { ok: true, state: 'paid', remoteStatus: 'authorised', step: 'authorised' });
    assert.deepEqual(calls, ['GET https://api.tamara.co/merchants/orders/ord-12345678',
      'POST https://api.tamara.co/orders/ord-12345678/authorise']);
    assert.deepEqual(h.seenKeys, [''], 'nothing the window sends is used as a credential');
  } finally { h.restore(); }
});

test('Tamara: a checkout not finished yet is left open, with nothing posted', async () => {
  const calls = [];
  const h = mainHandlers(async (url, init) => { calls.push(init.method); return reply(200, { status: 'new' }); });
  try {
    assert.deepEqual(await h.check({ provider: 'tamara', id: 'ord-12345678' }), { ok: true, state: 'open', remoteStatus: 'new' });
    assert.deepEqual(calls, ['GET']);
  } finally { h.restore(); }
});

test('Tabby: an authorised payment is captured at Tabby\'s own amount, idempotently', async () => {
  const calls = [];
  const h = mainHandlers(async (url, init) => {
    calls.push({ m: init.method, url, body: init.body && JSON.parse(init.body) });
    if (init.method === 'GET') return reply(200, { status: 'AUTHORIZED', amount: '172.50' });
    return reply(200, { status: 'CLOSED' });
  });
  try {
    const r = await h.check({ provider: 'tabby', id: 'pay-12345678', currency: 'AED' });
    assert.deepEqual(r, { ok: true, state: 'paid', remoteStatus: 'CLOSED', step: 'captured' });
    assert.equal(calls[1].url, 'https://api.tabby.ai/api/v2/payments/pay-12345678/captures');
    assert.deepEqual(calls[1].body, { amount: '172.50', reference_id: 'khayt-capture-pay-12345678' });
  } finally { h.restore(); }
});

test('a failed authorise or capture is reported, and an id that could change the URL is refused', async () => {
  const h = mainHandlers(async (url, init) => (init.method === 'GET' ? reply(200, { status: 'AUTHORIZED', amount: '10.00' }) : reply(400, { error: 'bad' })));
  try {
    const r = await h.check({ provider: 'tabby', id: 'pay-12345678' });
    assert.equal(r.ok, false);
    assert.equal(r.remoteStatus, 'AUTHORIZED');
    assert.equal((await h.check({ provider: 'tabby', id: '../../admin' })).error, 'Invalid payment id');
    assert.equal((await h.check({ provider: 'stripe', id: 'pay-12345678' })).error, 'Unknown provider');
  } finally { h.restore(); }
});

// ── the window: a paid link is recorded the way Record Payment records one ──
test('a paid link is recorded on its job once, with the payment rule and its effects', async () => {
  const OP = require('../lib/order-payment');
  const order = { id: 'J1', project: 'Lamp', price: 200, paidAmount: 0,
    bnplLinks: [{ provider: 'tabby', id: 'pay-12345678', amount: 200, currency: 'SAR', createdAt: new Date().toISOString(), state: 'open' }] };
  const effects = [];
  let checks = 0;
  const ctx = {
    console, setTimeout, setInterval, KhaytBnplConfirm: B,
    printLog: [order], settings: { bnpl: { tabby: { enabled: true } } },
    window: { hubAPI: { bnplCheck: async () => { checks++; return { ok: true, state: 'paid', remoteStatus: 'CLOSED' }; } } },
    PaymentRules: () => OP, runPaymentEffects: (o, e) => effects.push(...e.map((x) => x.type)),
    localDateStr: () => '2026-10-10', saveAll() {}, toast() {}, t: (k) => k,
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'bnpl-watch.js'), 'utf8') + ';this.checkBnplLinks = checkBnplLinks;', ctx);
  await ctx.checkBnplLinks();
  assert.equal(order.paidAmount, 200);
  assert.equal(order.paymentMethod, 'Tabby');
  assert.equal(order.paidAt, '2026-10-10');
  assert.equal(order.bnplLinks[0].state, 'paid');
  assert.ok(effects.includes('save') && effects.includes('webhook') && effects.includes('email'), effects.join());
  await ctx.checkBnplLinks();
  assert.equal(checks, 1, 'a paid link is never asked about, or recorded, again');
});

test('nothing is checked when neither Tabby nor Tamara is switched on', async () => {
  let checks = 0;
  const ctx = { console, setTimeout, setInterval, KhaytBnplConfirm: B, settings: { bnpl: {} },
    printLog: [{ id: 'J', bnplLinks: [{ provider: 'tabby', id: 'pay-12345678', state: 'open', createdAt: new Date().toISOString() }] }],
    window: { hubAPI: { bnplCheck: async () => { checks++; return { ok: true, state: 'open' }; } } } };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'bnpl-watch.js'), 'utf8') + ';this.checkBnplLinks = checkBnplLinks;', ctx);
  await ctx.checkBnplLinks();
  assert.equal(checks, 0);
});

// ── Tabby's region, and Tamara's capture at shipment ─────────────────────────
test('a Saudi Tabby link is asked about on api.tabby.sa, any other on api.tabby.ai', async () => {
  assert.equal(B.tabbyBase('SAR'), 'https://api.tabby.sa/api/v2');
  assert.equal(B.tabbyBase('sar'), 'https://api.tabby.sa/api/v2');
  assert.equal(B.tabbyBase('AED'), 'https://api.tabby.ai/api/v2');
  assert.equal(B.tabbyBase('KWD'), 'https://api.tabby.ai/api/v2');
  const urls = [];
  const h = mainHandlers(async (url) => { urls.push(url); return reply(200, { status: 'CREATED' }); });
  try {
    await h.check({ provider: 'tabby', id: 'pay-12345678', currency: 'SAR' });
    await h.check({ provider: 'tabby', id: 'pay-12345678' });   // a link made before currencies were kept: SAR, as the checkout defaults
    assert.deepEqual(urls, ['https://api.tabby.sa/api/v2/payments/pay-12345678', 'https://api.tabby.sa/api/v2/payments/pay-12345678']);
  } finally { h.restore(); }
  const R = require('../lib/bnpl-requests');
  assert.equal(R.plan('checkout', { provider: 'tabby', currency: 'SAR' }, []).request.url, 'https://api.tabby.sa/api/v2/checkout', 'the checkout uses the same host');
  assert.equal(R.plan('checkout', { provider: 'tabby', currency: 'AED' }, []).request.url, 'https://api.tabby.ai/api/v2/checkout');
  for (const f of ['main/payment-links.js', 'bnpl-requests.js']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', f), 'utf8');
    assert.ok(!/'https:\/\/api\.tabby\.ai/.test(src), 'no hard-coded UAE host left in ' + f);
  }
});

// ── the checkout itself: one definition, which the Mac sends too ───────────
function checkoutHandlers(fetchImpl) {
  const handlers = new Map();
  const realFetch = global.fetch;
  global.fetch = fetchImpl;
  const { registerPaymentLinks } = require('../lib/main/payment-links.js');
  registerPaymentLinks({ ipcMain: { handle: (n, f) => handlers.set(n, f) }, resolveStoreSecret: (incoming) => incoming || 'sk_disk' });
  return { tabby: (a) => handlers.get('hub:bnpl-tabby')(null, a), tamara: (a) => handlers.get('hub:bnpl-tamara')(null, a), restore: () => { global.fetch = realFetch; } };
}

test('the Tabby and Tamara checkouts send what they always sent, and read the id a check takes', async () => {
  const seen = [];
  const h = checkoutHandlers(async (url, init) => {
    seen.push({ url, method: init.method, auth: init.headers.Authorization, body: JSON.parse(init.body) });
    return url.includes('tamara')
      ? reply(200, { checkout_url: 'https://checkout.tamara.co/x', checkout_id: 'chk-1', order_id: 'ord-12345678' })
      : reply(200, { id: 'sess-1', payment: { id: 'pay-12345678' }, configuration: { available_products: { installments: [{ web_url: 'https://checkout.tabby.ai/x' }] } } });
  });
  try {
    const args = { amount: 172.5, currency: 'SAR', description: 'Lamp', buyer: { name: 'Sara Al Ahmad', phone: '+966500000000', email: 's@x.test' }, orderId: 'INV-7', itemName: 'Lamp' };
    assert.deepEqual(await h.tabby({ ...args, apiKey: 'k1', merchantCode: 'M1' }),
      { ok: true, url: 'https://checkout.tabby.ai/x', checkoutId: 'sess-1', paymentId: 'pay-12345678' });
    assert.deepEqual(seen[0].url, 'https://api.tabby.sa/api/v2/checkout');
    assert.equal(seen[0].auth, 'Bearer k1');
    assert.deepEqual(seen[0].body, {
      payment: {
        amount: '172.50', currency: 'SAR', description: 'Lamp',
        buyer: { phone: '+966500000000', name: 'Sara Al Ahmad', email: 's@x.test' },
        buyer_history: { registered_since: '2024-01-01T00:00:00Z', loyalty_level: 0 },
        order: { reference_id: 'INV-7', items: [{ title: 'Lamp', unit_price: '172.50', qty: 1, category: '3D Printing', reference_id: 'INV-7' }], tax_amount: '0.00', shipping_amount: '0.00' },
        meta: { order_id: 'INV-7', customer: 'Sara Al Ahmad' },
      },
      lang: 'en', merchant_code: 'M1',
      merchant_urls: { success: 'https://khaytapp.com/success', cancel: 'https://khaytapp.com/cancel', failure: 'https://khaytapp.com/failure' },
    });
    assert.deepEqual(await h.tamara({ ...args, apiKey: 'k2', country: 'sa' }),
      { ok: true, url: 'https://checkout.tamara.co/x', checkoutId: 'chk-1', orderId: 'ord-12345678' });
    assert.equal(seen[1].url, 'https://api.tamara.co/checkout');
    assert.deepEqual(seen[1].body, {
      order_reference_id: 'INV-7', total_amount: { amount: '172.50', currency: 'SAR' }, description: 'Lamp', country_code: 'SA',
      payment_type: 'PAY_BY_INSTALMENTS', instalments: 3,
      items: [{ name: 'Lamp', sku: 'INV-7', quantity: 1, unit_price: { amount: '172.50', currency: 'SAR' }, total_amount: { amount: '172.50', currency: 'SAR' }, type: 'digital' }],
      consumer: { email: 's@x.test', first_name: 'Sara', last_name: 'Al Ahmad', phone_number: '+966500000000' },
      merchant_url: { success: 'https://khaytapp.com/success', failure: 'https://khaytapp.com/failure', cancel: 'https://khaytapp.com/cancel', notification: 'https://khaytapp.com/notify' },
    });
  } finally { h.restore(); }
});

test('a refused checkout says the provider\'s own words', async () => {
  const h = checkoutHandlers(async (url) => (url.includes('tamara') ? reply(422, { message: 'bad phone' }) : reply(401, { error: 'bad key' })));
  try {
    assert.deepEqual(await h.tabby({ apiKey: 'k', amount: 1 }), { ok: false, status: 401, error: 'bad key' });
    assert.deepEqual(await h.tamara({ apiKey: 'k', amount: 1 }), { ok: false, status: 422, error: 'bad phone' });
  } finally { h.restore(); }
});

test('a Tamara link is captured once its job has gone out, inside Tamara\'s 21 days', () => {
  const now = '2026-10-20T12:00:00Z';
  const tam = (over) => ({ provider: 'tamara', id: 'x', state: 'paid', remoteStatus: 'authorised', authorisedAt: '2026-10-10T00:00:00Z', ...over });
  const orders = [
    { id: 'shipped', shippedAt: '2026-10-19T09:00:00Z', bnplLinks: [tam()] },
    { id: 'pickup', deliveredAt: '2026-10-19T09:00:00Z', bnplLinks: [tam()] },
    { id: 'not-out', bnplLinks: [tam()] },
    { id: 'done', shippedAt: '2026-10-19', bnplLinks: [tam({ capturedAt: '2026-10-19T10:00:00Z' })] },
    { id: 'gone', shippedAt: '2026-10-19', bnplLinks: [tam({ captureDone: true })] },
    { id: 'old', shippedAt: '2026-10-19', bnplLinks: [tam({ authorisedAt: '2026-09-20T00:00:00Z' })] },
    { id: 'tabby', shippedAt: '2026-10-19', bnplLinks: [tam({ provider: 'tabby' })] },
    { id: 'open', shippedAt: '2026-10-19', bnplLinks: [tam({ state: 'open' })] },
    { id: 'captured-remote', shippedAt: '2026-10-19', bnplLinks: [tam({ remoteStatus: 'fully_captured' })] },
  ];
  assert.deepEqual(B.linksToCapture(orders, now).map((x) => x.orderId), ['shipped', 'pickup']);
  assert.deepEqual(B.captureShipping({ shippedAt: '2026-10-19T09:00:00Z', courierName: 'SMSA', trackingNumber: ' 123 ', trackingUrl: 'https://t/1' }),
    { shipped_at: '2026-10-19T09:00:00.000Z', shipping_company: 'SMSA', tracking_number: '123', tracking_url: 'https://t/1' });
  assert.deepEqual(B.captureShipping({ deliveredAt: '2026-10-19T09:00:00Z', trackingUrl: 'http://t' }),
    { shipped_at: '2026-10-19T09:00:00.000Z', shipping_company: 'Own delivery' });
});

test('Tamara capture posts Tamara\'s own total with the shipping, and never a captured order twice', async () => {
  const calls = [];
  let status = 'authorised';
  const h = mainHandlers(async (url, init) => {
    calls.push({ m: init.method, url, body: init.body && JSON.parse(init.body) });
    if (init.method === 'GET') return reply(200, { status, total_amount: { amount: 230, currency: 'SAR' } });
    return reply(200, { status: 'fully_captured', capture_id: 'c1' });
  });
  try {
    const shipping = { shipped_at: '2026-10-19T09:00:00Z', shipping_company: 'SMSA', tracking_number: '123', tracking_url: 'javascript:x' };
    const r = await h.capture({ provider: 'tamara', id: 'ord-12345678', shipping });
    assert.deepEqual(r, { ok: true, captured: true, remoteStatus: 'fully_captured' });
    assert.equal(calls[1].url, 'https://api.tamara.co/payments/capture');
    assert.deepEqual(calls[1].body, { order_id: 'ord-12345678', total_amount: { amount: 230, currency: 'SAR' },
      shipping_info: { shipped_at: '2026-10-19T09:00:00.000Z', shipping_company: 'SMSA', tracking_number: '123' } });
    calls.length = 0; status = 'fully_captured';
    assert.deepEqual(await h.capture({ provider: 'tamara', id: 'ord-12345678', shipping }), { ok: true, captured: true, remoteStatus: 'fully_captured' });
    calls.length === 1 || assert.fail('nothing posted for an order already captured');
    status = 'fully_refunded';
    assert.deepEqual(await h.capture({ provider: 'tamara', id: 'ord-12345678', shipping }), { ok: true, captured: false, remoteStatus: 'fully_refunded' });
    assert.equal((await h.capture({ provider: 'tabby', id: 'ord-12345678', shipping })).error, 'Unknown provider');
    assert.equal((await h.capture({ provider: 'tamara', id: '../x', shipping })).error, 'Invalid payment id');
    assert.equal((await h.capture({ provider: 'tamara', id: 'ord-12345678', shipping: {} })).error, 'No shipping date');
  } finally { h.restore(); }
});

test('the window captures a shipped Tamara job once, and says a failure once', async () => {
  const order = { id: 'J9', project: 'Vase', shippedAt: new Date().toISOString(), courierName: 'Aramex',
    bnplLinks: [{ provider: 'tamara', id: 'ord-12345678', state: 'paid', remoteStatus: 'authorised', authorisedAt: new Date().toISOString(), createdAt: new Date().toISOString() }] };
  const toasts = [];
  let reply1 = { ok: false, remoteStatus: 'authorised', error: 'down' };
  let captures = 0;
  const ctx = {
    console, setTimeout, setInterval, KhaytBnplConfirm: B, printLog: [order],
    settings: { bnpl: { tamara: { enabled: true } } },
    window: { hubAPI: { bnplCheck: async () => ({ ok: true, state: 'open' }),
      bnplCapture: async (a) => { captures++; assert.equal(a.shipping.shipping_company, 'Aramex'); return reply1; } } },
    saveAll() {}, toast: (m) => toasts.push(m), t: (k) => k,
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'bnpl-watch.js'), 'utf8') + ';this.checkBnplLinks = checkBnplLinks;', ctx);
  await ctx.checkBnplLinks();
  await ctx.checkBnplLinks();
  assert.equal(captures, 2, 'a failure is retried');
  assert.deepEqual(toasts, ['bnpl.capture_failed'], 'but said once');
  reply1 = { ok: true, captured: true, remoteStatus: 'fully_captured' };
  await ctx.checkBnplLinks();
  assert.ok(order.bnplLinks[0].capturedAt);
  assert.equal(order.bnplLinks[0].captureError, undefined);
  await ctx.checkBnplLinks();
  assert.equal(captures, 3, 'a captured link is never captured again');
});

test('a Tamara authorise starts the 21 days', async () => {
  const order = { id: 'J8', project: 'Cup', price: 100, paidAmount: 0,
    bnplLinks: [{ provider: 'tamara', id: 'ord-12345678', amount: 100, currency: 'SAR', createdAt: new Date().toISOString(), state: 'open' }] };
  const OP = require('../lib/order-payment');
  const ctx = {
    console, setTimeout, setInterval, KhaytBnplConfirm: B, printLog: [order], settings: { bnpl: { tamara: { enabled: true } } },
    window: { hubAPI: { bnplCheck: async () => ({ ok: true, state: 'paid', remoteStatus: 'authorised', step: 'authorised' }), bnplCapture: async () => assert.fail('not shipped') } },
    PaymentRules: () => OP, runPaymentEffects() {}, localDateStr: () => '2026-10-10', saveAll() {}, toast() {}, t: (k) => k,
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'bnpl-watch.js'), 'utf8') + ';this.checkBnplLinks = checkBnplLinks;', ctx);
  await ctx.checkBnplLinks();
  assert.equal(order.bnplLinks[0].authorisedAt, order.bnplLinks[0].checkedAt);
});

// ── settings: the Mac saves through lib/settings-edit.js ────────────────────
test('a settings form carrying bnpl merges per provider; keys absent are kept, empty cleared, Stripe untouched', () => {
  const { apply } = require('../lib/settings-edit.js');
  const stored = { bnpl: {
    tabby: { enabled: false, apiKey: '__enc__a', merchantCode: 'M', currency: 'SAR' },
    tamara: { enabled: true, apiKey: '__enc__b', notificationToken: '__enc__c', currency: 'SAR', country: 'SA' },
    stripe: { enabled: true, apiKey: '__enc__s' },
  } };
  const out = apply(stored, { bnpl: { tabby: { enabled: true, merchantCode: ' M2 ' }, tamara: { notificationToken: '' } } }, { year: 2026 }).bnpl;
  assert.deepEqual(out.tabby, { enabled: true, apiKey: '__enc__a', merchantCode: 'M2', currency: 'SAR' });
  assert.deepEqual(out.tamara, { enabled: true, apiKey: '__enc__b', notificationToken: '', currency: 'SAR', country: 'SA' });
  assert.deepEqual(out.stripe, stored.bnpl.stripe);
  assert.deepEqual(apply(stored, {}, { year: 2026 }).bnpl, stored.bnpl, 'a form without bnpl keeps it as stored');
});

// ── the link is for what is still owed ──────────────────────────────────────
test('a pay-later link asks for what is owed: the tax-on-top bill less the deposit, and none when settled', () => {
  require('../lib/tax.js');
  require('../lib/business-scope.js');
  require('../lib/order-money.js');
  const R = require('../lib/bnpl-requests');
  const EXCL = { currency: 'SAR', tax: { name: 'VAT', mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
    bnpl: { tabby: { merchantCode: 'M1', currency: 'SAR' }, tamara: { country: 'SA' } } };
  // 200 + 15% = 230 billed, 50 deposit paid: 180 owed. It was order.price, 200.
  const order = { id: 'J1', project: 'Lamp', price: 200, paidAmount: 50, status: 'completed', clientId: 'C1', date: '2026-10-01' };
  const clients = [{ id: 'C1', phone: '+9665', email: 'c@x.test' }];
  const tab = R.checkoutArgs(order, 'tabby', { settings: EXCL, clients, buyerName: 'Noura' });
  assert.equal(tab.amount, 180);
  assert.equal(tab.merchantCode, 'M1');
  assert.deepEqual(tab.buyer, { name: 'Noura', phone: '+9665', email: 'c@x.test' });
  assert.equal(tab.description, 'Lamp');
  assert.equal(R.checkoutArgs(order, 'tamara', { settings: EXCL, clients }).country, 'SA');
  // The checkout body carries it.
  assert.equal(R.plan('checkout', tab, []).request.body.payment.amount, '180.00');
  // Settled: no link for nothing.
  assert.deepEqual(R.checkoutArgs({ ...order, paidAmount: 230 }, 'tabby', { settings: EXCL, clients }), { refused: 'nothing_owed' });
  // An inclusive (or untaxed) shop: the price is the bill.
  assert.equal(R.checkoutArgs(order, 'tabby', { settings: { currency: 'SAR' }, clients }).amount, 150);
  // The desktop dialog builds from this, not from order.price.
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'integrations.js'), 'utf8');
  assert.match(src, /KhaytBnplRequests\.checkoutArgs\(order, svc\.id, bnplCtx\)/);
  assert.ok(!/const amount = \+order\.price/.test(src), 'no link for the bare price');
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8'), /<script src="\.\.\/lib\/bnpl-requests\.js"><\/script>/);
});

// ── Tabby hears who the customer is to the shop ────────────────────────────
test('a Tabby checkout carries the customer\'s real history, not a fixed 2024 date', () => {
  require('../lib/tax.js');
  require('../lib/business-scope.js');
  require('../lib/order-money.js');
  const R = require('../lib/bnpl-requests');
  const S = { currency: 'SAR', bnpl: { tabby: { merchantCode: 'M1' } } };
  const order = { id: 'J9', price: 100, status: 'completed', clientId: 'C1', date: '2026-10-01' };
  const orders = [
    order,
    { id: 'J1', clientId: 'C1', status: 'completed', date: '2023-03-04' },
    { id: 'J2', clientId: 'C1', status: 'completed', date: '2025-01-01' },
    { id: 'J3', clientId: 'C1', status: 'cancelled', date: '2022-01-01' },
    { id: 'J4', clientId: 'C2', status: 'completed', date: '2020-01-01' },
  ];
  // The record's own date wins when it is earlier than every job.
  let h = R.checkoutArgs(order, 'tabby', { settings: S, clients: [{ id: 'C1', createdAt: '2021-06-15' }], orders }).buyerHistory;
  assert.deepEqual(h, { registeredSince: '2021-06-15T00:00:00Z', loyaltyLevel: 2 });
  // A record made after their first job: the first job is when the shop met them.
  // (A cancelled job still dates the meeting; only completed ones are loyalty.)
  h = R.checkoutArgs(order, 'tabby', { settings: S, clients: [{ id: 'C1', createdAt: '2026-01-01' }], orders }).buyerHistory;
  assert.equal(h.registeredSince, '2022-01-01T00:00:00Z');
  // No record and no other jobs: this job's date; not this job in its own loyalty.
  h = R.checkoutArgs({ ...order, clientId: null, client: 'Walk-in' }, 'tabby', { settings: S, clients: [], orders }).buyerHistory;
  assert.deepEqual(h, { registeredSince: '2026-10-01T00:00:00Z', loyaltyLevel: 0 });
  // The body sends it.
  const body = R.plan('checkout', R.checkoutArgs(order, 'tabby', { settings: S, clients: [{ id: 'C1', createdAt: '2021-06-15T09:30:00.000Z' }], orders }), []).request.body;
  assert.deepEqual(body.payment.buyer_history, { registered_since: '2021-06-15T09:30:00Z', loyalty_level: 2 });
  // Tamara has no such field: nothing added.
  assert.equal(R.checkoutArgs(order, 'tamara', { settings: S, clients: [], orders }).buyerHistory, undefined);
  // The desktop's main process passes it through, and the dialog hands it the book.
  const ipc = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main', 'payment-links.js'), 'utf8');
  assert.match(ipc, /provider: 'tabby', merchantCode, amount, currency, description, buyer, orderId, itemName, buyerHistory \}/);
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'integrations.js'), 'utf8'), /bnplCtx = \{ settings, clients, orders: printLog/);
});

// ── Stripe: a custom redirect URL is kept, a private one is not ─────────────
test('Stripe keeps a shop\'s own https success and cancel URLs, and refuses private ones', async () => {
  const handlers = new Map();
  const realFetch = global.fetch;
  const sent = [];
  global.fetch = async (url, init) => { sent.push(new URLSearchParams(init.body)); return reply(200, { url: 'https://checkout.stripe.com/x', id: 'cs_1' }); };
  try {
    const { registerPaymentLinks } = require('../lib/main/payment-links.js');
    registerPaymentLinks({ ipcMain: { handle: (n, f) => handlers.set(n, f) }, resolveStoreSecret: (incoming) => incoming });
    const stripe = (a) => handlers.get('hub:bnpl-stripe')(null, { apiKey: 'sk_test_1', amount: 10, ...a });
    assert.equal((await stripe({ successUrl: 'https://shop.example/thanks', cancelUrl: 'https://shop.example/back' })).ok, true);
    assert.equal(sent[0].get('success_url'), 'https://shop.example/thanks');
    assert.equal(sent[0].get('cancel_url'), 'https://shop.example/back');
    await stripe({ successUrl: 'https://127.0.0.1/x', cancelUrl: 'https://192.168.1.5/y' });
    assert.equal(sent[1].get('success_url'), 'https://khaytapp.com/success');
    assert.equal(sent[1].get('cancel_url'), 'https://khaytapp.com/cancel');
  } finally { global.fetch = realFetch; }
});
