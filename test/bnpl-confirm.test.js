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
  return { check: (args) => handlers.get('hub:bnpl-check')(null, args), restore: () => { global.fetch = realFetch; }, seenKeys };
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
    const r = await h.check({ provider: 'tabby', id: 'pay-12345678' });
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
