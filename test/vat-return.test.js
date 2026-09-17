'use strict';
/**
 * The VAT return declared nothing.
 *
 * Boxes 1-3 read `o.vatAmount` and `o.vatRate`. NEITHER FIELD IS EVER WRITTEN —
 * not by the order form, not by the invoice, not by any importer. `+undefined
 * || 0` is 0 and `NaN === 0` is false, so:
 *
 *   Box 2 (zero-rated sales)  always 0
 *   Box 3 (VAT due on sales)  always 0  ← the number the shop pays on
 *   Box 1 (standard sales)    the price INCLUDING the VAT
 *
 * On SAR 400,000 of sales at 15% the form declared SAR 400,000 of sales, zero
 * VAT due, and a net of zero. SAR 52,173.92 was owed.
 *
 * The arithmetic already existed — lib/tax.js, which every invoice uses, and
 * whose profile treats a price as tax-INCLUSIVE. The return now uses the same
 * module, so it and the invoices cannot disagree about one order.
 *
 * These drive the real exported function through the real DOM-free globals it
 * reads, and assert on the HTML it produces, so the wiring is what is tested.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const KhaytTax = require(path.join(ROOT, 'lib/tax.js'));
// 'delivered' is finished too — the return counts both spellings of a sale.
const KhaytOrderStatus = require(path.join(ROOT, 'lib/order-status.js'));

/**
 * Run exportGaztVatReturn with the globals it reads, and capture the HTML it
 * would have written. Loading the real source means a change to the function
 * is what these tests see.
 */
function runReturn({ orders, expenses = [], settings = { enableVat: true, vatRate: 15, currency: 'SAR' } }) {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/operations-extras.js'), 'utf8');
  let captured = null;
  const sandbox = {
    KhaytTax,
    KhaytOrderStatus,
    settings,
    printLog: orders,
    expenses,
    console,
    // Revenue chokepoint: base currency, credit notes deducted, personal excluded.
    orderNetRevenueBase: (o) => Math.max(0, (+o.price || 0) - ((o.creditNotes || []).reduce((s, c) => s + (+c.amount || 0), 0))),
    orderCurrency: () => 'SAR',
    convertToBase: (v) => v,
    fmtMoney: (v) => Number(v).toFixed(2),
    currencySymbol: () => 'SAR',
    shopName: () => 'Test Shop',
    escapeHtml: (s2) => String(s2).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])),
    // The report now calls t() for its own toasts, like the rest of the app.
    // Returning the key is enough: nothing here asserts on a toast.
    t: (k) => k,
    toast: () => {},
    downloadBlob: () => {},
    Blob: class { constructor(parts) { captured = parts.join(''); } },
    window: {},
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: 'operations-extras.js' });
  sandbox.exportGaztVatReturn('year');
  assert.ok(captured, 'the return produced no document');
  return captured;
}

/**
 * Pull one row's amount out of the rendered table.
 *
 * By POSITION, not by "Box N": the box numbers are the Saudi form's and are
 * deliberately absent for every other country, so matching on them would make
 * this helper work only where the bug already was.
 */
const ROW_ORDER = [1, 2, 3, 6, 7];
function box(html, n) {
  const body = html.slice(html.indexOf('<tbody>'), html.indexOf('</tbody>'));
  const rows = [...body.matchAll(/<tr[^>]*>\s*<td>[^<]*<\/td><td>([^<]*)<\/td><td>([^<]*)<\/td>/g)];
  const i = ROW_ORDER.indexOf(n);
  assert.ok(i >= 0, `no such row: ${n}`);
  assert.ok(rows[i], `row ${n} is missing from the summary (found ${rows.length} rows)`);
  return rows[i][2];
}

/** The label of that row, for the tests that care what it is called. */
function rowLabel(html, n) {
  const body = html.slice(html.indexOf('<tbody>'), html.indexOf('</tbody>'));
  const rows = [...body.matchAll(/<tr[^>]*>\s*<td>[^<]*<\/td><td>([^<]*)<\/td><td>([^<]*)<\/td>/g)];
  return rows[ROW_ORDER.indexOf(n)][1];
}

const YEAR = new Date().getFullYear();
const d = (m) => `${YEAR}-${m}-15`;
const sale = (price, extra = {}) => ({ id: `O-${price}`, status: 'completed', date: d('06'), project: 'p', price, ...extra });

