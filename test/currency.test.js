const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/format.js');
const { convertToBase, clientCurrency, orderCurrency, orderRevenueBase, fmtPrice } = require('../renderer/currency.js');

test('convertToBase uses exchange rate', () => {
  global.settings = { currency: 'SAR', exchangeRates: { USD: 3.75 } };
  assert.equal(convertToBase(10, 'USD'), 37.5);
  assert.equal(convertToBase(10, 'SAR'), 10);
});

test('clientCurrency prefers client override', () => {
  global.settings = { currency: 'SAR' };
  global.clients = [{ id: 'c1', currency: 'USD' }];
  assert.equal(clientCurrency('c1'), 'USD');
  assert.equal(clientCurrency(null), 'SAR');
});

test('fmtPrice uses settings currency', () => {
  global.settings = { currency: 'USD' };
  assert.match(fmtPrice(10), /^\$\u202f10\.00$/);
});

test('orderCurrency: per-order override wins, then client, then base', () => {
  global.settings = { currency: 'SAR' };
  global.clients = [{ id: 'c1', currency: 'USD' }, { id: 'c2' }];
  assert.equal(orderCurrency({ currency: 'EUR', clientId: 'c1' }), 'EUR'); // override
  assert.equal(orderCurrency({ clientId: 'c1' }), 'USD');                  // client currency
  assert.equal(orderCurrency({ clientId: 'c2' }), 'SAR');                  // client w/o currency → base
  assert.equal(orderCurrency({}), 'SAR');                                  // no client → base
  assert.equal(orderCurrency({ currency: 'ZZZ', clientId: 'c1' }), 'USD'); // unknown code ignored
});

test('orderRevenueBase converts via the order currency override', () => {
  global.settings = { currency: 'SAR', exchangeRates: { USD: 3.75, EUR: 4 } };
  global.clients = [{ id: 'c1', currency: 'USD' }, { id: 'c2' }];
  assert.equal(orderRevenueBase({ price: 100, currency: 'EUR', clientId: 'c1' }), 400); // override EUR@4
  assert.equal(orderRevenueBase({ price: 100, clientId: 'c1' }), 375);                  // client USD@3.75
  assert.equal(orderRevenueBase({ price: 100, clientId: 'c2' }), 100);                  // base unchanged
});

test('orderOwedBase subtracts payments and gift card credit', () => {
  const { orderOwedBase } = require('../renderer/currency.js');
  global.settings = { currency: 'SAR' };
  global.clients = [];
  assert.equal(orderOwedBase({ price: 100, paidAmount: 40, giftCardDiscount: 10 }), 50);
  assert.equal(orderOwedBase({ price: 100, paidAmount: 100 }), 0);
  // Credit notes reduce what's owed (refund / cancelled charge).
  assert.equal(orderOwedBase({ price: 100, paidAmount: 0, creditNotes: [{ amount: 100 }] }), 0);
  assert.equal(orderOwedBase({ price: 100, paidAmount: 0, creditNotes: [{ amount: 30 }] }), 70);
});
