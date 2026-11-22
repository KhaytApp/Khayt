const { test } = require('node:test');
const assert = require('node:assert/strict');

const D = require('../lib/product-docs.js');

/**
 * Issue #364 item 4 — "add other files to a part (PDF for assembly instructions,
 * or safety sheets), printed when the part is made and added to the package when
 * shipped".
 *
 * Stored against the PRODUCT rather than the part. A safety sheet describes the
 * thing being made, so filing it against one order's line item would mean
 * re-attaching the same PDF for every order of the same product.
 *
 * Two audiences, and the split between them is the substance of this module: the
 * work order is read by whoever makes it and lists everything; the delivery note
 * goes to the customer and lists only what the shop marked to ship.
 */

const PRODUCTS = [{
  id: 'PROD-1',
  nameEn: 'Bracket',
  docs: [
    { filename: 'a.pdf', originalName: 'Assembly.pdf', packWithOrder: true },
    { filename: 'b.pdf', originalName: 'Safety sheet.pdf', packWithOrder: true },
    { filename: 'c.pdf', originalName: 'Machine setup.pdf', packWithOrder: false },
  ],
}];

test('an order for a product carries that product’s documents', () => {
  const all = D.docsForOrder({ id: 'O1', productId: 'PROD-1' }, PRODUCTS);
  assert.equal(all.length, 3);
  assert.deepEqual(all.map((d) => d.name), ['Assembly.pdf', 'Safety sheet.pdf', 'Machine setup.pdf']);
});

test('the customer gets only what the shop marked to ship', () => {
  // A machine setup sheet is for the floor, not for the box.
  const packable = D.packableDocsForOrder({ id: 'O1', productId: 'PROD-1' }, PRODUCTS);
  assert.deepEqual(packable.map((d) => d.name), ['Assembly.pdf', 'Safety sheet.pdf']);
});

test('a document attached before the ship flag existed still ships', () => {
  // Absent must mean yes. Defaulting it to "no" would silently stop shipping
  // papers that used to go in the box, and nobody would notice for months.
  const products = [{ id: 'P', docs: [{ filename: 'x.pdf', originalName: 'Old.pdf' }] }];
  const packable = D.packableDocsForOrder({ productId: 'P' }, products);
  assert.equal(packable.length, 1);
  assert.equal(packable[0].packWithOrder, true);
});

test('an order with no product has no documents', () => {
  // Most orders are one-off calculator jobs with no catalog product at all.
  assert.deepEqual(D.docsForOrder({ id: 'O1' }, PRODUCTS), []);
  assert.deepEqual(D.docsForOrder({ id: 'O1', productId: null }, PRODUCTS), []);
});

test('a product that has been deleted does not break the document list', () => {
  assert.deepEqual(D.docsForOrder({ productId: 'GONE' }, PRODUCTS), []);
});

test('a product with no documents yields none', () => {
  assert.deepEqual(D.docsForOrder({ productId: 'P' }, [{ id: 'P' }]), []);
  assert.deepEqual(D.docsForOrder({ productId: 'P' }, [{ id: 'P', docs: 'nonsense' }]), []);
});

test('nameless entries are dropped rather than printed blank', () => {
  const products = [{ id: 'P', docs: [{ packWithOrder: true }, null, { filename: 'ok.pdf' }] }];
  const rows = D.docsForOrder({ productId: 'P' }, products);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].name, 'ok.pdf', 'falls back to the stored filename when there is no original name');
});

test('malformed input is safe', () => {
  for (const bad of [null, undefined, {}, 'x']) {
    assert.deepEqual(D.docsForOrder(bad, PRODUCTS), []);
    assert.deepEqual(D.docsForOrder({ productId: 'PROD-1' }, bad), []);
  }
});
