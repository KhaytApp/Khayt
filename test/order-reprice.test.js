'use strict';
/**
 * lib/order-edit.js `repriceTerms` re-prices a job FORWARD from what it was
 * priced from (lib/pricing.js `quoteTotal`, as lib/order-new.js stored the
 * inputs), not backwards from the price. It used to add the agreed part
 * amounts a second time and drop the rush fee.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/product-price.js');
const Pricing = require('../lib/pricing.js');
const M = require('../lib/order-money.js');
require('../lib/order-payment.js');
const E = require('../lib/order-edit.js');

test('a job holding agreed parts adds shipping once: 150 + 10 is 160, not 210', () => {
  const o = { price: 150, discountPct: 0, priceBeforeDiscount: null, shippingCost: 0, agreedAmount: 50 };
  assert.equal(E.repriceTerms(o, { shippingCost: 10 }, {}), true);
  assert.equal(o.price, 160);
  assert.equal(o.agreedAmount, 50);
});

test('a rushed, discounted job keeps its rush fee when shipping is added', () => {
  // 100 base, 10% off = 90, 25% rush = 22.50 → 112.50.
  const o = { price: 112.5, discountPct: 10, priceBeforeDiscount: 100, shippingCost: 0,
              rushFee: 22.5, rushFeeAmount: 22.5 };
  E.repriceTerms(o, { shippingCost: 10 }, {});
  assert.equal(o.price, 122.5, 'was 100: the rush fee fell off and the price dropped');
  assert.equal(o.rushFeeAmount, 22.5);
  // A discount change rebuilds the rush on the new subtotal: 80 × 1.25 + 10.
  E.repriceTerms(o, { discountPct: 20 }, {});
  assert.equal(o.price, 110);
  assert.equal(o.rushFeeAmount, 20);
  assert.equal(o.rushFee, 20);
  assert.equal(o.priceBeforeDiscount, 100);
});

test('the forward re-price is what quoteTotal gives for the new terms', () => {
  const inputs = { baseCost: 80, margin: 25, agreedAmount: 40, rushEnabled: true, rushPct: 25 };
  const q0 = Pricing.quoteTotal(Object.assign({ discountPct: 15, shippingCost: 5, extraLines: [{ amount: 7 }] }, inputs));
  const o = { price: +q0.total.toFixed(2), discountPct: 15, priceBeforeDiscount: +q0.priceBeforeDiscount.toFixed(2),
              agreedAmount: 40, shippingCost: 5, extraLines: [{ label: 'Box', amount: 7 }],
              rushFee: +q0.rushFee.toFixed(2), rushFeeAmount: +q0.rushFee.toFixed(2) };
  E.repriceTerms(o, { discountPct: 5, shippingCost: 12, extraLines: [{ amount: 3 }] }, {});
  const q1 = Pricing.quoteTotal(Object.assign({ discountPct: 5, shippingCost: 12, extraLines: [{ amount: 3 }] }, inputs));
  assert.equal(o.price, +q1.total.toFixed(2));
  assert.equal(o.rushFeeAmount, +q1.rushFee.toFixed(2));
});

test('a rounded job is rounded again by its own rule', () => {
  // computed 147.36 → rounded to 150 (step 10, nearest).
  const o = { price: 150, computedPrice: 147.36, priceSource: 'rounded', priceRound: { step: 10, mode: 'nearest' },
              discountPct: 0, shippingCost: 0 };
  E.repriceTerms(o, { shippingCost: 20 }, {});
  assert.equal(o.computedPrice, 167.36);
  assert.equal(o.price, 170);
});

test('a typed price stays as typed, moved only by the term that changed', () => {
  // Arithmetic said 112.50; the shop typed 100.
  const o = { price: 100, priceSource: 'override', priceOverride: 100, computedPrice: 112.5,
              discountPct: 10, priceBeforeDiscount: 100, shippingCost: 0, rushFeeAmount: 22.5, rushFee: 22.5 };
  E.repriceTerms(o, { shippingCost: 15 }, {});
  assert.equal(o.price, 115, 'the typed 100 plus the 15 of shipping, not re-derived to 127.50');
  assert.equal(o.priceOverride, 115);
  assert.equal(o.priceSource, 'override');
  assert.equal(o.computedPrice, 127.5);
});

test('a price edited by hand without a marker is treated as typed too', () => {
  // The inputs give 112.50 but the job reads 105: someone changed it.
  const o = { price: 105, discountPct: 10, priceBeforeDiscount: 100, shippingCost: 0, rushFeeAmount: 22.5 };
  E.repriceTerms(o, { shippingCost: 10 }, {});
  assert.equal(o.price, 115);
});

test('an old job with no stored inputs is recovered from its price, without double counting', () => {
  const o = { price: 230, shippingCost: 30, discountPct: 0, extraLines: [{ label: 'Design', amount: 20 }] };
  E.repriceTerms(o, { discountPct: 10 }, {});
  // base 180, 10% off = 162, + 30 + 20.
  assert.equal(o.price, 212);
  assert.equal(o.priceBeforeDiscount, 180);
  assert.equal('rushFeeAmount' in o, false, 'no rush field invented on a job that had none');
  // And back again: the stored base takes over, same answer as before.
  E.repriceTerms(o, { discountPct: 0 }, {});
  assert.equal(o.price, 230);
});

test('an old job with a rush fee but no stored base keeps the rush out of the discount', () => {
  // 80 subtotal + 20 rush (25%) + 10 shipping = 110, no discount, nothing else stored.
  const o = { price: 110, shippingCost: 10, discountPct: 0, rushFeeAmount: 20 };
  E.repriceTerms(o, { discountPct: 50 }, {});
  // 40 + 25% = 50, + 10.
  assert.equal(o.price, 60);
  assert.equal(o.rushFeeAmount, 10);
});

test('an edit that changes nothing leaves the price exactly as it was', () => {
  const o = { price: 112.37, discountPct: 10, priceBeforeDiscount: 99.99, shippingCost: 4.5,
              agreedAmount: 12, rushFeeAmount: 3.33, extraLines: [{ amount: 1.11 }] };
  const before = JSON.stringify(o);
  assert.equal(E.repriceTerms(o, { discountPct: 10, shippingCost: 4.5, extraLines: [{ amount: 1.11 }] }, {}), false);
  assert.equal(JSON.stringify(o), before);
  const r = E.applyDetails(o, { discountPct: 10, shippingCost: 4.5 }, { now: Date.now(), id: 'e1' });
  assert.equal(r.changed, false);
  assert.equal(o.price, 112.37);
});

test('a tax-on-top shop re-prices the pre-tax price and caps paid at price + tax', () => {
  const settings = { currency: 'USD', tax: { name: 'Sales Tax', mode: 'exclusive', rates: [{ id: 'st', label: 'Sales tax', percent: 10 }] } };
  // 150 pre-tax (100 costed + 50 agreed) + 10% tax = 165, paid in full.
  const o = { price: 150, discountPct: 0, shippingCost: 0, agreedAmount: 50,
              paidAmount: 165, paidGross: true, paymentStatus: 'paid' };
  E.repriceTerms(o, { discountPct: 20 }, { settings });
  // 100 × 0.8 + 50 = 130 pre-tax; the agreed 50 is not discounted.
  assert.equal(o.price, 130);
  assert.equal(M.orderGrossRaw(o, { settings }), 143);
  assert.equal(o.paidAmount, 143, 'paid capped at the new price + tax, not at the pre-tax price');
  assert.equal(o.paymentStatus, 'paid');
});
