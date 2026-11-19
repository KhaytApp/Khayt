'use strict';
/**
 * A job stored BEFORE the qty-labour rule (#2586) costs byte-identically
 * through every reader (money review of #2586, HIGH 1). Its parts carry no
 * `labourPerLine`, so KhaytOrderMoney.lineLabour gives them the old sum and
 * their packaging is one box a line, whatever `perBox` says. The figures were
 * computed by main's lib at 6f966002c and frozen in the fixture (CI's shallow
 * checkout has no origin/main to read). Readers: the part cost and its
 * breakdown, the dashboard's cost of goods (kpi-rows orderCost), the P&L's
 * stock share, product profit (and its profit per hour) and break-even.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'print-rates', 'calculator-cost', 'pnl-report']) require('../lib/' + f + '.js');
const CC = globalThis.KhaytCalculatorCost, P = globalThis.KhaytPnl;
const K = require('../lib/kpi-rows.js'), PF = require('../lib/product-profit.js'), BE = require('../lib/break-even.js');
const F = require('./fixtures/stored-jobs-before-2586.json');
const book = JSON.parse(JSON.stringify(F));
const ctx = { inventory: book.inventory, settings: book.settings };
const r6 = (v) => Math.round(v * 1e6) / 1e6;
const round = (x) => JSON.parse(JSON.stringify(x, (k, v) => (typeof v === 'number' ? r6(v) : v)));

test('the stored parts carry no labourPerLine (they are the old records)', () => {
  for (const o of book.orders) for (const p of o.parts) assert.equal(p.labourPerLine, undefined);
});

test('part cost and breakdown, part for part, == main', () => {
  for (const o of book.orders) o.parts.forEach((p, i) => {
    assert.equal(r6(CC.partTotalCost(p, ctx)), F.figures.parts[o.id + '#' + i], o.id + '#' + i);
    assert.deepEqual(round(CC.computePartBreakdown(p, ctx)), F.figures.breakdown[o.id + '#' + i], o.id + '#' + i);
  });
});

test('dashboard cost of goods and the P&L stock share, job for job, == main', () => {
  for (const o of book.orders) {
    assert.equal(r6(K.orderCost(o, ctx)), F.figures.orderCost[o.id], o.id);
    assert.equal(r6(P.stockShare(o, ctx)), F.figures.stockShare[o.id], o.id);
  }
});

test('product profit and break-even == main', () => {
  const partCostOf = (p) => CC.partTotalCost(p, ctx);
  assert.deepEqual(round(PF.productProfit({ orders: book.orders, products: book.products }, { partCostOf })), F.figures.productProfit);
  assert.deepEqual(round(BE.breakEven({ completed: book.orders, fixedCosts: [{ name: 'rent', amount: 1000 }], month: '2026-10', since: '2026-01-01' },
    { partCostOf, revenueOf: (o) => o.price })), F.figures.breakEven);
});

test('the same part marked labourPerLine IS on the new rule (the test can tell the two apart)', () => {
  const p = Object.assign({}, book.orders[0].parts[0], { labourPerLine: true });
  assert.ok(CC.partTotalCost(p, ctx) < F.figures.parts['J1#0'] - 200, 'prep once on a line of 10: 222.75 less');
});
