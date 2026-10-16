'use strict';
/**
 * ⌘D: another of a job, or of a product — and what the copy must NOT carry.
 *
 * The job copy is the input `newOrder` takes, so the last test runs it through
 * `newOrder` and checks the record that comes out: fresh id, a fresh invoice
 * number only for a job, nothing paid, no dates of the original's.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
const N = require('../lib/order-new.js');
const D = require('../lib/record-duplicate.js');

const ORIGINAL = Object.freeze({
  id: 'INV-2026-0042',
  invoiceNum: 'INV-2026-0042',
  invoiceNumber: 'INV-2026-0042',
  status: 'completed',
  date: '2026-03-01',
  timestamp: '2026-03-01T09:00:00.000Z',
  project: 'Lamp shades',
  clientId: 'CLI-7',
  clientRef: 'PO-19',
  currency: 'SAR',
  productId: 'PROD-1',
  notes: 'Matte black, no logo',
  internalNotes: 'Use the 0.6 nozzle',
  invoiceNotes: 'Thanks!',
  price: 240,
  paidAmount: 240,
  paymentStatus: 'paid',
  paymentMethod: 'cash',
  paidAt: '2026-03-04',
  payments: [{ amount: 240, at: '2026-03-04' }],
  deliveredAt: '2026-03-05',
  shippedAt: '2026-03-04',
  dueDate: '2026-03-06',
  printRuns: [{ machineId: 'M1', at: '2026-03-02' }],
  printPhotos: ['a.jpg'],
  actualWeight: 310,
  actualPrintTime: 9.5,
  materialDeducted: true,
  trackingToken: 'abc',
  discountPct: 10,
  shippingCost: 15,
  extraLines: [{ label: 'Etsy', pct: 6.5, amount: 14.2, platformId: 'etsy' }, { label: 'Design', amount: 30 }],
  components: [{ consumableId: 'C1', qtyPerUnit: 2 }, { note: 'no id' }],
  assemblyQty: 3,
  parts: [{
    id: 'PRT-1', name: 'Shade', printWeight: 100, printTime: 3, qty: 2, baseCost: 40,
    filamentId: 'SP-1', material: 'PLA', printFileId: 'PF-9', plate: 1,
    partStatus: 'done', partMachineId: 'M1', startedAt: 'x', completedAt: 'y',
    actualWeight: 105, actualPrintTime: 3.2,
  }],
});

test('a job copy carries the work and the customer', () => {
  const input = D.job(ORIGINAL);
  assert.equal(input.project, 'Lamp shades');
  assert.equal(input.clientId, 'CLI-7');
  assert.equal(input.clientRef, 'PO-19');
  assert.equal(input.currency, 'SAR');
  assert.equal(input.productId, 'PROD-1');
  assert.equal(input.notes, 'Matte black, no logo');
  assert.equal(input.internalNotes, 'Use the 0.6 nozzle');
  assert.equal(input.invoiceNotes, 'Thanks!');
  assert.equal(input.discountPct, 10);
  assert.equal(input.shippingCost, 15);
  assert.equal(input.assemblyQty, 3);
  assert.deepEqual(input.components, [{ consumableId: 'C1', qtyPerUnit: 2 }]);
  assert.equal(input.asQuote, false);
  assert.equal(input.parts.length, 1);
  const part = input.parts[0];
  assert.equal(part.name, 'Shade');
  assert.equal(part.printFileId, 'PF-9');
  assert.equal(part.qty, 2);
});

test('a job copy leaves the original run behind', () => {
  const input = D.job(ORIGINAL);
  for (const key of ['id', 'invoiceNum', 'invoiceNumber', 'status', 'date', 'timestamp', 'price',
    'paidAmount', 'paymentStatus', 'paymentMethod', 'paidAt', 'payments', 'deliveredAt', 'shippedAt',
    'dueDate', 'printRuns', 'printPhotos', 'actualWeight', 'actualPrintTime', 'materialDeducted',
    'trackingToken']) {
    assert.equal(key in input, false, `${key} was copied`);
  }
  for (const key of D.PART_RUN_KEYS) {
    assert.equal(key in input.parts[0], false, `part ${key} was copied`);
  }
  // A percentage line is priced again; a flat one keeps its amount.
  assert.deepEqual(input.extraLines, [{ label: 'Etsy', pct: 6.5, platformId: 'etsy' }, { label: 'Design', amount: 30 }]);
});

test('the original is not touched', () => {
  const before = JSON.stringify(ORIGINAL);
  const input = D.job(ORIGINAL);
  input.parts[0].name = 'changed';
  input.extraLines[0].label = 'changed';
  assert.equal(JSON.stringify(ORIGINAL), before);
});

test('a quote copies as a quote', () => {
  assert.equal(D.job({ ...ORIGINAL, status: 'quote' }).asQuote, true);
  assert.equal(D.job({ ...ORIGINAL, status: 'pending' }).asQuote, false);
});

test('nothing in, a blank job out — never a throw', () => {
  for (const bad of [null, undefined, 7, 'x', []]) {
    const input = D.job(bad);
    assert.deepEqual(input.parts, []);
    assert.equal(input.project, '');
    assert.equal(input.asQuote, false);
  }
});

test('through newOrder: a fresh id and number, nothing paid, no history', () => {
  const settings = { invPrefix: 'INV', invNumNext: 43, invNumYear: 2026, quoteNumNext: 5, quoteNumYear: 2026 };
  const now = new Date('2026-10-16T08:00:00.000Z');
  const ctx = { settings, orders: [ORIGINAL], now, tokens: {} };
  const copy = N.newOrder({ ...D.job(ORIGINAL), margin: 40 }, ctx);
  assert.notEqual(copy.id, ORIGINAL.id);
  assert.equal(copy.id, 'INV-2026-0043');
  assert.equal(copy.invoiceNumber, 'INV-2026-0043');
  assert.equal(copy.status, 'pending');
  assert.equal(copy.paidAmount, 0);
  assert.equal(copy.paymentStatus, 'unpaid');
  assert.equal(copy.deliveredAt, null);
  assert.equal(copy.shippedAt, null);
  assert.equal(copy.printRuns, undefined);
  assert.deepEqual(copy.printPhotos, []);
  assert.equal(copy.actualWeight, null);
  assert.equal(copy.materialDeducted, false);
  assert.equal(copy.date, '2026-10-16');
  assert.equal(copy.clientId, 'CLI-7');
  assert.equal(copy.notes, 'Matte black, no logo');
  assert.equal(copy.internalNotes, 'Use the 0.6 nozzle');
  assert.equal(copy.invoiceNotes, 'Thanks!');
  assert.equal(copy.parts[0].partStatus, 'pending');

  const quote = N.newOrder({ ...D.job({ ...ORIGINAL, status: 'quote' }), margin: 40 },
    { settings, orders: [], now, tokens: {} });
  assert.equal(quote.status, 'quote');
  assert.equal(quote.invoiceNumber, null, 'a quote copy must not consume an invoice number');
  assert.match(quote.id, /^QUO-2026-/);
});

test('newOrder without notes still writes empty notes', () => {
  const settings = {};
  const rec = N.newOrder({ parts: [], margin: 0 }, { settings, orders: [], now: new Date(), tokens: {} });
  assert.equal(rec.notes, '');
  assert.equal(rec.internalNotes, '');
  assert.equal(rec.invoiceNotes, '');
  const odd = N.newOrder({ parts: [], margin: 0, notes: 7 }, { settings, orders: [], now: new Date(), tokens: {} });
  assert.equal(odd.notes, '');
});

const PRODUCT = Object.freeze({
  id: 'PROD-1', rev: 4, updatedAt: '2026-01-01T00:00:00Z', createdAt: '2025-12-01',
  name: 'Desk lamp', nameAr: 'مصباح', name_fr: '', description: 'Warm light',
  defaultMargin: 55, group: 'Lighting', category: 'Home',
  images: [{ id: 'I1', path: 'p.jpg' }], imagePath: 'p.jpg', thumbnail: 'data:x',
  docs: [{ name: 'guide.pdf' }], sku: 'LAMP-01', storefrontHidden: true,
  parts: [{ name: 'Shade', printWeight: 100 }], priceOverride: 90,
});

test('a product copy keeps what it is and drops what is the original’s alone', () => {
  const copy = D.product(PRODUCT, { id: 'PROD-2', today: '2026-10-16', suffix: 'copy' });
  assert.equal(copy.id, 'PROD-2');
  assert.equal(copy.createdAt, '2026-10-16');
  assert.equal(copy.name, 'Desk lamp copy');
  assert.equal(copy.nameAr, 'مصباح copy');
  assert.equal(copy.name_fr, '', 'a blank name stays blank');
  assert.equal(copy.description, 'Warm light');
  assert.equal(copy.defaultMargin, 55);
  assert.equal(copy.priceOverride, 90);
  assert.deepEqual(copy.parts, [{ name: 'Shade', printWeight: 100 }]);
  for (const key of ['rev', 'updatedAt', 'images', 'imagePath', 'thumbnail', 'docs', 'sku', 'storefrontHidden']) {
    assert.equal(key in copy, false, `${key} was copied`);
  }
  copy.parts[0].name = 'changed';
  assert.equal(PRODUCT.parts[0].name, 'Shade');
});

test('a product copy needs an id from the host', () => {
  assert.throws(() => D.product(PRODUCT, {}));
  const bare = D.product(PRODUCT, { id: 'PROD-3' });
  assert.equal(bare.name, 'Desk lamp', 'no suffix, no change');
  assert.equal('createdAt' in bare, false);
});
