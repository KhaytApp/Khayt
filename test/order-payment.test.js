'use strict';
/**
 * What a shop has been paid, and what that makes an order.
 *
 * "Is this paid" decides what appears in receivables, who gets chased and what
 * a period earned — and it was answered in three places that did not agree.
 * The one that mattered most was the SMALLEST: the payment modal derived the
 * status inline from gift cards alone, so recording a payment on an order that
 * had been part-credited wrote a status the very next read disagreed with.
 *
 * So the first test runs the ORIGINAL implementations — `payStatus` copied out
 * of app-helpers.js and the modal's inline derivation copied out of
 * order-flows.js — against the extracted module over a few thousand generated
 * orders, and shows exactly where the two originals part company.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/order-payment.js');

const TODAY = '2026-09-04';

/* ── The originals, copied before the move ─────────────────────────────────── */

/** renderer/app-helpers.js — the full rule, and the one every report read. */
function originalPayStatus(order) {
  if (order.voidedAt) return 'voided';
  if (order.creditedAt) return 'voided';
  const price = +order.price || 0;
  if (price === 0) return order.paymentStatus || 'paid';
  const totalCredited = (order.creditNotes || []).reduce((s, cn) => s + (+cn.amount || 0), 0);
  const effectivePrice = Math.max(0, price - totalCredited);
  const paidTotal = (+order.paidAmount || 0) + (+order.giftCardDiscount || 0);
  if (effectivePrice <= 0) return 'paid';
  if (paidTotal <= 0) return 'unpaid';
  if (paidTotal >= effectivePrice) return 'paid';
  return 'partial';
}

/** renderer/order-flows.js — what the payment modal WROTE. */
function originalModalWrite(order, draft) {
  const fullAmount = +order.price || 0;
  order.paidAmount = Math.min(Math.max(0, draft.paidAmount || 0), +order.price || 0);
  order.paymentMethod = draft.paymentMethod;
  order.paidAt = draft.paidAt;
  const giftCredit = +order.giftCardDiscount || 0;
  const effPaid = (draft.paidAmount || 0) + giftCredit;
  order.paymentStatus = (effPaid >= fullAmount) ? 'paid' : (effPaid > 0 ? 'partial' : 'unpaid');
}

/* ── Generated orders ──────────────────────────────────────────────────────── */
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeOrder(rnd, i) {
  const maybe = (p) => rnd() < p;
  const money = (max) => Math.round(rnd() * max * 100) / 100;
  const o = { id: `o${i}`, price: maybe(0.12) ? 0 : money(5000) };
  if (maybe(0.7)) o.paidAmount = maybe(0.3) ? o.price : money(o.price || 100);
  if (maybe(0.2)) o.giftCardDiscount = money(Math.max(50, o.price / 2));
  if (maybe(0.2)) {
    o.creditNotes = Array.from({ length: 1 + Math.floor(rnd() * 2) },
      () => ({ amount: money(Math.max(20, o.price / 2)) }));
  }
  if (maybe(0.08)) o.voidedAt = '2026-08-01T00:00:00.000Z';
  if (maybe(0.08)) o.creditedAt = '2026-08-01T00:00:00.000Z';
  if (maybe(0.6)) o.paymentStatus = ['unpaid', 'partial', 'paid'][Math.floor(rnd() * 3)];
  return o;
}

test('the lifted rule and the report rule agree on every order', () => {
  const rnd = mulberry32(20260904);
  let compared = 0;
  for (let i = 0; i < 4000; i++) {
    const o = makeOrder(rnd, i);
    assert.equal(P.statusOf(o), originalPayStatus(o), `diverged for ${JSON.stringify(o)}`);
    compared++;
  }
  assert.ok(compared === 4000);
});

/**
 * The divergence this move exists to close.
 *
 * Both implementations are run over the same orders; where they differ, the
 * modal's answer was WRITTEN to the order and the report's answer was what
 * every screen then read. This asserts the difference is real (so the fix is
 * not imaginary) and that the lifted version now matches the report.
 */
