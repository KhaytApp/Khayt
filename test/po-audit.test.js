const { test } = require('node:test');
const assert = require('node:assert/strict');

const A = require('../lib/po-audit.js');

/**
 * The code that priced purchase orders per SPOOL where a per-GRAM rate was
 * expected is fixed (#500), but stores written before that still hold the bad
 * orders — a 750 g reorder of an 85/kg spool asking for 63,750 instead of
 * 63.75. This module finds them.
 *
 * The governing constraint: it must never correct one by itself. A purchase
 * order may already have been sent to a supplier, so an amount silently
 * rewritten is worse than the amount being wrong and visible.
 */

const SPOOL = { id: 'INV1', material: 'PLA', cost: 85, spoolWeight: 1000 };

test('a PO priced per spool is flagged with both figures', () => {
  const po = { id: 'PO1', itemId: 'INV1', qty: 750, unitPrice: 85, status: 'draft' };
  const [hit] = A.findSuspectPurchaseOrders([po], [SPOOL]);
  assert.ok(hit, 'the defective PO must be found');
  assert.equal(hit.currentTotal, 63750);
  assert.equal(hit.suggested, 0.085);
  assert.equal(hit.suggestedTotal, 63.75);
});

test('a correctly priced PO is left alone', () => {
  // The fixed code writes 0.085/g. Flagging it would train the owner to ignore
  // the banner, which is worse than not having one.
  const po = { id: 'PO1', itemId: 'INV1', qty: 750, unitPrice: 0.085, status: 'draft' };
  assert.deepEqual(A.findSuspectPurchaseOrders([po], [SPOOL]), []);
});

test('the threshold separates real prices from whole-spool figures', () => {
  // Filament runs ~0.02–0.5 per gram. The defect produced 50–200. Two orders of
  // magnitude apart, so the exact threshold is not load-bearing — but an
  // expensive-but-real price must still pass.
  const mk = (unitPrice) => [{ id: 'P', itemId: 'INV1', qty: 100, unitPrice, status: 'draft' }];
  for (const ok of [0.02, 0.085, 0.5, 1.2, 4.9]) {
    assert.deepEqual(A.findSuspectPurchaseOrders(mk(ok), [SPOOL]), [], `${ok}/g is a plausible price`);
  }
  for (const bad of [5.1, 45, 85, 200]) {
    assert.equal(A.findSuspectPurchaseOrders(mk(bad), [SPOOL]).length, 1, `${bad}/g is not a filament price`);
  }
});

test('only orders that can still be corrected are flagged', () => {
  // Received and cancelled orders are history. Proposing to rewrite a settled
  // document invites the owner to falsify their own records.
  const mk = (status) => [{ id: 'P', itemId: 'INV1', qty: 750, unitPrice: 85, status }];
  for (const s of ['draft', 'ordered']) {
    assert.equal(A.findSuspectPurchaseOrders(mk(s), [SPOOL]).length, 1, `${s} is still correctable`);
  }
  for (const s of ['received', 'cancelled', 'closed']) {
    assert.deepEqual(A.findSuspectPurchaseOrders(mk(s), [SPOOL]), [], `${s} must not be offered a rewrite`);
  }
});

test('a PO whose item is gone is still flagged, without a suggestion', () => {
  // The owner should know the amount is wrong even when nothing can propose a
  // replacement — silence here would leave a 63,750 order looking deliberate.
  const po = { id: 'PO1', itemId: 'DELETED', qty: 750, unitPrice: 85, status: 'draft' };
  const [hit] = A.findSuspectPurchaseOrders([po], [SPOOL]);
  assert.ok(hit);
  assert.equal(hit.suggested, null);
  assert.equal(hit.suggestedTotal, null);
});

test('correction refuses rather than guesses when there is no cost to work from', () => {
  const po = { id: 'PO1', itemId: 'X', qty: 750, unitPrice: 85, status: 'draft' };
  const entry = A.findSuspectPurchaseOrders([po], [{ id: 'X', cost: 0 }])[0];
  const res = A.applyCorrection(entry);
  assert.equal(res.ok, false);
  assert.equal(po.unitPrice, 85, 'a refused correction must not touch the order');
});

test('correction is derived from costPerKg when there is no spool cost', () => {
  const item = { id: 'K', costPerKg: 120 };
  const po = { id: 'PO1', itemId: 'K', qty: 500, unitPrice: 120, status: 'draft' };
  const entry = A.findSuspectPurchaseOrders([po], [item])[0];
  assert.equal(entry.suggested, 0.12);
  assert.equal(A.applyCorrection(entry).ok, true);
  assert.equal(po.unitPrice, 0.12);
});

