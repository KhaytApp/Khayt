'use strict';

/**
 * Cash flow counts the tax a tax-added shop collected (lib/cash-flow.js),
 * and nothing changes for inclusive or untaxed shops.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/business-scope.js');
require('../lib/order-money.js');
const { cashFlow } = require('../lib/cash-flow.js');

const EXCL = { currency: 'USD', tax: { name: 'Sales Tax', mode: 'exclusive', rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] } };
const VAT15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const run = (order, settings) => cashFlow({ orders: [order], expenses: [], endMonth: '2026-10', months: 1, settings },
  { revenueOf: (o) => +o.price, countsForBusiness: () => true });

test('a tax-added shop paid $108.25 on a $100 job collected $108.25', () => {
  const order = { id: 'O1', status: 'completed', price: 100, paidAmount: 108.25, paidAt: '2026-10-02' };
  assert.equal(run(order, EXCL).rows[0].collected, 108.25);
  assert.equal(run(order, undefined).rows[0].collected, 100, 'without settings: as before');
});

test('an inclusive shop is unchanged, and overpayment is still capped at what was billed', () => {
  const order = { id: 'O2', status: 'completed', price: 115, paidAmount: 200, paidAt: '2026-10-02' };
  assert.equal(run(order, VAT15).rows[0].collected, 115);
  const over = { id: 'O3', status: 'completed', price: 100, paidAmount: 150, paidAt: '2026-10-02' };
  assert.equal(run(over, EXCL).rows[0].collected, 108.25, 'capped at price + tax, not at the payment');
});

test('the desktop passes settings to cash flow, caps the payment form by cashDue, and re-derives status on a price edit', () => {
  const fs = require('node:fs'); const path = require('node:path');
  const r = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
  const a = r('analytics.js');
  const at = a.indexOf('KhaytCashFlow.cashFlow({');
  assert.match(a.slice(at, at + 300), /settings,/);
  const f = r('order-flows.js');
  assert.match(f, /KhaytOrderPayment\.cashDue\(order, \{ settings \}\)\.cash/);
  assert.match(f, /const billed = KhaytOrderMoney\.orderGrossRaw\(order, \{ settings \}\);\n\s+if \(\(order\.paidAmount \|\| 0\) > billed\) order\.paidAmount = billed;\n\s+order\.paymentStatus = KhaytOrderPayment\.statusOf\(order, \{ settings \}\);/);
  assert.doesNotMatch(f, /draft\.paidAmount = Math\.min\(Math\.max\(0, rawVal\), \+order\.price \|\| 0\)/);
});

test('an order settled before tax-on-top keeps its status when its plan is edited', () => {
  const Plan = require('../lib/payment-plan.js');
  const M = require('../lib/order-money.js');
  const old = { id: 'O9', price: 100, paidAmount: 100, paymentStatus: 'paid', paidAt: '2026-09-01' };   // no paidGross stamp
  const t = Plan.collectionTotals({ price: old.price, paidAmount: old.paidAmount, instalments: [], due: M.orderDueRaw(old, { settings: EXCL }) });
  assert.equal(t.paymentStatus, 'paid', 'grandfathered: still paid at the pre-tax price');
  const fresh = { ...old, paidGross: true };
  const t2 = Plan.collectionTotals({ price: 100, paidAmount: 100, instalments: [], due: M.orderDueRaw(fresh, { settings: EXCL }) });
  assert.equal(t2.paymentStatus, 'partial', 'a new order owes the tax');
});
