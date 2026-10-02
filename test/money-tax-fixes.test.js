'use strict';
/**
 * Seven money bugs, each pinned to the shared rule that now answers it.
 *
 *  1. Profit screens counted VAT as revenue. A 15% VAT-inclusive job charged
 *     115 that cost 80 read "profit 35 (30.4%)" beside a P&L that said 20 (20%).
 *  2. The invoice summary did not add up once rush and shipping were on it:
 *     Subtotal 280 + Rush 25 + Shipping 30 printed above Total 280.
 *  5. The ZATCA QR was stamped with a date and no time.
 *  6. A gift card plus a payment plan stayed "partial" for ever, because the
 *     plan covers price − gift card and was judged against the whole price.
 *  7. Tax added on top: $100 + 8.25% paid as $108.25 was recorded as $100, and
 *     what was owed was worked out from the pre-tax price.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/tax.js');
require('../lib/business-scope.js');
const Money = require('../lib/order-money.js');
const Pay = require('../lib/order-payment.js');
const Plan = require('../lib/payment-plan.js');
const Audit = require('../lib/deposit-audit.js');
const Doc = require('../lib/invoice-document.js');
const Qr = require('../lib/zatca-qr.js');

const VAT15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const SALES_TAX = {
  currency: 'USD',
  tax: { name: 'Sales Tax', mode: 'exclusive', rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] },
};

/* ── 1. revenue is net of tax on every profit screen ──────────────────────── */

test('an order earns its price NET of an inclusive tax', () => {
  const o = { id: 'a', price: 115, status: 'completed' };
  assert.equal(Money.orderEarnedBase(o, { settings: VAT15 }), 100);
});

test('an exclusive shop earns its price unchanged — the tax was never in it', () => {
  const o = { id: 'a', price: 100, status: 'completed' };
  assert.equal(Money.orderEarnedBase(o, { settings: SALES_TAX }), 100);
});

test('an unregistered shop earns what it charged', () => {
  const o = { id: 'a', price: 115, status: 'completed' };
  assert.equal(Money.orderEarnedBase(o, { settings: { currency: 'SAR' } }), 115);
});

test('earned revenue converts and takes credit notes off first', () => {
  const settings = { ...VAT15, exchangeRates: { USD: 3.75 } };
  const o = { id: 'a', price: 46, currency: 'USD', creditNotes: [{ amount: 23 }] };
  // (46 − 23) USD × 3.75 = 86.25 SAR gross; net of 15% = 75.
  assert.equal(Money.orderEarnedBase(o, { settings }), 75);
});

/* ── 7. what the customer is asked for, mode-aware ───────────────────────── */

test('an exclusive shop is owed the price PLUS the tax', () => {
  const ctx = { settings: SALES_TAX };
  const o = { id: 'a', price: 100, paidAmount: 0 };
  assert.equal(Money.orderGrossRaw(o, ctx), 108.25);
  assert.equal(Money.orderOwedRaw(o, ctx), 108.25);
  assert.equal(Money.orderOwedBase(o, ctx), 108.25);
  assert.equal(Money.orderOwedRaw({ ...o, paidAmount: 100 }, ctx), 8.25);
});

test('an inclusive shop is owed the price, exactly as before', () => {
  const o = { id: 'a', price: 115, paidAmount: 15 };
  assert.equal(Money.orderOwedRaw(o, { settings: VAT15 }), 100);
  assert.equal(Money.orderOwedRaw(o), 100);
});

test('a payment of price + tax is recorded in full and settles the order', () => {
  const ctx = { today: '2026-10-02', settings: SALES_TAX };
  const o = { id: 'a', price: 100 };
  Pay.recordPayment(o, { amount: 108.25, method: 'card' }, ctx);
  assert.equal(o.paidAmount, 108.25);
  assert.equal(o.paymentStatus, 'paid');
});

test('the pre-tax price alone leaves an exclusive order part-paid', () => {
  const o = { id: 'a', price: 100, paidAmount: 100 };
  assert.equal(Pay.statusOf(o, { settings: SALES_TAX }), 'partial');
  assert.equal(Pay.statusOf(o, { settings: VAT15 }), 'paid');
});

test('a payment is still capped at what is due — an overpayment is a credit note', () => {
  const o = { id: 'a', price: 100 };
  Pay.recordPayment(o, { amount: 500 }, { settings: SALES_TAX });
  assert.equal(o.paidAmount, 108.25);
});

test('cashDue is the most cash an order can still take', () => {
  const o = { id: 'a', price: 115, giftCardDiscount: 15, creditNotes: [{ amount: 10 }] };
  const due = Pay.cashDue(o, { settings: VAT15 });
  assert.deepEqual(due, { gross: 115, credited: 10, giftCard: 15, cash: 90 });
  assert.equal(Pay.cashDue({ id: 'b', price: 100 }, { settings: SALES_TAX }).cash, 108.25);
});

