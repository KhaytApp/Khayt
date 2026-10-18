/**
 * The stock review's fixes: what a delivery costs, what waste really took and
 * what deleting it gives back, receipts that have nowhere to land, a spool's
 * tax against its new price, and a per-gram price that keeps its digits.
 *
 * A spool's `usageHistory` is what LEFT it, so a receipt is a NEGATIVE row.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const PO = require('../lib/purchase-orders.js');
const W = require('../lib/waste-entry.js');
const D = require('../lib/order-deduction.js');
const SE = require('../lib/spool-edit.js');
const R = require('../lib/reorder.js');

const OLD = { id: 'S1', material: 'PLA', weight: 600, spoolWeight: 1000, cost: 80, vatAmount: 10.43, lot: 'A' };

// ── 1. A new lot is priced as what arrived ──────────────────────────────────

test('a part delivery of a new lot costs what the order charged for it, not the old roll', () => {
  const po = { id: 'PO1', itemId: 'S1', qty: 1000, unitPrice: 0.08 };
  const out = PO.receive({ po, item: { ...OLD }, quantity: 250, today: '2026-10-01', lot: 'B', newSpoolId: 'S9' });
  assert.equal(out.ok, true);
  assert.equal(out.newItem.spoolWeight, 250);
  assert.equal(out.newItem.cost, 20, '250 g at 0.08 — what the expense booked, not the old 80');
  assert.equal(out.expense.amount, 20);
  assert.equal(out.newItem.vatAmount, 2.61, 'the tax scales with the price it was charged on');
});

test('with no price on the order, a new lot is priced by its share of the old roll', () => {
  const po = { id: 'PO1', itemId: 'S1', qty: 1000 };
  const out = PO.receive({ po, item: { ...OLD }, quantity: 250, today: 'd', lot: 'B', newSpoolId: 'S9' });
  assert.equal(out.newItem.cost, 20, '80 for 1000 g, so 250 g is 20');
  assert.equal(out.newItem.vatAmount, 2.61);
  assert.equal(out.expense, undefined);
});

test('a roll with no price and no tax gains neither on a split', () => {
  const plain = { id: 'S1', material: 'PLA', weight: 600, spoolWeight: 1000, lot: 'A' };
  const out = PO.receive({ po: { id: 'PO1', qty: 1000 }, item: plain, quantity: 250, today: 'd', lot: 'B' });
  assert.equal('cost' in out.newItem, false);
  assert.equal('vatAmount' in out.newItem, false);
});

test('a later part of the same new lot grows the roll it became, weight AND price', () => {
  const po = { id: 'PO1', itemId: 'S1', qty: 1000, unitPrice: 0.08 };
  const first = PO.receive({ po, item: { ...OLD }, quantity: 250, today: 'd', lot: 'B', newSpoolId: 'S9' });
  const second = PO.receive({ po: first.po, item: { ...OLD }, quantity: 500, today: 'd', lot: 'B',
                              receivedSpools: [first.newItem] });
  assert.equal(second.newItem, undefined, 'topped up, not split again');
  assert.equal(second.item.id, 'S9');
  assert.equal(second.item.weight, 750);
  assert.equal(second.item.spoolWeight, 750);
  assert.equal(second.item.cost, 60, '20 + 500 g at 0.08');
  assert.equal(second.item.vatAmount, 7.83, '2.61 + 5.22: the roll\'s own tax rate on the 40 more');
});

test('a top-up with no price on the order keeps the roll\'s price per gram', () => {
  const po = { id: 'PO1', itemId: 'S1', qty: 1000 };
  const first = PO.receive({ po, item: { ...OLD }, quantity: 250, today: 'd', lot: 'B', newSpoolId: 'S9' });
  const second = PO.receive({ po: first.po, item: { ...OLD }, quantity: 250, today: 'd', lot: 'B',
                              receivedSpools: [first.newItem] });
  assert.equal(second.item.spoolWeight, 500);
  assert.equal(second.item.cost, 40);
});

test('an ordinary top-up of the same lot leaves the roll\'s price alone', () => {
  const out = PO.receive({ po: { id: 'PO1', qty: 1000, unitPrice: 0.08 }, item: { ...OLD },
                           quantity: 250, today: 'd', lot: 'A' });
  assert.equal(out.item.cost, 80);
  assert.equal(out.item.spoolWeight, 1000);
  assert.equal(out.item.weight, 850);
});

test('the sample shop\'s full 1000 g new-lot receipt keeps its figures (PO-sample03 / sp-14)', () => {
  // sp-1: 75 for 1000 g with 9.78 tax, lot GB-2406-17; the order is 1000 g at
  // 0.075 and arrived as lot GB-2408-05. A whole roll at the roll's own price
  // is the same roll's price.
  const sp1 = { id: 'sp-1', material: 'PLA+ 2.0', weight: 247.16, spoolWeight: 1000, cost: 75,
                vatAmount: 9.78, lot: 'GB-2406-17' };
  const po = { id: 'PO-sample03', itemId: 'sp-1', qty: 1000, unitPrice: 0.075 };
  const out = PO.receive({ po, item: sp1, quantity: 1000, today: '2026-09-01', lot: 'GB-2408-05', newSpoolId: 'sp-14' });
  assert.equal(out.newItem.cost, 75);
  assert.equal(out.newItem.vatAmount, 9.78);
  assert.equal(out.newItem.spoolWeight, 1000);
  assert.equal(out.expense.amount, 75);
});

// ── 5. Goods with nowhere to land ───────────────────────────────────────────

test('receiving against a deleted spool is refused, and books nothing', () => {
  const po = { id: 'PO1', itemId: 'gone', qty: 1000, unitPrice: 0.08, receivedSoFar: 0 };
  const out = PO.receive({ po, item: undefined, quantity: 250, today: 'd' });
  assert.deepEqual(out, { ok: false, reason: 'no_item' });
});

test('receiving against a deleted consumable is refused too', () => {
  const po = { id: 'PO2', kind: 'consumable', itemId: 'gone', qty: 10, unitPrice: 3 };
  assert.deepEqual(PO.receive({ po, consumable: null, quantity: 5, today: 'd' }),
                   { ok: false, reason: 'no_item' });
  const ok = PO.receive({ po, consumable: { id: 'c', stock: 1 }, quantity: 5, today: 'd' });
  assert.equal(ok.ok, true);
  assert.equal(ok.consumable.stock, 6);
});

test('both apps say so in words, in every locale', () => {
  const fs = require('fs');
  const path = require('path');
  const dir = path.join(__dirname, '../renderer/locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) require(path.join(dir, f));
  const L = global.KhaytLocales;
  assert.ok(L.en['po.item_gone']);
  assert.ok(L.ar['po.item_gone']);
  assert.notEqual(L.ar['po.item_gone'], L.en['po.item_gone']);
  const wire = fs.readFileSync(path.join(__dirname, '../renderer/wire-events.js'), 'utf8');
  assert.match(wire, /done\.reason === 'no_item' \? t\('po\.item_gone'\)/);
  const mac = fs.readFileSync(path.join(__dirname,
    '../mac/KhaytCore/Sources/KhaytApp/Shop+Stock.swift'), 'utf8');
  assert.match(mac, /done\.reason == "no_item" \? "po\.item_gone"/);
});

// ── 2. Waste records what it took ───────────────────────────────────────────

test('waste bigger than the roll records what the roll gave, and deleting gives back only that', () => {
  const inventory = [{ id: 'S1', material: 'PLA', weight: 50 }];
  const { entry } = W.newEntry({ material: 'PLA', weight: 200, deduct: true },
                               { id: 'w1', today: 'd', inventory });
  assert.equal(entry.weight, 200, 'the log still says what was wasted');
  assert.deepEqual(entry.drawn, [{ spoolId: 'S1', grams: 50 }]);
  assert.equal(inventory[0].weight, 0);
  W.removeEntry([entry], 'w1', { inventory });
  assert.equal(inventory[0].weight, 50, 'not 200 — the roll never held it');
});

test('an empty roll is skipped for the next one of the material', () => {
  const inventory = [
    { id: 'S1', material: 'PLA', weight: 0 },
    { id: 'S2', material: 'PLA', weight: 500 },
  ];
  const { entry } = W.newEntry({ material: 'PLA', weight: 120, deduct: true },
                               { id: 'w1', today: 'd', inventory });
  assert.equal(entry.spoolId, 'S2');
  assert.deepEqual(inventory.map((s) => s.weight), [0, 380]);
  W.removeEntry([entry], 'w1', { inventory });
  assert.deepEqual(inventory.map((s) => s.weight), [0, 500]);
});

test('when every roll of it is empty, the entry takes nothing and gives nothing back', () => {
  const inventory = [{ id: 'S1', material: 'PLA', weight: 0 }];
  const { entry } = W.newEntry({ material: 'PLA', weight: 120, deduct: true },
                               { id: 'w1', today: 'd', inventory });
  assert.deepEqual(entry.drawn, []);
  W.removeEntry([entry], 'w1', { inventory });
  assert.equal(inventory[0].weight, 0);
});

test('an old entry with only spoolId still restores its weight', () => {
  const inventory = [{ id: 'S1', material: 'PLA', weight: 100 }];
  W.removeEntry([{ id: 'old', spoolId: 'S1', weight: 40 }], 'old', { inventory });
  assert.equal(inventory[0].weight, 140);
});

// ── 4. Restoring a draw takes its history line with it ──────────────────────

test('deleting a job\'s waste takes its line out of the spool history, so a recall no longer finds it', () => {
  const inv = [{ id: 'S1', material: 'PLA', weight: 800, lot: 'L1',
                 usageHistory: [{ orderId: 'J1', weightUsed: 120, date: 'earlier' }] }];
  const order = { id: 'J1', parts: [{ filamentId: 'S1', printWeight: 300, qty: 1 }] };
  const out = W.forOrder(order, { material: 'PLA', weight: 120 },
                         { id: 'W1', today: 'd', inventory: inv, settings: {} });
  assert.equal(inv[0].usageHistory.length, 2);
  assert.equal(inv[0].usageHistory[0].lot, 'L1');
  W.removeEntry([out.entry], 'W1', { inventory: inv });
  assert.equal(inv[0].weight, 800);
  assert.equal(inv[0].usageHistory.length, 1, 'only the line the failure wrote is gone');
  assert.equal(inv[0].usageHistory[0].date, 'earlier');
});

test('restoreDrawn without a job leaves history alone; a split draw removes every line it wrote', () => {
  const inv = [{ id: 'S1', weight: 0, usageHistory: [
    { orderId: 'J1', weightUsed: 30 }, { orderId: 'J1', weightUsed: 20 }, { orderId: 'J2', weightUsed: 50 },
    { type: 'received', orderId: 'J1', weightUsed: -50 },
  ] }];
  D.restoreDrawn([{ spoolId: 'S1', grams: 50 }], { inventory: inv });
  assert.equal(inv[0].usageHistory.length, 4);
  D.restoreDrawn([{ spoolId: 'S1', grams: 50 }], { inventory: inv, orderId: 'J1' });
  assert.deepEqual(inv[0].usageHistory.map((h) => h.orderId + ':' + h.weightUsed), ['J2:50', 'J1:-50']);
  assert.equal(inv[0].weight, 100);
});

// ── 7. The tax is held against the NEW price ────────────────────────────────

test('raising a roll\'s price and its tax together keeps the tax', () => {
  const spool = { id: 'S1', material: 'PLA', weight: 1000, cost: 10 };
  SE.applyEdit(spool, { cost: 230, vatAmount: 30 }, { today: 'd' });
  assert.equal(spool.cost, 230);
  assert.equal(spool.vatAmount, 30, 'clamped against the old 10 it stored 10');
});

test('the tax still cannot exceed the price', () => {
  const spool = { id: 'S1', material: 'PLA', weight: 1000, cost: 100 };
  SE.applyEdit(spool, { cost: 20, vatAmount: 30 }, { today: 'd' });
  assert.equal(spool.vatAmount, 20);
});

// ── 9. A per-gram price keeps its digits ────────────────────────────────────

test('a per-gram price is kept to six places', () => {
  assert.equal(R.perGramPriceFor({ material: 'PLA', cost: 19.99, spoolWeight: 1000 }, []).perG, 0.01999);
  const quoted = R.perGramPriceFor({ material: 'PLA' },
    [{ id: 'sup', name: 'S', priceList: [{ material: 'PLA', pricePerKg: 19.99 }] }]);
  assert.equal(quoted.supplierId, 'sup');
  assert.equal(quoted.perG, 0.01999, 'it read 0.020 — a twentieth dearer on every gram ordered');
});
