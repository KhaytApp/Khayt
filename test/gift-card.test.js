/**
 * Gift cards. Money that belongs to the CUSTOMER rather than the shop, which
 * is what makes over-spending one worse than under-counting revenue: the shop
 * can find its own missing figure, and the customer cannot find balance that
 * was quietly taken off a card.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/order-money.js');
const G = require('../lib/gift-card.js');

const TODAY = '2026-09-06';
const NOW = '2026-09-06T10:00:00.000Z';
const card = (over = {}) => ({
  id: 'GC-1', code: 'ABC123', initialBalance: 500, balance: 500,
  issuedTo: null, issuedToName: '', issuedAt: NOW, expiresAt: null,
  redeemedOrders: [], ...over,
});

// ── status ────────────────────────────────────────────────────────────────

test('a card with balance and no expiry is active', () => {
  assert.equal(G.status(card(), TODAY), G.ACTIVE);
});

test('a spent card reads used', () => {
  assert.equal(G.status(card({ balance: 0 }), TODAY), G.USED);
});

// Expired says WHY it cannot be used; "used" would suggest the customer had
// the benefit of it.
test('expiry beats an empty balance', () => {
  assert.equal(G.status(card({ balance: 0, expiresAt: '2026-01-01' }), TODAY), G.EXPIRED);
});

test('a card expiring today is still good today', () => {
  assert.equal(G.status(card({ expiresAt: TODAY }), TODAY), G.ACTIVE);
  assert.equal(G.status(card({ expiresAt: '2026-09-05' }), TODAY), G.EXPIRED);
});

test('no expiry date is not an expiry of nothing', () => {
  for (const blank of [null, undefined, '']) {
    assert.equal(G.status(card({ expiresAt: blank }), TODAY), G.ACTIVE);
  }
});

// ── issuing ───────────────────────────────────────────────────────────────

test('a new card starts full, and its balance is its initial balance', () => {
  const r = G.newCard({ code: 'sum23', initialBalance: 250 }, { id: 'GC-9', now: NOW });
  assert.equal(r.ok, true);
  assert.equal(r.card.code, 'SUM23', 'codes are read down a telephone, so they are shouted');
  assert.equal(r.card.balance, 250);
  assert.equal(r.card.initialBalance, 250);
  assert.deepEqual(r.card.redeemedOrders, []);
});

test('a code has to look like a code', () => {
  for (const [code, error] of [
    ['', 'giftCardCodeRequired'],
    ['   ', 'giftCardCodeRequired'],
    ['AB', 'giftCardCodeInvalid'],
    ['A-B-C', 'giftCardCodeInvalid'],
    ['ABCDEFGHIJKLMNOPQRSTUV', 'giftCardCodeInvalid'],
  ]) {
    assert.equal(G.newCard({ code, initialBalance: 50 }, {}).error, error, `for ${JSON.stringify(code)}`);
  }
});

test('a duplicate code is refused, however it was typed', () => {
  const existing = [card({ code: 'ABC123' })];
  assert.equal(G.newCard({ code: 'abc123', initialBalance: 10 }, { existing }).error,
    'giftCardCodeDuplicate');
});

test('a card must be worth something, and not absurdly much', () => {
  assert.equal(G.newCard({ code: 'AAA111', initialBalance: 0 }, {}).error, 'giftCardBalanceRequired');
  assert.equal(G.newCard({ code: 'AAA111', initialBalance: -5 }, {}).error, 'giftCardBalanceRequired');
  const big = G.newCard({ code: 'AAA111', initialBalance: 9e9 }, {});
  assert.equal(big.card.balance, G.MAX_BALANCE, 'a fat-fingered balance is capped, not taken');
});

test('nothing is built when the input is refused', () => {
  assert.equal(G.newCard({ code: '!!', initialBalance: 50 }, {}).card, undefined);
});

// ── redeeming ─────────────────────────────────────────────────────────────

// THE BUG THIS MODULE WAS EXTRACTED TO FIX. The renderer worked out what an
// order owed as price − paid − giftCardDiscount, leaving CREDIT NOTES out. On
// a 500 order carrying a 300 credit note that reads 500, so redeeming spent
// 300 of the customer's balance against money they did not owe.
test('a credit note is money already off the order, not money a card pays', () => {
  const order = { id: 'O1', price: 500, paidAmount: 0, creditNotes: [{ amount: 300 }] };
  const r = G.redeem(card(), order, { today: TODAY, now: NOW });
  assert.equal(r.amount, 200, 'spent more than the order owed');
  assert.equal(r.card.balance, 300, 'the customer keeps what the order did not need');
  assert.equal(r.order.giftCardDiscount, 200);
});

test('a card smaller than the bill is spent to the last unit', () => {
  const r = G.redeem(card({ balance: 120 }), { id: 'O1', price: 500, paidAmount: 0 },
    { today: TODAY, now: NOW });
  assert.equal(r.amount, 120);
  assert.equal(r.card.balance, 0);
  assert.equal(G.status(r.card, TODAY), G.USED);
});

test('a second card on one order keeps the first one’s credit', () => {
  const first = G.redeem(card({ balance: 100 }), { id: 'O1', price: 500, paidAmount: 0 },
    { today: TODAY, now: NOW });
  const second = G.redeem(card({ code: 'XYZ789', balance: 100 }), first.order,
    { today: TODAY, now: NOW });
  assert.equal(second.order.giftCardDiscount, 200, 'the first redemption was overwritten');
});

test('an order that owes nothing is a refusal, not a zero write', () => {
  const r = G.redeem(card(), { id: 'O1', price: 100, paidAmount: 100 }, { today: TODAY, now: NOW });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'orderFullyCovered');
});

test('an expired or empty card cannot be spent', () => {
  const order = { id: 'O1', price: 500, paidAmount: 0 };
  assert.equal(G.redeem(card({ expiresAt: '2026-01-01' }), order, { today: TODAY }).reason,
    'giftCardExpired');
  assert.equal(G.redeem(card({ balance: 0 }), order, { today: TODAY }).reason, 'giftCardInvalid');
});

// Returning what things SHOULD become, rather than editing them, is what lets
// a caller that cannot save leave the shop exactly as it was.
test('redeeming changes nothing until the caller writes it', () => {
  const c = card();
  const order = { id: 'O1', price: 500, paidAmount: 0 };
  const before = JSON.stringify({ c, order });
  G.redeem(c, order, { today: TODAY, now: NOW });
  assert.equal(JSON.stringify({ c, order }), before, 'the arguments were mutated');
});

test('a card that predates redeemedOrders does not throw', () => {
  const legacy = card();
  delete legacy.redeemedOrders;
  const r = G.redeem(legacy, { id: 'O1', price: 50, paidAmount: 0 }, { today: TODAY, now: NOW });
  assert.equal(r.ok, true);
  assert.deepEqual(r.card.redeemedOrders, [{ orderId: 'O1', amount: 50, at: NOW }]);
});

// ── the rule has to be REACHED ────────────────────────────────────────────
//
// A pure module that every caller has quietly stopped using is this repo's
// signature bug, and it is what the arithmetic above looked like for as long
// as it lived in the renderer. These read the source, because the renderer
// cannot be loaded here.
const fs = require('node:fs');
const path = require('node:path');
const extras = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'operations-extras.js'), 'utf8');
const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

test('the renderer asks the module instead of doing the arithmetic', () => {
  for (const call of ['KhaytGiftCard.status(', 'KhaytGiftCard.newCard(', 'KhaytGiftCard.redeem(']) {
    assert.ok(extras.includes(call), `the renderer no longer calls ${call}`);
  }
});

// The exact expression that spent a customer's balance on money they did not
// owe. If it comes back, it will come back looking like this.
test('the outstanding-amount arithmetic is gone from the renderer', () => {
  assert.doesNotMatch(extras, /\+order\.price \|\| 0\) - \(\+order\.paidAmount/,
    'the renderer works out what an order owes again, without credit notes');
  assert.doesNotMatch(extras, /\/\^\[A-Z0-9\]\{3,20\}\$\//,
    'the code rule is spelled out in the renderer again');
});

// It reads `KhaytOrderMoney` off the global, so load order is part of whether
// it works at all — and a missing module makes it REFUSE, which would look
// like a broken gift card rather than a broken page.
test('gift-card is loaded after the money rule it depends on', () => {
  const money = indexHtml.indexOf('lib/order-money.js');
  const gift = indexHtml.indexOf('lib/gift-card.js');
  assert.ok(gift > -1, 'gift-card.js is not loaded by the renderer at all');
  assert.ok(money > -1 && money < gift, 'gift-card.js loads before order-money.js');
});
