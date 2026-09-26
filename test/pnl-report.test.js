'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { computePnl, pnlToCsv } = require('../lib/pnl-report.js');

test('computePnl totals revenue, cogs, gross, expenses-by-category, net', () => {
  const s = computePnl({
    label: 'This month',
    orders: [
      { revenue: 100, cogs: 40, vat: 13.04 },
      { revenue: 60, cogs: 20, vat: 7.83 },
    ],
    expenses: [
      { amount: 30, category: 'Filament' },
      { amount: 10, category: 'Filament' },
      { amount: 25, category: 'Rent' },
    ],
  });
  assert.equal(s.orderCount, 2);
  assert.equal(s.revenue, 160);
  assert.equal(s.cogs, 60);
  assert.equal(s.grossProfit, 100);
  assert.equal(s.grossMargin, 62.5);
  // Filament is stock (accrual, 2026-09-26): the 40 bought is in cogs as it is
  // used, so it is not an operating expense as well.
  assert.equal(s.expensesTotal, 25);
  assert.equal(s.inventoryPurchases, 40);
  assert.equal(s.netProfit, 75); // 100 gross - 25 opex
  assert.equal(s.vatCollected, 20.87);
  assert.deepEqual(s.expensesByCategory, [{ category: 'Rent', amount: 25 }]);
});

test('computePnl handles empties + blank category', () => {
  const s = computePnl({ orders: [], expenses: [{ amount: 5 }] });
  assert.equal(s.revenue, 0);
  assert.equal(s.grossMargin, 0);
  assert.deepEqual(s.expensesByCategory, [{ category: 'Uncategorized', amount: 5 }]);
  assert.equal(s.netProfit, -5);
});

test('pnlToCsv is spreadsheet-safe and includes a row per expense category', () => {
  const s = computePnl({
    label: 'Q1', orders: [{ revenue: 100, cogs: 40 }],
    expenses: [{ amount: 30, category: '=Filament' }],
  });
  const csv = pnlToCsv(s, { currency: 'SAR' });
  const lines = csv.replace(/^﻿/, '').split('\r\n');
  assert.match(lines[0], /"P&L summary","Q1"/);
  assert.match(lines[1], /"Amount \(SAR\)"/);
  assert.match(csv, /"Revenue","100"/);
  assert.match(csv, /"Cost of goods sold","-40"/);
  assert.match(csv, /"  =Filament","-30"/); // indent makes the leading = safe
  assert.match(csv, /"Net profit","30"/);
});
