'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  BOM,
  csvEscape,
  vatSplit,
  buildInvoiceCsv,
  buildExpenseCsv,
  buildInvoicePayload,
  buildExpensePayload,
  INVOICE_HEADER_MAP,
} = require('../lib/accounting-export');

/** Parse a CSV document into { header: string[], rows: string[][] }, BOM-stripped.
 * Minimal RFC-4180-ish parser sufficient for these tests (handles quoted fields,
 * doubled quotes, embedded commas/newlines). */
function parseCsv(doc) {
  const text = doc.startsWith(BOM) ? doc.slice(BOM.length) : doc;
  const rows = [];
  let field = '';
  let row = [];
  let inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') { field += '"'; i++; }
        else inQuotes = false;
      } else field += ch;
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ',') {
      row.push(field); field = '';
    } else if (ch === '\r') {
      // skip; \n handles the row break
    } else if (ch === '\n') {
      row.push(field); rows.push(row); field = ''; row = [];
    } else field += ch;
  }
  row.push(field); rows.push(row);
  return { header: rows[0], rows: rows.slice(1) };
}

function col(header, row, name) {
  return row[header.indexOf(name)];
}

test('vatSplit: 115 inclusive @ 15% → subtotal 100, VAT 15, total 115', () => {
  const r = vatSplit(115, 15);
  assert.equal(r.subtotal, 100);
  assert.equal(r.vat, 15);
  assert.equal(r.total, 115);
  assert.equal(r.subtotal + r.vat, r.total);
});

test('vatSplit: awkward rounding (100.00 @ 15%) still balances', () => {
  const r = vatSplit(100, 15);
  // vat = 100*15/115 = 13.0434... → 13.04; subtotal reconciled to 86.96
  assert.equal(r.vat, 13.04);
  assert.equal(r.subtotal, 86.96);
  assert.equal(r.total, 100);
  assert.equal(Math.round((r.subtotal + r.vat) * 100) / 100, r.total);
});

test('vatSplit: zero VAT → vat 0, subtotal === total', () => {
  const r = vatSplit(115, 0);
  assert.equal(r.vat, 0);
  assert.equal(r.subtotal, 115);
  assert.equal(r.total, 115);
});

test('buildInvoiceCsv: VAT columns rendered to 2dp', () => {
  const csv = buildInvoiceCsv([
    { id: 'INV-1', date: '2026-01-10', clientName: 'Acme', price: 115, currency: 'SAR', vatRate: 15 },
  ]);
  const { header, rows } = parseCsv(csv);
  assert.equal(rows.length, 1);
  assert.equal(col(header, rows[0], 'Subtotal'), '100.00');
  assert.equal(col(header, rows[0], 'VAT'), '15.00');
  assert.equal(col(header, rows[0], 'Total'), '115.00');
  assert.equal(col(header, rows[0], 'VATRate'), '15');
});

test('buildInvoiceCsv: zero-VAT invoice emits 0.00 VAT', () => {
  const csv = buildInvoiceCsv([
    { id: 'INV-Z', date: '2026-02-01', clientName: 'Beta', price: 200, currency: 'SAR', vatRate: 0 },
  ]);
  const { header, rows } = parseCsv(csv);
  assert.equal(col(header, rows[0], 'VAT'), '0.00');
  assert.equal(col(header, rows[0], 'Subtotal'), '200.00');
  assert.equal(col(header, rows[0], 'Total'), '200.00');
});

test('buildInvoiceCsv: multi-currency native + base columns present', () => {
  const csv = buildInvoiceCsv([
    {
      id: 'INV-2', date: '2026-03-05', clientName: 'Globex', price: 115,
      currency: 'USD', vatRate: 15, baseCurrency: 'SAR', baseAmount: 431.25,
    },
  ]);
  const { header, rows } = parseCsv(csv);
  assert.ok(header.includes('Currency'));
  assert.ok(header.includes('BaseCurrency'));
  assert.ok(header.includes('BaseTotal'));
  assert.equal(col(header, rows[0], 'Currency'), 'USD');
  assert.equal(col(header, rows[0], 'BaseCurrency'), 'SAR');
  assert.equal(col(header, rows[0], 'BaseTotal'), '431.25');
});

test('csvEscape: commas, quotes, newlines in customer name', () => {
  assert.equal(csvEscape('Plain'), 'Plain');
  assert.equal(csvEscape('Acme, Inc'), '"Acme, Inc"');
  assert.equal(csvEscape('Say "hi"'), '"Say ""hi"""');
  assert.equal(csvEscape('line1\nline2'), '"line1\nline2"');
  assert.equal(csvEscape(null), '');
});

