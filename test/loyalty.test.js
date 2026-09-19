/**
 * Loyalty & store-credit ledger-math tests. See docs/KHAYT-3.0-LOYALTY-SPEC.md
 * §9 (Test plan & DoD). Pure arithmetic — no fs, no renderer, no DOM.
 *
 * Redemption is applied to an order via the existing `giftCardDiscount` rail in
 * the renderer; these tests only cover the wallet/ledger math behind it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const L = require('../lib/loyalty.js');

// ---- earnPoints: floor + tier multiplier + ex-VAT base ---------------------

test('earnPoints floors fractional results', () => {
  // 99.9 SAR ex-VAT × 1 pt/SAR = 99.9 → 99
  assert.equal(L.earnPoints(99.9, { pointsPerUnit: 1 }), 99);
  assert.equal(L.earnPoints(10, { pointsPerUnit: 0.33 }), 3); // 3.3 → 3
});

test('earnPoints applies the tier multiplier (115 SAR incl VAT ⇒ 100 ex-VAT × 1.5)', () => {
  // Caller passes the ex-VAT base (115 / 1.15 = 100); module just does the math.
  assert.equal(L.earnPoints(100, { pointsPerUnit: 1, tierMultiplier: 1.5 }), 150);
});

test('earnPoints defaults pointsPerUnit and tierMultiplier to 1', () => {
  assert.equal(L.earnPoints(50), 50);
  assert.equal(L.earnPoints(50, {}), 50);
});

test('earnPoints returns 0 for negative/zero/garbage spend', () => {
  assert.equal(L.earnPoints(-10), 0);
  assert.equal(L.earnPoints(0), 0);
  assert.equal(L.earnPoints(NaN), 0);
  assert.equal(L.earnPoints('abc'), 0);
});

// ---- pointsToCredit conversion ---------------------------------------------

test('pointsToCredit converts at the given rate (100 pts = 1 SAR ⇒ rate 0.01)', () => {
  assert.equal(L.pointsToCredit(100, 0.01), 1);
  assert.equal(L.pointsToCredit(250, 0.05), 12.5);
});

test('pointsToCredit clamps negatives to 0', () => {
  assert.equal(L.pointsToCredit(-100, 0.01), 0);
  assert.equal(L.pointsToCredit(100, -0.01), 0);
});

// ---- ledgerBalance: empty + folding ----------------------------------------

test('empty ledger folds to {points:0, credit:0}', () => {
  assert.deepEqual(L.ledgerBalance([]), { points: 0, credit: 0 });
  assert.deepEqual(L.ledgerBalance(undefined), { points: 0, credit: 0 });
  assert.deepEqual(L.ledgerBalance(null), { points: 0, credit: 0 });
});

test('ledgerBalance folds earn + redeem + referral + clawback correctly', () => {
  const ledger = [
    L.earnEntry({ orderId: 'o1', exVatAmount: 100, pointsPerUnit: 1, tierMultiplier: 1 }), // +100 pts
    L.referralEntry({ referredClientId: 'c2', credit: 25 }),                                // +25 credit
    L.redeemEntry({ points: 40, orderId: 'o2' }, { points: 100, credit: 25 }),             // -40 pts
    L.clawbackOnRefund({ originalEarnPoints: 100, refundFraction: 0.5 }),                   // -50 pts
  ];
  // points: 100 - 40 - 50 = 10 ; credit: 25
  assert.deepEqual(L.ledgerBalance(ledger), { points: 10, credit: 25 });
});

test('ledgerBalance tracks points and credit separately', () => {
  const ledger = [
    L.earnEntry({ orderId: 'o1', exVatAmount: 200 }),    // +200 pts, 0 credit
    L.referralEntry({ referredClientId: 'c9', credit: 25 }), // 0 pts, +25 credit
  ];
  assert.deepEqual(L.ledgerBalance(ledger), { points: 200, credit: 25 });
});

test('ledgerBalance ignores malformed entries', () => {
  const ledger = [null, 'x', 42, L.earnEntry({ exVatAmount: 30 }), {}];
  assert.deepEqual(L.ledgerBalance(ledger), { points: 30, credit: 0 });
});

// ---- redeem beyond balance is rejected -------------------------------------

test('redeemEntry rejects redeeming more points than available', () => {
  assert.throws(
    () => L.redeemEntry({ points: 150 }, { points: 100, credit: 0 }),
    /insufficient points/,
  );
});

test('redeemEntry rejects redeeming more credit than available', () => {
  assert.throws(
    () => L.redeemEntry({ credit: 30 }, { points: 0, credit: 25 }),
    /insufficient credit/,
  );
});

test('redeemEntry produces negative deltas within balance', () => {
  const e = L.redeemEntry({ points: 40, credit: 10, orderId: 'o3' }, { points: 100, credit: 25 });
  assert.equal(e.type, 'redeem');
  assert.equal(e.points, -40);
  assert.equal(e.credit, -10);
  assert.equal(e.orderId, 'o3');
});

test('redeemEntry accepts the (ledger, request) call form', () => {
  const ledger = [L.earnEntry({ exVatAmount: 100 })]; // 100 pts
  const e = L.redeemEntry(ledger, { points: 60, orderId: 'o4' });
  assert.equal(e.points, -60);
  // and rejects over-redemption against the folded ledger
  assert.throws(() => L.redeemEntry(ledger, { points: 101 }), /insufficient points/);
});

test('redeemEntry rejects empty and negative requests', () => {
  assert.throws(() => L.redeemEntry({}, { points: 100, credit: 100 }), /nothing to redeem/);
  assert.throws(() => L.redeemEntry({ points: -5 }, { points: 100 }), /non-negative/);
});

// ---- clawback removes proportional points on refund ------------------------

test('clawbackOnRefund removes the proportional (floored) points', () => {
  assert.equal(L.clawbackOnRefund({ originalEarnPoints: 100, refundFraction: 0.5 }).points, -50);
  assert.equal(L.clawbackOnRefund({ originalEarnPoints: 99, refundFraction: 0.5 }).points, -49); // floor(49.5)
  assert.equal(L.clawbackOnRefund({ originalEarnPoints: 100, refundFraction: 1 }).points, -100);
});

test('clawbackOnRefund clamps fraction to 0..1 and caps at originally earned', () => {
  assert.equal(L.clawbackOnRefund({ originalEarnPoints: 100, refundFraction: 2 }).points, -100);
  assert.equal(L.clawbackOnRefund({ originalEarnPoints: 100, refundFraction: -1 }).points, 0);
});

test('a full clawback exactly reverses the matching earn (net zero)', () => {
  const earn = L.earnEntry({ orderId: 'o1', exVatAmount: 100 }); // +100
  const claw = L.clawbackOnRefund({ originalEarnPoints: earn.points, refundFraction: 1 }); // -100
  assert.deepEqual(L.ledgerBalance([earn, claw]), { points: 0, credit: 0 });
});

// ---- balance never negative ------------------------------------------------

test('ledgerBalance clamps at 0 — a corrupt/over-removing ledger never goes negative', () => {
  const ledger = [
    L.earnEntry({ exVatAmount: 50 }),                  // +50 pts
    { type: 'clawback', points: -999, credit: 0 },     // hand-edited over-removal
    { type: 'adjust', credit: -999 },                  // corrupt credit removal
  ];
  assert.deepEqual(L.ledgerBalance(ledger), { points: 0, credit: 0 });
});

test('clamp does not strand later positive deltas at 0', () => {
  const ledger = [
    { type: 'clawback', points: -999 }, // clamps points to 0
    L.earnEntry({ exVatAmount: 30 }),   // +30 after the clamp
  ];
  assert.equal(L.ledgerBalance(ledger).points, 30);
});

// ---- entry constructors: shape ---------------------------------------------

test('earnEntry builds a well-formed earn entry', () => {
  const e = L.earnEntry({ orderId: 'o7', exVatAmount: 100, tierMultiplier: 2, ts: 123 });
  assert.equal(e.type, 'earn');
  assert.equal(e.points, 200);
  assert.equal(e.credit, 0);
  assert.equal(e.orderId, 'o7');
  assert.equal(e.ts, 123);
});

test('referralEntry builds a credit-only entry and clamps negatives', () => {
  const e = L.referralEntry({ referredClientId: 'c5', credit: 25, ts: 9 });
  assert.equal(e.type, 'referral');
  assert.equal(e.points, 0);
  assert.equal(e.credit, 25);
  assert.equal(e.referredClientId, 'c5');
  assert.equal(L.referralEntry({ referredClientId: 'c5', credit: -25 }).credit, 0);
});

/* ────────────────────────────────────────────────────────────────────────────
 * WHAT ONE CUSTOMER HAS EARNED — lifted out of renderer/clients.js so the
 * macOS app can answer it too.
 *
 * Every exclusion below was a real over-award. Points are a liability the shop
 * honours in money, so counting one that was never a sale is a discount on
 * income the shop never had.
 * ──────────────────────────────────────────────────────────────────────────── */

