/**
 * Every place that names an invoice names it the way the paper does.
 *
 * A plain job's id comes from `settings.invPrefix` and its `invoiceNumber`
 * from the counter's own `invNumPrefix`. The paper prints the id, but the
 * payment QR's reference, a credit note's "reversal of", the ZATCA XML, a
 * payment link and the invoice export read `invoiceNumber || id`. So a shop
 * whose prefix is ATH handed out invoice ATH-2026-0012 with a bank reference
 * of INV-2026-0012, and could not match the transfer to the invoice.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

require('../renderer/format.js');
require('../lib/order-new.js');
require('../lib/invoice-document.js');
globalThis.saveAll = () => {};
globalThis.settings = { invPrefix: 'ATH', invNumPrefix: 'INV', quotePrefix: 'QUO' };
const { invoiceDocNumber } = require('../renderer/invoicing.js');

test('a plain job is named by the id its paper prints', () => {
  const job = { id: 'ATH-2026-0012', status: 'pending', invoiceNum: 'INV-2026-0012', invoiceNumber: 'INV-2026-0012' };
  assert.equal(invoiceDocNumber(job), 'ATH-2026-0012');
  assert.equal(invoiceDocNumber(job), KhaytInvoiceDocument.documentNumber(job, settings));
});

test('a job that began as a quote is named by its invoice number', () => {
  const job = { id: 'QUO-2026-0003', status: 'pending', quoteAcceptedAt: '2026-10-01',
    invoiceNum: 'INV-2026-0013', invoiceNumber: 'INV-2026-0013' };
  assert.equal(invoiceDocNumber(job), 'INV-2026-0013');
});

test('a quote is named by its quote id', () => {
  assert.equal(invoiceDocNumber({ id: 'QUO-2026-0004', status: 'quote' }), 'QUO-2026-0004');
});

test('no desktop file names an invoice by its own rule any more', () => {
  const dir = path.join(__dirname, '..', 'renderer');
  const offenders = [];
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    src.split('\n').forEach((line, i) => {
      if (/\binvoiceNumber\s*\|\|\s*\w+\.id\b/.test(line)) offenders.push(`${f}:${i + 1}`);
    });
  }
  assert.deepEqual(offenders, [], 'use invoiceDocNumber / KhaytInvoiceDocument.documentNumber');
});
