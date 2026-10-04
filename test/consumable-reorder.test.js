/**
 * Reorder suggestions for consumables.
 *
 * Asked for by a user: running out of glue stops a job the way running out of
 * filament does, but only filament reached the reorder list.
 *
 * The failures worth testing are the ones that read as "the feature is fine"
 * rather than as a bug:
 *
 *   UNIT DRIFT     a count of boxes rendered, or ordered, as grams
 *   SILENT NEVER   an item that can never be called low, so it never appears
 *   INVENTED USE   a rate built from orders that never actually deducted, which
 *                  inflates every quantity derived from it
 *   CROSS-TALK     a consumable PO suppressing the filament PO for an empty spool
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  isLow, consumptionByConsumable, consumableSuggestions,
  consumableReorderText, consumablesNeedingDraftPo, qtyLabel,
} = require('../lib/consumable-reorder.js');

const DAY = 86400000;
const NOW = Date.parse('2026-08-09T12:00:00Z');
const daysAgo = (n) => new Date(NOW - n * DAY).toISOString();

const c = (over) => Object.assign({ id: 'C1', name: 'Glue', stock: 10, unit: 'pcs' }, over);
/** A completed order that DID run its deductions, unless told otherwise. */
const order = (over) => Object.assign(
  { completedAt: daysAgo(5), materialDeducted: true, packagingDeducted: true }, over);

// ───────────────────────────────────────────────────────────── what is low

test('an empty shelf is low even with no minimum set', () => {
  // Most consumables never get a minStock. The table's rule required one, so
  // those items could never be low — and an item that is never low is an item
  // the reorder list will never mention, however empty it is.
  assert.equal(isLow(c({ stock: 0, minStock: undefined })), true);
  assert.equal(isLow(c({ stock: 0, minStock: 0 })), true);
});

test('a threshold the shop set is honoured', () => {
  assert.equal(isLow(c({ stock: 3, minStock: 5 })), true);
  assert.equal(isLow(c({ stock: 5, minStock: 5 })), true, 'at the threshold is low, not below it');
  assert.equal(isLow(c({ stock: 6, minStock: 5 })), false);
});

test('a stocked item with no minimum is not low', () => {
  // The other half of the old contradiction: this must NOT be low, or every
  // consumable in the shop lands on the reorder list at once.
  assert.equal(isLow(c({ stock: 10, minStock: undefined })), false);
  assert.equal(isLow(c({ stock: 10, minStock: null })), false);
  assert.equal(isLow(c({ stock: 10, minStock: '' })), false);
});

test('junk in, no throw out', () => {
  for (const bad of [null, undefined, {}, { stock: 'lots' }, { stock: NaN }]) {
    assert.doesNotThrow(() => isLow(bad), JSON.stringify(bad));
  }
  assert.deepEqual(consumableSuggestions(null, null), []);
  assert.deepEqual(consumptionByConsumable('nope', 42), {});
  assert.equal(consumableReorderText(null), '');
});

// ──────────────────────────────────────────────────────── measuring the use

test('hourly usage is counted from print time', () => {
  const items = [c({ id: 'IPA', usagePerHour: 2 })];
  const orders = [order({ printTime: 10 }), order({ printTime: 5, completedAt: daysAgo(9) })];
  const r = consumptionByConsumable(items, orders, { now: NOW, windowDays: 30 });
  assert.equal(Math.round(r.IPA * 30), 30, '2/h over 15 h should be 30 units in the window');
});

test('packaging is one per order, not one per hour', () => {
  const items = [c({ id: 'BAG', isPackaging: true })];
  const orders = [order({ printTime: 40 }), order({ printTime: 1 })];
  const r = consumptionByConsumable(items, orders, { now: NOW, windowDays: 30 });
  assert.equal(Math.round(r.BAG * 30), 2, 'packaging scaled with print hours');
});

