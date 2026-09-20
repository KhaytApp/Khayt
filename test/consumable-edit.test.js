'use strict';
/**
 * The consumable record, and what an edit to one means.
 *
 * The cases here are the ones the renderer's inline save handler answered by
 * accident and that a second host would otherwise answer differently: a
 * negative count, a blank name, a partial edit, and the two spellings of
 * "no category".
 */
const test = require('node:test');
const assert = require('node:assert');

const { newConsumable, applyEdit, FIELDS } = require('../lib/consumable-edit.js');
const { isLow } = require('../lib/consumable-reorder.js');
const CC = require('../lib/consumable-categories.js');

test('a consumable needs a name, and nothing else', () => {
  assert.deepEqual(newConsumable({ name: '   ' }, { id: 'CNS1' }), { refused: 'name' });
  assert.deepEqual(newConsumable({}, { id: 'CNS1' }), { refused: 'name' });

  const { consumable } = newConsumable({ name: '  Kapton tape  ' }, { id: 'CNS1' });
  assert.equal(consumable.name, 'Kapton tape', 'the name is trimmed');
  assert.equal(consumable.id, 'CNS1');
  assert.equal(consumable.stock, 0);
  assert.equal(consumable.cost, 0);
  assert.equal(consumable.minStock, 0);
  assert.equal(consumable.usagePerHour, 0);
  assert.equal(consumable.isPackaging, false);
  assert.equal(consumable.unit, '');
  assert.ok(!('category' in consumable), 'no category is absent, not empty string');
});

test('counts, prices and thresholds can never go negative', () => {
  const { consumable } = newConsumable(
    { name: 'IPA', stock: -5, cost: -2, minStock: -1, usagePerHour: -0.5 }, { id: 'C' });
  assert.equal(consumable.stock, 0);
  assert.equal(consumable.cost, 0);
  assert.equal(consumable.minStock, 0);
  assert.equal(consumable.usagePerHour, 0);
});

test('nonsense in a number field is zero, not NaN', () => {
  // NaN would survive into the book and make every comparison downstream false,
  // so an item would silently never be low.
  const { consumable } = newConsumable({ name: 'Gloves', stock: 'lots' }, { id: 'C' });
  assert.equal(consumable.stock, 0);
  assert.equal(isLow(consumable), true, 'empty is low whatever the threshold');
});

test('a new consumable with no stock is already low', () => {
  // Deliberate: writing down a thing you have just run out of is exactly when
  // a shop adds one, and consumable-reorder treats stock <= 0 as low.
  const { consumable } = newConsumable({ name: 'Bubble wrap' }, { id: 'C' });
  assert.equal(isLow(consumable), true);
});

test('an edit touches only the fields it is handed', () => {
  const c = {
    id: 'C', name: 'Mailing bags', stock: 6, unit: 'each', cost: 12,
    minStock: 10, usagePerHour: 0, isPackaging: true, category: 'Packaging',
    // A field neither app knows about. It must survive an edit.
    supplierSku: 'MB-250350',
  };
  applyEdit(c, { stock: 42 });
  assert.equal(c.stock, 42);
  assert.equal(c.name, 'Mailing bags', 'name untouched');
  assert.equal(c.category, 'Packaging', 'category untouched');
  assert.equal(c.isPackaging, true, 'the boolean is untouched, not reset to false');
  assert.equal(c.supplierSku, 'MB-250350', 'a field this rule does not own survives');
});

test('an edit cannot blank the name', () => {
  const c = { id: 'C', name: 'IPA', stock: 1 };
  assert.deepEqual(applyEdit(c, { name: '  ' }), { refused: 'name' });
  assert.equal(c.name, 'IPA', 'and the record is left as it was');
});

test('clearing a category writes absent, never an empty string', () => {
  // consumable-categories folds '' and undefined into one bucket already; if
  // both spellings reached the book the grouping would still be right, but the
  // record would carry a key that means nothing.
  const c = { id: 'C', name: 'Kapton tape', category: 'Spares' };
  applyEdit(c, { category: '   ' });
  assert.equal(c.category, undefined);
  assert.equal(CC.categoryOf(c), CC.UNCATEGORISED);
});

test('usagePerHour 0 is stored, because 0 means deliberately off', () => {
  const c = { id: 'C', name: 'IPA', usagePerHour: 2.5 };
  applyEdit(c, { usagePerHour: 0 });
  assert.equal(c.usagePerHour, 0, 'not dropped — "never set" and "switched off" differ');
});

test('the unit is free text, and is not forced into the spool vocabulary', () => {
  // A spool's unit decides arithmetic and is a closed list. A consumable's is
  // only ever printed beside its own number, and "roll" is most of that shelf.
  for (const unit of ['roll', 'sheet', 'bottle', 'each', 'L']) {
    const { consumable } = newConsumable({ name: 'x', unit }, { id: 'C' });
    assert.equal(consumable.unit, unit);
  }
});

test('a category is matched case- and space-insensitively by the grouping', () => {
  // The editor stores what was typed; consumable-categories folds the spelling.
  // This pins that the two modules agree, because the form offers suggestions
  // from one and files under the other.
  const a = newConsumable({ name: 'a', category: 'Screws' }, { id: 'A' }).consumable;
  const b = newConsumable({ name: 'b', category: '  screws ' }, { id: 'B' }).consumable;
  assert.equal(b.category, 'screws', 'stored as typed, minus the padding');
  const cats = CC.categories([a, b]);
  assert.equal(cats.length, 1, 'one shelf, not two spellings of one');
  assert.equal(cats[0].count, 2);
});

test('FIELDS is the list the form must be read against', () => {
  // A field added to a form and not to this list is silently dropped, which is
  // the failure this list exists to make findable.
  assert.deepEqual(FIELDS, ['name', 'stock', 'unit', 'cost', 'minStock',
                            'usagePerHour', 'category', 'isPackaging']);
});
