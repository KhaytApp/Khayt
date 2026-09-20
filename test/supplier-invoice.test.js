'use strict';
const test = require('node:test');
const assert = require('node:assert');
const inv = require('../lib/supplier-invoice.js');

// A real order off a shop's shelf: 750 g at 0.085/g is 63.75.
const filament = { id: 'PO-1', qty: 750, unitPrice: 0.085, status: 'received' };

test('the expected amount is quantity times the unit price', () => {
  assert.strictEqual(Math.round(inv.expectedAmount(filament) * 100) / 100, 63.75);
});

test('an order missing either half expects nothing, and cannot disagree', () => {
  // The defect this replaces read `weightOrdered`/`unitCost`, which nothing
  // writes, so expected was always 0 — and because the old code ALSO guarded
  // on `expected > 0`, no mismatch was ever flagged. The guard is right; the
  // fields were wrong. Both are pinned here so neither can come back alone.
  assert.strictEqual(inv.expectedAmount({ qty: 750 }), 0);
  assert.strictEqual(inv.expectedAmount({ unitPrice: 0.085 }), 0);
  assert.strictEqual(inv.discrepancy({ qty: 0, unitPrice: 0 }, 999), false,
    'an order with no expected amount flagged a mismatch, so every hand-drafted PO would');
});

test('a rounding difference is not a discrepancy, and a real one is', () => {
  assert.strictEqual(inv.discrepancy(filament, 63.75), false);
  assert.strictEqual(inv.discrepancy(filament, 64.5), false, 'within one currency unit');
  assert.strictEqual(inv.discrepancy(filament, 65.1), true);
  // The 1000x defect lib/po-audit.js exists for, seen from the invoice side.
  assert.strictEqual(inv.discrepancy(filament, 63750), true);
});

test('recording returns the two fields and nothing else, so a caller merges', () => {
  const out = inv.record(filament, { number: ' INV-9 ', amount: '63.75', date: '2026-09-20T10:00:00Z' });
  assert.deepStrictEqual(Object.keys(out).sort(), ['invoiceDiscrepancy', 'supplierInvoice']);
  assert.strictEqual(out.supplierInvoice.number, 'INV-9', 'the number was not trimmed');
  assert.strictEqual(out.supplierInvoice.amount, 63.75, 'a typed amount stayed a string');
  assert.strictEqual(out.supplierInvoice.date, '2026-09-20', 'a timestamp was stored as a date');
  assert.strictEqual(out.invoiceDiscrepancy, false);
});

test('the state is three words, not a boolean nobody can read', () => {
  assert.strictEqual(inv.state(filament), 'none', 'an unbilled order claimed to match');
  assert.strictEqual(inv.state({ ...filament, supplierInvoice: {}, invoiceDiscrepancy: false }), 'matched');
  assert.strictEqual(inv.state({ ...filament, supplierInvoice: {}, invoiceDiscrepancy: true }), 'mismatch');
});

test('a bill can only be recorded once the goods have arrived', () => {
  assert.strictEqual(inv.canRecord({ status: 'received' }), true);
  assert.strictEqual(inv.canRecord({ status: 'partial' }), true,
    'a part-delivery is still billed, often for the part that arrived');
  assert.strictEqual(inv.canRecord({ status: 'draft' }), false);
  assert.strictEqual(inv.canRecord({ status: 'ordered' }), false);
  assert.strictEqual(inv.canRecord(null), false);
});