test('BOM components multiply by the assembly quantity', () => {
  const items = [c({ id: 'SCREW' })];
  const orders = [order({ assemblyQty: 4, components: [{ consumableId: 'SCREW', qtyPerUnit: 3 }] })];
  const r = consumptionByConsumable(items, orders, { now: NOW, windowDays: 30 });
  assert.equal(Math.round(r.SCREW * 30), 12);
});

test('an order that never deducted contributes nothing', () => {
  // The deduction paths guard on these flags, so an order completed before a
  // path existed never touched stock. Counting it would invent usage that never
  // happened and inflate every quantity derived from the rate.
  const items = [c({ id: 'IPA', usagePerHour: 2 }), c({ id: 'BAG', isPackaging: true })];
  const orders = [order({ printTime: 10, materialDeducted: false, packagingDeducted: false })];
  assert.deepEqual(consumptionByConsumable(items, orders, { now: NOW, windowDays: 30 }), {});
});

test('usage outside the window is not counted', () => {
  const items = [c({ id: 'IPA', usagePerHour: 2 })];
  const old = [order({ printTime: 10, completedAt: daysAgo(60) })];
  const future = [order({ printTime: 10, completedAt: new Date(NOW + DAY).toISOString() })];
  assert.deepEqual(consumptionByConsumable(items, old, { now: NOW, windowDays: 30 }), {});
  assert.deepEqual(consumptionByConsumable(items, future, { now: NOW, windowDays: 30 }), {});
});

test('usage against an unknown consumable is dropped, not credited to someone', () => {
  const items = [c({ id: 'SCREW' })];
  const orders = [order({ components: [{ consumableId: 'DELETED', qtyPerUnit: 5 }] })];
  assert.deepEqual(consumptionByConsumable(items, orders, { now: NOW, windowDays: 30 }), {});
});

// ─────────────────────────────────────────────────────────── the suggestion

test('a well-stocked, slow-moving item is left off the list', () => {
  const items = [c({ id: 'IPA', stock: 500, minStock: 5, usagePerHour: 1 })];
  const orders = [order({ printTime: 2 })];
  assert.deepEqual(consumableSuggestions(items, orders, { now: NOW }), []);
});

test('an item forecast to run out inside the lead time is surfaced before it is low', () => {
  // The whole point of a forecast: 20 units at 2/day is 10 days, inside a
  // 14-day lead time, and it is not "low" by any threshold yet.
  const items = [c({ id: 'IPA', stock: 20, minStock: 1, usagePerHour: 6 })];
  const orders = [order({ printTime: 10 })];       // 60 units / 30 days = 2/day
  const [s] = consumableSuggestions(items, orders, { now: NOW, leadDays: 14, targetDays: 45 });
  assert.ok(s, 'an item due to empty inside the lead time was not surfaced');
  assert.equal(s.low, false, 'surfaced as low rather than as a forecast');
  assert.equal(s.daysLeft, 10);
  assert.equal(s.suggestQty, 70, '45 days at 2/day is 90, less the 20 on hand');
});

test('quantities carry the item\'s own unit and never a gram', () => {
  const items = [c({ id: 'BAG', stock: 0, unit: 'boxes' })];
  const [s] = consumableSuggestions(items, [], { now: NOW });
  assert.equal(s.unit, 'boxes');
  assert.ok(!('suggestG' in s), 'a gram-named field on a count of boxes');
  const text = consumableReorderText([{ label: 'Bags', suggestQty: 4, unit: 'boxes' }]);
  assert.match(text, /4 boxes/);
  assert.doesNotMatch(text, /\bg\b/, 'a count was rendered as grams');
});

test('with no measurable usage, the suggestion is the shop\'s own minimum', () => {
  // Nothing else is defensible. Guessing a horizon for an item whose rate is
  // unknown would put an invented number on a supplier's order form.
  const items = [c({ id: 'X', stock: 2, minStock: 10 })];
  const [s] = consumableSuggestions(items, [], { now: NOW });
  assert.equal(s.perDay, 0);
  assert.equal(s.suggestQty, 8);
});

