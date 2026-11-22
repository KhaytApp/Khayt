'use strict';
/**
 * What one order is worth, and what is still owed on it.
 *
 * This is the single chokepoint for revenue in every reported figure — 53 call
 * sites — lifted out of renderer/currency.js so the Mac app can use the same
 * rules instead of inventing its own.
 *
 * The danger in moving code like this is not a crash. It is a shop's revenue
 * moving by a few riyals and nobody noticing for a quarter. So the first test
 * runs the ORIGINAL implementations and the extracted module over a few hundred
 * generated orders and compares every figure.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
const M = require('../lib/order-money.js');

const CURRENCIES = { SAR: {}, USD: {}, EUR: {}, KWD: {} };

/** The renderer's globals, as the original code read them. */
function makeGlobals(settings, clients) {
  return { settings, clients };
}

/* ── The originals, copied verbatim from renderer/currency.js before the move ── */
function original(g) {
  const { settings, clients } = g;
  const KhaytBusinessScope = globalThis.KhaytBusinessScope;
  function clientCurrency(clientId) {
    if (!clientId) return settings.currency || 'SAR';
    const c = clients.find((x) => x.id === clientId);
    return c && c.currency ? c.currency : settings.currency || 'SAR';
  }
  function orderCurrency(o) {
    if (o && o.currency && CURRENCIES[o.currency]) return o.currency;
    return clientCurrency(o && o.clientId);
  }
  function convertToBase(amount, fromCurrency) {
    const base = settings.currency || 'SAR';
    if (!fromCurrency || fromCurrency === base) return +amount || 0;
    const rate = (settings.exchangeRates || {})[fromCurrency];
    if (!rate || rate <= 0) return +amount || 0;
    return (+amount || 0) * rate;
  }
  const orderRevenueBase = (o) => convertToBase(+o.price || 0, orderCurrency(o));
  const orderCreditedRaw = (o) => ((o && o.creditNotes) || []).reduce((s, cn) => s + (+cn.amount || 0), 0);
  const orderCreditedBase = (o) => convertToBase(orderCreditedRaw(o), orderCurrency(o));
  function orderNetRevenueBase(o) {
    if (typeof KhaytBusinessScope !== 'undefined' && !KhaytBusinessScope.countsForBusiness(o)) return 0;
    if (typeof KhaytBusinessScope !== 'undefined' && KhaytBusinessScope.isSuperseded(o)) return 0;
    return Math.max(0, orderRevenueBase(o) - orderCreditedBase(o));
  }
  function orderOwedRaw(o) {
    if (typeof KhaytBusinessScope !== 'undefined' && !KhaytBusinessScope.countsForBusiness(o)) return 0;
    if (typeof KhaytBusinessScope !== 'undefined' && KhaytBusinessScope.isSuperseded(o)) return 0;
    return Math.max(0, (+o.price || 0) - (+o.paidAmount || 0) - (+o.giftCardDiscount || 0) - orderCreditedRaw(o));
  }
  function orderOwedBase(o) {
    if (typeof KhaytBusinessScope !== 'undefined' && !KhaytBusinessScope.countsForBusiness(o)) return 0;
    if (typeof KhaytBusinessScope !== 'undefined' && KhaytBusinessScope.isSuperseded(o)) return 0;
    const cur = orderCurrency(o);
    return Math.max(0, convertToBase(+o.price || 0, cur) - convertToBase(+o.paidAmount || 0, cur)
      - convertToBase(+o.giftCardDiscount || 0, cur) - orderCreditedBase(o));
  }
  return { clientCurrency, orderCurrency, convertToBase, orderRevenueBase,
    orderCreditedRaw, orderCreditedBase, orderNetRevenueBase, orderOwedRaw, orderOwedBase };
}

/** Deterministic pseudo-random, so a failure is reproducible. */
function lcg(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
}

