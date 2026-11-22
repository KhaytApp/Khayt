const { test } = require('node:test');
const assert = require('node:assert/strict');

const { computePartBaseCost, partTotalCost, getActivePriceTier, computePartBreakdown } = require('../lib/calculator-cost.js');

test('computePartBaseCost for simple FDM part', () => {
  global.inventory = [];
  global.settings = { defaultPackagingCost: 0 };
  const cost = computePartBaseCost({
    spoolCost: 100,
    spoolWeight: 1000,
    printWeight: 50,
    printTime: 2,
    wearRate: 1,
    powerDraw: 0,
    elecRate: 0,
    prepTime: 0,
    postTime: 0,
    laborRate: 0,
    failureRate: 0,
  });
  assert.equal(cost, 7);
});

test('getActivePriceTier picks highest matching tier', () => {
  const tier = getActivePriceTier({
    qty: 10,
    priceTiers: [
      { minQty: 1, price: 9 },
      { minQty: 5, price: 8 },
    ],
  });
  assert.equal(tier.price, 8);
});

test('computePartBreakdown splits cost buckets', () => {
  global.inventory = [];
  const b = computePartBreakdown({
    spoolCost: 100,
    spoolWeight: 100,
    printWeight: 10,
    printTime: 1,
    wearRate: 2,
    powerDraw: 0,
    elecRate: 0,
    prepTime: 0,
    postTime: 0,
    laborRate: 0,
    failureRate: 10,
  });
  assert.ok(b.material > 0);
  assert.ok(b.machine > 0);
  assert.ok(b.buffer > 0);
});

test('resin material uses per-kg formula', () => {
  global.inventory = [{ id: 'R1', materialType: 'resin' }];
  global.settings = { defaultPackagingCost: 0 };
  // spoolCost here is price-per-kg for resin: 150/kg × 20 g = 3.00
  const cost = computePartBaseCost({
    filamentId: 'R1', spoolCost: 150, spoolWeight: 1000, printWeight: 20, failureRate: 0,
  });
  assert.equal(cost, 3);
});

test('blended multicolour part never uses the resin per-kg branch', () => {
  // Regression: the planner sets spoolCost=Σmoney, spoolWeight=Σgrams and a
  // fallback filamentId that may point at a resin spool. The blended part must
  // still cost as the FDM ratio (spoolCost), not (spoolCost/1000)*grams.
  global.inventory = [{ id: 'R1', materialType: 'resin' }];
  global.settings = { defaultPackagingCost: 0 };
  const part = {
    filamentId: 'R1',            // dominant spool happens to be resin
    colours: [{ filamentId: 'R1', grams: 80, cost: 6 }, { filamentId: 'F2', grams: 20, cost: 2 }],
    spoolCost: 8, spoolWeight: 100, printWeight: 100, failureRate: 0,
  };
  assert.equal(computePartBaseCost(part), 8);           // true blended total, not ~0.8
  assert.equal(computePartBreakdown(part).material, 8); // preview agrees with committed
});

/* ── qty is part of the cost basis ──────────────────────────────────────────
 * computePartBaseCost() is PER UNIT (packaging is divided by qty). Summing it
 * across an order and comparing to the order's revenue understates cost by a
 * factor of qty — which underpriced every duplicated/reprinted order and
 * inflated every margin in analytics and the P&L export. */

const QTY_PART = {
  spoolCost: 100, spoolWeight: 1000, printWeight: 15, printTime: 0.5,
  wearRate: 1, powerDraw: 0, elecRate: 0, prepTime: 0, postTime: 0,
  laborRate: 0, failureRate: 0,
};
const withQtyGlobals = () => { global.inventory = []; global.settings = { defaultPackagingCost: 0 }; };

test('partTotalCost multiplies the per-unit cost by the line quantity', () => {
  withQtyGlobals();
  const part = { ...QTY_PART, qty: 100 };
  const unit = computePartBaseCost(part);
  assert.ok(unit > 0, 'fixture should have a real cost');
  assert.equal(partTotalCost(part), unit * 100);
});

test('partTotalCost treats a missing/invalid qty as one unit, never zero', () => {
  withQtyGlobals();
  const base = { ...QTY_PART };
  const unit = computePartBaseCost(base);
  for (const qty of [undefined, null, 0, -5, NaN, 'abc']) {
    assert.equal(partTotalCost({ ...base, qty }), unit, `qty=${String(qty)} must cost one unit, not zero`);
  }
});

test('a 100-unit line is not priced as one unit (the duplicate-order defect)', () => {
  // Reproduces the shipped bug: duplicateOrder stored the per-unit cost as the line's
  // baseCost while keeping qty:100 — so it printed 100 units and quoted for 1.
  withQtyGlobals();
  const part = { ...QTY_PART, qty: 100 };
  const wrong = computePartBaseCost(part);       // what the old rebuild path stored
  const right = partTotalCost(part);             // what the calculator stores
  assert.ok(right > wrong * 50, 'line total must scale with quantity');
  assert.equal(right / wrong, 100);
});

test('a part costs its consumables, at the shelf price, else the price it was written with', () => {
  const part = {
    spoolCost: 0, spoolWeight: 1000, printWeight: 0, printTime: 0, qty: 2,
    consumables: [{ consumableId: 'mag', qty: 4, unitCost: 0.5 }, { consumableId: 'gone', qty: 1, unitCost: 2 }],
  };
  const ctx = { inventory: [], settings: {}, consumables: [{ id: 'mag', cost: 0.25 }] };
  // 4 × 0.25 (shelf) + 1 × 2 (written) = 3 per piece; qty multiplies only in partTotalCost.
  assert.equal(computePartBaseCost(part, ctx), 3);
  assert.equal(partTotalCost(part, ctx), 6);
  // No consumables in reach: every line at its own unitCost.
  assert.equal(computePartBaseCost(part, { inventory: [], settings: {} }), 4);
  const b = computePartBreakdown(part, ctx);
  assert.equal(b.material, 3, 'folded into the material bucket, so the buckets still add up');
  // Untouched parts are unchanged.
  assert.equal(computePartBaseCost({ spoolCost: 100, spoolWeight: 1000, printWeight: 50 }, ctx), 5);
});
