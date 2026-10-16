'use strict';

/**
 * A machine is paid for once — as its depreciation.
 *
 * A shop that bought a printer could record it as an expense (the receipt)
 * AND give the machine a purchase price and depreciation. The P&L charged
 * both: the whole price as an operating expense the day it was paid, and the
 * same price again, spread out, as the depreciation line. These tests were
 * written against that double count and failed on it (a 6,000 printer took
 * 6,000 + 503.76 off a quarter whose cost was 503.76).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
require('../lib/depreciation.js');
const P = require('../lib/pnl-report.js');
const D = require('../lib/depreciation.js');
const LP = require('../lib/location-pl.js');
const { machineProfit } = require('../lib/machine-pl.js');
const { cashFlow } = require('../lib/cash-flow.js');
const Book = require('../lib/expense-book.js');

const NOW = new Date(2026, 9, 16);
const X1C = {
  id: 'M1', name: 'X1C', locationId: 'LOC-a',
  depreciation: { price: 6000, purchaseDate: '2026-07-01', life: 3, lifeUnit: 'years', method: 'straightLine' },
};
const SALE = { id: 'A', status: 'completed', date: '2026-08-10', price: 1000 };
const q3 = (expenses, machines = [X1C], extra = {}) =>
  P.pnlByPeriod([SALE], expenses, { machines, now: NOW, ...extra }).find((r) => r.period === '2026-Q3');

test('THE BUG: a printer recorded as an expense AND depreciated is charged once', () => {
  // As a shop records it today: the receipt under "tools", the machine's
  // price and purchase date on the machine sheet.
  const r = q3([{ id: 'E1', date: '2026-07-01', category: 'tools', amount: 6000, note: 'Bambu X1C printer' }]);
  assert.ok(r.depreciation > 0, 'the machine is being depreciated');
  assert.equal(r.expenses, 0, 'the purchase was charged as an operating expense on top of its depreciation');
  assert.equal(r.capital, 6000, 'reported beside the arithmetic, not dropped');
  assert.equal(r.net, Math.round((1000 - r.depreciation) * 100) / 100);
});

test('a depreciated machine does not hide an UNRELATED equipment purchase', () => {
  // A dryer, an enclosure, a second printer nobody depreciated: its cost must
  // not vanish from the P&L because some other machine is depreciated.
  const r = q3([
    { id: 'E1', date: '2026-07-01', category: 'equipment', amount: 6000, note: 'X1C' },
    { id: 'E2', date: '2026-08-20', category: 'equipment', amount: 2500, note: 'Filament dryer' },
  ]);
  assert.equal(r.capital, 6000, 'the X1C is matched');
  assert.equal(r.expenses, 2500, 'the dryer is still an expense');
  // Alone, with no purchase of its own to match, still an expense.
  const s = q3([{ id: 'E2', date: '2026-08-20', category: 'equipment', amount: 2500 }]);
  assert.equal(s.expenses, 2500);
  assert.equal(s.capital, 0);
});

test('equipment: within 1% of the price and 31 days of the purchase date is the purchase', () => {
  // 20 days late and 0.5% over: a receipt is rarely the same day or figure.
  const r = q3([{ id: 'E1', date: '2026-07-21', category: 'equipment', amount: 6030 }]);
  assert.equal(r.capital, 6030);
  assert.equal(r.expenses, 0);
  // Paid before the purchase date (a deposit, a pre-order) counts too.
  const q2 = P.pnlByPeriod([SALE], [{ id: 'E1', date: '2026-06-20', category: 'equipment', amount: 5970 }],
    { machines: [X1C], now: NOW }).find((x) => x.period === '2026-Q2');
  assert.equal(q2.capital, 5970);
  // Too far off in either measure: an ordinary expense.
  for (const e of [{ date: '2026-08-02', amount: 6000 }, { date: '2026-07-01', amount: 6061 },
    { date: '2026-07-01', amount: 5939 }]) {
    const x = q3([{ id: 'E', category: 'equipment', ...e }]);
    assert.equal(x.capital, 0, JSON.stringify(e));
    assert.equal(x.expenses, e.amount);
  }
  // The near match is equipment only: a `tools` line 20 days late stays an expense.
  assert.equal(q3([{ id: 'E1', date: '2026-07-21', category: 'tools', amount: 6030 }]).capital, 0);
});

test('an explicit machineId link matches whatever the amount or date', () => {
  const r = q3([{ id: 'E1', date: '2026-09-15', category: 'other', amount: 5200, machineId: 'M1' }]);
  assert.equal(r.capital, 5200);
  assert.equal(r.expenses, 0);
  // Linked to a machine that is not depreciated: an expense, and never
  // re-matched to another machine by its amount.
  const s = q3([{ id: 'E1', date: '2026-07-01', category: 'equipment', amount: 6000, machineId: 'M9' }]);
  assert.equal(s.capital, 0);
  assert.equal(s.expenses, 6000);
  // One per machine: the link claims it, a matching equipment line stays an expense.
  const t = q3([
    { id: 'E1', date: '2026-09-15', category: 'other', amount: 5200, machineId: 'M1' },
    { id: 'E2', date: '2026-07-01', category: 'equipment', amount: 6000 },
  ]);
  assert.equal(t.capital, 5200);
  assert.equal(t.expenses, 6000);
});

test('a shop that does not use depreciation keeps seeing the purchase as an expense', () => {
  const ex = [{ id: 'E1', date: '2026-07-01', category: 'equipment', amount: 6000 }];
  for (const machines of [[], [{ id: 'M1', name: 'X1C' }],
    // A price and nothing else is not depreciated: no life to spread it over.
    [{ id: 'M1', depreciation: { price: 6000, purchaseDate: '2026-07-01' } }],
    // Nor is a machine whose residual is its whole price.
    [{ id: 'M1', depreciation: { price: 6000, residual: 6000, life: 3, lifeUnit: 'years', purchaseDate: '2026-07-01' } }]]) {
    const r = q3(ex, machines);
    assert.equal(r.depreciation, 0);
    assert.equal(r.expenses, 6000, JSON.stringify(machines));
    assert.equal(r.capital, 0);
  }
});

test('an ordinary expense is untouched, even on the purchase day', () => {
  const r = q3([
    { id: 'E1', date: '2026-07-01', category: 'tools', amount: 120, note: 'Spare nozzles' },
    { id: 'E2', date: '2026-07-02', category: 'tools', amount: 6000, note: 'not the purchase day' },
    { id: 'E3', date: '2026-07-01', category: 'maintenance', amount: 5999.99 },
  ]);
  assert.equal(r.expenses, 120 + 6000 + 5999.99);
  assert.equal(r.capital, 0);
});

test('one expense per machine: two identical receipts, one machine, one left out', () => {
  const r = q3([
    { id: 'E1', date: '2026-07-01', category: 'tools', amount: 6000 },
    { id: 'E2', date: '2026-07-01', category: 'other', amount: 6000 },
  ]);
  assert.equal(r.capital, 6000);
  assert.equal(r.expenses, 6000);
  // An equipment receipt for it is the purchase; the tools line stays an expense.
  const s = q3([
    { id: 'E1', date: '2026-07-01', category: 'tools', amount: 6000 },
    { id: 'E2', date: '2026-07-01', category: 'equipment', amount: 6000 },
  ]);
  assert.equal(s.capital, 6000);
  assert.equal(s.expenses, 6000);
});

test('the price is matched as paid or net of the tax on the receipt; the tax is still reclaimed', () => {
  const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
  const r = P.pnlByPeriod([SALE], [{ id: 'E1', date: '2026-07-01', category: 'tools', amount: 6900, vatAmount: 900 }],
    { machines: [X1C], now: NOW, settings }).find((x) => x.period === '2026-Q3');
  assert.equal(r.expenses, 0);
  assert.equal(r.capital, 6000, 'net of the reclaimable tax, like the filament line');
  assert.equal(r.vatReclaimable, 900, 'the tax on a printer is reclaimable all the same');
});

test('filament is stock first: never also a capital purchase', () => {
  const r = q3([{ id: 'E1', date: '2026-07-01', category: 'filament', amount: 6000 }]);
  assert.equal(r.inventory, 6000);
  assert.equal(r.capital, 0);
});

test('isCharged: only a machine the P&L can actually depreciate', () => {
  assert.equal(D.isCharged(X1C), true);
  assert.equal(D.isCharged({ id: 'x' }), false);
  assert.equal(D.isCharged({ depreciation: { price: 100 } }), false);
  assert.equal(D.isCharged({ depreciation: { price: 100, life: 1000, lifeUnit: 'hours', method: 'perHour' } }), true);
  assert.equal(D.isCharged({ depreciation: { price: 100, life: 2, lifeUnit: 'years', method: 'straightLine' } }), false,
    'straight line with no purchase date has nothing to count from');
});

test('cash flow is unchanged: the money did leave the bank', () => {
  const { rows } = cashFlow({
    orders: [], expenses: [{ date: '2026-07-01', amount: 6000, category: 'tools' }],
    endMonth: '2026-07', months: 1,
  }, { revenueOf: () => 0, countsForBusiness: () => true });
  assert.equal(rows[0].paidOut, 6000);
});

test('computePnl (the desktop headline and CSV) agrees, and the CSV says where it went', () => {
  const s = P.computePnl({
    orders: [{ revenue: 1000, cogs: 0 }],
    expenses: [{ amount: 6000, category: 'tools', date: '2026-07-01' }, { amount: 40, category: 'other', date: '2026-07-03' }],
    depreciation: 500, machines: [X1C],
  });
  assert.equal(s.expensesTotal, 40);
  assert.equal(s.capitalBought, 6000);
  assert.equal(s.netProfit, 1000 - 40 - 500);
  const csv = P.pnlToCsv(s, { labels: { capital: 'Equipment bought (depreciated)' } });
  assert.match(csv, /"Equipment bought \(depreciated\)","6000"/);
  // No machines handed in: exactly as before.
  const old = P.computePnl({ orders: [{ revenue: 1000, cogs: 0 }], expenses: [{ amount: 6000, category: 'tools', date: '2026-07-01' }] });
  assert.equal(old.expensesTotal, 6000);
  assert.equal(old.capitalBought, 0);
  assert.doesNotMatch(P.pnlToCsv(old), /Equipment bought/);
});

test('the statement file carries the memo line, outside the arithmetic', () => {
  const rows = P.pnlByPeriod([SALE], [{ id: 'E1', date: '2026-07-01', category: 'tools', amount: 6000 }],
    { machines: [X1C], now: NOW });
  const t = P.periodTotals(rows);
  assert.equal(t.capital, 6000);
  assert.equal(t.expenses, 0);
  const csv = P.periodsToCsv(rows, null, {});
  assert.match(csv, /"Equipment bought \(depreciated\)",6000/);
  const html = P.periodsToHtml(rows, null, {});
  assert.match(html, /<tr class="aside"><th scope="row">Equipment bought \(depreciated\)<\/th><td>6,000\.00<\/td>/);
  assert.equal(P.STATEMENT_LABELS.capital, 'Equipment bought (depreciated)');
});

test('location P&L: the purchase is not a site expense when its machine is depreciated', () => {
  const r = LP.locationPl({
    locations: [{ id: 'LOC-a', name: 'A' }], machines: [X1C], now: NOW,
    orders: [{ ...SALE, machineId: 'M1' }],
    expenses: [{ id: 'E1', date: '2026-07-01', category: 'tools', amount: 6000, locationId: 'LOC-a' }],
    range: { from: '2026-07-01', to: '2026-09-30' },
  });
  const a = r.rows.find((x) => x.locationId === 'LOC-a');
  assert.ok(a.depreciation > 0);
  assert.equal(a.expenses, 0, 'the site was charged the purchase and its depreciation');
});

test('machine P&L: a purchase booked against a job is not that job\'s cost', () => {
  const { rows } = machineProfit({
    machines: [X1C],
    completed: [{ id: 'a', machineId: 'M1', price: 1000, status: 'completed', date: '2026-08-10' }],
    expenses: [{ orderId: 'a', date: '2026-07-01', category: 'equipment', amount: 6000 },
      { orderId: 'a', date: '2026-08-10', category: 'other', amount: 30 }],
    range: { from: '2026-07-01', to: '2026-09-30' },
  }, { revenueOf: (o) => +o.price || 0, partCostOf: () => 0 });
  assert.equal(rows.find((r) => r.machineId === 'M1').linkedExpenses, 30);
});

test('both apps can record the category', () => {
  assert.ok(Book.CATEGORIES.includes('equipment'));
  assert.equal(Book.newExpense({ amount: 6000, category: 'equipment' }, { id: 'E', today: '2026-07-01' }).expense.category, 'equipment');
  const root = path.join(__dirname, '..');
  const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
  assert.match(read('renderer/expenses.js'), /'tools','equipment','shipping'/);
  assert.match(read('renderer/index.html'), /<option value="equipment"/);
  assert.match(read('mac/KhaytCore/Sources/KhaytApp/Shop+Stock.swift'), /"tools", "equipment", "shipping"/);
});

test('wired: the desktop P&L and CSV, and the Mac card and export, show the memo line', () => {
  const root = path.join(__dirname, '..');
  const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
  const an = read('renderer/analytics.js');
  assert.match(an, /t\('pnl\.capital_note', \{ amount: fmtMoney\(kit\) \}\)/);
  assert.match(an, /capital: t\('pnl\.capital'\)/);
  assert.match(an, /machines: kit, recentMonthlyHours/);
  assert.match(read('mac/KhaytCore/Sources/KhaytApp/Reports.swift'), /"pnl\.capital"/);
  assert.match(read('mac/KhaytCore/Sources/KhaytApp/Shop+Pnl.swift'), /"capital": words\.callIt\("pnl\.capital"\)/);
});

test('every locale has the new words', () => {
  for (const l of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'locales', l + '.js'), 'utf8');
    for (const k of ['exp.cat.equipment', 'pnl.capital', 'pnl.capital_note']) {
      assert.match(src, new RegExp(`"${k.replace(/\./g, '\\.')}": "`), `${l} lacks ${k}`);
    }
    assert.match(src, /"pnl\.capital_note": "[^"]*\{amount\}/, `${l}: the note must keep {amount}`);
  }
});
