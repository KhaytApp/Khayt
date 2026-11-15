'use strict';
/**
 * lib/order-new.js previewTotal and canTake: the total a New Job screen shows
 * while the job is typed is the price newOrder records, and showing it uses
 * no invoice or quote number.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
const N = require('../lib/order-new.js');

const part = (over) => Object.assign({ name: 'p.stl', material: 'PLA', qty: 1, printWeight: 100, printTime: 2, unitCost: 40, baseCost: 40 }, over || {});
const tokens = () => ({ tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) });
const clients = [{ id: 'C-EUR', currency: 'EUR' }, { id: 'C-USD', currency: 'USD' }];
const baseSettings = () => ({ currency: 'SAR', invNumNext: 7, quoteNumNext: 3, rushFeePct: 25, exchangeRates: { EUR: 4 } });

const CASES = [
  { parts: [part()], margin: 30 },
  { parts: [part(), part({ qty: 3, baseCost: 120 })], margin: 55, discountPct: 10 },
  { parts: [part()], margin: 30, rushEnabled: true, shippingCost: 25 },
  { parts: [part()], margin: 30, priceRound: { step: 5, mode: 'up' } },
  { parts: [part()], margin: 30, priceOverride: 99 },
  { parts: [part({ agreedPrice: 70 }), part()], margin: 40 },
  { parts: [part()], margin: 30, extraLines: [{ label: 'Paint', amount: 15 }, { label: 'Fee', pct: 5 }] },
  { parts: [part()], margin: 30, clientId: 'C-EUR' },
  { parts: [part()], margin: 30, clientId: 'C-USD' },
  { parts: [part()], margin: 30, overheadPerHour: 3 },
];

test('previewTotal is the price newOrder records, for every kind of cart', () => {
  for (const [n, input] of CASES.entries()) {
    for (const asQuote of [false, true]) {
      const shown = N.previewTotal(Object.assign({ asQuote }, input), { settings: baseSettings(), clients });
      const job = N.newOrder(Object.assign({ asQuote }, input), { settings: baseSettings(), clients, orders: [], now: new Date('2026-11-15T09:00:00Z'), tokens: tokens() });
      assert.equal(shown.total, job.price, `case ${n}${asQuote ? ' (quote)' : ''}`);
      assert.equal(shown.currency, job.currency, `case ${n} currency`);
    }
  }
});

test('previewTotal allocates nothing: the settings come out as they went in', () => {
  const settings = baseSettings();
  const before = JSON.stringify(settings);
  N.previewTotal({ parts: [part()], margin: 30 }, { settings, clients });
  N.previewTotal({ parts: [part()], margin: 30, asQuote: true }, { settings, clients });
  assert.equal(JSON.stringify(settings), before);
});

test('canTake: a job needs a part', () => {
  assert.deepEqual(N.canTake({ parts: [] }), { ok: false, reason: 'no_parts' });
  assert.deepEqual(N.canTake({}), { ok: false, reason: 'no_parts' });
  assert.deepEqual(N.canTake({ parts: [null] }), { ok: false, reason: 'no_parts' });
  assert.deepEqual(N.canTake({ parts: [part()] }), { ok: true, reason: null });
});

test('a customer in another currency is really priced in it, and the three currency outcomes are pinned', () => {
  const ctx = { settings: baseSettings(), clients };
  const own = N.previewTotal({ parts: [part()], margin: 30 }, ctx);
  const eur = N.previewTotal({ parts: [part()], margin: 30, clientId: 'C-EUR' }, ctx);
  const usd = N.previewTotal({ parts: [part()], margin: 30, clientId: 'C-USD' }, ctx);
  assert.equal(own.currency, undefined, "the shop's own currency leaves the record's currency unset, as newOrder does");
  assert.equal(eur.currency, 'EUR');
  assert.equal(eur.total, own.total / 4, 'converted at exchangeRates.EUR (4 SAR per EUR)');
  assert.equal(usd.currency, 'SAR', 'no rate for USD: an honest price in the shop currency');
  assert.equal(usd.total, own.total);
});
