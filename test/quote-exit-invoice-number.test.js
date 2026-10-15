/**
 * A quote that leaves the quote column is an order, and its invoice needs a number.
 *
 * Only the Approve button and the LAN path called nextInvoiceNumber(). A quote
 * dragged to Pending, moved from the Job menu, or moved with the batch bar kept
 * no number, so its invoice printed the quote's id (QUO-…). Every one of those
 * paths goes through ensureOrderInvoiceNumber now.
 */
const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

require('../renderer/format.js');
globalThis.saveAll = () => {};
globalThis.settings = {};
const { ensureOrderInvoiceNumber } = require('../renderer/invoicing.js');

const YEAR = new Date().getFullYear();
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

beforeEach(() => {
  globalThis.settings = {
    invNumPrefix: 'INV', invNumNext: 7, invNumYear: YEAR,
    invNumFormat: '{prefix}-{year}-{seq4}',
  };
});

test('a quote moved to any working column takes the next invoice number', () => {
  for (const to of ['pending', 'printing', 'post', 'qc', 'completed', 'on_hold']) {
    settings.invNumNext = 7;
    const order = { id: 'QUO-1', status: 'quote' };
    assert.equal(ensureOrderInvoiceNumber(order, to), true, to);
    assert.equal(order.invoiceNum, `INV-${YEAR}-0007`, to);
    assert.equal(order.invoiceNumber, order.invoiceNum, `${to}: both spellings`);
    assert.equal(settings.invNumNext, 8, `${to}: the counter moves once`);
  }
});

test('a cancelled quote takes no number', () => {
  const order = { id: 'QUO-1', status: 'quote' };
  assert.equal(ensureOrderInvoiceNumber(order, 'cancelled'), false);
  assert.equal(order.invoiceNum, undefined);
  assert.equal(settings.invNumNext, 7);
});

test('a job that is not a quote is left alone', () => {
  const order = { id: 'J1', status: 'pending' };
  assert.equal(ensureOrderInvoiceNumber(order, 'printing'), false);
  assert.equal(order.invoiceNum, undefined);
  assert.equal(settings.invNumNext, 7);
});

test('a number already there is kept, in either spelling, and never doubled', () => {
  const a = { id: 'Q', status: 'quote', invoiceNum: 'INV-X-0001' };
  assert.equal(ensureOrderInvoiceNumber(a, 'pending'), false);
  assert.equal(a.invoiceNumber, 'INV-X-0001');
  const b = { id: 'Q', status: 'quote', invoiceNumber: 'INV-X-0002' };
  assert.equal(ensureOrderInvoiceNumber(b, 'pending'), false);
  assert.equal(b.invoiceNum, 'INV-X-0002');
  assert.equal(settings.invNumNext, 7, 'no number used up');
});

test('every desktop path that moves a job calls it', () => {
  const flows = read('renderer/order-flows.js');
  const upd = flows.slice(flows.indexOf('function updateStatus('), flows.indexOf('function holdOrder('));
  // Both branches: the completion prompt, and the plain move.
  assert.equal((upd.match(/ensureOrderInvoiceNumber\(order, newStatus\)/g) || []).length, 2);
  // The plain move takes it before the Undo snapshot, so an Undo keeps the
  // number and moving the quote out again leaves no gap in the sequence.
  assert.ok(upd.indexOf('ensureOrderInvoiceNumber(order, newStatus);\n  const _undoIdx')
    > 0, 'numbered before the Undo snapshot');
  const logs = read('renderer/logs.js');
  const batch = logs.slice(logs.indexOf('async function batchMoveStatus('), logs.indexOf('async function batchAssignMachine('));
  assert.ok(batch.indexOf('ensureOrderInvoiceNumber(o, status)') < batch.indexOf('o.status = status'),
    'the batch bar numbers before it overwrites the status');
  assert.ok(batch.includes('ensureOrderInvoiceNumber(o, status)'));
});