test('applying a correction changes only the unit price', () => {
  const po = { id: 'PO1', itemId: 'INV1', qty: 750, unitPrice: 85, status: 'draft', notes: 'keep', supplierId: 'S1' };
  const entry = A.findSuspectPurchaseOrders([po], [SPOOL])[0];
  const res = A.applyCorrection(entry);
  assert.deepEqual({ ok: res.ok, before: res.before, after: res.after }, { ok: true, before: 85, after: 0.085 });
  assert.equal(po.qty, 750, 'quantity is what the shop actually needs — never touched');
  assert.equal(po.status, 'draft');
  assert.equal(po.notes, 'keep');
  assert.equal(po.supplierId, 'S1');
});

test('the worst overstatement is listed first', () => {
  // The largest is the one most likely to have already reached a supplier.
  const pos = [
    { id: 'small', itemId: 'INV1', qty: 100, unitPrice: 85, status: 'draft' },
    { id: 'big', itemId: 'INV1', qty: 5000, unitPrice: 85, status: 'draft' },
  ];
  assert.deepEqual(A.findSuspectPurchaseOrders(pos, [SPOOL]).map((e) => e.po.id), ['big', 'small']);
});

test('empty and malformed input is safe', () => {
  for (const bad of [null, undefined, [], 'nope', {}]) {
    assert.deepEqual(A.findSuspectPurchaseOrders(bad, [SPOOL]), []);
    assert.deepEqual(A.findSuspectPurchaseOrders([{ id: 'P', itemId: 'INV1', qty: 1, unitPrice: 85, status: 'draft' }], bad).length, 1,
      'a missing inventory must still flag, just without a suggestion');
  }
  assert.equal(A.applyCorrection(null).ok, false);
});

/**
 * Consumables reached purchase orders in 3.6.0-beta.16. They are counted in the
 * shop's own unit — boxes, sheets, pcs — so their unit price is the price of one
 * box, and it routinely exceeds the per-gram threshold this audit is built on.
 * Every one of them was flagged as a 1000x pricing error.
 */
const BAGS = { id: 'CNS-BAG', name: 'Mailer bags', cost: 12, unit: 'boxes' };

test('a consumable order priced per box is not a per-gram defect', () => {
  // 5 boxes at 12/box = 60. Correct, ordinary, and above IMPLAUSIBLE_PER_GRAM.
  const po = { id: 'PO1', kind: 'consumable', itemId: 'CNS-BAG', itemName: 'Mailer bags',
    qty: 5, unit: 'boxes', unitPrice: 12, status: 'draft' };
  assert.deepEqual(A.findSuspectPurchaseOrders([po], [SPOOL, BAGS]), [],
    'a box price is not a whole-spool figure in a per-gram field');
});

test('an expensive consumable is not flagged however high its unit price', () => {
  // The threshold is meaningless for consumables: a build plate at 400/pc is a
  // real price, and dividing it by a spool weight would be the actual error.
  for (const unitPrice of [6, 40, 400, 4000]) {
    const po = { id: 'P', kind: 'consumable', itemId: 'CNS-BAG', qty: 1, unitPrice, status: 'draft' };
    assert.deepEqual(A.findSuspectPurchaseOrders([po], [SPOOL, BAGS]), [], `${unitPrice}/unit must pass`);
  }
});

test('a filament order is still caught when consumables sit beside it', () => {
  // The guard must exclude consumables, not disable the audit.
  const pos = [
    { id: 'cons', kind: 'consumable', itemId: 'CNS-BAG', qty: 5, unitPrice: 12, status: 'draft' },
    { id: 'fil', itemId: 'INV1', qty: 750, unitPrice: 85, status: 'draft' },
  ];
  assert.deepEqual(A.findSuspectPurchaseOrders(pos, [SPOOL, BAGS]).map((e) => e.po.id), ['fil']);
});

test('a PO with no kind is treated as filament', () => {
  // Every order written before consumables could be ordered has no `kind`, and
  // those are exactly the stores holding the defect. Absent must not mean exempt.
  const po = { id: 'old', itemId: 'INV1', qty: 750, unitPrice: 85, status: 'draft' };
  assert.equal(A.findSuspectPurchaseOrders([po], [SPOOL]).length, 1);
  assert.equal(A.isFilamentOrder(po), true, 'absent kind reads as filament');
  assert.equal(A.isFilamentOrder({ kind: 'filament' }), true);
  assert.equal(A.isFilamentOrder({ kind: 'consumable' }), false);
});
