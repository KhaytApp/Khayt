'use strict';

/**
 * lib/quote-pay-link.js — what Khayt signs when a shop sends a customer a
 * link to pay an approved quote on its web store.
 *
 * The contract is the store's: docs/quote-pay-link.md in the athartuwaiq3d
 * repository (branch quote-pay-links, 9ddee49). Its test vector is pinned
 * below byte for byte; the store's own suite checks the same bytes.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHmac } = require('node:crypto');
require('../lib/tax.js');
require('../lib/order-money.js');
const L = require('../lib/quote-pay-link.js');

/** What a device does: HMAC-SHA256 over the signing input, key = the secret's UTF-8 bytes. */
const hmac = (input, secret) => Array.from(createHmac('sha256', Buffer.from(secret, 'utf8')).update(input).digest());

// ── The store's vector (never a real secret) ───────────────────────────────
const VECTOR_SECRET = 'khayt-quote-link-test-vector-secret-0001';
const VECTOR_PAYLOAD = '{"v":1,"quote_id":"q_01JCQ7Z3K8M2V5X9T4N6P0R1S2","ref":"AT-Q-0142","currency":"SAR","prices_include_vat":false,"items":[{"title":"dragon-v2.stl","spec":"PLA, red and yellow, 180 mm","quantity":2,"unit_amount":14500,"weight_grams":450},{"title":"Design fee","quantity":1,"unit_amount":5000,"weight_grams":0}],"lead_time_days":{"min":5,"max":7},"customer":{"name":"Sara Example"},"shipping":"lamha","iat":1794470400,"exp":1795075200}';
const VECTOR_HMAC_HEX = '3455fc2af4dfbf04c976e9a63bd11369ea0b020f6a7d4e1fd9dfb85ee779402c';
const VECTOR_SIGNATURE = 'NFX8KvTfvwTJdummO9ETaeoLAg9qfU4f2d-4Xud5QCw';

const CONFIG = { storeUrl: 'https://athartuwaiq3d.com', hasSecret: true };
const SETTINGS = { currency: 'SAR', enableVat: false };
const NOW = 1794470400;

/** An approved, unpaid job that began as a quote: two dragons and a design fee. */
function job(over) {
  return Object.assign({
    id: 'QUO-2026-0142-ab3k', jobNumber: 'QUO-2026-0142', status: 'pending',
    quoteAcceptedAt: '2026-11-12', project: 'Dragon', price: 340, paidAmount: 0,
    parts: [{ name: 'dragon-v2.stl', material: 'PLA', color: 'red', qty: 2, printWeight: 450, baseCost: 80 }],
    extraLines: [{ label: 'Design fee', amount: 50 }],
  }, over || {});
}
const ctx = (over) => Object.assign({ settings: SETTINGS, clients: [], config: CONFIG, nowSeconds: NOW }, over || {});