test('every figure matches the original, over generated orders', () => {
  const rnd = lcg(20260904);
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const settingsCases = [
    { currency: 'SAR', exchangeRates: { USD: 3.75, EUR: 4.1 } },
    { currency: 'USD', exchangeRates: { SAR: 0.27 } },
    { currency: 'SAR' },                                  // no rates at all
    { currency: 'SAR', exchangeRates: { USD: 0 } },        // a rate of zero
    {},                                                    // no currency either
  ];
  const clients = [
    { id: 'c1', currency: 'USD' }, { id: 'c2', currency: 'EUR' },
    { id: 'c3' }, { id: 'c4', currency: 'JPY' },           // a currency with no rate
  ];

  let checked = 0;
  for (const settings of settingsCases) {
    const g = makeGlobals(settings, clients);
    const was = original(g);
    const ctx = { settings, clients };
    for (let i = 0; i < 120; i++) {
      const o = {
        id: 'O' + i,
        price: pick([0, 100, 1234.56, -50, null, undefined]),
        paidAmount: pick([0, 50, 100, 2000, null]),
        giftCardDiscount: pick([0, 25, null]),
        currency: pick([undefined, 'SAR', 'USD', 'EUR', 'JPY', 'ZZZ']),
        clientId: pick([undefined, 'c1', 'c2', 'c3', 'c4', 'missing']),
        creditNotes: pick([undefined, [], [{ amount: 30 }], [{ amount: 10 }, { amount: 5 }]]),
        isPersonal: pick([undefined, true, false]),
        supersededBy: pick([undefined, 'ORD-9']),
      };
      for (const fn of ['orderCurrency', 'orderRevenueBase', 'orderCreditedRaw',
                        'orderCreditedBase', 'orderNetRevenueBase', 'orderOwedRaw', 'orderOwedBase']) {
        const mine = fn === 'orderCreditedRaw' || fn === 'orderOwedRaw'
          ? M[fn](o) : M[fn](o, ctx, CURRENCIES);
        assert.equal(mine, was[fn](o),
          `${fn} differs for ${JSON.stringify(o)} under ${JSON.stringify(settings)}`);
        checked++;
      }
    }
  }
  assert.ok(checked > 4000, `only ${checked} comparisons`);
});

test('a missing exchange rate leaves the amount unconverted, never zero', () => {
  // The worse of the two wrong answers is hiding revenue: a shop notices a
  // wrong total sooner than a missing one.
  const ctx = { settings: { currency: 'SAR', exchangeRates: {} }, clients: [] };
  assert.equal(M.convertToBase(100, 'USD', ctx), 100);
  assert.equal(M.convertToBase(100, 'USD', { settings: { currency: 'SAR', exchangeRates: { USD: 0 } } }), 100);
});

test('a gift card pays an order down but is not a discount on the sale', () => {
  // Netting it against revenue would make it revenue nowhere at all: the card
  // was sold separately, and redemption is the only moment it can be earned.
  const ctx = { settings: { currency: 'SAR' }, clients: [] };
  const o = { price: 100, giftCardDiscount: 40 };
  assert.equal(M.orderNetRevenueBase(o, ctx), 100, 'revenue is untouched by a gift card');
  assert.equal(M.orderOwedBase(o, ctx), 60, 'but it does pay the order down');
});

test('a credit note is a real reduction of the sale', () => {
  const ctx = { settings: { currency: 'SAR' }, clients: [] };
  const o = { price: 100, creditNotes: [{ amount: 40 }] };
  assert.equal(M.orderNetRevenueBase(o, ctx), 60);
  assert.equal(M.orderOwedBase(o, ctx), 60);
});

test('neither figure ever goes negative', () => {
  const ctx = { settings: { currency: 'SAR' }, clients: [] };
  assert.equal(M.orderNetRevenueBase({ price: 10, creditNotes: [{ amount: 99 }] }, ctx), 0);
  assert.equal(M.orderOwedBase({ price: 10, paidAmount: 99 }, ctx), 0);
});

test('an order currency the app does not know falls through to the client', () => {
  const ctx = { settings: { currency: 'SAR' }, clients: [{ id: 'c1', currency: 'USD' }] };
  assert.equal(M.orderCurrency({ currency: 'ZZZ', clientId: 'c1' }, ctx, CURRENCIES), 'USD');
  // Without a catalogue, any code is taken at its word.
  assert.equal(M.orderCurrency({ currency: 'ZZZ', clientId: 'c1' }, ctx), 'ZZZ');
});