test('recording a payment used to write a status the next read disagreed with', () => {
  const rnd = mulberry32(4242);
  let disagreements = 0;
  for (let i = 0; i < 4000; i++) {
    const base = makeOrder(rnd, i);
    if (base.voidedAt || base.creditedAt) continue;   // both agree these are not payable
    const draft = {
      paidAmount: Math.round(rnd() * (base.price || 100) * 100) / 100,
      paymentMethod: 'cash', paidAt: TODAY,
    };

    const a = JSON.parse(JSON.stringify(base));
    originalModalWrite(a, draft);

    const b = JSON.parse(JSON.stringify(base));
    P.recordPayment(b, { amount: draft.paidAmount, method: draft.paymentMethod, paidAt: draft.paidAt }, {});

    // The money is recorded identically either way.
    assert.equal(b.paidAmount, a.paidAmount);
    assert.equal(b.paymentMethod, a.paymentMethod);
    assert.equal(b.paidAt, a.paidAt);

    // The STATUS is what moved: the lifted one always matches what the reports
    // will say about the same order a moment later.
    assert.equal(b.paymentStatus, originalPayStatus(b),
      `the written status must survive being read back: ${JSON.stringify(b)}`);
    if (a.paymentStatus !== b.paymentStatus) disagreements++;
  }
  assert.ok(disagreements > 0,
    'if the two never disagreed there was nothing here worth fixing — check the generator');
});

/* ── The rules that are easy to break and hard to notice ───────────────────── */

test('a credit note reduces what is due; a gift card pays it down', () => {
  // SAR 100 job, SAR 60 credited back, SAR 40 paid. Forty is the whole of what
  // is left owing, so it is paid — and the modal used to call it partial.
  const credited = { price: 100, paidAmount: 40, creditNotes: [{ amount: 60 }] };
  assert.equal(P.statusOf(credited), 'paid');

  // A gift card is a tender, not a discount: it pays the order down.
  const gifted = { price: 100, paidAmount: 40, giftCardDiscount: 60 };
  assert.equal(P.statusOf(gifted), 'paid');

  const partly = { price: 100, paidAmount: 40, giftCardDiscount: 20 };
  assert.equal(P.statusOf(partly), 'partial');
});

test('a voided order is not unpaid — it is not an order', () => {
  assert.equal(P.statusOf({ price: 500, voidedAt: 'x' }), 'voided');
  // Credited in full: generateCreditNote stamps creditedAt, and an order whose
  // whole price has been handed back must stop appearing as money owed.
  assert.equal(P.statusOf({ price: 500, creditedAt: 'x' }), 'voided');
  assert.equal(P.isOutstanding({ price: 500, voidedAt: 'x' }), false);
});

test('a costless order keeps the answer the shop gave it', () => {
  // Nothing owed and nothing paid is either "free, and settled" or "not priced
  // yet", and only the shop knows which.
  assert.equal(P.statusOf({ price: 0, paymentStatus: 'unpaid' }), 'unpaid');
  assert.equal(P.statusOf({ price: 0 }), 'paid');
});

test('a payment cannot exceed the price', () => {
  const order = { price: 100 };
  P.recordPayment(order, { amount: 250 }, {});
  assert.equal(order.paidAmount, 100, 'an overpayment is a credit note, not a bigger paidAmount');
  assert.equal(order.paymentStatus, 'paid');

  P.recordPayment(order, { amount: -50 }, {});
  assert.equal(order.paidAmount, 0);
  assert.equal(order.paymentStatus, 'unpaid');
});

test('a payment with no date is dated today', () => {
  const order = { price: 100 };
  P.recordPayment(order, { amount: 50 }, { today: TODAY });
  assert.equal(order.paidAt, TODAY);
});

test('the status written is the status that will be read back', () => {
  const rnd = mulberry32(99);
  for (let i = 0; i < 500; i++) {
    const order = makeOrder(rnd, i);
    if (order.voidedAt || order.creditedAt) continue;
    P.recordPayment(order, { amount: (order.price || 0) / 2 }, { today: TODAY });
    assert.equal(order.paymentStatus, P.statusOf(order));
  }
});