test('the store\'s test vector: the same bytes signed give the same token', () => {
  const claims = JSON.parse(VECTOR_PAYLOAD);
  // The claims serialise back to the vector's exact bytes, so key order held.
  assert.equal(JSON.stringify(claims), VECTOR_PAYLOAD);
  const input = L.signingInput(claims);
  assert.equal(input.split('.')[0], 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9');
  assert.equal(input.split('.')[1], Buffer.from(VECTOR_PAYLOAD).toString('base64url'));
  const mac = hmac(input, VECTOR_SECRET);
  assert.equal(Buffer.from(mac).toString('hex'), VECTOR_HMAC_HEX);
  const token = L.tokenFrom(input, mac);
  assert.equal(token, `${input}.${VECTOR_SIGNATURE}`);
  // A device may hand the signature back as text instead of bytes.
  assert.equal(L.tokenFrom(input, VECTOR_SIGNATURE), token);
  assert.equal(L.urlFor(CONFIG.storeUrl, 'ar', token), `https://athartuwaiq3d.com/sa/ar/pay/${token}`);
});

test('a job builds the claims the store reads, in the store\'s key order', () => {
  const claims = L.claimsFor(job(), ctx({ customerName: 'Sara Example', leadDays: { min: 5, max: 7 } }));
  assert.deepEqual(Object.keys(claims), ['v', 'quote_id', 'ref', 'currency', 'prices_include_vat', 'items',
    'lead_time_days', 'customer', 'shipping', 'iat', 'exp']);
  assert.deepEqual(claims.items, [
    { title: 'dragon-v2.stl', spec: 'PLA, red', quantity: 2, unit_amount: 14500, weight_grams: 450 },
    { title: 'Design fee', quantity: 1, unit_amount: 5000, weight_grams: 0 },
  ]);
  assert.equal(claims.quote_id, 'QUO-2026-0142-ab3k');
  assert.equal(claims.ref, 'QUO-2026-0142');
  assert.equal(claims.prices_include_vat, false);
  assert.equal(claims.exp - claims.iat, 7 * 24 * 60 * 60);
  assert.equal(L.amountOf(claims), 340);
  assert.deepEqual(L.recordOf(claims), { issuedAt: NOW, expiresAt: NOW + 604800, amount: 340 });
});

test('only the name goes with it: no email, no phone, whatever the device holds', () => {
  const claims = L.claimsFor(job({ clientEmail: 'sara@example.com', phone: '+966500000000' }),
    ctx({ customerName: 'Sara Example', customerEmail: 'sara@example.com', customerPhone: '+966500000000' }));
  assert.deepEqual(claims.customer, { name: 'Sara Example' });
  const text = JSON.stringify(claims);
  assert.equal(text.includes('@'), false);
  assert.equal(text.includes('9665'), false);
  // No name known: no customer block at all.
  assert.equal('customer' in L.claimsFor(job(), ctx()), false);
});

test('the lines add up to the quote in whole halalas, whatever the shares come to', () => {
  // 100.00 over three parts of equal cost: 33.33 + 33.33 + 33.33 is 99.99.
  const three = job({ price: 100, extraLines: [], parts: [1, 2, 3].map((n) => ({ name: `p${n}`, qty: 1, printWeight: 10, baseCost: 5 })) });
  const a = L.linesFor(three);
  assert.deepEqual(a.problems, []);
  assert.deepEqual(a.items.map((i) => i.unit_amount), [3334, 3333, 3333]);
  assert.equal(L.totalOf(a.items), 10000);

  // Many shapes: the sum is always price − delivery, to the halala.
  let seed = 7;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  for (let run = 0; run < 400; run++) {
    const parts = Array.from({ length: 1 + rnd(6) }, (_, k) => {
      const p = { name: `part ${k}`, qty: 1 + rnd(7), printWeight: 1 + rnd(900), baseCost: rnd(4) ? rnd(20000) / 100 : 0 };
      if (rnd(5) === 0) p.agreedPrice = rnd(5000) / 100;
      return p;
    });
    const extras = Array.from({ length: rnd(3) }, (_, k) => ({ label: `fee ${k}`, amount: rnd(3000) / 100 }));
    const rush = rnd(3) === 0 ? rnd(4000) / 100 : 0;
    const delivery = rnd(2) ? rnd(5000) / 100 : 0;
    const fees = extras.reduce((s, l) => s + Math.round(l.amount * 100), 0) + Math.round(rush * 100);
    const price = (fees + Math.round(delivery * 100) + rnd(200000)) / 100;
    const o = job({ price, parts, extraLines: extras, rushFeeAmount: rush, shippingCost: delivery });
    const r = L.linesFor(o);
    assert.deepEqual(r.problems, [], `run ${run}`);
    assert.equal(L.totalOf(r.items), Math.round(price * 100) - Math.round(delivery * 100), `run ${run}: the sum`);
    for (const it of r.items) {
      assert.ok(Number.isInteger(it.unit_amount) && it.unit_amount >= 0, `run ${run}: whole halalas`);
      assert.ok(Number.isInteger(it.quantity) && it.quantity >= 1, `run ${run}`);
      assert.ok(Number.isInteger(it.weight_grams) && it.weight_grams >= 0, `run ${run}: a weight on every line`);
    }
  }
});

test('a line that does not divide by its count is sent whole, with the weight of all its pieces', () => {
  // 100.00 for three pieces is 33.33 each and one halala over.
  const o = job({ price: 100, extraLines: [], parts: [{ name: 'bracket', material: 'PETG', qty: 3, printWeight: 40, baseCost: 9 }] });
  assert.deepEqual(L.linesFor(o).items, [
    { title: 'bracket', spec: 'PETG, × 3', quantity: 1, unit_amount: 10000, weight_grams: 120 },
  ]);
  // 99.00 does divide: the count stays a count and the weight is one piece's.
  assert.deepEqual(L.linesFor(job({ price: 99, extraLines: [], parts: o.parts })).items, [
    { title: 'bracket', spec: 'PETG', quantity: 3, unit_amount: 3300, weight_grams: 40 },
  ]);
});

test('a part the customer agreed a price for is charged that price; the rest share what is left', () => {
  const o = job({ price: 300, extraLines: [], parts: [
    { name: 'agreed', qty: 2, printWeight: 10, agreedPrice: 50 },
    { name: 'a', qty: 1, printWeight: 10, baseCost: 30 },
    { name: 'b', qty: 1, printWeight: 10, baseCost: 10 },
  ] });
  assert.deepEqual(L.linesFor(o).items.map((i) => [i.title, i.quantity, i.unit_amount]),
    [['agreed', 2, 5000], ['a', 1, 15000], ['b', 1, 5000]]);
});

test('fees are their own lines and ship nothing; delivery on the quote is left out and reported', () => {
  const o = job({ price: 425, shippingCost: 25, rushFeeAmount: 60, extraLines: [{ label: 'Design fee', amount: 50 }, { label: '', amount: 10 }] });
  const r = L.linesFor(o, { rush: 'رسوم استعجال', extra: 'رسوم إضافية' });
  assert.deepEqual(r.problems, []);
  assert.deepEqual(r.items.slice(1), [
    { title: 'Design fee', quantity: 1, unit_amount: 5000, weight_grams: 0 },
    { title: 'رسوم إضافية', quantity: 1, unit_amount: 1000, weight_grams: 0 },
    { title: 'رسوم استعجال', quantity: 1, unit_amount: 6000, weight_grams: 0 },
  ]);
  assert.equal(L.totalOf(r.items), 40000, 'the 25.00 delivery is not charged by the link');
  assert.equal(L.deliveryOnQuote(o), 25);
  assert.equal(L.deliveryOnQuote(job()), 0);
});

test('a part with no weight blocks the link: the store would guess a kilo', () => {
  const o = job({ parts: [{ name: 'unsliced.stl', qty: 1, baseCost: 10 }] });
  assert.deepEqual(L.linesFor(o).problems, ['no_weight']);
  assert.ok(L.blockers(o, ctx()).includes('no_weight'));
  assert.equal(L.claimsFor(o, ctx()), null);
  assert.ok(L.blockers(job({ parts: [] }), ctx()).includes('no_parts'));
});

test('when a link may not be offered, and why', () => {
  const why = (over, c) => L.blockers(job(over), ctx(c));
  assert.deepEqual(why(), []);
  assert.deepEqual(why({}, { config: { storeUrl: 'https://athartuwaiq3d.com', hasSecret: false } }), ['not_set_up']);
  assert.deepEqual(why({}, { config: { storeUrl: 'http://athartuwaiq3d.com', hasSecret: true } }), ['not_set_up'], 'https only');
  assert.deepEqual(why({}, { config: null }), ['not_set_up']);
  assert.deepEqual(why({ status: 'quote', quoteAcceptedAt: undefined }), ['not_a_quote'], 'still waiting for its answer');
  assert.deepEqual(why({ quoteAcceptedAt: undefined }), ['not_a_quote'], 'never a quote');
  assert.deepEqual(why({ quoteAcceptedAt: undefined, clientApprovedAt: '2026-11-12' }), [], 'approved by the customer online');
  assert.ok(why({ status: 'cancelled' }).includes('closed'));
  assert.ok(why({ voidedAt: '2026-11-12' }).includes('closed'));
  assert.deepEqual(why({ paidAmount: 100 }), ['paid'], 'the store charges the whole quote, so a part-paid job gets no link');
  assert.deepEqual(why({ paymentStatus: 'paid' }), ['paid']);
  assert.deepEqual(why({ giftCardDiscount: 20 }), ['paid']);
  assert.deepEqual(why({ milestoneInvoices: [{ amount: 100 }] }), ['milestones']);
  assert.deepEqual(why({}, { settings: { currency: 'USD' } }), ['currency']);
  assert.deepEqual(why({}, { settings: { currency: 'SAR', enableVat: true, vatRate: 15 } }), ['tax']);
  assert.deepEqual(why({}, { settings: { currency: 'SAR', tax: { mode: 'exclusive', rates: [{ id: 'v', label: 'VAT', percent: 15 }] } } }), ['tax']);
  // An id the store would refuse is refused here, never cleaned up.
  assert.deepEqual(why({ id: 'عرض-2026-0142-ab3k' }), ['reference']);
  assert.deepEqual(why({ id: 'QUO 2026/0142' }), ['reference']);
  assert.deepEqual(why({ id: 'x'.repeat(65) }), ['reference']);
  assert.deepEqual(why({ jobNumber: 'J'.repeat(41) }), ['reference'], 'the reference shown is 40 characters at most');
  assert.equal(L.claimsFor(job({ paidAmount: 1 }), ctx()), null);
});

test('a re-send is always later than the link before it', () => {
  const first = L.claimsFor(job(), ctx());
  assert.equal(first.iat, NOW);
  const again = L.claimsFor(job(), ctx({ lastIssuedAt: first.iat }));
  assert.equal(again.iat, NOW + 1, 'the same second would be two quotes with one iat');
  assert.equal(again.quote_id, first.quote_id, 'and it is the same quote');
  const later = L.claimsFor(job(), ctx({ nowSeconds: NOW + 3600, lastIssuedAt: first.iat }));
  assert.equal(later.iat, NOW + 3600);
  assert.equal(L.claimsFor(job(), ctx({ nowSeconds: 0 })), null, 'no clock, no link');
});

test('Arabic and emoji survive the hand-written encoder byte for byte', () => {
  for (const text of ['', 'a', 'ab', 'abc', 'فانوس رمضان', 'مجسم 🐉 v2', 'é€𝄞', '\ud83d', 'x\udc00y']) {
    assert.equal(L.base64url(L.utf8(text)), Buffer.from(text, 'utf8').toString('base64url'), JSON.stringify(text));
  }
  const claims = L.claimsFor(job({ parts: [{ name: 'فانوس رمضان', material: 'PLA', color: 'ذهبي', qty: 1, printWeight: 300, baseCost: 1 }] }),
    ctx({ customerName: 'سارة' }));
  const body = L.signingInput(claims).split('.')[1];
  assert.deepEqual(JSON.parse(Buffer.from(body, 'base64url').toString('utf8')), claims);
});

test('a token is only made from what a device could have produced', () => {
  const input = L.signingInput(L.claimsFor(job(), ctx()));
  const mac = hmac(input, VECTOR_SECRET);
  assert.ok(L.tokenFrom(input, mac));
  assert.equal(L.tokenFrom(input, mac.slice(0, 31)), '', 'not 32 bytes');
  assert.equal(L.tokenFrom(input, 'short'), '');
  assert.equal(L.tokenFrom('abc.def', mac), '', 'not our header');
  assert.equal(L.tokenFrom(input + '.x', mac), '');
  assert.equal(L.signingInput(null), '');
  // Too long for the store to read: no token, not a cut one.
  const big = { v: 1, items: Array.from({ length: 50 }, () => ({ title: 'x'.repeat(200) })) };
  assert.equal(L.tokenFrom(L.signingInput(big), mac), '');
});

test('the link is the store\'s address, the language and the token as it is', () => {
  const token = 'aaa.bbb.ccc';
  assert.equal(L.urlFor('https://athartuwaiq3d.com/', 'en-GB', token), 'https://athartuwaiq3d.com/sa/en/pay/aaa.bbb.ccc');
  assert.equal(L.urlFor('https://athartuwaiq3d.com', '', token), 'https://athartuwaiq3d.com/sa/ar/pay/aaa.bbb.ccc', 'Arabic when unknown');
  assert.equal(L.urlFor('http://athartuwaiq3d.com', 'ar', token), '');
  assert.equal(L.urlFor('https://athartuwaiq3d.com?x=1', 'ar', token), '');
  assert.equal(L.urlFor('https://athartuwaiq3d.com', 'ar', 'not a token'), '');
  assert.equal(L.secretIsUsable('x'.repeat(31)), false);
  assert.equal(L.secretIsUsable('x'.repeat(32)), true);
});

test('the secret is never an input to anything this module exports', () => {
  const source = require('node:fs').readFileSync(require.resolve('../lib/quote-pay-link.js'), 'utf8');
  // The one place the word may appear as a parameter is the length check.
  const params = [...source.matchAll(/function\s+\w+\s*\(([^)]*)\)|const\s+\w+\s*=\s*\(([^)]*)\)\s*=>/g)]
    .map((m) => m[1] || m[2] || '').filter((p) => /secret/i.test(p));
  assert.deepEqual(params, ['secret']);
  assert.equal(/createHmac|require\(['"](node:)?crypto/.test(source), false, 'it does no cryptography');
});