/* ── 6. a gift card and a plan ───────────────────────────────────────────── */

test('a plan that covers price − gift card settles the order once collected', () => {
  // 500 order, 100 gift card, plan of 400 over two rows, both collected.
  const r = Plan.collectionTotals({
    price: 500, paidAmount: 0, instalmentBase: 0, giftCardDiscount: 100,
    instalments: [{ amount: 200, paid: true }, { amount: 200, paid: true }],
  });
  assert.equal(r.paidAmount, 400);
  assert.equal(r.paymentStatus, 'paid');
});

test('credit notes come off what the plan is judged against', () => {
  const r = Plan.collectionTotals({
    price: 500, paidAmount: 0, credited: 50, instalments: [{ amount: 450, paid: true }],
  });
  assert.equal(r.paymentStatus, 'paid');
});

test('an exclusive shop’s plan is judged against price + tax', () => {
  const r = Plan.collectionTotals({
    price: 100, due: 108.25, paidAmount: 0, instalments: [{ amount: 100, paid: true }],
  });
  assert.equal(r.paymentStatus, 'partial');
});

test('restoring a deposit counts the gift card toward settling', () => {
  const order = {
    id: 'a', price: 500, giftCardDiscount: 100, depositAmount: 100, paidAmount: 0,
    instalments: [{ amount: 150, paid: true }, { amount: 150, paid: true }],
  };
  const hits = Audit.findErasedDeposits([order]);
  assert.equal(hits.length, 1);
  assert.equal(hits[0].recovered, 400);
  const res = Audit.restoreDeposit(hits[0]);
  assert.equal(res.ok, true);
  assert.equal(order.paymentStatus, 'paid');
});

test('restoring a deposit on an exclusive shop settles only at price + tax', () => {
  const order = {
    id: 'a', price: 100, depositAmount: 50, paidAmount: 0,
    instalments: [{ amount: 50, paid: true }],
  };
  const hits = Audit.findErasedDeposits([order]);
  Audit.restoreDeposit(hits[0], { settings: SALES_TAX });
  assert.equal(order.paymentStatus, 'partial');
});

/* ── 2. the invoice summary adds up ──────────────────────────────────────── */

test('Subtotal + Rush + Shipping − Discount = Total, on the document', () => {
  const profile = { mode: 'inclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] };
  const s = Doc.invoiceSummary({ price: 280, rushFeeAmount: 25, shippingCost: 30 }, profile);
  assert.equal(s.itemsSubtotal, 225);
  assert.equal(s.rush, 25);
  assert.equal(s.shipping, 30);
  assert.equal(s.total, 280);
  assert.equal(s.itemsSubtotal + s.rush + s.shipping - s.discount, s.total);
});

test('a discount is shown before it is taken off', () => {
  const s = Doc.invoiceSummary({
    price: 180, priceBeforeDiscount: 200, discountPct: 10, shippingCost: 0,
  }, { mode: 'inclusive', rates: [] });
  assert.equal(s.discount, 20);
  assert.equal(s.itemsSubtotal, 200);
  assert.equal(s.itemsSubtotal - s.discount, s.total);
});

test('an exclusive shop’s total is the price plus tax, and the tax is a line', () => {
  const s = Doc.invoiceSummary({ price: 100 }, SALES_TAX.tax);
  assert.equal(s.subtotal, 100);
  assert.equal(s.taxTotal, 8.25);
  assert.equal(s.total, 108.25);
});

/* ── 5. the ZATCA timestamp has a time in it ─────────────────────────────── */

function tlvFields(b64) {
  const bytes = Buffer.from(b64, 'base64');
  const out = {};
  for (let i = 0; i < bytes.length;) {
    const tag = bytes[i];
    const len = bytes[i + 1];
    out[tag] = bytes.slice(i + 2, i + 2 + len).toString('utf8');
    i += 2 + len;
  }
  return out;
}

test('a date-only timestamp becomes a full ISO 8601 date-time', () => {
  const ts = Qr.issueTimestamp('2026-07-02');
  assert.match(ts, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const tlv = tlvFields(Qr.buildTLV({
    sellerName: 'Shop', vatNumber: '300000000000003', timestamp: '2026-07-02',
    total: '115.00', vatAmount: '15.00',
  }));
  assert.match(tlv[3], /^2026-07-0[12]T\d{2}:\d{2}:\d{2}Z$/);
});

test('a full timestamp is kept as the moment it names', () => {
  assert.equal(Qr.issueTimestamp('2026-07-02T14:32:05.123Z'), '2026-07-02T14:32:05Z');
  assert.equal(Qr.issueTimestamp({ timestamp: '2026-07-02T14:32:05Z', date: '2026-07-01' }),
    '2026-07-02T14:32:05Z');
});

test('an order with no timestamp is stamped from its date', () => {
  assert.match(Qr.issueTimestamp({ date: '2026-07-02' }), /^2026-07-0[12]T/);
});
