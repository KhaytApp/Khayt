'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { computeKpis } = require('../lib/kpi.js');

test('computeKpis: revenue/margin/AOV over completed orders only', () => {
  const k = computeKpis([
    { revenue: 100, cost: 40, completed: true, clientName: 'Acme', productName: 'Vase' },
    { revenue: 60, cost: 30, completed: true, clientName: 'Acme', productName: 'Bracket' },
    { revenue: 999, cost: 0, completed: false }, // pending → excluded from revenue
  ]);
  assert.equal(k.orderCount, 3);
  assert.equal(k.completedCount, 2);
  assert.equal(k.revenue, 160);
  assert.equal(k.grossProfit, 90);          // 160 - 70
  assert.equal(k.grossMargin, 56.3);        // 90/160
  assert.equal(k.avgOrderValue, 80);        // 160/2
  assert.equal(k.topClients[0].name, 'Acme');
  assert.equal(k.topClients[0].revenue, 160);
  assert.equal(k.topClients[0].count, 2);
});

test('on-time % counts only completed orders that had a due date', () => {
  const k = computeKpis([
    { revenue: 1, cost: 0, completed: true, onTime: true },
    { revenue: 1, cost: 0, completed: true, onTime: false },
    { revenue: 1, cost: 0, completed: true, onTime: null }, // no due date → not counted
    { revenue: 1, cost: 0, completed: false, onTime: true }, // not completed → ignored
  ]);
  assert.equal(k.onTimeTotal, 2);
  assert.equal(k.onTimePct, 50);
});

test('outstanding sums across all rows; empty input is safe', () => {
  const k = computeKpis([
    { revenue: 100, completed: true, outstanding: 30 },
    { revenue: 50, completed: false, outstanding: 50 },
  ]);
  assert.equal(k.outstanding, 80);
  const empty = computeKpis([]);
  assert.equal(empty.revenue, 0);
  assert.equal(empty.onTimePct, null);
  assert.deepEqual(empty.topClients, []);
});