test('a VAT-registered shop declares the VAT it actually owes', () => {
  const html = runReturn({ orders: [sale(200000), sale(150000), sale(50000)] });
  // 400,000 gross at 15% inclusive → 347,826.08 net + 52,173.92 VAT.
  assert.equal(box(html, 1), '347826.08', 'Box 1 still reports the VAT-inclusive price as sales');
  assert.equal(box(html, 3), '52173.92', 'Box 3 declared no VAT due');
  assert.equal(box(html, 2), '0.00', 'a registered shop has no zero-rated sales in this model');
});

test('a delivered sale is declared, exactly like a completed one', () => {
  // `delivered` is the other spelling of finished. The return counted only
  // `completed`, so a shop that had marked its jobs delivered declared less
  // tax than it owed — and under-declaring is not a rounding error.
  const completed = runReturn({ orders: [sale(200000), sale(150000)] });
  const delivered = runReturn({
    orders: [sale(200000, { status: 'delivered' }), sale(150000, { status: 'delivered' })],
  });
  assert.equal(box(delivered, 1), box(completed, 1));
  assert.equal(box(delivered, 3), box(completed, 3));
  assert.equal(box(delivered, 3), '45652.18');
});

test('a job that is not finished is still not declared', () => {
  for (const status of ['quote', 'pending', 'printing', 'post', 'qc', 'on_hold']) {
    const html = runReturn({ orders: [sale(200000, { status })] });
    assert.equal(box(html, 1), '0.00', status);
    assert.equal(box(html, 3), '0.00', status);
  }
});

test('Box 1 and Box 3 add back up to what was charged', () => {
  const html = runReturn({ orders: [sale(1234.56), sale(99.99)] });
  const total = Number(box(html, 1)) + Number(box(html, 3));
  assert.ok(Math.abs(total - (1234.56 + 99.99)) < 0.02,
    `net + VAT (${total}) does not reconstruct the gross taken`);
});

test('a shop with VAT off reports zero-rated sales, not standard-rated ones', () => {
  const html = runReturn({
    orders: [sale(1000)],
    settings: { enableVat: false, currency: 'SAR' },
  });
  assert.equal(box(html, 1), '0.00');
  assert.equal(box(html, 2), '1000.00', 'sales vanished from the return entirely');
  assert.equal(box(html, 3), '0.00', 'VAT was declared by a shop that charges none');
});

test('a credit note reverses the sale and its VAT together', () => {
  const full = runReturn({ orders: [sale(1000)] });
  const credited = runReturn({ orders: [sale(1000, { creditNotes: [{ amount: 400 }] })] });
  assert.ok(Number(box(credited, 3)) < Number(box(full, 3)), 'the credit note did not reduce the VAT due');
  const expected = KhaytTax.computeTax(600, KhaytTax.profileFromSettings({ enableVat: true, vatRate: 15 }));
  assert.equal(box(credited, 3), expected.taxTotal.toFixed(2));
});

test('only completed orders in the period are counted', () => {
  const html = runReturn({
    orders: [
      sale(1000),
      { id: 'O-q', status: 'quote', date: d('06'), project: 'p', price: 9999 },
      { id: 'O-old', status: 'completed', date: `${YEAR - 1}-06-15`, project: 'p', price: 8888 },
    ],
  });
  const gross = Number(box(html, 1)) + Number(box(html, 3));
  assert.ok(Math.abs(gross - 1000) < 0.02, 'a quote or a prior year leaked into the return');
});

test('Box 7 is blank, and says why, rather than claiming nothing is reclaimable', () => {
  // No expense record has ever carried a VAT figure. Printing a confident 0
  // invited a shop to file "nothing reclaimable" as though Khayt had checked.
  const html = runReturn({
    orders: [sale(1000)],
    expenses: [{ id: 'E1', date: d('06'), amount: 500, category: 'filament' }],
  });
  assert.equal(box(html, 7), '&mdash;', 'the recoverable row prints a figure Khayt has no data for');
  assert.match(rowLabel(html, 7), /recoverable/i);
  assert.match(html, /does not record VAT on expenses/, 'the shop is not warned before filing');
});

test('an expense that does carry VAT is totalled and the warning goes away', () => {
  const html = runReturn({
    orders: [sale(1000)],
    expenses: [{ id: 'E1', date: d('06'), amount: 500, vatAmount: 65.22 }],
  });
  assert.equal(box(html, 7), '65.22');
  assert.ok(!/does not record VAT on expenses/.test(html), 'warned about data that is present');
});