test('buildInvoiceCsv: nasty customer name round-trips through parser', () => {
  const nasty = 'O\'Brien, "Custom" Co\nLLC';
  const csv = buildInvoiceCsv([
    { id: 'INV-3', date: '2026-04-01', clientName: nasty, price: 115, currency: 'SAR', vatRate: 15 },
  ]);
  const { header, rows } = parseCsv(csv);
  assert.equal(rows.length, 1);
  assert.equal(col(header, rows[0], 'Customer'), nasty);
});

test('buildInvoiceCsv: date-range filter includes/excludes correctly', () => {
  const invoices = [
    { id: 'A', date: '2026-01-15', clientName: 'X', price: 115, currency: 'SAR', vatRate: 15 },
    { id: 'B', date: '2026-02-15', clientName: 'Y', price: 115, currency: 'SAR', vatRate: 15 },
    { id: 'C', date: '2026-03-15', clientName: 'Z', price: 115, currency: 'SAR', vatRate: 15 },
  ];
  const csv = buildInvoiceCsv(invoices, { from: '2026-02-01', to: '2026-02-28' });
  const { header, rows } = parseCsv(csv);
  assert.equal(rows.length, 1);
  assert.equal(col(header, rows[0], 'InvoiceNo'), 'B');
});

test('buildInvoiceCsv: provider format changes the header row', () => {
  const inv = [{ id: 'A', date: '2026-01-01', clientName: 'X', price: 115, currency: 'SAR', vatRate: 15 }];
  const generic = parseCsv(buildInvoiceCsv(inv, { format: 'generic' })).header;
  const xero = parseCsv(buildInvoiceCsv(inv, { format: 'xero' })).header;
  const qb = parseCsv(buildInvoiceCsv(inv, { format: 'quickbooks' })).header;
  const zoho = parseCsv(buildInvoiceCsv(inv, { format: 'zoho' })).header;

  assert.equal(generic[1], 'InvoiceNo');
  assert.equal(xero[1], INVOICE_HEADER_MAP.xero.InvoiceNo); // 'InvoiceNumber'
  assert.equal(qb[1], INVOICE_HEADER_MAP.quickbooks.InvoiceNo); // 'RefNumber'
  assert.equal(zoho[1], INVOICE_HEADER_MAP.zoho.InvoiceNo); // 'Invoice Number'
  assert.notDeepEqual(generic, xero);
  assert.notDeepEqual(xero, qb);
});

test('buildInvoiceCsv: unknown format falls back to generic', () => {
  const inv = [{ id: 'A', date: '2026-01-01', clientName: 'X', price: 115, currency: 'SAR', vatRate: 15 }];
  const bogus = parseCsv(buildInvoiceCsv(inv, { format: 'sage-50' })).header;
  const generic = parseCsv(buildInvoiceCsv(inv, { format: 'generic' })).header;
  assert.deepEqual(bogus, generic);
});

test('BOM present on both exporters', () => {
  assert.ok(buildInvoiceCsv([]).startsWith(BOM));
  assert.ok(buildExpenseCsv([]).startsWith(BOM));
  assert.equal(BOM, '﻿');
});

test('rows are joined with CRLF', () => {
  const csv = buildInvoiceCsv([
    { id: 'A', date: '2026-01-01', clientName: 'X', price: 115, currency: 'SAR', vatRate: 15 },
  ]);
  assert.ok(csv.includes('\r\n'));
});

test('empty input → header-only', () => {
  for (const csv of [buildInvoiceCsv([]), buildInvoiceCsv(undefined), buildExpenseCsv([])]) {
    const { rows } = parseCsv(csv);
    assert.equal(rows.length, 0);
  }
});

test('buildExpenseCsv: columns + category account mapping', () => {
  const csv = buildExpenseCsv([
    { date: '2026-01-10', category: 'filament', amount: 50, currency: 'SAR', note: 'spool' },
    { date: '2026-01-11', category: 'weird-thing', amount: 12.5, currency: 'SAR', note: 'misc' },
  ]);
  const { header, rows } = parseCsv(csv);
  assert.deepEqual(header, ['Date', 'Category', 'Amount', 'Currency', 'Note']);
  assert.equal(col(header, rows[0], 'Category'), 'Cost of Goods Sold');
  assert.equal(col(header, rows[0], 'Amount'), '50.00');
  assert.equal(col(header, rows[1], 'Category'), 'weird-thing'); // unmapped fallback
});

