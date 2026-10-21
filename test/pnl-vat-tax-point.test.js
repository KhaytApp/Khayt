'use strict';
/**
 * The VAT summary and the accountant's invoice export cover the SAME jobs.
 *
 * Under ZATCA the tax point is the invoice: a job whose invoice was issued
 * owes its VAT in the period it is dated, finished or not. The export
 * (`lib/accounting-rows.js isInvoice`) has always listed every issued invoice,
 * pending and printing included; the VAT summary summed the P&L's finished
 * jobs only. So a quarter with one finished 115 job and one 230 job still on
 * the printer (both invoiced, 15% inclusive) read:
 *
 *     before   summary output VAT 15.00, sales 100   export VAT 45.00
 *     after    summary output VAT 45.00, sales 300   export VAT 45.00
 *
 * while the P&L's REVENUE stays 100 — it is earned when the work is finished.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
require('../lib/order-money.js');
const KhaytTax = require('../lib/tax.js');
const { ordersToInvoiceRows, isInvoice } = require('../lib/accounting-rows.js');
const { pnlByPeriod, isTaxPoint } = require('../lib/pnl-report.js');
const { summarize } = require('../lib/vat-summary.js');

const VAT15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const NOW = new Date(2026, 9, 16, 12, 0, 0);
const RANGE = { from: '2026-10-01', to: '2026-10-31' };

const ORDERS = [
  { id: 'INV-1', status: 'completed', date: '2026-10-02', price: 115, invoiceNumber: 'INV-1' },
  { id: 'INV-2', status: 'printing', date: '2026-10-05', price: 230, invoiceNumber: 'INV-2' },
  { id: 'QUO-1', status: 'quote', date: '2026-10-06', price: 345 },
];

/** The export's VAT, worked from its own rows the way the CSV does. */
function exportVat(orders, settings) {
  const profile = KhaytTax.profileFromSettings(settings);
  return ordersToInvoiceRows(orders, { settings, KhaytTax })
    .reduce((s, r) => s + KhaytTax.computeTax(r.price, profile).taxTotal, 0);
}

function summaryOf(orders, settings) {
  const rows = pnlByPeriod(orders, [], { settings, clients: [], now: NOW, range: RANGE });
  return { rows, vat: summarize(rows, { settings, expenses: [], range: RANGE }) };
}

test('a printing job with an invoice is in both; a quote is in neither', () => {
  const exported = ordersToInvoiceRows(ORDERS, { settings: VAT15, KhaytTax }).map((r) => r.id);
  assert.deepEqual(exported.sort(), ['INV-1', 'INV-2']);

  const { rows, vat } = summaryOf(ORDERS, VAT15);
  assert.equal(vat.output, 45, 'VAT on 115 and 230 — the printing job included, the quote not');
  assert.equal(vat.sales, 300, 'the sales the tax was charged on, net of it');
  assert.equal(Math.round(exportVat(ORDERS, VAT15) * 100) / 100, vat.output);

  // Revenue is still finished work only: the job on the printer earns when done.
  assert.equal(rows.length, 1);
  assert.equal(rows[0].revenue, 100);
  assert.equal(rows[0].orders, 1);
});

test('a quote alone owes nothing and opens no period', () => {
  const quoteOnly = [ORDERS[2]];
  assert.deepEqual(ordersToInvoiceRows(quoteOnly, { settings: VAT15, KhaytTax }), []);
  const { rows, vat } = summaryOf(quoteOnly, VAT15);
  assert.deepEqual(rows, []);
  assert.equal(vat.output, 0);
});

test('the P&L\'s tax-point rule IS the export\'s isInvoice, over every shape of job', () => {
  const statuses = ['quote', 'pending', 'printing', 'completed', 'delivered', 'cancelled', 'split', 'on_hold'];
  for (const status of statuses) {
   for (const quote of [{}, { hasQuote: true }, { hasQuote: true, quoteAcceptedAt: 'x' }, { hasQuote: true, clientApprovedAt: 'x' }]) {
    for (const voidedAt of [undefined, '2026-10-01']) {
      for (const creditedAt of [undefined, '2026-10-01']) {
        for (const nonBusiness of [undefined, true]) {
          for (const splitInto of [undefined, [], ['a']]) {
            const o = { status, voidedAt, creditedAt, nonBusiness, splitInto, ...quote };
            assert.equal(isTaxPoint(o), isInvoice(o), JSON.stringify(o));
          }
        }
      }
    }
   }
  }
});