test('the return uses the same tax module as the invoices', () => {
  // If these ever diverge, one order is taxed two ways by the same shop.
  // Comments stripped: this guard quotes the old field names in the explanation
  // above the fix, and a guard that reads its own prose as the bug never passes.
  const src = fs.readFileSync(path.join(ROOT, 'renderer/operations-extras.js'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
  const at = src.indexOf('function exportGaztVatReturn');
  const body = src.slice(at, at + 3000);
  assert.match(body, /KhaytTax\.profileFromSettings\(settings\)/, 'the return derives its own tax profile');
  assert.match(body, /KhaytTax\.computeTax\(/, 'the return computes VAT by hand again');
  assert.ok(!/o\.vatAmount|o\.vatRate/.test(body),
    'the return still reads an order field that nothing writes');
});


/* ------------------------------------------------------------------
 * The figures travel; the box numbers do not.
 *
 * lib/tax.js carries THIRTY country presets — VAT, GST, Sales Tax — in both
 * inclusive and exclusive mode, and the arithmetic is right for all of them.
 * The paperwork was not: the document called itself a "GAZT VAT Return" and
 * numbered its rows Box 1/2/3/6/7, which is the Saudi form. A UK shop files a
 * VAT100 whose nine boxes mean different things; a US shop has no VAT return at
 * all. Handing either of them a Saudi form with their numbers in it is worse
 * than a plain list, because the numbers look authoritative.
 * ------------------------------------------------------------------ */

const SA = { tax: { country: 'SA', name: 'VAT', mode: 'inclusive', rates: [{ id: 'v', label: 'VAT', percent: 15 }] }, currency: 'SAR' };
const GB = { tax: { country: 'GB', name: 'VAT', mode: 'inclusive', rates: [{ id: 'v', label: 'VAT', percent: 20 }] }, currency: 'GBP' };
const US = { tax: { country: 'US', name: 'Sales Tax', mode: 'exclusive', rates: [{ id: 's', label: 'Sales Tax', percent: 8.875 }] }, currency: 'USD' };

test('an inclusive-priced shop has the tax taken OUT of the price', () => {
  const html = runReturn({ orders: [sale(1000)], settings: GB });
  // 1000 gross at 20% inclusive → 833.33 net + 166.67 tax.
  assert.equal(box(html, 1), '833.33');
  assert.equal(box(html, 3), '166.67');
  assert.match(html, /Prices in Khayt include VAT at 20%/);
});

test('an exclusive-priced shop has the tax added ON TOP', () => {
  // The price IS the net. Getting this backwards would understate the tax due
  // on every US and Canadian shop.
  const html = runReturn({ orders: [sale(1000)], settings: US });
  assert.equal(box(html, 1), '1000.00', 'an exclusive price was treated as tax-inclusive');
  assert.equal(box(html, 3), '88.75');
  assert.match(html, /Prices in Khayt exclude Sales Tax/);
});

test('the shop\'s own tax name is used, not "VAT" everywhere', () => {
  const html = runReturn({ orders: [sale(1000)], settings: US });
  assert.match(html, /Sales Tax collected on sales/);
  assert.match(html, /Net Sales Tax payable/);
  assert.ok(!/VAT/.test(html), 'a US shop is shown VAT it does not pay');
});

test('Saudi keeps its box numbers; nobody else is given them', () => {
  assert.match(runReturn({ orders: [sale(1000)], settings: SA }), /<td>Box 1<\/td>/);
  for (const s2 of [GB, US]) {
    const html = runReturn({ orders: [sale(1000)], settings: s2 });
    assert.ok(!/Box \d/.test(html), 'a non-Saudi shop is given Saudi box numbers, which look authoritative and are wrong');
  }
});

test('a shop from before the country presets is still treated as Saudi', () => {
  // settings.enableVat with no settings.tax is the pre-presets shape, and every
  // shop that had it was Saudi. Dropping their box numbers would be a regression.
  const html = runReturn({ orders: [sale(1000)], settings: { enableVat: true, vatRate: 15, currency: 'SAR' } });
  assert.match(html, /<td>Box 1<\/td>/);
});

test('it never calls itself a return, and says the box numbers differ', () => {
  const html = runReturn({ orders: [sale(1000)], settings: GB });
  assert.ok(!/GAZT/.test(html), 'a non-Saudi shop is handed a Saudi authority\'s form');
  assert.match(html, /summary to transcribe onto the return you file/);
  assert.match(html, /The box numbers on your form will differ/);
  assert.match(html, /mixed or exempt rating must\s+split these figures itself/,
    'the one-rate limitation is not stated, so a shop with exempt sales would file this as-is');
});

test('the Saudi form does not tell a Saudi shop its box numbers differ', () => {
  const html = runReturn({ orders: [sale(1000)], settings: SA });
  assert.ok(!/box numbers on your form will differ/.test(html));
  assert.match(html, /summary to transcribe onto the return you file/, 'every shop needs that caveat');
});