test('with neither usage nor a minimum, it says restock rather than a number', () => {
  const items = [c({ id: 'X', stock: 0 })];
  const [s] = consumableSuggestions(items, [], { now: NOW });
  assert.equal(s.low, true);
  assert.equal(s.suggestQty, 0, 'a quantity was invented for an item with nothing to derive one from');
  assert.match(consumableReorderText([s]), /restock/);
});

test('the most urgent item is first', () => {
  const items = [
    c({ id: 'SLOW', stock: 100, minStock: 1, usagePerHour: 1 }),
    c({ id: 'GONE', stock: 0 }),
    c({ id: 'SOON', stock: 10, minStock: 1, usagePerHour: 6 }),
  ];
  const orders = [order({ printTime: 10 })];
  const ids = consumableSuggestions(items, orders, { now: NOW }).map((s) => s.id);
  assert.equal(ids[0], 'GONE', `expected the empty item first, got ${ids}`);
  assert.ok(ids.indexOf('SOON') < ids.indexOf('SLOW') || ids.indexOf('SLOW') === -1);
});

test('a stock figure is never negative, however the store was written', () => {
  const [s] = consumableSuggestions([c({ id: 'X', stock: -5 })], [], { now: NOW });
  assert.equal(s.stock, 0);
});

// ──────────────────────────────────────────────────────────── the draft POs

test('a consumable PO cannot suppress a filament PO for the same id', () => {
  // Both ids come from the same uid(), and a PO written before this feature
  // carries no `kind`. If the match ignored kind, an open consumable order would
  // silence the reorder for a genuinely empty spool — silently, and in the
  // direction that stops production.
  const sug = [{ item: { id: 'SHARED' }, suggestQty: 5 }];
  const filamentPo = [{ itemId: 'SHARED', status: 'ordered' }];               // no kind = filament
  assert.equal(consumablesNeedingDraftPo(sug, filamentPo).length, 1,
    'a filament PO suppressed the consumable one');
  const consumablePo = [{ itemId: 'SHARED', status: 'ordered', kind: 'consumable' }];
  assert.equal(consumablesNeedingDraftPo(sug, consumablePo).length, 0,
    'a duplicate consumable PO would be drafted on every boot');
});

test('a closed PO does not block a new one', () => {
  const sug = [{ item: { id: 'C1' }, suggestQty: 5 }];
  for (const status of ['received', 'cancelled']) {
    assert.equal(consumablesNeedingDraftPo(sug, [{ itemId: 'C1', status, kind: 'consumable' }]).length, 1, status);
  }
});

test('only items with a real quantity become draft orders', () => {
  // "restock" is not something a supplier can price.
  const sug = [{ item: { id: 'A' }, suggestQty: 0, low: true }, { item: { id: 'B' }, suggestQty: 3 }];
  assert.deepEqual(consumablesNeedingDraftPo(sug, []).map((s) => s.item.id), ['B']);
});

test('qtyLabel omits a unit that was never set', () => {
  assert.equal(qtyLabel(4, 'pcs'), '4 pcs');
  assert.equal(qtyLabel(4, ''), '4');
  assert.equal(qtyLabel(4, null), '4');
  assert.equal(qtyLabel(null, 'pcs'), '');
});

test('a part\'s own consumables count as usage', () => {
  const { consumptionByConsumable: rate } = require('../lib/consumable-reorder.js');
  const rows = [c({ id: 'mag' })];
  const done = order({ materialDeducted: true, parts: [{ qty: 3, consumables: [{ consumableId: 'mag', qty: 2 }] }] });
  const r = rate(rows, [done], { now: NOW, windowDays: 30 });
  assert.ok(Math.abs(r.mag - 6 / 30) < 1e-9, JSON.stringify(r));
});
