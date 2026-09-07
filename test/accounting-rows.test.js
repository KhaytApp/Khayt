'use strict';
/**
 * What an invoice row SAYS, as opposed to how it is laid out.
 *
 * This module exists because the decisions were in the renderer and a second
 * app calling the CSV formatter directly got a file that looked right and was
 * wrong in four ways at once. These tests are those four ways: each one fails
 * if the mapping is skipped, which is exactly how the bug happened.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
const rows = require('../lib/accounting-rows.js');
const csv = require('../lib/accounting-export.js');

const SETTINGS = { currency: 'SAR', enableVat: true, vatRate: 15 };
const CLIENTS = [{ id: 'c1', name: 'KAUST Prototyping Lab' }];
const BOOK = [
  { id: 'ORD-1', date: '2026-07-02', clientId: 'c1', price: 1150, currency: 'SAR', status: 'delivered' },
  { id: 'Q-1',   date: '2026-07-03', clientId: 'c1', price: 500,  status: 'quote' },
  { id: 'Z-1',   date: '2026-07-04', clientId: 'c1', price: 0,    status: 'delivered' },
];
const map = (o = BOOK, ctx = {}) =>
  rows.ordersToInvoiceRows(o, Object.assign({ settings: SETTINGS, clients: CLIENTS }, ctx));

test('a quote is not an invoice, and neither is an order with no price', () => {
  const out = map();
  assert.deepEqual(out.map((r) => r.id), ['ORD-1'],
    'a quote or a priced-at-nothing order reached the accountant');
});

test('the rate and the pricing mode come from the shop, not from zero', () => {
  const [r] = map();
  assert.equal(r.vatRate, 15, 'the row carried no rate — every VAT cell would be 0.00');
  assert.equal(r.taxMode, 'inclusive');
  // The consequence, stated in the file itself, because that is what is handed
  // over: 1,150 inclusive of 15% is a thousand and a hundred and fifty.
  const line = csv.buildInvoiceCsv(map(), { format: 'generic' }).trim().split('\n')[1];
  assert.match(line, /,1000\.00,150\.00,15,1150\.00,/,
    `the VAT split is wrong in the exported line: ${line}`);
});

test('a customer has a name on the invoice', () => {
  assert.equal(map()[0].clientName, 'KAUST Prototyping Lab');
  // And a walk-in still exports, with the name the order itself carries.
  const walkIn = map([{ id: 'W-1', date: '2026-07-02', price: 100, client: 'Cash', status: 'delivered' }]);
  assert.equal(walkIn[0].clientName, 'Cash');
});

test('without a converter the base columns are empty, not wrong', () => {
  // An empty column is one an accountant asks about. A column silently holding
  // the foreign figure as though it were the shop's own is one nobody asks
  // about and everybody reports.
  const [plain] = map();
  assert.equal(plain.baseCurrency, '');
  assert.equal(plain.baseAmount, undefined);
  const [converted] = map(BOOK, { toBase: (amt) => amt * 3.75 });
  assert.equal(converted.baseCurrency, 'SAR');
  assert.equal(converted.baseAmount, 4312.5);
});

test('the row shape is the one the formatter reads', () => {
  // The join between the two modules, which is where this went wrong: the
  // formatter reads `clientName`, and a mapping that wrote `client` would pass
  // every test above and still export a column of blanks.
  const line = csv.buildInvoiceCsv(map(), { format: 'generic' }).trim().split('\n')[1];
  assert.ok(line.includes('KAUST Prototyping Lab'),
    `the customer did not survive into the CSV: ${line}`);
});
