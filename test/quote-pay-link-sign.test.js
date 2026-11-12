'use strict';

/**
 * The desktop's half of the quote pay link: the HMAC and the secret, in the
 * main process (lib/main/quote-pay-link-sign.js). What is signed is the shared
 * rule's (lib/quote-pay-link.js, test/quote-pay-link.test.js); this checks
 * that main refuses without a usable secret, that what it signs verifies
 * against an independent HMAC of the shared rule's signing input, and that
 * nothing it answers the window with carries the secret.
 *
 * Fake secret and fake store only: 'test-secret-not-real…', https://shop.example.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const L = require('../lib/quote-pay-link.js');
const { signQuotePayLink, registerQuotePayLink } = require('../lib/main/quote-pay-link-sign.js');

const SECRET = 'test-secret-not-real-0123456789abcdef';   // 37 characters, >= SECRET_MIN
const NOW = 1794470400;

function book(over) {
  return {
    settings: { currency: 'SAR', enableVat: false, quotePayLink: { storeUrl: 'https://shop.example' } },
    clients: [{ id: 'C1', nameEn: 'Sara Example', nameAr: 'سارة مثال', phone: '+966500000000', email: 'sara@example.com' }],
    printLog: [Object.assign({
      id: 'QUO-2026-0142-ab3k', jobNumber: 'QUO-2026-0142', status: 'pending', clientId: 'C1',
      quoteAcceptedAt: '2026-11-12', project: 'Dragon', price: 340, paidAmount: 0,
      parts: [{ name: 'dragon-v2.stl', material: 'PLA', color: 'red', qty: 2, printWeight: 450, baseCost: 80 }],
      extraLines: [{ label: 'Design fee', amount: 50 }],
    }, over || {})],
  };
}
const sign = (o) => signQuotePayLink(Object.assign({
  store: book(), orderId: 'QUO-2026-0142-ab3k', secret: SECRET, locale: 'ar', words: {}, nowSeconds: NOW, crypto,
}, o || {}));

/** An independent check of a token: recompute the HMAC over header.payload with the secret. */
function verify(token, secret) {
  const [h, p, s] = token.split('.');
  const want = crypto.createHmac('sha256', Buffer.from(secret, 'utf8')).update(`${h}.${p}`).digest('base64url');
  return { ok: h === L.HEADER && crypto.timingSafeEqual(Buffer.from(s), Buffer.from(want)),
    claims: JSON.parse(Buffer.from(p, 'base64url').toString('utf8')) };
}

test('no secret: refused, and the reason is "not set up"', () => {
  const r = sign({ secret: '' });
  assert.equal(r.ok, false);
  assert.deepEqual(r.blockers.slice(0, 1), ['not_set_up']);
});

test('a secret shorter than the store accepts is no secret', () => {
  const r = sign({ secret: 'test-secret-not-real' });
  assert.equal(r.ok, false);
  assert.ok(r.blockers.includes('not_set_up'));
});

test('no store address: refused', () => {
  const b = book(); b.settings.quotePayLink = {};
  assert.deepEqual(sign({ store: b }).blockers.slice(0, 1), ['not_set_up']);
});

test('a job the book does not have is refused, not guessed', () => {
  assert.deepEqual(sign({ orderId: 'NOPE' }), { ok: false, error: 'no_job' });
});

