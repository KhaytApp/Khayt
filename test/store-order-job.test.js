/**
 * Store orders become real jobs: `lib/store-order-job.js` and the one matching
 * rule in `lib/shelf-sale.js` (`matcher`), through the webhook rule both LAN
 * servers run (`lib/storefront-webhook.js record`).
 *
 * The rule: SKU first (the product's own and its variants'), then the exact
 * normalised name, else unmatched — never a guess.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/print-rates.js');
require('../lib/calculator-cost.js');
const S = require('../lib/shelf-sale.js');
const J = require('../lib/store-order-job.js');
const W = require('../lib/storefront-webhook.js');
const { committedByItem } = require('../lib/reorder.js');

const CTX = { id: 'salla-9-zz', day: '2026-11-04', at: '2026-11-04T08:00:00.000Z' };

const hood = {
  id: 'PRD-HOOD', nameEn: 'Falcon hood', sku: 'FH-01',
  variants: [{ sku: 'FH-01-RED' }, { sku: 'FH-01-BLK' }],
  parts: [
    { name: 'Shell', qty: 1, printWeight: 40, printTime: 2, filamentId: 'SP-1', spoolCost: 100, spoolWeight: 1000, printFileId: 'PF-1' },
    { name: 'Strap', qty: 2, printWeight: 5, printTime: 0.5, filamentId: 'SP-2', spoolCost: 100, spoolWeight: 1000 },
  ],
  components: [{ consumableId: 'C-MAG', qtyPerUnit: 2 }],
};
const dragon = {
  id: 'PRD-DRAGON', nameEn: 'Flexi Dragon', sku: 'FD-01',
  parts: [{ name: 'Dragon', qty: 1, printWeight: 30, printTime: 3, filamentId: 'SP-1', spoolCost: 100, spoolWeight: 1000 }],
};
const book = (stock = {}) => ({
  printLog: [],
  products: [hood, dragon],
  inventory: [{ id: 'SP-1', material: 'PLA', weight: 1000 }, { id: 'SP-2', material: 'PETG', weight: 1000 }],
  consumables: [{ id: 'C-MAG', name: 'Magnet', cost: 0.5 }],
  settings: { currency: 'SAR', storefront: { stockQty: stock } },
});
const salla = (ref, items) => ({
  data: { reference_id: ref, customer: { name: 'Nora' }, amounts: { total: { amount: 200 } }, items },
});

test('a SKU is matched before the name, and a variant SKU names its product', () => {
  const m = S.matcher([hood, dragon]);
  // The name says dragon; the SKU says hood. The SKU wins.
  assert.deepEqual(m.place({ name: 'Flexi Dragon', sku: 'FH-01' }), { productId: 'PRD-HOOD', by: 'sku' });
  assert.deepEqual(m.place({ name: 'whatever', sku: 'fh-01-red ' }), { productId: 'PRD-HOOD', by: 'sku' },
    'a variant SKU, case and spaces round it aside');
  assert.deepEqual(m.place({ name: 'Flexi  dragon', sku: 'NOPE' }), { productId: 'PRD-DRAGON', by: 'name' },
    'an unknown SKU falls back to the exact normalised name');
  assert.equal(m.place({ name: 'Flexi Drag', sku: '' }), null, 'a near name is not a match');
  assert.equal(m('Flexi Dragon'), 'PRD-DRAGON', 'the old call shape still answers an id');
});

test('a SKU two products claim names neither, and the line falls to its name', () => {
  const twin = { id: 'PRD-TWIN', nameEn: 'Twin', sku: 'FD-01' };
  const m = S.matcher([dragon, twin]);
  assert.equal(m.place({ name: 'Something', sku: 'FD-01' }), null);
  assert.deepEqual(m.place({ name: 'Twin', sku: 'FD-01' }), { productId: 'PRD-TWIN', by: 'name' });
});

test('the cloud queue reads a line\'s SKU too, and says how each line matched', () => {
  const r = S.readLines(S.structuredLines([
    { name: 'Hood (red)', qty: 1, sku: 'FH-01-RED' },
    { name: 'Flexi Dragon', qty: 1 },
    { name: 'Mystery', qty: 1 },
  ]), { products: [hood, dragon], stock: {} });
  assert.deepEqual(r.lines.map((l) => [l.productId, l.matchedBy]),
    [['PRD-HOOD', 'sku'], ['PRD-DRAGON', 'name'], [null, null]]);
  assert.equal(r.unmatched, 1);
});

test('a Salla order for a product becomes a job with the product\'s parts, sized and costed', () => {
  const r = W.record('salla', salla('S-1', [{ name: 'Hood', sku: 'FH-01', quantity: 3 }]), book(), CTX);
  const o = r.order;
  assert.equal(o.productId, 'PRD-HOOD');
  assert.equal(o.price, 200, 'the price is what the customer paid, untouched');
  assert.deepEqual(o.parts.map((p) => [p.id, p.name, p.qty, p.filamentId, p.printFileId || null]), [
    ['salla-9-zz-L1-P1', 'Shell', 3, 'SP-1', 'PF-1'],
    ['salla-9-zz-L1-P2', 'Strap', 6, 'SP-2', null],
  ], 'per-piece part counts times the line quantity, model link kept');
  assert.deepEqual(o.parts.map((p) => p.material), ['PLA', 'PETG'], 'material from the spool it names');
  // 40 g at 0.1/g = 4 per shell, before the failure allowance and the rest.
  assert.ok(o.parts[0].baseCost >= 12, `a line total, not one piece: ${o.parts[0].baseCost}`);
  assert.equal(o.material, 'PLA, PETG');
  assert.equal(o.printTime, 2.5);
  assert.deepEqual(o.components, [{ consumableId: 'C-MAG', qtyPerUnit: 2 }]);
  assert.equal(o.assemblyQty, 3, 'a set of magnets per hood');
  assert.equal(o.componentsCost, 3, '2 magnets × 0.5 × 3 hoods');
  assert.deepEqual(o.storeLines, [{ name: 'Hood', qty: 3, productId: 'PRD-HOOD', matchedBy: 'sku', sku: 'FH-01' }]);
  assert.doesNotMatch(o.notes, /Not matched/);
});

test('the job reserves its filament the way every open job does', () => {
  const r = W.record('salla', salla('S-2', [{ name: 'Flexi Dragon', quantity: 2 }]), book(), CTX);
  const reserved = committedByItem(r.store.printLog, { partGrams: (p) => (+p.printWeight || 0) * (+p.qty || 1) });
  assert.equal(reserved['SP-1'], 60);
});

test('the shelf covers part of a line: the job prints only the rest', () => {
  const r = W.record('salla', salla('S-3', [{ name: 'Flexi Dragon', quantity: 5 }]), book({ 'PRD-DRAGON': 3 }), CTX);
  assert.equal(r.order.status, 'pending');
  assert.equal(r.order.parts[0].qty, 2);
  assert.equal(r.store.settings.storefront.stockQty['PRD-DRAGON'], 0);
});

test('the shelf covers it all: finished from stock, the parts kept as what it cost', () => {
  const r = W.record('salla', salla('S-4', [{ name: 'Flexi Dragon', quantity: 2 }]), book({ 'PRD-DRAGON': 9 }), CTX);
  assert.equal(r.order.status, 'completed');
  assert.equal(r.order.fromStock, true);
  assert.equal(r.order.parts[0].qty, 2);
});

test('a basket of two products is neither of them; an unmatched line is kept and noted', () => {
  const r = W.record('zid', { order: { id: 77, customer: { name: 'Sara' }, order_total: 90, items: [
    { name: 'Flexi Dragon', quantity: 1 },
    { name: 'Hood', sku: 'FH-01-BLK', quantity: 1 },
    { name: 'Gift wrap', sku: 'GW', quantity: 1 },
  ] } }, book(), { ...CTX, id: 'zid-1' });
  const o = r.order;
  assert.equal(o.productId, undefined, 'no single product, so none is stamped');
  assert.equal(o.parts.length, 3);
  assert.deepEqual(o.storeLines.map((l) => [l.productId, l.matchedBy]),
    [['PRD-DRAGON', 'name'], ['PRD-HOOD', 'sku'], [null, null]]);
  assert.match(o.notes, /Not matched to a product: Gift wrap × 1 \(SKU GW\)/);
});

test('the shop picks the product for an unmatched line later', () => {
  const r = W.record('salla', salla('S-5', [{ name: 'Custom hood', quantity: 2 }]), book(), CTX);
  assert.equal(r.order.parts, undefined);
  assert.deepEqual(J.unmatched(r.order).map((u) => u.index), [0]);
  const placed = J.assignLine(r.order, 0, hood, r.store);
  assert.equal(placed.storeLines[0].productId, 'PRD-HOOD');
  assert.equal(placed.storeLines[0].matchedBy, 'shop');
  assert.deepEqual(placed.parts.map((p) => p.qty), [2, 4]);
  assert.equal(placed.productId, 'PRD-HOOD');
  assert.equal(placed.assemblyQty, 2);
  assert.doesNotMatch(placed.notes, /Not matched/, 'the note goes once the line is placed');
  assert.match(placed.notes, /S-5/, 'the rest of the notes stay');
  assert.deepEqual(J.unmatched(placed), []);
  assert.equal(J.assignLine(placed, 0, hood, r.store), null, 'a placed line is not placed twice');
  assert.equal(J.assignLine(placed, 5, hood, r.store), null);
});

test('an order with no basket at all is recorded as before', () => {
  const r = W.record('salla', { data: { amounts: { total: { amount: 5 } } } }, book(), CTX);
  assert.equal('storeLines' in r.order, false);
  assert.equal('parts' in r.order, false);
});

test('placing a cloud-queue line replaces its bare stand-in part rather than printing beside it', () => {
  const reading = S.readLines(S.structuredLines([{ name: 'Custom hood', qty: 1 }]), { products: [hood], stock: {} });
  const { storeLines } = J.linesOf(reading);
  const order = { id: 'INV-1', notes: J.unmatchedNote(storeLines[0]), storeLines,
                  parts: [{ id: 'PRT-X', name: 'Custom hood', qty: 1, printWeight: 0 }] };
  const placed = J.assignLine(order, 0, hood, book());
  assert.deepEqual(placed.parts.map((p) => p.name), ['Shell', 'Strap']);
  assert.equal(placed.notes, '');
});

test('a store order is priced at the money that moved, not at cost plus margin', () => {
  const lines = S.structuredLines([
    { name: 'Hood', sku: 'FH-01', qty: 2, unitPrice: 45 },
    { name: 'Flexi Dragon', qty: 1, unitPrice: 30 },
  ]);
  const reading = S.readLines(lines, { products: [hood, dragon], stock: {} });
  assert.equal(J.orderPrice(reading, {}, { products: [hood, dragon], settings: {} }), 120,
    '2 × 45 + 30, what the customer paid');
  // No line carried a price: the order's own total, when it has one.
  const bare = S.readLines(S.structuredLines([{ name: 'Hood', qty: 1 }]), { products: [hood], stock: {} });
  assert.equal(J.orderPrice(bare, { paidTotal: 99.5 }, { products: [hood] }), 99.5);
  // Nothing came with the order: null, and the caller costs the job instead.
  assert.equal(J.orderPrice(bare, {}, { products: [hood] }), null);
});

test('a line price is the book\'s price as it stands, whatever the tax mode (the Mac queue\'s rule)', () => {
  require('../lib/tax.js');
  require('../lib/order-money.js');
  const salesTax = { currency: 'USD', tax: { name: 'Sales Tax', mode: 'exclusive',
    rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] } };
  const reading = S.readLines(S.structuredLines([{ name: 'Hood', qty: 2, unitPrice: 50 }]),
    { products: [hood], stock: {} });
  assert.equal(J.orderPrice(reading, {}, { products: [hood], settings: salesTax }), 100,
    'pre-tax on a tax-on-top shop: the tax is added on the invoice, not baked into price');
});

test('a webhook order keeps the platform\'s total as its price, parts or not, in any tax mode', () => {
  const b = Object.assign(book(), { settings: { currency: 'SAR', enableVat: true, vatRate: 15, storefront: { stockQty: {} } } });
  const r = W.record('salla', salla('S-9', [{ name: 'Hood', sku: 'FH-01', quantity: 3, price: { amount: 10 } }]), b, CTX);
  assert.equal(r.order.price, 200, 'the total Salla says was paid, not cost plus margin and not a line sum');
  assert.ok(r.order.parts.length > 0);
});
