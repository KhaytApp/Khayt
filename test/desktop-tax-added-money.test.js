'use strict';

/**
 * The desktop's half of #1718: every place that decides paid / partial, caps a
 * payment, or counts profit is given the shop's settings, so a shop that adds
 * tax on top and an inclusive shop each get the figures the Mac shows.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

require('../lib/tax.js');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
const Edit = require('../lib/order-edit.js');
const Portal = require('../lib/portal-refresh.js');

const EXCL = { currency: 'USD', tax: { name: 'Sales Tax', mode: 'exclusive', rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] } };

test('editing the price of a tax-added order keeps a payment that covered the tax', () => {
  // $100 + 8.25% = $108.25, paid in full. Without settings the cap cut it to $100.
  const order = { id: 'O1', price: 100, paidAmount: 108.25, paymentStatus: 'paid', status: 'queued' };
  Edit.applyEdit(order, { price: 100 }, { now: Date.parse('2026-10-02T10:00:00Z'), id: 'e1', settings: EXCL });
  assert.equal(order.paidAmount, 108.25);
  assert.equal(order.paymentStatus, 'paid');

  const lowered = { id: 'O2', price: 200, paidAmount: 216.5, paymentStatus: 'paid', status: 'queued' };
  Edit.applyEdit(lowered, { price: 100 }, { now: Date.parse('2026-10-02T10:00:00Z'), id: 'e2', settings: EXCL });
  assert.equal(lowered.paidAmount, 108.25, 'capped at the new price PLUS its tax');
  assert.equal(lowered.paymentStatus, 'paid');
});

test('without settings, editing behaves exactly as before', () => {
  const order = { id: 'O3', price: 200, paidAmount: 216.5, status: 'queued' };
  Edit.applyEdit(order, { price: 100 }, { now: Date.parse('2026-10-02T10:00:00Z'), id: 'e3' });
  assert.equal(order.paidAmount, 100);
});

test('the customer portal calls a tax-added order paid only once the tax is paid', () => {
  const base = { id: 'O4', status: 'printing', price: 100, trackingToken: 't' };
  const half = Portal.payloadFor({ ...base, paidAmount: 100 }, { settings: EXCL });
  assert.equal(half.payload.paid, false, '$100 of $108.25 is not paid');
  const full = Portal.payloadFor({ ...base, paidAmount: 108.25 }, { settings: EXCL });
  assert.equal(full.payload.paid, true);
});

test('every desktop call site passes the settings (#1718 follow-ups)', () => {
  const r = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
  assert.match(r('app-helpers.js'), /rules\.statusOf\(order, \{ settings:/, 'payStatus');
  assert.match(r('order-flows.js'), /\{ today: localDateStr\(\), settings \}\);/, 'recordPayment cap');
  assert.match(r('currency.js'), /M\(\)\.orderOwedRaw\(o, ctx\(\)\)/, 'orderOwedRaw');
  assert.match(r('wire-events.js'), /A\.restoreDeposit\(entry, \{ settings \}\)/, 'restoreDeposit');
  assert.match(r('order-flows.js'), /applyEdit\(order, \{ price: [^\n]*settings \}\)/, 'price edit');
  const flows = r('order-flows.js');
  const ct = flows.slice(flows.indexOf('KhaytPaymentPlan.collectionTotals({'), flows.indexOf('KhaytPaymentPlan.collectionTotals({') + 700);
  for (const k of ['giftCardDiscount:', 'credited: KhaytOrderMoney.orderCreditedRaw(order)', 'due: KhaytOrderMoney.orderDueRaw(order, { settings })']) assert.ok(ct.includes(k), k);
  assert.match(r('invoicing.js'), /invoiceSummary\(order, _taxProfile\)\.itemsSubtotal/);
});

test('profit and the five business reports count what was earned, as on the Mac', () => {
  const a = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
  // Three machine-profit views, product profit and break-even (#1718); the
  // forecast, client sources, client value, customer mix and cost trends (#1725);
  // operator time tracking (lib/operators.js), which read the typed price.
  assert.equal((a.match(/revenueOf: orderEarnedBase/g) || []).length, 11);
  assert.match(a, /machMap\[o\.machineId\]\.revenue \+= orderEarnedBase\(o\);/);
  for (const mod of ['KhaytForecast.forecast(', 'KhaytClientValue.clientValue(', 'KhaytCustomerMix.customerMix(', 'KhaytCostTrends.costTrends(', 'KhaytClientSources.byClient(']) {
    const at = a.indexOf(mod);
    assert.ok(at > 0, mod);
    assert.match(a.slice(Math.max(0, at - 300), at + 600), /revenueOf: orderEarnedBase/, `${mod} is net of tax`);
  }
});
