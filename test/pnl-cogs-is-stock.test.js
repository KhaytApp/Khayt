'use strict';

/**
 * In the P&L, cost of goods is only what was STOCKED — material, extra
 * materials, packaging (maintainer's decision, 2026-09-28). A job's cost also
 * carries pricing estimates of wear, electricity and labour, and a failure
 * buffer; the P&L took off the real bills for those as well, so each was
 * counted twice.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
require('../lib/calculator-cost.js');
const { pnlByPeriod, stockShare } = require('../lib/pnl-report.js');

// 100 g of a 20-a-kilo spool = 2.00 material; 2 h × 0.5 wear = 1.00;
// 2 h × 200 W × 0.2 = 0.08 power; 0.5 h × 10 labour = 5.00; +10% buffer.
const part = { spoolCost: 20, spoolWeight: 1000, printWeight: 100, printTime: 2, wearRate: 0.5,
  powerDraw: 200, elecRate: 0.2, prepTime: 0.5, laborRate: 10, failureRate: 10, qty: 1 };
const whole = (2 + 1 + 0.08 + 5) * 1.1;

test('a costed part: only its material share is cost of goods', () => {
  const o = { parts: [{ ...part, baseCost: whole }] };
  assert.ok(Math.abs(stockShare(o, {}) * whole - 2) < 1e-9, 'material is 2.00 of the 8.888 priced');
});

test('a line with no inputs to split keeps its whole cost, as before', () => {
  assert.equal(stockShare({ parts: [{ baseCost: 30 }] }, {}), 1);
  const mixed = stockShare({ parts: [{ ...part, baseCost: whole }, { baseCost: 10 }] }, {});
  assert.ok(Math.abs(mixed * (whole + 10) - (2 + 10)) < 1e-9);
  assert.equal(stockShare({ parts: [] }, {}), 1);
});

test("the quarter uses the FROZEN cost, scaled — not today's prices", () => {
  const frozen = 44.44;   // what the job cost when it finished, whatever spoolCost says now
  const [q] = pnlByPeriod(
    [{ id: 'A', status: 'completed', date: '2026-08-10', price: 100, costBasis: frozen,
       parts: [{ ...part, baseCost: whole }] }],
    [], { settings: { currency: 'SAR' }, now: new Date(2026, 8, 30) },
  );
  assert.equal(q.cogs, Math.round(frozen * (2 / whole) * 100) / 100);
});

test('the desktop applies the same share to the headline and the CSV', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
  // The P&L headline applies the share inline; the dashboard KPI margin gets
  // it from lib/kpi-rows.js orderCost, the rule the Mac uses (#1720).
  assert.equal((src.match(/\* KhaytPnl\.stockShare\(o, \{ inventory, settings \}\)/g) || []).length, 1,
    'the P&L headline');
  assert.match(src, /cost: KhaytKpiRows\.orderCost\(o, \{/, 'the dashboard KPI margin, by the shared rule');
  assert.equal((src.match(/inventory: \(typeof inventory !== 'undefined' \? inventory : \[\]\)/g) || []).length, 3);
});
