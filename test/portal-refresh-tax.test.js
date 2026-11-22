/**
 * The customer's tracking link asks for what the customer actually owes.
 *
 * `payloadFor` sent `amount: (+o.price).toFixed(2)`. On a shop that adds tax on
 * top the price is the PRE-TAX figure, so the portal read "100.00" while 108.25
 * was owed. It sends `orderGrossRaw` now, which is mode-aware: a VAT-inclusive
 * shop and a shop with no tax are unchanged.
 *
 * Its own file: the parity proof in `portal-refresh.test.js` runs with no money
 * module loaded, and loading one here must not reach it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/currencies.js');
require('../lib/tax.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
require('../lib/portal-trial.js');
require('../lib/cloud-plans.js');
const Portal = require('../lib/portal-refresh.js');

const salesTax = { currency: 'USD', tax: { name: 'Sales Tax', mode: 'exclusive',
  rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] } };
const vat15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const noTax = { currency: 'SAR' };

const job = (extra) => Object.assign({
  id: 'J1', status: 'printing', price: 100, paidAmount: 0, trackingToken: 't',
}, extra || {});

const pay = (order, settings) => Portal.payloadFor(order, { settings, shopName: 'Shop' }).payload;

test('tax on top: the amount and the balance are the price plus the tax', () => {
  const p = pay(job(), salesTax);
  assert.equal(p.amount, '108.25');
  assert.equal(p.balanceDue, '108.25');
  // Paid the bare price: the tax is still owed.
  assert.equal(pay(job({ paidAmount: 100 }), salesTax).balanceDue, '8.25');
  // Paid in full: nothing owed.
  assert.equal(pay(job({ paidAmount: 108.25 }), salesTax).balanceDue, undefined);
});

test('VAT inside the price, and no tax at all: unchanged', () => {
  for (const settings of [vat15, noTax, {}]) {
    const p = pay(job({ price: 115, paidAmount: 15 }), settings);
    assert.equal(p.amount, '115.00');
    assert.equal(p.balanceDue, '100.00');
  }
});
