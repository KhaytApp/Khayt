'use strict';

/**
 * The packing slip, delivery note, work order and account statement are
 * `lib/shop-documents.js`, and both apps print them from there.
 *
 * The bodies were lifted out of the renderer unchanged; these pin what each
 * paper says, and that the desktop's four handlers call the lib rather than
 * keeping a copy of their own (the Mac's copy is the same file, bundled).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

require('../lib/invoice-language.js');
const SD = require('../lib/shop-documents.js');

const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
  .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

function ctx(over = {}) {
  return {
    t: (k) => '[' + k + ']',
    tIn: (l, k) => '{' + l + ':' + k + '}',
    lang: 'en',
    escapeHtml: esc,
    settings: {},
    clients: [{ id: 'C1', name: 'Sara', phone: '0500', email: 's@x.com', addresses: [{ address: 'Olaya' }] }],
    machines: [{ id: 'M1', name: 'X1C' }],
    inventory: [{ id: 'F1', material: 'PETG', printTemp: 240 }],
    docs: [{ name: 'Safety sheet', packWithOrder: true }, { name: 'Setup sheet', packWithOrder: false }],
    shopName: 'Atelier',
    safeBizLogo: '',
    brandMark: '<svg id="mark"></svg>',
    safeCssColor: (v, fb) => (/^#[0-9a-f]{3,8}$/i.test(String(v || '')) ? v : fb),
    jobRef: (o) => String(o.jobNumber || o.id),
    localName: (c) => c.name,
    formatPrintDate: (d) => 'D:' + d,
    today: '2026-11-05',
    localeTag: 'en-GB',
    fmtPrice: (n) => n.toFixed(2) + ' SAR',
    orderRevenueBase: (o) => +o.price || 0,
    orderOwedBase: (o) => (o.paymentStatus === 'paid' ? 0 : Math.max(0, (+o.price || 0) - (+o.paidAmount || 0))),
    orderToBase: (n) => n,
    payStatus: (o) => o.paymentStatus || 'unpaid',
    ...over,
  };
}

const job = {
  id: 'INV-7', clientId: 'C1', project: 'Lamp <b>', date: '2026-10-01', price: 100, paidAmount: 40,
  machineId: 'M1', dueDate: '2026-10-09', notes: 'Wrap well',
  parts: [{ name: 'Shade', qty: 2, printWeight: 10, material: 'PLA', colour: 'Red', filamentId: 'F1', printTime: 1.5 }],
};

test('packing slip: a whole page, escaped, with the parts, quantities and weights', () => {
  const html = SD.packingSlipHtml(job, ctx());
  assert.match(html, /^<!DOCTYPE html>/);
  assert.ok(html.includes('Lamp &lt;b&gt;') || html.includes('Shade'));
  assert.ok(!html.includes('<b>'), 'the project name is escaped');
  assert.ok(html.includes('<td style="text-align:right;">20g</td>'), 'weight is qty × grams');
  assert.ok(html.includes('<strong>Sara</strong>'), 'ships to the linked customer');
  assert.ok(html.includes('[ps.thank_you]'));
});

test('packing slip: right to left for an Arabic shop', () => {
  assert.match(SD.packingSlipHtml(job, ctx({ lang: 'ar' })), /<html lang="ar" dir="rtl">/);
});

test('delivery note: lists only the documents that go in the box', () => {
  const html = SD.deliveryNoteHtml(job, ctx());
  assert.ok(html.includes('Safety sheet'));
  assert.ok(!html.includes('Setup sheet'), 'a setup sheet is not packed');
  assert.ok(html.includes('[doc.delivery_note]'));
  assert.ok(html.includes('<svg id="mark"></svg>'), 'the mark when there is no logo');
});

test('delivery note: the second language title when the shop prints bilingual', () => {
  const html = SD.deliveryNoteHtml(job, ctx({ settings: { invoiceBilingual: 'both', invoiceSecondLang: 'ar' } }));
  assert.ok(html.includes('{ar:doc.delivery_note}'));
});

test('work order: no prices, every document, the machine and the spool settings', () => {
  const html = SD.workOrderHtml(job, ctx());
  assert.ok(!html.includes('100.00'), 'the floor sheet carries no price');
  assert.ok(html.includes('Safety sheet') && html.includes('Setup sheet'));
  assert.ok(html.includes('X1C'));
  assert.ok(html.includes('240°C'));
  assert.ok(html.includes('WO-INV-7'));
  assert.ok(html.includes('D:2026-11-05'), 'dated today, from ctx');
});

test('statement: base-currency figures that reconcile, oldest job first', () => {
  const orders = [
    { id: 'B', clientId: 'C1', date: '2026-10-02', price: 50, paidAmount: 0, creditNotes: [{ amount: 5 }] },
    { id: 'A', clientId: 'C1', date: '2026-09-01', price: 30, paymentStatus: 'paid' },
    { id: 'X', clientId: 'C2', date: '2026-09-01', price: 999 },
  ];
  const f = SD.statementFigures('C1', orders, ctx());
  assert.deepEqual(f.rows.map((r) => r.order.id), ['A', 'B']);
  assert.equal(f.totalCharges, 80);
  assert.equal(f.totalPaid, 30, 'a legacy paid job with no amount counts its price');
  assert.equal(f.totalCredit, 5);
  assert.equal(f.outstanding, 50);
  const html = SD.clientStatementHtml(ctx().clients[0], orders, ctx());
  assert.ok(html.includes('80.00 SAR') && html.includes('50.00 SAR'));
  assert.ok(!html.includes('999'), 'another customer is not on it');
});

test('invoices to export: the customer’s finished work, oldest first', () => {
  const orders = [
    { id: 'B', clientId: 'C1', date: '2026-10-02', status: 'completed' },
    { id: 'Q', clientId: 'C1', date: '2026-08-02', status: 'quote' },
    { id: 'A', clientId: 'C1', date: '2026-09-01', status: 'delivered' },
  ];
  const done = (o) => o.status === 'completed' || o.status === 'delivered';
  assert.deepEqual(SD.invoicesToExport('C1', orders, done).map((o) => o.id), ['A', 'B']);
});

test('the desktop prints these from the lib, not from copies of its own', () => {
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');
  assert.match(read('order-flows.js'), /KhaytShopDocuments\.packingSlipHtml\(/);
  assert.match(read('invoicing.js'), /KhaytShopDocuments\.deliveryNoteHtml\(/);
  assert.match(read('invoicing.js'), /KhaytShopDocuments\.clientStatementHtml\(/);
  assert.match(read('invoicing.js'), /KhaytShopDocuments\.invoicesToExport\(/);
  assert.match(read('app-exports.js'), /KhaytShopDocuments\.workOrderHtml\(/);
  for (const page of ['index.html', 'bedready.html']) {
    assert.ok(read(page).includes('<script src="../lib/shop-documents.js"></script>'), page + ' loads the lib');
  }
});