test('over generated books, the summary\'s output VAT is the export\'s', () => {
  let x = 20261021;
  const r = () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
  const pick = (list) => list[Math.floor(r() * list.length)];
  for (let i = 0; i < 500; i++) {
    const orders = [];
    for (let j = 0; j < 1 + Math.floor(r() * 10); j++) {
      const o = {
        id: 'O' + j, date: `2026-10-${String(1 + Math.floor(r() * 28)).padStart(2, '0')}`,
        status: pick(['quote', 'pending', 'printing', 'completed', 'delivered', 'cancelled']),
        price: pick([0, 115, 230, 999.5]),
      };
      if (r() < 0.15) o.voidedAt = '2026-10-20';
      if (r() < 0.1) o.nonBusiness = true;
      if (r() < 0.2) o.creditNotes = [{ amount: pick([15, 115]) }];
      orders.push(o);
    }
    const settings = r() < 0.5 ? VAT15
      : { currency: 'SAR', tax: { name: 'GST', mode: 'exclusive', rates: [{ id: 'g', label: 'GST', percent: 15 }] } };
    const { vat } = summaryOf(orders, settings);
    assert.ok(Math.abs(vat.output - exportVat(orders, settings)) <= 0.01, `case ${i}`);
  }
});

test('a quote parked on hold, not yet accepted, is no invoice and owes no VAT (beta.2 review)', () => {
  // Before: a 345 on-hold quote with no yes recorded passed both rules and
  // read 45 VAT, though it has no invoice number (order-new invoiceNumberOwed).
  const parked = { id: 'QUO-2', status: 'on_hold', hasQuote: true, date: '2026-10-07', price: 345 };
  assert.equal(isInvoice(parked), false);
  assert.equal(isTaxPoint(parked), false);
  assert.deepEqual(ordersToInvoiceRows([parked], { settings: VAT15, KhaytTax }), []);
  assert.equal(summaryOf([parked], VAT15).vat.output, 0);
  // Accepted, it is an invoice: in both.
  const accepted = { ...parked, quoteAcceptedAt: '2026-10-08', invoiceNumber: 'INV-3' };
  assert.equal(summaryOf([accepted], VAT15).vat.output, 45);
  assert.equal(Math.round(exportVat([accepted], VAT15) * 100) / 100, 45);
});

test('revenue grosses up by its OWN tax: the open invoice\'s VAT is not in it (beta.2 review)', () => {
  // The Mac's GROSS tile was revenue + vatCollected: finished 115 + printing
  // 230 read 100 + 45 = 145. It is revenue + revenueVat = 115.
  const { rows } = summaryOf(ORDERS, VAT15);
  assert.equal(rows[0].vatCollected, 45);
  assert.equal(rows[0].revenueVat, 15);
  assert.equal(rows[0].revenue + rows[0].revenueVat, 115);
});

test('the desktop Tax summary CSV reads its VAT off pnlByPeriod, not finished jobs of its own', () => {
  const fs = require('fs');
  const src = fs.readFileSync(require('path').join(__dirname, '../renderer/expenses.js'), 'utf8');
  const start = src.indexOf('function _doExportTaxSummary');
  const body = src.slice(start, src.indexOf('\n}\n', start));
  assert.ok(start > 0);
  assert.match(body, /KhaytPnl\.pnlByPeriod\(/);
  assert.doesNotMatch(body, /KhaytTax\.computeTax\(/);
});

test('computePnl: an open invoice adds its VAT and nothing else (beta.2 review)', () => {
  // The desktop's P&L CSV hands computePnl the finished jobs, plus each open
  // invoice as a `taxOnly` row, so its "VAT collected" is the P&L table's.
  const { computePnl } = require('../lib/pnl-report.js');
  const s = computePnl({ orders: [
    { revenue: 100, cogs: 20, vat: 15 },
    { taxOnly: true, revenue: 0, cogs: 0, vat: 30 },
  ], expenses: [] });
  assert.equal(s.vatCollected, 45);
  assert.equal(s.revenue, 100);
  assert.equal(s.orderCount, 1);
  assert.equal(s.grossProfit, 80);
});

test('the desktop P&L builder and VAT return use the tax-point rule, and shipping is not cost', () => {
  const fs = require('fs');
  const path = require('path');
  const an = fs.readFileSync(path.join(__dirname, '../renderer/analytics.js'), 'utf8');
  const at = an.indexOf('function pnlInputsForRange');
  const body = an.slice(at, an.indexOf('\nfunction ', at + 10));
  assert.match(body, /KhaytPnl\.isTaxPoint\(o\)/);
  assert.match(body, /taxOnly: true/);
  // Dated by the invoice's day, so an accepted quote's VAT is in range by its acceptance.
  assert.match(body, /inRange\(KhaytPnl\.taxPointDate\(o\), analyticsRange/);
  assert.doesNotMatch(body, /shippingCost/);
  const ops = fs.readFileSync(path.join(__dirname, '../renderer/operations-extras.js'), 'utf8');
  assert.match(ops, /KhaytPnl\.isTaxPoint\(o\) && day >= fromDate/);
});