require('../lib/order-money.js');
require('../lib/order-status.js');
require('../lib/tax.js');
const { earnedBy, redeemedBy, availableFor, overRedeemed, tierFor, redemption } =
  require('../lib/loyalty.js');

const SETTINGS = { loyaltyEnabled: true, loyaltyPointsPerUnit: 1, enableVat: true, vatRate: 15 };
const sale = (id, clientId, price, extra = {}) =>
  Object.assign({ id, clientId, status: 'completed', price, date: '2026-09-01' }, extra);

test('earnedBy: points are earned on what the shop keeps, not the tax it collects', () => {
  const orders = [sale('a', 'c1', 115), sale('b', 'c1', 230)];
  assert.equal(earnedBy({ orders, clientId: 'c1', settings: SETTINGS }), 300);
});

test('earnedBy: a voided order is not a sale', () => {
  const orders = [sale('a', 'c1', 115), sale('b', 'c1', 1150, { voidedAt: '2026-09-02' })];
  assert.equal(earnedBy({ orders, clientId: 'c1', settings: SETTINGS }), 100);
});

test('earnedBy: an order refunded in full by a credit note earns nothing', () => {
  // It read the GROSS price, so the shop awarded points on money it gave back.
  const orders = [sale('a', 'c1', 115, { creditNotes: [{ amount: 115 }] })];
  assert.equal(earnedBy({ orders, clientId: 'c1', settings: SETTINGS }), 0);
});

