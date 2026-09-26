'use strict';

/**
 * Filament wasted on failed prints is its own P&L line (maintainer's decision,
 * 2026-09-26). Under accrual (#1633) a failed print's filament never becomes a
 * job's cost, so without this line it would leave the P&L entirely.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
const { computePnl, pnlByPeriod, pnlToCsv } = require('../lib/pnl-report.js');

test('the summary takes waste off net, and reports it', () => {
  const s = computePnl({ orders: [{ revenue: 100, cogs: 30 }], expenses: [{ amount: 10, category: 'rent' }],
    waste: [{ cost: 12.5 }, { cost: 2.5 }, { cost: -4 }, null] });
  assert.equal(s.waste, 15, 'negative and missing entries count as nothing');
  assert.equal(s.netProfit, 100 - 30 - 10 - 15);
  assert.equal(computePnl({ orders: [{ revenue: 100, cogs: 30 }] }).waste, 0);
});

test('the quarter: waste lands in the period it failed, and comes off net', () => {
  const rows = pnlByPeriod(
    [{ id: 'A', status: 'completed', date: '2026-08-10', price: 1000 }],
    [],
    { settings: { currency: 'SAR' }, now: new Date(2026, 8, 30),
      wasteLog: [{ date: '2026-08-12', cost: 40 }, { date: '2026-04-02', cost: 7 }] },
  );
  const q3 = rows.find((r) => r.period.endsWith('Q3') || r.period.includes('Q3'));
  const q2 = rows.find((r) => r !== q3);
  assert.equal(q3.waste, 40);
  assert.equal(q3.net, Math.round((q3.revenue - q3.cogs - q3.expenses - 40 - q3.fixed) * 100) / 100);
  assert.equal(q2.waste, 7, 'a quarter with only a failed print still has a row');
});

test('a host that passes no waste log sees exactly what it saw before', () => {
  const orders = [{ id: 'A', status: 'completed', date: '2026-08-10', price: 1000 }];
  const [q] = pnlByPeriod(orders, [], { settings: { currency: 'SAR' }, now: new Date(2026, 8, 30) });
  assert.equal(q.waste, 0);
  assert.equal(q.net, Math.round((q.revenue - q.cogs - q.expenses - q.fixed) * 100) / 100);
});

test('the CSV lists the waste as a cost', () => {
  const csv = pnlToCsv(computePnl({ orders: [{ revenue: 100, cogs: 30 }], waste: [{ cost: 15 }] }),
    { labels: { waste: 'Wasted' } });
  assert.match(csv, /"Wasted","-15"/);
  assert.match(csv, /"Net profit","55"/);
});

test('the desktop passes its waste log to every P&L it draws', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
  assert.equal((src.match(/wasteLog: \(typeof wasteLog !== 'undefined' \? wasteLog : \[\]\)/g) || []).length, 3,
    'every pnlByPeriod call site');
  assert.match(src, /return \{ orders, expenses: expenseRows, waste: wasteRows \};/, 'the headline and the CSV');
  assert.match(src, /net: d\.revenue - d\.matCost - d\.expenses - d\.waste/, 'the per-location view');
});
