'use strict';
/**
 * What a purchase order is, and what receiving one does to the book.
 *
 * Both rules lived in the renderer, where the macOS app cannot reach them, and
 * the receive chain has carried two faults of exactly the shape a shared,
 * tested rule prevents:
 *
 *   - a CONSUMABLE order looked its item up in `inventory`, found nothing,
 *     restocked nothing, and still marked itself received — goods paid for and
 *     silently absent from stock;
 *   - the expense divided by 1000 for a per-KILO rate no version of the app has
 *     ever written, so every filament receipt booked nothing at all.
 *
 * Both are asserted below, from the outside.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const PO = require('../lib/purchase-orders.js');

const spool = (over = {}) => ({ id: 'sp-1', material: 'PLA+', weight: 200,
                                usageHistory: [], ...over });

/* ── Drafting ───────────────────────────────────────────────────────────── */

test('a filament order asks for a spool when nothing says otherwise', () => {
  const po = PO.draft({ item: spool(), ask: {}, id: 'PO-1', today: '2026-09-19' });
  assert.equal(po.qty, 1000);
  assert.equal(po.itemName, 'PLA+', 'a spool is described by what it is made of');
  assert.equal(po.status, 'ordered');
  assert.equal(po.orderedAt, '2026-09-19');
  assert.equal(po.receivedAt, null);
  assert.equal(po.kind, undefined, 'absent kind is what makes an old order read as filament');
});

test('a consumable order asks for one, not a kilo of screws', () => {
  const po = PO.draft({
    item: { id: 'c-1', name: 'Kapton tape', unit: 'roll' },
    ask: { kind: 'consumable' }, id: 'PO-2', today: '2026-09-19',
  });
  assert.equal(po.qty, 1);
  assert.equal(po.kind, 'consumable');
  assert.equal(po.unit, 'roll');
  assert.equal(po.itemName, 'Kapton tape', 'a consumable is named, not described');
});

test("the item's own reorder quantity wins over the default", () => {
  const po = PO.draft({ item: spool({ reorderQty: 2000 }), ask: {}, id: 'PO-3', today: 'T' });
  assert.equal(po.qty, 2000);
});

test('what the caller asked for wins over everything', () => {
  const po = PO.draft({
    item: spool({ reorderQty: 2000, supplierId: 'SUP-old' }),
    ask: { qty: 750, unitPrice: 0.085, supplierId: 'SUP-new', notes: 'rush' },
    id: 'PO-4', today: 'T', supplierName: 'Ignored',
  });
  assert.equal(po.qty, 750);
  assert.equal(po.unitPrice, 0.085);
  assert.equal(po.supplierId, 'SUP-new');
  assert.equal(po.notes, 'rush');
});

test('an order with no price carries no price, rather than zero', () => {
  // `unitPrice: 0` would read as "free" to every reader downstream, including
  // the expense the receive path books.
  assert.equal(PO.draft({ item: spool(), ask: {}, id: 'PO-5', today: 'T' }).unitPrice, undefined);
});

/* ── Receiving ──────────────────────────────────────────────────────────── */

test('receiving filament restocks the spool, books the expense, and logs it', () => {
  const po = { id: 'PO-1', qty: 1000, unitPrice: 0.085 };
  const out = PO.receive({ po, item: spool(), quantity: 1000, notes: 'box',
                           today: '2026-09-19', expenseId: 'EXP-1',
                           expenseLabel: 'PO receive' });
  assert.equal(out.ok, true);
  assert.equal(out.item.weight, 1200);
  assert.equal(out.po.status, 'received');
  assert.equal(out.po.receivedAt, '2026-09-19');
  assert.equal(out.po.receivedSoFar, 1000);

  // 1,000 g at 0.085/g is 85 — NOT 0.085, which is what the /1000 produced.
  assert.equal(out.expense.amount, 85);
  assert.equal(out.expense.category, 'filament');
  assert.equal(out.expense.poId, 'PO-1');
  assert.match(out.expense.note, /PO receive: PO-1 — box/);

  // An arrival is a use of MINUS that much: the history is a list of what
  // left the shelf.
  assert.equal(out.item.usageHistory[0].weightUsed, -1000);
  assert.equal(out.item.usageHistory[0].type, 'received');
});

