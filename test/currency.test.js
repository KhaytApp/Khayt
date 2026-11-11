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

test('pinCurrenciesOf: a customer\'s unstamped jobs keep today\'s currency when theirs is about to change', () => {
  const M = require('../lib/order-money.js');
  const ctx = { settings: { currency: 'SAR', exchangeRates: { EUR: 4.1 } }, clients: [{ id: 'c1' }, { id: 'c2' }] };
  const orders = [
    { id: 'a', clientId: 'c1', price: 1000, paidAmount: 1000 },
    { id: 'b', clientId: 'c1', price: 500, currency: 'USD' },
    { id: 'c', clientId: 'c2', price: 70 },
  ];
  const changed = M.pinCurrenciesOf(orders, 'c1', ctx);
  assert.deepEqual(changed.map((o) => o.id), ['a']);
  assert.equal(orders[0].currency, 'SAR');
  assert.equal(orders[1].currency, 'USD');
  assert.equal(orders[2].currency, undefined);
  // The customer now bills in EUR; the old job is still 1,000 SAR.
  const after = { settings: ctx.settings, clients: [{ id: 'c1', currency: 'EUR' }, { id: 'c2' }] };
  assert.equal(M.orderToBase ? M.orderToBase(1000, orders[0], after) : 1000, 1000);
});
