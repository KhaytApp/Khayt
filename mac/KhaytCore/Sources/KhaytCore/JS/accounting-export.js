'use strict';
(function () {

/**
 * Accounting export core — pure CSV builders for invoices & expenses.
 * See docs/KHAYT-3.0-ACCOUNTING-SPEC.md.
 *
 * This is a STANDALONE, pure module: data in → CSV string out. It does no I/O
 * (no fs, no Blob, no DOM) and requires nothing from the renderer. It reproduces
 * the existing CSV convention used by renderer/expenses.js / app-exports.js:
 *   - a leading UTF-8 BOM ('﻿'),
 *   - fields joined with ',',
 *   - rows joined with '\r\n',
 *   - per-field escaping (here: quote only when needed, doubling inner quotes).
 *
 * VAT mirrors zatcaInvoiceAmounts(order) in renderer/invoicing.js: order.price is
 * VAT-INCLUSIVE; vatAmt = price * rate / (100 + rate); rate defaults to 15 when
 * VAT is enabled and 0 otherwise. We round each money figure to 2dp with
 * roundMoney() and reconcile the rounding penny onto the subtotal so that
 * subtotal + vat === total exactly (same stance as buildZatcaInvoiceXml's amt()).
 */

const BOM = '﻿';

/**
 * CSV-safe field. Quotes the value only when it contains a comma, double quote,
 * CR or LF; internal double quotes are doubled. Non-string values are stringified
 * (null/undefined → '').
 * @param {*} value
 * @returns {string}
 */
function csvEscape(value) {
  const s = value === null || value === undefined ? '' : String(value);
  if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

/** Round a number to 2 decimal places (half-up on positive magnitude). */
function roundMoney(n) {
  const v = +n || 0;
  return Math.round((v + Number.EPSILON) * 100) / 100;
}

/** Fixed 2dp string for CSV output (e.g. 100 → "100.00"). */
function money(n) {
  return roundMoney(n).toFixed(2);
}

/**
 * Split a price into { subtotal, vat, total }, all rounded to 2dp, with
 * subtotal + vat === total guaranteed after rounding.
 *
 * `mode` decides what `price` MEANS, and it is the whole reason this takes a
 * third argument. Under 'inclusive' the price already contains the tax and the
 * tax is divided out of it — the only thing Khayt used to do. Under 'exclusive'
 * (the US and Canadian norm) the price is the pre-tax figure and the tax is added
 * to it, so the TOTAL is larger than the price passed in. Exporting an exclusive
 * shop's invoices with the inclusive split understates every total in the
 * bookkeeping file, silently.
 *
 * @param {number} price the order price, as the shop enters it
 * @param {number} rate  tax percentage (e.g. 15). 0 → zero-rated / tax off.
 * @param {string} mode  'inclusive' (default, and what every legacy caller means)
 * @returns {{ subtotal: number, vat: number, total: number }}
 */
function vatSplit(price, rate, mode = 'inclusive') {
  const r = +rate || 0;
  const p = +price || 0;
  if (r <= 0) { const t = roundMoney(p); return { subtotal: t, vat: 0, total: t }; }
  if (mode === 'exclusive') {
    const subtotal = roundMoney(p);
    const vat = roundMoney(p * r / 100);
    return { subtotal, vat, total: roundMoney(subtotal + vat) };
  }
  const total = roundMoney(p);
  const vat = roundMoney(p * r / (100 + r));
  // Reconcile the rounding penny onto the subtotal so the document balances.
  const subtotal = roundMoney(total - vat);
  return { subtotal, vat, total };
}

/**
 * Per-provider header maps. The keys are the canonical generic column names; the
 * values are the column titles each provider's importer expects. Field semantics
 * follow docs/KHAYT-3.0-ACCOUNTING-SPEC.md §2. The column ORDER below (the order
 * of these keys) is the order columns are emitted.
 */
const INVOICE_COLUMNS = [
  'Date',
  'InvoiceNo',
  'Customer',
  'Currency',
  'AccountCode',
  'Subtotal',
  'VAT',
  'VATRate',
  'Total',
  'BaseCurrency',
  'BaseTotal',
];

// Providers whose tax column expects a CODE/name (not a numeric %): Xero's
// TaxType and Zoho's Tax Name are codes the importer matches to a tax rate.
const TAX_CODE_PROVIDERS = new Set(['xero', 'zoho']);

const INVOICE_HEADER_MAP = {
  generic: {
    Date: 'Date',
    InvoiceNo: 'InvoiceNo',
    Customer: 'Customer',
    Currency: 'Currency',
    AccountCode: 'AccountCode',
    Subtotal: 'Subtotal',
    VAT: 'VAT',
    VATRate: 'VATRate',
    Total: 'Total',
    BaseCurrency: 'BaseCurrency',
    BaseTotal: 'BaseTotal',
  },
  quickbooks: {
    Date: 'Date',
    InvoiceNo: 'RefNumber',
    Customer: 'Name',
    Currency: 'Currency',
    AccountCode: 'AccountRef',
    Subtotal: 'Amount',
    VAT: 'TaxAmt',
    VATRate: 'TaxRate',
    Total: 'TrnsAmount',
    BaseCurrency: 'HomeCurrency',
    BaseTotal: 'HomeAmount',
  },
  xero: {
    Date: 'InvoiceDate',
    InvoiceNo: 'InvoiceNumber',
    Customer: 'ContactName',
    Currency: 'Currency',
    AccountCode: 'AccountCode',
    Subtotal: 'UnitAmount',
    VAT: 'TaxAmount',
    VATRate: 'TaxType',
    Total: 'Total',
    BaseCurrency: 'BaseCurrency',
    BaseTotal: 'BaseTotal',
  },
  zoho: {
    Date: 'Invoice Date',
    InvoiceNo: 'Invoice Number',
    Customer: 'Customer Name',
    Currency: 'Currency Code',
    AccountCode: 'Account',
    Subtotal: 'Item Price',
    VAT: 'Tax Amount',
    VATRate: 'Tax Name',
    Total: 'Total',
    BaseCurrency: 'Base Currency',
    BaseTotal: 'Base Total',
  },
};

const EXPENSE_COLUMNS = ['Date', 'Category', 'Amount', 'Currency', 'Note'];

const EXPENSE_HEADER_MAP = {
  generic: { Date: 'Date', Category: 'Category', Amount: 'Amount', Currency: 'Currency', Note: 'Note' },
  quickbooks: { Date: 'Date', Category: 'Account', Amount: 'Amount', Currency: 'Currency', Note: 'Memo' },
  xero: { Date: 'Date', Category: 'AccountCode', Amount: 'UnitAmount', Currency: 'Currency', Note: 'Description' },
  zoho: { Date: 'Expense Date', Category: 'Expense Account', Amount: 'Amount', Currency: 'Currency Code', Note: 'Description' },
};

/**
 * Small per-provider-agnostic account map (spec §2): canonical Khayt expense
 * categories → an accounting account name. Unmapped categories fall through to
 * the raw category string so nothing is silently dropped.
 */
const CATEGORY_ACCOUNT_MAP = {
  filament: 'Cost of Goods Sold',
  material: 'Cost of Goods Sold',
  materials: 'Cost of Goods Sold',
  supplies: 'Cost of Goods Sold',
  electricity: 'Utilities',
  utilities: 'Utilities',
  rent: 'Rent',
  shipping: 'Shipping & Delivery',
  software: 'Software & Subscriptions',
  marketing: 'Advertising & Marketing',
  fees: 'Bank & Transaction Fees',
};

/** Map a raw category to an account name, falling back to the raw string. */
function mapCategoryAccount(category) {
  if (!category) return '';
  const key = String(category).trim().toLowerCase();
  return CATEGORY_ACCOUNT_MAP[key] || String(category);
}

/** Normalise a date value to a YYYY-MM-DD prefix for range comparison. */
function dateKey(date) {
  if (!date) return '';
  return String(date).slice(0, 10);
}

/**
 * Inclusive date-range predicate over a row's `date`. `from`/`to` may be omitted
 * (open-ended). Comparison is lexical on the YYYY-MM-DD prefix, which is correct
 * for ISO dates.
 */
function inRange(date, from, to) {
  const d = dateKey(date);
  if (!d) return !from && !to ? true : false;
  if (from && d < dateKey(from)) return false;
  if (to && d > dateKey(to)) return false;
  return true;
}

/** Resolve the provider header row for a given column set + format. */
function headerRow(columns, headerMap, format) {
  const map = headerMap[format] || headerMap.generic;
  return columns.map((c) => csvEscape(map[c])).join(',');
}

/** Join a BOM-prefixed CSV document from an array of already-escaped rows. */
function joinCsv(rows) {
  return BOM + rows.join('\r\n');
}

/**
 * Build an invoices CSV string (UTF-8 BOM, \r\n rows).
 *
 * @param {Array<{id?:string,date?:string,clientName?:string,price?:number,
 *   currency?:string,vatRate?:number,baseCurrency?:string,baseAmount?:number,
 *   status?:string}>} invoices VAT-inclusive `price`.
 * @param {{format?:'generic'|'quickbooks'|'xero'|'zoho',from?:string,to?:string}} [opts]
 * @returns {string} CSV document. Always at least a header row.
 */
function buildInvoiceCsv(invoices, opts = {}) {
  const format = opts.format && INVOICE_HEADER_MAP[opts.format] ? opts.format : 'generic';
  const rows = [headerRow(INVOICE_COLUMNS, INVOICE_HEADER_MAP, format)];

  for (const inv of Array.isArray(invoices) ? invoices : []) {
    if (!inRange(inv.date, opts.from, opts.to)) continue;
    const rate = inv.vatRate === undefined || inv.vatRate === null ? 0 : +inv.vatRate;
    const { subtotal, vat, total } = vatSplit(inv.price, rate, inv.taxMode);
    const baseCurrency = inv.baseCurrency || '';
    const baseTotal = inv.baseAmount === undefined || inv.baseAmount === null
      ? '' : money(inv.baseAmount);
    // Providers that key tax by code (Xero TaxType / Zoho Tax Name) get the
    // configured tax code; everything else gets the numeric rate.
    const taxCell = (TAX_CODE_PROVIDERS.has(format) && opts.taxCode) ? opts.taxCode : rate;
    const cells = {
      Date: dateKey(inv.date),
      InvoiceNo: inv.id || '',
      Customer: inv.clientName || '',
      Currency: inv.currency || '',
      AccountCode: opts.salesAccount || '',
      Subtotal: money(subtotal),
      VAT: money(vat),
      VATRate: taxCell,
      Total: money(total),
      BaseCurrency: baseCurrency,
      BaseTotal: baseTotal,
    };
    rows.push(INVOICE_COLUMNS.map((c) => csvEscape(cells[c])).join(','));
  }

  return joinCsv(rows);
}

/**
 * Build an expenses CSV string (UTF-8 BOM, \r\n rows).
 *
 * @param {Array<{date?:string,category?:string,amount?:number,currency?:string,
 *   note?:string}>} expenses
 * @param {{format?:'generic'|'quickbooks'|'xero'|'zoho',from?:string,to?:string}} [opts]
 * @returns {string} CSV document. Always at least a header row.
 */
function buildExpenseCsv(expenses, opts = {}) {
  const format = opts.format && EXPENSE_HEADER_MAP[opts.format] ? opts.format : 'generic';
  const rows = [headerRow(EXPENSE_COLUMNS, EXPENSE_HEADER_MAP, format)];

  for (const exp of Array.isArray(expenses) ? expenses : []) {
    if (!inRange(exp.date, opts.from, opts.to)) continue;
    const cells = {
      Date: dateKey(exp.date),
      Category: mapCategoryAccount(exp.category),
      Amount: money(exp.amount),
      Currency: exp.currency || '',
      Note: exp.note || '',
    };
    rows.push(EXPENSE_COLUMNS.map((c) => csvEscape(cells[c])).join(','));
  }

  return joinCsv(rows);
}

/**
 * Canonical JSON payload for pushing ONE invoice to an accounting webhook.
 * Provider-agnostic + idempotent (idempotencyKey = "inv:<id>"); the receiving
 * bridge (Zapier/Make/n8n/own endpoint) maps it to QuickBooks/Zoho/Xero.
 */
function buildInvoicePayload(inv, opts = {}) {
  inv = inv || {};
  const rate = inv.vatRate === undefined || inv.vatRate === null ? 0 : +inv.vatRate;
  const { subtotal, vat, total } = vatSplit(inv.price, rate, inv.taxMode);
  return {
    type: 'invoice',
    format: opts.format || 'generic',
    idempotencyKey: 'inv:' + (inv.id || ''),
    date: dateKey(inv.date),
    invoiceNo: inv.id || '',
    customer: inv.clientName || '',
    currency: inv.currency || '',
    salesAccount: opts.salesAccount || '',
    taxCode: opts.taxCode || '',
    subtotal: roundMoney(subtotal),
    vat: roundMoney(vat),
    vatRate: rate,
    total: roundMoney(total),
    baseCurrency: inv.baseCurrency || '',
    baseTotal: inv.baseAmount === undefined || inv.baseAmount === null ? null : roundMoney(inv.baseAmount),
  };
}

/** Canonical JSON payload for pushing ONE expense (idempotencyKey = "exp:<id>"). */
function buildExpensePayload(exp, opts = {}) {
  exp = exp || {};
  return {
    type: 'expense',
    format: opts.format || 'generic',
    idempotencyKey: 'exp:' + (exp.id || ''),
    date: dateKey(exp.date),
    account: mapCategoryAccount(exp.category),
    category: exp.category || '',
    amount: roundMoney(exp.amount),
    currency: exp.currency || '',
    note: exp.note || '',
  };
}

const api = {
  BOM,
  csvEscape,
  vatSplit,
  roundMoney,
  mapCategoryAccount,
  buildInvoiceCsv,
  buildExpenseCsv,
  buildInvoicePayload,
  buildExpensePayload,
  INVOICE_COLUMNS,
  EXPENSE_COLUMNS,
  INVOICE_HEADER_MAP,
  EXPENSE_HEADER_MAP,
  CATEGORY_ACCOUNT_MAP,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAccountingExport = api;

})();