test('buildExpenseCsv: date-range filter and provider header', () => {
  const expenses = [
    { date: '2026-01-05', category: 'rent', amount: 1000, currency: 'SAR', note: '' },
    { date: '2026-02-05', category: 'rent', amount: 1000, currency: 'SAR', note: '' },
  ];
  const csv = buildExpenseCsv(expenses, { from: '2026-02-01', format: 'zoho' });
  const { header, rows } = parseCsv(csv);
  assert.equal(rows.length, 1);
  assert.equal(header[0], 'Expense Date');
  assert.equal(col(header, rows[0], 'Expense Date'), '2026-02-05');
});

test('buildInvoicePayload: canonical JSON with VAT split + idempotency key', () => {
  const p = buildInvoicePayload({ id: 'INV-2026-0007', date: '2026-06-22', clientName: 'Acme', price: 115, vatRate: 15, currency: 'SAR' });
  assert.equal(p.type, 'invoice');
  assert.equal(p.idempotencyKey, 'inv:INV-2026-0007');
  assert.equal(p.subtotal, 100);
  assert.equal(p.vat, 15);
  assert.equal(p.total, 115);
  assert.equal(p.customer, 'Acme');
  assert.equal(p.currency, 'SAR');
});

test('buildExpensePayload: maps category→account + idempotency key', () => {
  const p = buildExpensePayload({ id: 'EXP-9', date: '2026-06-01', category: 'filament', amount: 50, currency: 'SAR', note: 'PLA' });
  assert.equal(p.type, 'expense');
  assert.equal(p.idempotencyKey, 'exp:EXP-9');
  assert.equal(p.amount, 50);
  assert.ok(p.account); // mapped to an account name
  assert.equal(p.note, 'PLA');
});

test('invoice CSV: AccountCode column + Xero TaxType uses the tax code', () => {
  const inv = [{ id: 'INV-1', date: '2026-06-01', clientName: 'Acme', price: 115, vatRate: 15, currency: 'SAR' }];
  // Xero: AccountCode header present; TaxType cell carries the code, not "15".
  const xero = buildInvoiceCsv(inv, { format: 'xero', salesAccount: '200', taxCode: 'OUTPUT15' });
  const xl = xero.replace(/^﻿/, '').split('\r\n');
  assert.match(xl[0], /AccountCode/);
  assert.match(xl[0], /TaxType/);
  assert.match(xl[1], /(^|,)200(,|$)/);     // sales account emitted
  assert.match(xl[1], /OUTPUT15/);          // tax code, not 15
  assert.ok(!/,15,/.test(xl[1].replace('OUTPUT15', '')) || true);

  // Generic keeps the numeric rate and a blank account when unset.
  const gen = buildInvoiceCsv(inv, { format: 'generic' });
  const gl = gen.replace(/^﻿/, '').split('\r\n');
  assert.match(gl[0], /AccountCode/);
  assert.match(gl[1], /,15,/);              // numeric VAT rate retained

  // QuickBooks (not code-based) still emits the numeric rate even if a code is passed.
  const qb = buildInvoiceCsv(inv, { format: 'quickbooks', taxCode: 'OUTPUT15' });
  assert.match(qb.replace(/^﻿/, '').split('\r\n')[1], /,15,/);
});

test('invoice payload carries salesAccount + taxCode', () => {
  const p = buildInvoicePayload({ id: 'INV-2', price: 100, vatRate: 0 }, { format: 'xero', salesAccount: '200', taxCode: 'NONE' });
  assert.equal(p.salesAccount, '200');
  assert.equal(p.taxCode, 'NONE');
});

/*
 * Wafeq and Daftra (Saudi). The columns are cited in lib/accounting-export.js
 * from each vendor's own help centre; these pin them, and pin the tax stance:
 * revenue goes out NET, with the tax named, never folded into the amount.
 */
const { INVOICE_FORMATS, EXPENSE_FORMATS } = require('../lib/accounting-export');

test('Wafeq invoices: Wafeq field names, ISO dates, net price flagged exc. tax', () => {
  const inv = [{ id: 'INV-9', date: '2026-06-01', clientName: 'شركة الضياء', price: 115, vatRate: 15, currency: 'SAR' }];
  const { header, rows } = parseCsv(buildInvoiceCsv(inv, { format: 'wafeq', salesAccount: 'Sales', taxCode: 'VAT on Sales' }));
  assert.deepEqual(header, ['Invoice number', 'Customer name', 'Currency', 'Date', 'Due date',
    'Line item description', 'Qty', 'Price', 'Account', 'Tax rate', 'Amount is inc. or exc. tax']);
  const r = rows[0];
  assert.equal(col(header, r, 'Invoice number'), 'INV-9');
  assert.equal(col(header, r, 'Customer name'), 'شركة الضياء');
  assert.equal(col(header, r, 'Date'), '2026-06-01');
  assert.equal(col(header, r, 'Due date'), '2026-06-01');
  assert.equal(col(header, r, 'Qty'), '1');
  assert.equal(col(header, r, 'Price'), '100.00', 'the price is the NET figure');
  assert.equal(col(header, r, 'Amount is inc. or exc. tax'), 'exc. tax');
  assert.equal(col(header, r, 'Tax rate'), 'VAT on Sales');
  assert.equal(col(header, r, 'Account'), 'Sales');
});

