'use strict';
/**
 * An order settled BEFORE tax-on-top was owed stays settled.
 *
 * Until alpha.58 `recordPayment` capped a payment at the PRICE, so every order
 * a tax-added-on-top shop ever settled reads paidAmount === price with
 * paymentStatus 'paid'. The new rule judges an exclusive shop's order against
 * price + tax, and with nothing to tell old from new every one of those orders
 * moved into receivables owing the tax: the portal showed a balance, the
 * reminders would chase it, and the KPI's outstanding grew by 8.25% of a
 * year's sales.
 *
 * The marker: `recordPayment` now stamps `paidGross: true` — the payment was
 * judged against price + tax. An order WITHOUT the stamp whose stored status
 * is 'paid' and whose tenders cover the price was settled under the old rule.
 * Every new payment carries the stamp, so the new behaviour holds for them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/currencies.js');
require('../lib/tax.js');
require('../lib/business-scope.js');
const Money = require('../lib/order-money.js');
const Pay = require('../lib/order-payment.js');
require('../lib/portal-trial.js');
require('../lib/cloud-plans.js');
const Portal = require('../lib/portal-refresh.js');
const Receivables = require('../lib/receivables.js');

const SALES_TAX = {
  currency: 'USD',
  tax: { name: 'Sales Tax', mode: 'exclusive', rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] },
};
const ctx = { settings: SALES_TAX };

const legacy = (extra) => Object.assign({
  id: 'OLD', status: 'printing', price: 100, paidAmount: 100, paymentStatus: 'paid',
  trackingToken: 't', date: '2026-06-01', clientId: 'C1',
}, extra || {});

test('a settled pre-alpha.58 order is still paid, owes nothing, and is billed price + tax', () => {
  const o = legacy();
  assert.equal(Pay.statusOf(o, ctx), 'paid');
  assert.equal(Pay.isOutstanding(o, ctx), false);
  assert.equal(Money.orderOwedRaw(o, ctx), 0);
  assert.equal(Money.orderOwedBase(o, ctx), 0);
  // The most cash it can hold is the price it was settled at — so a payment
  // sheet previews nothing owed (paid 100 of 100), not 8.25.
  assert.equal(Pay.cashDue(o, ctx).cash, 100);
  // The document still says what it always said: the bill was 108.25.
  assert.equal(Money.orderGrossRaw(o, ctx), 108.25);
});

test('the portal shows no balance on it', () => {
  const p = Portal.payloadFor(legacy(), { settings: SALES_TAX, shopName: 'Shop' }).payload;
  assert.equal(p.amount, '108.25');
  assert.equal(p.balanceDue, undefined);
});

test('receivables leave it out, and keep a new short payment', () => {
  const out = Receivables.aged([legacy(), legacy({ id: 'NEW', paidGross: true, paymentStatus: 'partial' })],
    { settings: SALES_TAX, clients: [], now: new Date('2026-10-03T12:00:00Z') });
  assert.deepEqual(out.rows.map((r) => r.id), ['NEW']);
  assert.equal(out.total, 8.25);
});

test('a payment recorded now is stamped and judged against price + tax', () => {
  const o = { id: 'NEW', price: 100, paidAmount: 0 };
  Pay.recordPayment(o, { amount: 100, method: 'cash' }, { today: '2026-10-03', settings: SALES_TAX });
  assert.equal(o.paidGross, true);
  assert.equal(o.paymentStatus, 'partial');
  assert.equal(Money.orderOwedRaw(o, ctx), 8.25);
  Pay.recordPayment(o, { amount: 108.25, method: 'cash' }, { today: '2026-10-03', settings: SALES_TAX });
  assert.equal(o.paymentStatus, 'paid');
  assert.equal(Money.orderOwedRaw(o, ctx), 0);
});

test('an unstamped order is NOT grandfathered unless it was recorded paid and covers the price', () => {
  // Paid the price but never recorded paid (e.g. a status written by the new rule).
  assert.equal(Money.orderOwedRaw(legacy({ paymentStatus: 'partial' }), ctx), 8.25);
  // Recorded paid but short of the price — owed as before, plus the tax.
  assert.equal(Money.orderOwedRaw(legacy({ paidAmount: 60 }), ctx), 48.25);
  // A gift card and a credit note count toward covering the price.
  const mixed = legacy({ paidAmount: 50, giftCardDiscount: 30, creditNotes: [{ amount: 20 }] });
  assert.equal(Money.orderOwedRaw(mixed, ctx), 0);
  assert.equal(Pay.statusOf(mixed, ctx), 'paid');
});

test('an inclusive or untaxed shop is untouched', () => {
  const vat = { settings: { currency: 'SAR', enableVat: true, vatRate: 15 } };
  assert.equal(Money.orderOwedRaw(legacy({ paidAmount: 90 }), vat), 10);
  assert.equal(Money.orderOwedRaw(legacy(), {}), 0);
});

test('the due figure is named: price for a grandfathered order, price + tax once stamped', () => {
  assert.equal(typeof Money.orderDueRaw, 'function', 'the due figure is named so every reader can ask for it');
  assert.equal(Money.orderDueRaw(legacy(), ctx), 100);
  assert.equal(Money.orderDueRaw(legacy({ paidGross: true }), ctx), 108.25);
});
