'use strict';

/**
 * Filament is counted when it is USED, not when it is bought (maintainer's
 * decision, 2026-09-26). Receiving a PO books the spool as a `filament`
 * expense, and each job's cost counts it again as it is printed; once net
 * took the cost of goods out (#1623), a shop that recorded what it bought was
 * charged for it twice.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
const { computePnl, pnlByPeriod, pnlToCsv, isInventoryPurchase } = require('../lib/pnl-report.js');

test('a filament purchase, from a PO or by hand, in any case, is stock', () => {
  assert.equal(isInventoryPurchase({ category: 'filament', poId: 'PO-1' }), true);
  assert.equal(isInventoryPurchase({ category: ' Filament ' }), true);
  for (const c of ['electricity', 'maintenance', 'tools', 'shipping', 'other', '', undefined]) {
    assert.equal(isInventoryPurchase({ category: c }), false, String(c));
  }
  assert.equal(isInventoryPurchase(null), false);
});

test('the quarter: filament is not an expense and not in net, and is reported beside them', () => {
  const [q] = pnlByPeriod(
    [{ id: 'A', status: 'completed', date: '2026-08-10', price: 1000 }],
    [
      { date: '2026-08-01', amount: 300, category: 'filament', poId: 'PO-1' },
      { date: '2026-08-05', amount: 50, category: 'electricity' },
    ],
    { settings: { currency: 'SAR' }, now: new Date(2026, 8, 30) },
  );
  assert.equal(q.expenses, 50, 'only the electricity is an expense');
  assert.equal(q.inventory, 300, 'the filament is reported as stock bought');
  assert.equal(q.net, Math.round((q.revenue - q.cogs - 50 - q.fixed) * 100) / 100, 'and it is not in net');
});

test('the tax on filament is still reclaimable: accrual moves the cost, not the VAT', () => {
  const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
  const [q] = pnlByPeriod(
    [{ id: 'A', status: 'completed', date: '2026-08-10', price: 1150 }],
    [{ date: '2026-08-01', amount: 115, vatAmount: 15, category: 'filament' }],
    { settings, now: new Date(2026, 8, 30) },
  );
  assert.equal(q.vatReclaimable, 15);
  assert.equal(q.inventory, 100, 'stock bought, net of the reclaimable tax');
  assert.equal(q.expenses, 0);
});

test('the CSV says what was bought, outside the arithmetic', () => {
  const s = computePnl({ orders: [{ revenue: 100, cogs: 30 }], expenses: [{ amount: 40, category: 'filament' }] });
  const csv = pnlToCsv(s, { labels: { inventory: 'Filament bought' } });
  assert.match(csv, /"Filament bought","40"/);
  assert.match(csv, /"Net profit","70"/);
  assert.doesNotMatch(pnlToCsv(computePnl({ orders: [], expenses: [] })), /Filament bought/);
});

test('the per-location view and the P&L table use the same rule', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
  assert.match(src, /!KhaytPnl\.isInventoryPurchase\(e\)/, 'the location breakdown still counts filament twice');
  assert.match(src, /t\('pnl\.inventory_note', \{ amount: fmtMoney\(bought\) \}\)/, 'the table does not say where the filament went');
});