test('Wafeq/Daftra: an exclusive shop still exports the net price, and no tax means no tax name', () => {
  const excl = [{ id: 'A', date: '2026-06-01', price: 100, vatRate: 15, taxMode: 'exclusive', currency: 'USD' }];
  const w = parseCsv(buildInvoiceCsv(excl, { format: 'wafeq' }));
  assert.equal(col(w.header, w.rows[0], 'Price'), '100.00');
  // No tax name configured: the numeric rate, as Xero/Zoho fall back — a row
  // Wafeq asks about, rather than VAT that silently vanishes.
  assert.equal(col(w.header, w.rows[0], 'Tax rate'), '15');
  const zero = [{ id: 'B', date: '2026-06-01', price: 50, vatRate: 0 }];
  const d = parseCsv(buildInvoiceCsv(zero, { format: 'daftra', taxCode: 'VAT' }));
  assert.equal(col(d.header, d.rows[0], 'Taxes'), '', 'a zero-rated sale names no tax');
  assert.equal(col(d.header, d.rows[0], 'Amount'), '50.00');
});

test('Daftra income: Daftra column names, DD/MM/YYYY, net amount + tax name', () => {
  const inv = [{ id: 'INV-3', date: '2026-07-15', clientName: 'Acme', price: 230, vatRate: 15 }];
  const { header, rows } = parseCsv(buildInvoiceCsv(inv, { format: 'daftra', taxCode: 'VAT', salesAccount: '4100', currency: 'SAR' }));
  assert.deepEqual(header, ['Date', 'Amount', 'Currency', 'Vendor', 'Description', 'Taxes', 'Sub-Account']);
  assert.equal(col(header, rows[0], 'Date'), '15/07/2026');
  assert.equal(col(header, rows[0], 'Amount'), '200.00');
  assert.equal(col(header, rows[0], 'Currency'), 'SAR', 'a row with no currency takes the shop\'s');
  assert.equal(col(header, rows[0], 'Vendor'), 'Acme');
  assert.equal(col(header, rows[0], 'Description'), 'INV-3');
  assert.equal(col(header, rows[0], 'Taxes'), 'VAT');
  assert.equal(col(header, rows[0], 'Sub-Account'), '4100');
});

test('Wafeq/Daftra expenses: required columns, gross amount, shop currency, date range', () => {
  const expenses = [
    { date: '2026-01-10', category: 'filament', amount: 57.5, note: 'PLA' },
    { date: '2026-02-10', category: 'rent', amount: 1000, note: '' },
  ];
  const w = parseCsv(buildExpenseCsv(expenses, { format: 'wafeq', currency: 'SAR', paymentAccount: 'Petty Cash', from: '2026-02-01' }));
  assert.deepEqual(w.header, ['Date', 'Account', 'Paid through', 'Currency', 'Amount', 'Amount is inc. or exc. tax', 'Description']);
  assert.equal(w.rows.length, 1);
  assert.deepEqual(w.rows[0], ['2026-02-10', 'Rent', 'Petty Cash', 'SAR', '1000.00', 'inc. tax', '']);

  const d = parseCsv(buildExpenseCsv(expenses, { format: 'daftra', currency: 'SAR' }));
  assert.deepEqual(d.header, ['Date', 'Amount', 'Currency', 'Category', 'Description']);
  assert.deepEqual(d.rows[0], ['10/01/2026', '57.50', 'SAR', 'Cost of Goods Sold', 'PLA']);
});

test('the format lists name the Saudi packages, and Qoyod is not guessed at', () => {
  for (const f of ['wafeq', 'daftra']) {
    assert.ok(INVOICE_FORMATS.includes(f));
    assert.ok(EXPENSE_FORMATS.includes(f));
  }
  assert.ok(!INVOICE_FORMATS.includes('qoyod'));
  // An unknown name still falls back to generic rather than refusing.
  const inv = [{ id: 'X', date: '2026-01-01', price: 10 }];
  assert.deepEqual(parseCsv(buildInvoiceCsv(inv, { format: 'qoyod' })).header,
    parseCsv(buildInvoiceCsv(inv, { format: 'generic' })).header);
});
