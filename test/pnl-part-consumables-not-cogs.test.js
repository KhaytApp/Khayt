'use strict';

/**
 * A part's own consumables (magnets, inserts — `part.consumables`) are priced
 * into its material bucket, but they are NOT stock: a consumable purchase is
 * booked as an expense (`other`, lib/purchase-orders.js). So the P&L's cost of
 * goods leaves them out — counted there too, every magnet was paid for twice —
 * while every per-job figure (job cost, product profit) keeps them, exactly
 * as a product's components (shop decision, 2026-10-04).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
const CC = require('../lib/calculator-cost.js');
const { pnlByPeriod, stockShare } = require('../lib/pnl-report.js');
const { orderCost } = require('../lib/kpi-rows.js');
const { productProfit } = require('../lib/product-profit.js');

// 100 g of a 100-a-kilo spool = 10.00 material; 4 magnets at 2.00 = 8.00.
const shelf = [{ id: 'mag', name: 'Magnet', cost: 2 }];
const plain = { spoolCost: 100, spoolWeight: 1000, printWeight: 100, qty: 1 };
const magnets = { ...plain, consumables: [{ consumableId: 'mag', qty: 4, unitCost: 2 }] };
const ctx = { consumables: shelf };
const close = (a, b) => Math.abs(a - b) < 1e-9;

function job(part) {
  const cost = CC.partTotalCost(part, ctx);
  return { id: 'J1', status: 'completed', date: '2026-08-10', price: 50, costBasis: cost,
    parts: [{ ...part, baseCost: cost }] };
}

test('the per-job cost still includes the magnets', () => {
  assert.ok(close(CC.partTotalCost(magnets, ctx), 18), 'material 10 + magnets 8');
  const { rows } = productProfit({ orders: [job(magnets)] }, { partCostOf: (p) => CC.partTotalCost(p, ctx) });
  assert.ok(close(rows[0].cost, 18), 'product profit / job margin reads the full cost');
});

test("the P&L's cost of goods leaves the magnets out", () => {
  const o = job(magnets);
  assert.ok(close(stockShare(o, ctx) * o.costBasis, 10));
  const [q] = pnlByPeriod([o], [], { settings: { currency: 'SAR' }, consumables: shelf, now: new Date(2026, 8, 30) });
  assert.equal(q.cogs, 10);
  assert.ok(close(orderCost(o, ctx), 10), 'the dashboard cost of goods, by the shared rule');
});

test('a host with no shelf in reach prices the line at its written cost — still left out', () => {
  const o = job(magnets);
  assert.ok(close(stockShare(o, {}) * o.costBasis, 10));
});

test('the magnets come out before the buffer split, not instead of the wear', () => {
  const part = { ...magnets, printTime: 2, wearRate: 1, failureRate: 10 };
  const o = job(part);
  // material 10 + magnets 8 + wear 2 = 20, +10% = 22. Stocked: 10.
  assert.ok(close(o.costBasis, 22));
  assert.ok(close(stockShare(o, ctx) * o.costBasis, 10));
});

test('a job without consumables is unchanged', () => {
  const o = job(plain);
  assert.equal(stockShare(o, ctx), 1);
  const [q] = pnlByPeriod([o], [], { settings: { currency: 'SAR' }, now: new Date(2026, 8, 30) });
  assert.equal(q.cogs, 10);
});