test('earnedBy: work still on the bench has earned nothing yet', () => {
  const orders = [sale('a', 'c1', 115, { status: 'pending' })];
  assert.equal(earnedBy({ orders, clientId: 'c1', settings: SETTINGS }), 0);
});

test('earnedBy: a delivered job counts — delivered is PAST completed', () => {
  const orders = [sale('a', 'c1', 115, { status: 'delivered' })];
  assert.equal(earnedBy({ orders, clientId: 'c1', settings: SETTINGS }), 100);
});

test('earnedBy: nothing at all unless the shop turned the programme on', () => {
  const orders = [sale('a', 'c1', 115)];
  assert.equal(earnedBy({ orders, clientId: 'c1', settings: { loyaltyEnabled: false } }), 0);
});

test('tierFor: the highest bar a customer clears, not the first tier that matches', () => {
  const settings = Object.assign({}, SETTINGS, {
    loyaltyTiers: [
      { name: 'Silver', minOrders: 1, pointsMultiplier: 1 },
      { name: 'Gold', minOrders: 2, pointsMultiplier: 2 },
    ],
  });
  const orders = [sale('a', 'c1', 115), sale('b', 'c1', 115)];
  assert.equal(tierFor({ orders, clientId: 'c1', settings }).name, 'Gold');
  // And the multiplier is applied without the caller having to pass it.
  assert.equal(earnedBy({ orders, clientId: 'c1', settings }), 400);
});

test('tierFor: a customer who clears no bar has no tier', () => {
  const settings = Object.assign({}, SETTINGS, {
    loyaltyTiers: [{ name: 'Gold', minOrders: 5, pointsMultiplier: 2 }],
  });
  assert.equal(tierFor({ orders: [sale('a', 'c1', 115)], clientId: 'c1', settings }), null);
});

test('availableFor: what has been spent comes off, and never goes below zero', () => {
  const orders = [sale('a', 'c1', 115)];
  const ledger = [{ clientId: 'c1', type: 'redeem', points: 250 }];
  assert.equal(redeemedBy(ledger, 'c1'), 250);
  assert.equal(availableFor({ orders, ledger, clientId: 'c1', settings: SETTINGS }), 0);
});

test('redeemedBy: only this customer\'s redeem rows count', () => {
  const ledger = [
    { clientId: 'c2', type: 'redeem', points: 50 },
    { clientId: 'c1', type: 'earn', points: 999 },
  ];
  assert.equal(redeemedBy(ledger, 'c1'), 0);
});

test('overRedeemed: names the customers who spent more than they now show', () => {
  // Report-only, and deliberately: the points were over-awarded, the shop has
  // honoured some of them, and re-inflating the balance perpetuates a
  // liability it does not owe.
  const orders = [sale('a', 'c1', 115)];
  const ledger = [{ clientId: 'c1', type: 'redeem', points: 250 }];
  const out = overRedeemed({ orders, ledger, clients: [{ id: 'c1', name: 'Acme' }], settings: SETTINGS });
  assert.equal(out.length, 1);
  assert.equal(out[0].over, 150);
  assert.equal(out[0].name, 'Acme');
});

test('redemption: a gift card and a ledger row that names it', () => {
  const made = redemption({ clientId: 'c1', clientName: 'Acme', points: 250, rate: 0.01,
                            code: 'LOY1', cardId: 'GC1', entryId: 'L1', ts: 'T' });
  assert.equal(made.ok, true);
  assert.equal(made.card.balance, 2.5);
  assert.equal(made.card.source, 'loyalty');
  assert.equal(made.entry.giftCardCode, made.card.code);
  assert.equal(made.entry.points, 250);
});

test('redemption: nothing to redeem issues nothing', () => {
  assert.equal(redemption({ clientId: 'c1', points: 0, rate: 0.01 }).ok, false);
  assert.equal(redemption({ clientId: 'c1', points: -5, rate: 0.01 }).ok, false);
});

test('redemption: no rate set means the default rate, not a worthless card', () => {
  // `+settings.loyaltyRedeemRate || 0.01` is what the renderer has always
  // done, so an unset rate is a hundred points to the unit rather than a card
  // for nothing. Asserted rather than assumed, because the two apps now read
  // the same line.
  const made = redemption({ clientId: 'c1', points: 250, rate: 0, code: 'X', cardId: 'Y', entryId: 'Z' });
  assert.equal(made.ok, true);
  assert.equal(made.card.balance, 2.5);
});
