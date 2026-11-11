'use strict';
/**
 * `POST /api/quote` as a shared rule (`lib/lan-rest.js quotePart`).
 *
 * The desktop's server carried this inline and the Mac did not serve it, so
 * the phone's "ask the Mac" calculator always failed against a Mac (the Nov 10
 * 2026 review). The rule is lifted here for both; these pin its answer to the
 * cost and pricing modules it is made of.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/lan-rest.js');
const Cost = require('../lib/calculator-cost.js');
const Pricing = require('../lib/pricing.js');

const store = { settings: { currency: 'SAR', rushFeePct: 25 }, inventory: [{ id: 'S1', material: 'PLA' }] };
const part = { filamentId: 'S1', spoolCost: 80, spoolWeight: 1000, printWeight: 100, printTime: 2, qty: 2, margin: 50 };

test('the cost is calculator-cost\'s and the price is pricing\'s', () => {
  const out = R.quotePart(store, part, { today: '2026-11-10', overheadPerHour: 0 });
  assert.equal(out.status, 200);
  const unit = Cost.computePartBaseCost(part, { inventory: store.inventory, settings: store.settings });
  assert.ok(unit > 0);
  assert.equal(out.body.unitCost, Math.round(unit * 10000) / 10000);
  assert.equal(out.body.totalCost, Math.round(unit * 2 * 10000) / 10000);
  const price = Pricing.quoteTotal({ baseCost: unit * 2, qty: 2, margin: 50, overheadPerHour: 0, printHours: 4,
    priceTier: null, rushEnabled: false, rushPct: 25 });
  assert.equal(out.body.price.total, Math.round(price.total * 10000) / 10000);
  assert.equal(out.body.currency, 'SAR');
  assert.equal(out.body.priceTier, null);
});

test('rush uses the shop\'s percentage; a price tier replaces cost-plus and charges no overhead', () => {
  const rush = R.quotePart(store, Object.assign({}, part, { rush: true }), { overheadPerHour: 0 }).body;
  assert.ok(rush.price.rushFee > 0);
  const tiered = R.quotePart(store, Object.assign({}, part, { qty: 10, priceTiers: [{ minQty: 5, pricePerUnit: 30 }] }),
    { overheadPerHour: 9 }).body;
  assert.deepEqual(tiered.priceTier, { minQty: 5, pricePerUnit: 30 });
  assert.equal(tiered.price.overhead, 0);
  const hourly = R.quotePart(store, part, { overheadPerHour: 9 }).body;
  assert.ok(hourly.price.overhead > 0, 'fixed costs per print hour are charged when the shop turned them on');
});

test('a body that is not a part is refused, and the quantity is held to a sane range', () => {
  assert.equal(R.quotePart(store, null, {}).status, 400);
  assert.equal(R.quotePart(store, [1], {}).status, 400);
  assert.equal(R.quotePart(store, Object.assign({}, part, { qty: -4 }), { overheadPerHour: 0 }).body.qty, 1);
  assert.equal(R.quotePart(store, Object.assign({}, part, { qty: 1e9 }), { overheadPerHour: 0 }).body.qty, 100000);
});

test('with no today in ctx, the overhead rate is asked for a real day, not "NaN-NaN-NaN"', () => {
  assert.match(R.localDay(), /^\d{4}-\d{2}-\d{2}$/, 'a bare localDay() is today');
  const seen = [];
  const saved = globalThis.KhaytPublicQuote;
  globalThis.KhaytPublicQuote = { overheadPerHourFor: (_book, day) => { seen.push(day); return 0; } };
  try {
    R.quotePart(store, part, {});
    R.quotePart(store, part, { nowMs: Date.parse('2026-03-04T10:00:00') });
  } finally {
    if (saved === undefined) delete globalThis.KhaytPublicQuote; else globalThis.KhaytPublicQuote = saved;
  }
  assert.match(seen[0], /^\d{4}-\d{2}-\d{2}$/, `no ctx: ${seen[0]}`);
  assert.equal(seen[1], '2026-03-04', 'ctx.nowMs decides the day when today is not given');
});
