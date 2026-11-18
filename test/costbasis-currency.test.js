'use strict';
/**
 * costBasis is the SHOP's currency in every job: it is the parts' baseCost
 * summed (lib/order-status.js), and newOrder converts a job's PRICE into its
 * currency, never its cost. Every reader treats it so (money review, Nov 19):
 * the P&L converted it by the job's rate (a USD job at 3.75 with 40 SAR of
 * parts counted 150), the average margin likewise, ai-price compared a USD
 * price with a SAR cost, and the kit rollup refused to add two currencies of
 * what was one. The same job taken in SAR or in USD must cost the same.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'calculator-cost', 'print-rates']) require('../lib/' + f + '.js');
const Pnl = require('../lib/pnl-report.js');
const AI = require('../lib/ai-price.js');
const Kits = require('../lib/print-kits.js');

const settings = { currency: 'SAR', exchangeRates: { USD: 3.75 }, enableVat: false };
const base = { status: 'completed', date: '2026-11-10', completedAt: '2026-11-10T10:00:00Z', parts: [{ baseCost: 40 }], costBasis: 40 };
const sar = Object.assign({ id: 'SAR-1', currency: 'SAR', price: 100, paidAmount: 100, paymentStatus: 'paid' }, base);
const usd = Object.assign({ id: 'USD-1', currency: 'USD', fxRate: 3.75, price: 26.67, paidAmount: 26.67, paymentStatus: 'paid' }, base);
const cogs = (orders) => Pnl.pnlByPeriod(orders, [], { settings, now: new Date('2026-11-19T00:00:00Z'), granularity: 'month' })
  .reduce((s, r) => s + (+r.cogs || 0), 0);

test('the P&L counts a USD job\'s parts at what they cost the shop (40), not × 3.75 (150)', () => {
  assert.equal(Math.round(cogs([sar]) * 100) / 100, Math.round(cogs([usd]) * 100) / 100);
  assert.ok(cogs([usd]) < 41, `USD job COGS ${cogs([usd])}`);
});

test('ai-price compares like with like: the same job in SAR and in USD is a comparable at the same margin (60%)', () => {
  // realizedMargin is internal; buildComparables reads it for every finished job.
  const one = (o) => AI.buildComparables([o], { profile: null });
  const a = JSON.stringify(one(sar)), b = JSON.stringify(one(usd));
  const m = (j) => JSON.parse(j).medianMarginPct;
  const ma = m(a), mb = m(b);
  assert.ok(ma !== undefined && mb !== undefined, 'buildComparables reports a margin: ' + a);
  assert.ok(Math.abs(ma - mb) < 0.1, `SAR ${ma} vs USD ${mb}`);
});

test('a kit with a SAR job and a USD job adds their costs (both are the shop\'s)', () => {
  const r = Kits.rollup([sar, usd]);
  assert.equal(r.cost, 80);
  assert.equal(r.mixedCurrency, false);
});