test('clearing a payment leaves the order owed, whatever else is on it', () => {
  // A gift card or a credit note still on the order would make a derived status
  // read "paid" — and somebody clearing a payment means the order is owed.
  const order = {
    price: 100, paidAmount: 100, paymentMethod: 'cash', paidAt: TODAY,
    giftCardDiscount: 100,
  };
  P.clearPayment(order);
  assert.equal(order.paidAmount, 0);
  assert.equal(order.paymentMethod, null);
  assert.equal(order.paidAt, null);
  assert.equal(order.paymentStatus, 'unpaid');
});

test('a payment reaches nobody in a shop with nothing configured', () => {
  assert.deepEqual(P.outboundFor({ id: 'o', clientId: 'c1' }, { settings: {}, clients: [] }), []);
});

test('a payment reaches what the shop actually switched on', () => {
  const settings = {
    webhooks: { enabled: true },
    eventWebhooks: { enabled: true, url: 'https://erp.example.com/hook' },
    emailConfig: { provider: 'smtp', triggers: ['payment_received'] },
  };
  const clients = [{ id: 'c1', email: 'someone@example.com' }, { id: 'c2' }];
  assert.deepEqual(
    P.outboundFor({ id: 'o', clientId: 'c1' }, { settings, clients }).map(x => x.channel),
    ['webhooks', 'event_webhook', 'email']);
  assert.deepEqual(
    P.outboundFor({ id: 'o', clientId: 'c2' }, { settings, clients }).map(x => x.channel),
    ['webhooks', 'event_webhook'], 'a customer with no address is nobody to email');
  assert.deepEqual(
    P.outboundFor({ id: 'o' }, { settings, clients }).map(x => x.channel),
    ['webhooks', 'event_webhook'], 'and a walk-in is nobody at all');
});

test('a payment plan with collected rows refuses a clear, and a clear resets the plan base', () => {
  const Plan = require('../lib/payment-plan.js');
  // Collected rows are money received; zeroing paidAmount under them came back
  // on the next collection (instalmentBase + collected).
  const collected = {
    price: 300, paidAmount: 200, paymentMethod: 'cash', paidAt: TODAY, instalmentBase: 100,
    instalments: [{ amount: 100, paid: true, paidAt: TODAY }, { amount: 100, paid: false }],
  };
  const before = JSON.stringify(collected);
  const out = P.clearPayment(collected);
  assert.equal(out.refused, 'plan_collected');
  assert.deepEqual(out.effects, [{ type: 'toast_refused', key: 'pay.clear_plan_first' }]);
  assert.equal(JSON.stringify(collected), before, 'a refusal changes nothing');

  // No row collected: the deposit the plan was built on is what is cleared,
  // so the next collection counts from zero, not from the cleared deposit.
  const deposit = {
    price: 300, paidAmount: 100, instalmentBase: 100,
    instalments: [{ amount: 100, paid: false }, { amount: 100, paid: false }],
  };
  assert.equal(P.clearPayment(deposit).refused, undefined);
  assert.equal(deposit.paidAmount, 0);
  assert.equal(deposit.instalmentBase, 0);
  deposit.instalments[0].paid = true;
  const t = Plan.collectionTotals({ price: deposit.price, paidAmount: deposit.paidAmount,
    instalments: deposit.instalments, instalmentBase: deposit.instalmentBase });
  assert.equal(t.paidAmount, 100, 'the cleared deposit came back');

  // An order with no plan is cleared exactly as before, no base invented.
  const plain = { price: 100, paidAmount: 100 };
  P.clearPayment(plain);
  assert.equal('instalmentBase' in plain, false);
});

test('Electron shows the refusal', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'renderer', 'order-flows.js'), 'utf8');
  assert.match(src, /case 'toast_refused': toast\(t\(e\.key\), 'error'\)/);
});