test('the link it signs verifies, and says what the shared rule says', () => {
  const r = sign();
  assert.equal(r.ok, true);
  const m = /^https:\/\/shop\.example\/sa\/ar\/pay\/([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$/.exec(r.url);
  assert.ok(m, r.url);
  const v = verify(m[1], SECRET);
  assert.equal(v.ok, true, 'the signature checks against the secret');
  assert.equal(verify(m[1], 'test-secret-not-real-but-a-different-one').ok, false, 'and against no other');
  const b = book();
  const expected = L.claimsFor(b.printLog[0], { settings: b.settings, clients: b.clients,
    config: { storeUrl: 'https://shop.example', hasSecret: true }, nowSeconds: NOW, words: { rush: '', extra: '' }, customerName: 'سارة مثال' });
  assert.deepEqual(v.claims, expected);
  assert.deepEqual(v.claims.customer, { name: 'سارة مثال' }, 'the name in the customer\'s language, and nothing else');
  assert.deepEqual(r.record, { issuedAt: NOW, expiresAt: NOW + L.LIFETIME_S, amount: 340 });
});

test('English when asked, with the English name', () => {
  const r = sign({ locale: 'en' });
  assert.match(r.url, /^https:\/\/shop\.example\/sa\/en\/pay\//);
  assert.deepEqual(verify(r.url.split('/pay/')[1], SECRET).claims.customer, { name: 'Sara Example' });
});

test('a re-send is later than the link before it, even in the same second', () => {
  const r = sign({ store: book({ payLink: { issuedAt: NOW, expiresAt: NOW + 604800, amount: 340 } }) });
  assert.equal(r.record.issuedAt, NOW + 1);
});

test('a blocker of the shared rule is passed on (a part with no weight)', () => {
  const r = sign({ store: book({ parts: [{ name: 'bracket-left.stl', qty: 1, baseCost: 10 }] }) });
  assert.equal(r.ok, false);
  assert.ok(r.blockers.includes('no_weight'));
});

test('the IPC: set refuses a short secret, sign answers with a link and never the secret', async () => {
  const handlers = {};
  let disk = book();
  registerQuotePayLink({
    ipcMain: { handle: (ch, fn) => { handlers[ch] = fn; } },
    crypto,
    readBook: () => JSON.parse(JSON.stringify(disk)),
    updateStoreOnDisk: async (mutate) => { disk = mutate(JSON.parse(JSON.stringify(disk))); return disk; },
    now: () => NOW * 1000,
  });
  assert.deepEqual(await handlers['hub:quote-pay-link-set-secret']({}, 'short'), { ok: false, error: 'short' });
  const unsigned = await handlers['hub:quote-pay-link-sign']({}, { orderId: 'QUO-2026-0142-ab3k', locale: 'ar' });
  assert.equal(unsigned.ok, false);

  const set = await handlers['hub:quote-pay-link-set-secret']({}, SECRET);
  assert.deepEqual(set, { ok: true, setAt: new Date(NOW * 1000).toISOString() });
  assert.equal(disk.settings.quotePayLink.secret, SECRET);
  assert.equal(disk.settings.quotePayLink.storeUrl, 'https://shop.example', 'the address is kept');

  const signed = await handlers['hub:quote-pay-link-sign']({}, { orderId: 'QUO-2026-0142-ab3k', locale: 'ar', words: { rush: 'x'.repeat(500) } });
  assert.equal(signed.ok, true);
  assert.equal(verify(signed.url.split('/pay/')[1], SECRET).ok, true);
  assert.equal(JSON.stringify(signed).includes(SECRET), false, 'the answer carries no secret');

  assert.deepEqual(await handlers['hub:quote-pay-link-remove-secret']({}), { ok: true });
  assert.equal('secret' in disk.settings.quotePayLink, false);
  assert.equal('secretSetAt' in disk.settings.quotePayLink, false);
  assert.equal((await handlers['hub:quote-pay-link-sign']({}, { orderId: 'QUO-2026-0142-ab3k' })).ok, false);
});

test('a sealed value main could not open is not used as the key', async () => {
  const handlers = {};
  const disk = book();
  disk.settings.quotePayLink.secret = '__enc__' + 'A'.repeat(60);
  registerQuotePayLink({ ipcMain: { handle: (ch, fn) => { handlers[ch] = fn; } }, crypto,
    readBook: () => disk, updateStoreOnDisk: async () => disk, now: () => NOW * 1000 });
  const r = await handlers['hub:quote-pay-link-sign']({}, { orderId: 'QUO-2026-0142-ab3k' });
  assert.equal(r.ok, false);
  assert.ok(r.blockers.includes('not_set_up'));
});
