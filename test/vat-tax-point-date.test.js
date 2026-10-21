'use strict';
/**
 * The tax point's DAY (beta.2 review): an accepted quote is given its invoice
 * number when the customer says yes (`lib/order-new.js ensureInvoiceNumber`),
 * while its `date` stays the quote's. Every VAT figure bucketed by `date`, so
 * a September quote accepted in October put its VAT in September.
 *
 *     before   September VAT 150, October 0
 *     after    September 0,       October VAT 150   (revenue stays September)
 *
 * A plain job's tax point is still its own date.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
require('../lib/business-scope.js');
const money = require('../lib/order-money.js');
const KhaytTax = require('../lib/tax.js');
const KhaytOrderStatus = require('../lib/order-status.js');
const KhaytPnl = require('../lib/pnl-report.js');
const { summarize } = require('../lib/vat-summary.js');

const VAT15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const ROOT = path.join(__dirname, '..');
const accepted = { id: 'QUO-2026-0007', status: 'completed', date: '2026-09-20', price: 1150,
  quoteAcceptedAt: '2026-10-03', invoiceNumber: 'INV-0042' };
const plain = { id: 'INV-0043', status: 'completed', date: '2026-09-21', price: 1150 };

test('taxPointDate: the acceptance day for an accepted quote, the date otherwise', () => {
  assert.equal(KhaytPnl.taxPointDate(accepted), '2026-10-03');
  assert.equal(KhaytPnl.taxPointDate({ ...accepted, quoteAcceptedAt: null, clientApprovedAt: '2026-10-04' }), '2026-10-04');
  assert.equal(KhaytPnl.taxPointDate(plain), '2026-09-21');
  assert.equal(KhaytPnl.taxPointDate({ id: 'QUO-1', date: '2026-09-01' }), '2026-09-01');
});

function summaryFor(orders, from, to) {
  const range = { from, to };
  const rows = KhaytPnl.pnlByPeriod(orders, [], { settings: VAT15, clients: [], now: new Date(2026, 9, 16, 12),
    granularity: 'month', range });
  return { rows, vat: summarize(rows, { settings: VAT15, expenses: [], range }) };
}

test('the P&L and VAT summary put an accepted quote\'s VAT in its acceptance month; revenue stays', () => {
  const sep = summaryFor([accepted], '2026-09-01', '2026-09-30');
  const oct = summaryFor([accepted], '2026-10-01', '2026-10-31');
  assert.equal(sep.vat.output, 0);
  assert.equal(oct.vat.output, 150);
  assert.equal(oct.vat.sales, 1000);
  assert.equal(sep.rows[0].revenue, 1000, 'revenue is still the job\'s own month');
  assert.equal(sep.rows[0].revenueVat, 150, 'and its own tax grosses it up there');
  assert.equal(oct.rows[0].revenue, 0);
  // A plain job: unchanged, both in its own month.
  const p = summaryFor([plain], '2026-09-01', '2026-09-30');
  assert.equal(p.vat.output, 150);
  assert.equal(p.rows[0].revenue, 1000);
});

const sandboxBase = (orders) => ({
  KhaytTax, KhaytOrderStatus, KhaytPnl, settings: VAT15, clients: [], printLog: orders, expenses: [],
  console, orderNetRevenueBase: (o) => money.orderNetRevenueBase(o, { settings: VAT15, clients: [] }),
  orderCurrency: () => 'SAR', convertToBase: (v) => v, fmtMoney: (v) => Number(v).toFixed(2),
  currencySymbol: () => 'SAR', shopName: () => 'Shop', t: (k) => k, toast: () => {},
  escapeHtml: (x) => String(x), localDateStr: () => '2026-10-16', window: {},
});

test('the desktop VAT return declares it in the acceptance quarter', () => {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/operations-extras.js'), 'utf8');
  const run = (period) => {
    let html = null;
    // The return asks for the CURRENT year's quarters: pinned, so this does
    // not decay on the first of January.
    const RealDate = Date;
    class FrozenDate extends RealDate {
      constructor(...a) { super(...(a.length ? a : [new RealDate(2026, 9, 16, 12).getTime()])); }
    }
    const sb = { ...sandboxBase([accepted]), Date: FrozenDate, downloadBlob: () => {},
      Blob: class { constructor(parts) { html = parts.join(''); } } };
    sb.globalThis = sb;
    vm.createContext(sb);
    vm.runInContext(src, sb);
    sb.exportGaztVatReturn(period);
    return html;
  };
  assert.match(run('q3'), /collected on sales<\/td><td>0\.00/);
  assert.match(run('q4'), /collected on sales<\/td><td>150\.00/);
});

/** `_doExportTaxSummary`, verbatim from the source, run over a book. */
function taxSummaryCsv(orders, from, to) {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/expenses.js'), 'utf8');
  const at = src.indexOf('function _doExportTaxSummary');
  const body = src.slice(at, src.indexOf('\n}\n', at) + 2);
  let csv = null;
  const sb = { ...sandboxBase(orders), timeEntries: [],
    csvEsc: (v) => String(v), downloadBlob: () => {},
    Blob: class { constructor(parts) { csv = parts.join(''); } } };
  vm.createContext(sb);
  vm.runInContext(body + '\n_doExportTaxSummary("custom", ' + JSON.stringify(from) + ', ' + JSON.stringify(to) + ');', sb);
  return csv.replace(/^﻿/, '').split('\r\n');
}

test('the desktop Tax summary CSV: VAT in the acceptance month, with its taxable sales beside it', () => {
  const lines = taxSummaryCsv([accepted], '2026-09-01', '2026-10-31');
  assert.equal(lines[1], 'Month,Orders,Revenue (SAR),Shipping (SAR),Taxable Sales (SAR),VAT Collected (SAR),Expenses (SAR),Net Income (SAR)');
  assert.equal(lines[0].split(',').length, lines[1].split(',').length, 'the period row is as wide as the table');
  assert.equal(lines[2], '2026-09,1,1150.00,0.00,0.00,0.00,0.00,1150.00');
  assert.equal(lines[3], '2026-10,0,0.00,0.00,1000.00,150.00,0.00,0.00');
  // A plain job: one line, its tax and its base in its own month.
  assert.deepEqual(taxSummaryCsv([plain], '2026-09-01', '2026-09-30').slice(2),
    ['2026-09,1,1150.00,0.00,1000.00,150.00,0.00,1150.00']);
});