test('receiving a consumable restocks the CONSUMABLE, not a spool', () => {
  // The fault: this looked its item up in `inventory`, found nothing, and
  // marked the order received anyway.
  const po = { id: 'PO-2', kind: 'consumable', qty: 5, unitPrice: 12 };
  const out = PO.receive({ po, consumable: { id: 'c-1', stock: 1 }, quantity: 5,
                           today: 'T', expenseId: 'EXP-2' });
  assert.equal(out.consumable.stock, 6);
  assert.equal(out.item, undefined, 'no spool was touched');
  assert.equal(out.expense.amount, 60);
  assert.equal(out.expense.category, 'other', 'glue is not filament');
});

test('a part delivery is partial, and the next one completes it', () => {
  const po = { id: 'PO-3', qty: 1000, unitPrice: 0.1 };
  const first = PO.receive({ po, item: spool(), quantity: 400, today: 'T', expenseId: 'E1' });
  assert.equal(first.po.status, 'partial');
  assert.equal(first.po.receivedSoFar, 400);
  assert.equal(first.po.receivedAt, null);
  assert.equal(first.complete, false);

  const second = PO.receive({ po: first.po, item: spool({ weight: 600 }), quantity: 600,
                              today: '2026-09-19', expenseId: 'E2' });
  assert.equal(second.po.status, 'received');
  assert.equal(second.po.receivedSoFar, 1000);
  assert.equal(second.po.receivedAt, '2026-09-19');
});

test('an order with no quantity on it is never completed by arithmetic', () => {
  // Nothing to measure against, so the shop closes it by hand.
  const out = PO.receive({ po: { id: 'PO-4' }, item: spool(), quantity: 50, today: 'T' });
  assert.equal(out.po.status, 'partial');
  assert.equal(out.complete, false);
});

test('a spool cannot hold more than a shop can hold', () => {
  const out = PO.receive({ po: { id: 'PO-5', qty: 1 }, item: spool({ weight: 98_900 }),
                           quantity: 500, today: 'T' });
  assert.equal(out.item.weight, PO.MAX_SPOOL_GRAMS);
});

test("a spool's history does not grow without end", () => {
  const long = Array.from({ length: PO.MAX_USAGE_ROWS + 20 }, (_, i) => ({ type: 'used', i }));
  const out = PO.receive({ po: { id: 'PO-6', qty: 1 }, item: spool({ usageHistory: long }),
                           quantity: 10, today: 'T' });
  assert.equal(out.item.usageHistory.length, PO.MAX_USAGE_ROWS);
  assert.equal(out.item.usageHistory[0].type, 'received', 'newest first');
});

test('an order with no price books no expense, rather than one for nothing', () => {
  const out = PO.receive({ po: { id: 'PO-7', qty: 100 }, item: spool(), quantity: 100,
                           today: 'T', expenseId: 'E' });
  assert.equal(out.expense, undefined);
  assert.equal(out.item.weight, 300, 'and the goods still arrive');
});

test('nothing is mutated — the caller writes what comes back', () => {
  const po = { id: 'PO-8', qty: 100, unitPrice: 1 };
  const item = spool();
  const before = JSON.stringify({ po, item });
  PO.receive({ po, item, quantity: 100, today: 'T', expenseId: 'E' });
  assert.equal(JSON.stringify({ po, item }), before);
});

test('receiving nothing is refused', () => {
  assert.equal(PO.receive({ po: { id: 'P' }, quantity: 0 }).ok, false);
  assert.equal(PO.receive({ po: { id: 'P' }, quantity: -5 }).ok, false);
  assert.equal(PO.receive({ quantity: 5 }).ok, false);
});

/* ── Closing by hand ────────────────────────────────────────────────────── */

test('closing an order by hand says when', () => {
  const closed = PO.close({ id: 'PO-9', status: 'partial' }, '2026-09-19');
  assert.equal(closed.status, 'received');
  assert.equal(closed.receivedAt, '2026-09-19');
});

/* ── What an old order is ───────────────────────────────────────────────── */

test('an order written before consumables existed reads as filament', () => {
  // Absent `kind` MUST read as filament: the receive path restocks a different
  // collection depending on this answer.
  assert.equal(PO.isConsumableOrder({ id: 'PO-old' }), false);
  assert.equal(PO.isConsumableOrder({ id: 'PO-new', kind: 'consumable' }), true);
});
