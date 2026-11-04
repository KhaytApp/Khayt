'use strict';

/**
 * A deposit paid through the customer portal is recorded on the job, once
 * (`lib/portal-owner.js recordPortalPayment`), through the shop's own payment
 * rule (`lib/order-payment.js recordPayment`).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
const P = require('../lib/portal-owner.js');

const TODAY = '2026-11-04';
const AT = new Date('2026-11-03T10:00:00').getTime();
const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };

const quote = (over = {}) => Object.assign({
  id: 'ORD-1', status: 'quote', price: 1000, paidAmount: 0, paymentStatus: 'unpaid',
  cloudDeposit: 300, trackingToken: 'tok1',
}, over);
const items = (payment) => [{ token: 'tok1', kind: 'quote', action: null, payment }];
const ctx = { today: TODAY, settings };

test('nothing paid: nothing changes', () => {
  const o = quote();
  assert.equal(P.recordPortalPayment(items(null), 'tok1', o, ctx).outcome, 'none');
  assert.equal(P.recordPortalPayment(items({ status: 'pending', amount: '300' }), 'tok1', o, ctx).outcome, 'none');
  assert.equal(o.paidAmount, 0);
  assert.equal(o.portalPayments, undefined);
});

test('a paid deposit is recorded through the payment rule, dated the day it was paid', () => {
  const o = quote();
  const r = P.recordPortalPayment(items({ status: 'paid', amount: '300', ref: 'pay_abc', at: AT }), 'tok1', o, ctx);
  assert.equal(r.outcome, 'recorded');
  assert.equal(r.amount, 300);
  assert.equal(o.paidAmount, 300);
  assert.equal(o.paymentStatus, 'partial');
  assert.equal(o.paidAt, '2026-11-03');
  assert.equal(o.paidGross, true, 'stamped as every payment the rule records');
  assert.ok(r.effects.some((e) => e.type === 'webhook' && e.event === 'payment_received'));
  assert.equal(o.portalPayments.length, 1);
  assert.equal(o.portalPayments[0].key, 'ref:pay_abc');
  assert.equal(o.portalPayments[0].currency, 'SAR');
});

test('exactly once: a second check, or the other app, changes nothing', () => {
  const o = quote();
  const list = items({ status: 'paid', amount: '300', ref: 'pay_abc', at: AT });
  P.recordPortalPayment(list, 'tok1', o, ctx);
  const again = P.recordPortalPayment(list, 'tok1', o, ctx);
  assert.equal(again.outcome, 'already');
  assert.equal(o.paidAmount, 300);
  // The other app, after a sync, holds the same record with the key on it.
  const synced = JSON.parse(JSON.stringify(o));
  assert.equal(P.recordPortalPayment(list, 'tok1', synced, ctx).outcome, 'already');
  assert.equal(synced.paidAmount, 300);
});

test('without a provider reference the moment the cloud took it is the key', () => {
  const o = quote();
  const r = P.recordPortalPayment(items({ status: 'paid', amount: '', ref: '', at: AT }), 'tok1', o, ctx);
  assert.equal(r.outcome, 'recorded');
  assert.equal(r.amount, 300, 'no amount from the provider: the deposit the link asked for');
  assert.equal(r.key, 'at:tok1:' + AT);
  assert.equal(P.recordPortalPayment(items({ status: 'paid', at: AT }), 'tok1', o, ctx).outcome, 'already');
  // A later payment on the same link is a new one.
  const later = P.recordPortalPayment(items({ status: 'paid', amount: '200', at: AT + 86400000 }), 'tok1', o, ctx);
  assert.equal(later.outcome, 'recorded');
  assert.equal(o.paidAmount, 500);
});

test('a deposit the shop already typed in by hand is noted, not doubled', () => {
  const o = quote({ paidAmount: 300, paidAt: '2026-11-04', paymentStatus: 'partial', paidGross: true });
  const r = P.recordPortalPayment(items({ status: 'paid', amount: '300', ref: 'pay_abc', at: AT }), 'tok1', o, ctx);
  assert.equal(r.outcome, 'matched');
  assert.equal(o.paidAmount, 300);
  assert.equal(o.portalPayments[0].outcome, 'matched');
  assert.equal(P.recordPortalPayment(items({ status: 'paid', amount: '300', ref: 'pay_abc', at: AT }), 'tok1', o, ctx).outcome,
    'already', 'and not looked at again');
});

test('the same amount typed in long before is a different payment', () => {
  const o = quote({ paidAmount: 300, paidAt: '2026-10-01', paymentStatus: 'partial', paidGross: true });
  const r = P.recordPortalPayment(items({ status: 'paid', amount: '300', ref: 'p2', at: AT }), 'tok1', o, ctx);
  assert.equal(r.outcome, 'recorded');
  assert.equal(o.paidAmount, 600);
});

test('a job already settled is noted, and a payment over the bill is capped at it', () => {
  const settled = quote({ paidAmount: 1000, paidAt: '2026-10-01', paymentStatus: 'paid', paidGross: true });
  assert.equal(P.recordPortalPayment(items({ status: 'paid', amount: '300', ref: 'x', at: AT }), 'tok1', settled, ctx).outcome,
    'settled');
  assert.equal(settled.paidAmount, 1000);

  const nearly = quote({ paidAmount: 900, paidAt: '2026-10-01', paymentStatus: 'partial', paidGross: true });
  const r = P.recordPortalPayment(items({ status: 'paid', amount: '300', ref: 'y', at: AT }), 'tok1', nearly, ctx);
  assert.equal(r.outcome, 'recorded');
  assert.equal(nearly.paidAmount, 1000);
  assert.equal(r.amount, 100, 'what was actually added');
});

test('an exclusive shop is paid price + tax, in the job currency, with the saved rate noted', () => {
  const ex = { currency: 'SAR', tax: { name: 'VAT', mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  const o = quote({ price: 100, currency: 'EUR', fxRate: 4.1, cloudDeposit: null });
  const r = P.recordPortalPayment(items({ status: 'paid', amount: '115', ref: 'eur1', at: AT }), 'tok1', o,
    { today: TODAY, settings: ex });
  assert.equal(r.outcome, 'recorded');
  assert.equal(o.paidAmount, 115, 'not clamped to the pre-tax price');
  assert.equal(o.portalPayments[0].currency, 'EUR');
  assert.equal(o.portalPayments[0].fxRate, 4.1);
});

test('paid with no amount anywhere: noted once, nothing recorded', () => {
  const o = quote({ cloudDeposit: null });
  const r = P.recordPortalPayment(items({ status: 'paid', ref: 'z', at: AT }), 'tok1', o, ctx);
  assert.equal(r.outcome, 'no_amount');
  assert.equal(o.paidAmount, 0);
  assert.equal(P.recordPortalPayment(items({ status: 'paid', ref: 'z', at: AT }), 'tok1', o, ctx).outcome, 'already');
});

test('another link\'s payment is not this job\'s', () => {
  const o = quote();
  const list = [{ token: 'other', payment: { status: 'paid', amount: '300', ref: 'q' } }];
  assert.equal(P.recordPortalPayment(list, 'tok1', o, ctx).outcome, 'none');
});
