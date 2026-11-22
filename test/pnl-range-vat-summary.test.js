'use strict';
/**
 * The P&L over a span the shop chooses, the VAT owed for it, and the file an
 * accountant is handed.
 *
 * `pnlByPeriod` reported every period in the book; the Mac's Reports screen
 * now lets the shop pick "this month", "last quarter" or two days of its own,
 * and every figure has to follow — the records, the overhead charged to a
 * period cut short by the span, and the VAT summary under it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
const { pnlByPeriod, periodTotals, periodsToCsv, periodsToHtml } = require('../lib/pnl-report.js');
const { summarize, inSpan } = require('../lib/vat-summary.js');

const VAT15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const ADDED15 = { currency: 'SAR', tax: { name: 'GST', mode: 'exclusive', rates: [{ id: 'g', label: 'GST', percent: 15 }] } };
const UNREGISTERED = { currency: 'SAR' };

const job = (id, date, price) => ({ id, status: 'completed', date, price, paidAmount: price });
// Mid-October, local time: September is last month and Q3 last quarter.
const NOW = new Date(2026, 9, 16, 12, 0, 0);

const book = {
  orders: [
    job('a', '2026-07-10', 115),
    job('b', '2026-09-05', 230),
    job('c', '2026-10-02', 115),
  ],
  expenses: [
    { id: 'e1', date: '2026-09-12', amount: 115, vatAmount: 15, category: 'rent' },
    { id: 'e2', date: '2026-09-20', amount: 50, category: 'other' },
    { id: 'e3', date: '2026-10-03', amount: 23, vatAmount: 3, category: 'other' },
  ],
};

const run = (settings, range, granularity) => pnlByPeriod(book.orders, book.expenses, {
  settings, now: NOW, granularity: granularity || 'month', range,
});

test('no span: every period, and rows carry no from/to — the old output exactly', () => {
  const rows = run(VAT15, undefined);
  assert.deepEqual(rows.map((r) => r.period), ['2026-10', '2026-09', '2026-07']);
  for (const r of rows) {
    assert.equal('from' in r, false);
    assert.equal('to' in r, false);
  }
});

test('a span keeps only the records whose day is inside it', () => {
  const rows = run(VAT15, { from: '2026-09-01', to: '2026-09-30' });
  assert.deepEqual(rows.map((r) => r.period), ['2026-09']);
  const [sep] = rows;
  assert.equal(sep.orders, 1);
  assert.equal(sep.revenue, 200);           // 230 with the 15% taken out
  assert.equal(sep.vatCollected, 30);
  assert.equal(sep.vatReclaimable, 15);     // e1 only: e2 recorded no VAT
  assert.equal(sep.expenses, 150);          // 115 − 15 reclaimed, + 50
  assert.equal(sep.from, '2026-09-01');
  assert.equal(sep.to, '2026-09-30');
});

test('a span shorter than the grain is one row holding only its days', () => {
  const rows = run(VAT15, { from: '2026-09-01', to: '2026-09-30' }, 'quarter');
  assert.deepEqual(rows.map((r) => r.period), ['2026-Q3']);
  assert.equal(rows[0].orders, 1, 'July is in Q3 but not in September');
  assert.equal(rows[0].from, '2026-09-01');
  assert.equal(rows[0].to, '2026-09-30');
});

test('overhead: a whole past month is charged whole', () => {
  const settings = { ...VAT15, fixedCosts: [{ name: 'Rent', amount: 300 }] };
  const rows = pnlByPeriod(book.orders, book.expenses, {
    settings, now: NOW, granularity: 'month', range: { from: '2026-09-01', to: '2026-09-30' } });
  assert.equal(rows[0].fixed, 300);
});

test('overhead: one month of a quarter row is that month\'s share of the quarter', () => {
  const settings = { ...VAT15, fixedCosts: [{ name: 'Rent', amount: 300 }] };
  const rows = pnlByPeriod(book.orders, book.expenses, {
    settings, now: NOW, granularity: 'quarter', range: { from: '2026-09-01', to: '2026-09-30' } });
  // 900 a quarter × 30 of Q3's 92 days.
  assert.equal(rows[0].fixed, Math.round(900 * 30 / 92 * 100) / 100);
});

test('overhead: the month in progress is charged only up to today', () => {
  const settings = { ...VAT15, fixedCosts: [{ name: 'Rent', amount: 310 }] };
  const rows = pnlByPeriod(book.orders, book.expenses, {
    settings, now: NOW, granularity: 'month', range: { from: '2026-10-01', to: '2026-10-31' } });
  assert.deepEqual(rows.map((r) => r.period), ['2026-10']);
  assert.equal(rows[0].fixed, 160);   // 310 × 16 of 31 days
});

test('net follows the span: revenue − expenses − overhead, nothing outside it', () => {
  const rows = run(VAT15, { from: '2026-10-01', to: '2026-10-31' });
  assert.equal(rows[0].revenue, 100);
  assert.equal(rows[0].expenses, 20);
  assert.equal(rows[0].net, 80);
});

test('VAT summary, prices INCLUDE the tax: extracted, and the purchases reclaimed', () => {
  const range = { from: '2026-09-01', to: '2026-10-31' };
  const rows = run(VAT15, range);
  const vat = summarize(rows, { settings: VAT15, expenses: book.expenses, range });
  assert.equal(vat.applies, true);
  assert.equal(vat.mode, 'inclusive');
  assert.equal(vat.sales, 300);         // 230 + 115 with the tax out
  assert.equal(vat.output, 45);         // 30 + 15
  assert.equal(vat.input, 18);          // 15 + 3
  assert.equal(vat.net, 27);
  assert.equal(vat.position, 'payable');
  assert.equal(vat.expensesWithVat, 2);
  assert.equal(vat.expensesWithoutVat, 1);
  assert.deepEqual(vat.rates, [{ label: 'VAT', percent: 15 }]);
});

test('VAT summary, tax ADDED on top: the price is the net figure and the tax is extra', () => {
  const range = { from: '2026-10-01', to: '2026-10-31' };
  const rows = run(ADDED15, range);
  const vat = summarize(rows, { settings: ADDED15, expenses: book.expenses, range });
  assert.equal(vat.mode, 'exclusive');
  assert.equal(vat.sales, 115);         // typed 115, and that IS the revenue
  assert.equal(vat.output, 17.25);      // 15% on top of it
  assert.equal(vat.input, 3);
  assert.equal(vat.net, 14.25);
});

test('VAT summary: a span that bought more than it sold is a refund, not an error', () => {
  const range = { from: '2026-09-10', to: '2026-09-30' };
  const rows = run(VAT15, range);
  const vat = summarize(rows, { settings: VAT15, expenses: book.expenses, range });
  assert.equal(vat.output, 0);
  assert.equal(vat.input, 15);
  assert.equal(vat.net, -15);
  assert.equal(vat.position, 'refund');
});

test('VAT summary: a shop with no tax set has none to show', () => {
  const rows = run(UNREGISTERED, undefined);
  const vat = summarize(rows, { settings: UNREGISTERED, expenses: book.expenses });
  assert.equal(vat.applies, false);
  assert.equal(vat.output, 0);
  assert.equal(vat.input, 0);
  // And the P&L reclaimed nothing for it either: every riyal paid is a cost.
  assert.equal(rows.reduce((s, r) => s + r.vatReclaimable, 0), 0);
});

test('VAT summary agrees with the rows it sums, to the halalah', () => {
  const rows = run(VAT15, undefined);
  const vat = summarize(rows, { settings: VAT15, expenses: book.expenses });
  const due = rows.reduce((s, r) => s + r.vatDue, 0);
  assert.equal(vat.net, Math.round(due * 100) / 100);
});

test('inSpan compares book days as strings, either end optional', () => {
  assert.equal(inSpan('2026-09-30', { from: '2026-09-01', to: '2026-09-30' }), true);
  assert.equal(inSpan('2026-10-01', { from: '2026-09-01', to: '2026-09-30' }), false);
  assert.equal(inSpan('2026-01-01', { to: '2026-09-30' }), true);
  assert.equal(inSpan('2026', { from: '2026-01-01' }), false);
  assert.equal(inSpan('', null), true);
});

test('periodTotals adds the rows and blends the margin once', () => {
  const t = periodTotals([
    { revenue: 100, cogs: 20, net: 50, orders: 1 },
    { revenue: 10000, cogs: 9000, net: 900, orders: 3 },
  ]);
  assert.equal(t.orders, 4);
  assert.equal(t.revenue, 10100);
  assert.equal(t.net, 950);
  assert.equal(t.marginPct, Math.round(((10100 - 9020) / 10100) * 1000) / 10);
});

test('CSV: a BOM, the period, plain unquoted money, a total and the VAT block', () => {
  const range = { from: '2026-09-01', to: '2026-10-31' };
  const rows = run(VAT15, range);
  const vat = summarize(rows, { settings: VAT15, expenses: book.expenses, range });
  const csv = periodsToCsv(rows, vat, {
    currency: 'SAR', periodLabel: 'Custom range', from: range.from, to: range.to,
    labels: { title: 'الأرباح والخسائر', vatMissing: 'Expenses with no VAT recorded: 1' },
  });
  assert.equal(csv.charCodeAt(0), 0xFEFF);
  const lines = csv.slice(1).trim().split('\r\n');
  assert.equal(lines[0], '"الأرباح والخسائر","Custom range"');
  assert.ok(lines.includes('"From","2026-09-01"'));
  assert.ok(lines.includes('"Currency","SAR"'));
  // Oldest first, and money with no quotes, no separators, no mark.
  const sep = lines.find((l) => l.startsWith('"2026-09"'));
  // A whole month under the month view needs no days after its name.
  assert.equal(sep, '"2026-09",1,200,0,0,0,0,150,0,50,100,30,15,15');
  assert.ok(lines.indexOf(sep) < lines.findIndex((l) => l.startsWith('"2026-10')));
  assert.ok(lines.some((l) => l.startsWith('"Total",2,300,')));
  assert.ok(lines.includes('"Output VAT on sales",45'));
  assert.ok(lines.includes('"Input VAT on expenses",18'));
  assert.ok(lines.includes('"Net VAT payable",27'));
  assert.ok(lines.includes('"Expenses with no VAT recorded: 1"'));
});

test('CSV: a row the span cuts short is named with the days it holds', () => {
  const rows = run(VAT15, { from: '2026-09-01', to: '2026-09-30' }, 'quarter');
  const csv = periodsToCsv(rows, null, {});
  assert.ok(csv.includes('"2026-Q3 (2026-09-01 – 2026-09-30)",1,200,'));
});

test('CSV: no VAT block for a shop with no tax, and text cannot become a formula', () => {
  const rows = run(UNREGISTERED, undefined);
  const vat = summarize(rows, { settings: UNREGISTERED });
  const csv = periodsToCsv(rows, vat, { periodLabel: '=HYPERLINK("x")' });
  assert.equal(csv.includes('Output VAT'), false);
  assert.ok(csv.includes('"\'=HYPERLINK(""x"")"'));
});

test('HTML: escaped, right to left on request, the statement and the VAT lines', () => {
  const range = { from: '2026-09-01', to: '2026-10-31' };
  const rows = run(VAT15, range);
  const vat = summarize(rows, { settings: VAT15, expenses: book.expenses, range });
  const html = periodsToHtml(rows, vat, {
    dir: 'rtl', lang: 'ar', currency: 'SAR', periodLabel: '<b>x</b>', shopName: 'A & B',
    from: range.from, to: range.to,
  });
  assert.match(html, /^<div class="pnl-doc" dir="rtl" lang="ar">/);
  assert.ok(html.includes('&lt;b&gt;x&lt;/b&gt;'));
  assert.ok(html.includes('A &amp; B'));
  assert.ok(html.includes('Net VAT payable'));
  assert.ok(html.includes('<td>27.00</td>'));
  assert.ok(html.includes('<td>−150.00</td>'), 'expenses print as a cost');
  // Western digits, always.
  assert.equal(/[٠-٩]/.test(html), false);
});

test('HTML: no VAT section when the shop has no tax set', () => {
  const rows = run(UNREGISTERED, undefined);
  const html = periodsToHtml(rows, summarize(rows, { settings: UNREGISTERED }), {});
  assert.equal(html.includes('VAT for the period'), false);
});
