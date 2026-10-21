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
    for (const voidedAt of [undefined, '2026-10-01']) {
      for (const creditedAt of [undefined, '2026-10-01']) {
        for (const nonBusiness of [undefined, true]) {
          for (const splitInto of [undefined, [], ['a']]) {
            const o = { status, voidedAt, creditedAt, nonBusiness, splitInto };
            assert.equal(isTaxPoint(o), isInvoice(o), JSON.stringify(o));
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
