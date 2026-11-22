'use strict';

const test = require('node:test');
const assert = require('node:assert');
const U = require('../lib/inventory-units.js');
const DEDUCTION = require('../lib/order-deduction.js');

// ── Absent is grams, and no existing shelf may move ────────────────────────

test('an item with no unit is grams, because every item in every book is', () => {
  assert.equal(U.unitOf({}), 'g');
  assert.equal(U.unitOf(null), 'g');
  assert.equal(U.unitOf({ unit: '' }), 'g');
});

test('a unit this build has not learned reads as grams rather than vanishing', () => {
  // A newer Khayt writing `unit: "board-feet"` into a synced book must not drop
  // a row off an older one's shelf.
  assert.equal(U.unitOf({ unit: 'board-feet' }), 'g');
});

test('THE GRAM THRESHOLD IS EXACTLY WHAT IT WAS', () => {
  // Every item that exists is in grams. If this figure moves, every shop's
  // low-stock warnings change on the day they update, for no reason they asked
  // for. It is 200 and it stays 200.
  assert.equal(U.spec('g').low, 200);
  assert.equal(U.spec('g').low, DEDUCTION.DEFAULT_LOW_STOCK,
    'the two definitions of "low filament" must not drift apart');
});

// ── What a price is quoted per ─────────────────────────────────────────────

test('filament is priced per kilo, resin per litre, sheet goods per sheet', () => {
  assert.deepEqual(U.rateUnit('g'), { per: 1000, rate: 'kg' });
  assert.deepEqual(U.rateUnit('ml'), { per: 1000, rate: 'L' });
  assert.deepEqual(U.rateUnit('sheet'), { per: 1, rate: 'sheet' });
});

test('a 1 kg spool at 75 is 75 per kilo', () => {
  assert.deepEqual(U.costPerRateUnit(75, 1000, 'g'), { value: 75, rate: 'kg' });
});

test('a 750 g spool at 110 is 146.67 per kilo, not 110', () => {
  const r = U.costPerRateUnit(110, 750, 'g');
  assert.equal(r.rate, 'kg');
  assert.ok(Math.abs(r.value - 146.6666) < 0.001);
});

test('a 500 ml bottle at 180 is 360 per LITRE — the denominator is the point', () => {
  // On a bottle of resin the old `costPerKilo` answered 360 and called it a
  // kilo, which is a figure about a different quantity wearing the wrong name.
  assert.deepEqual(U.costPerRateUnit(180, 500, 'ml'), { value: 360, rate: 'L' });
});

test('a pack of 5 sheets at 240 is 48 per sheet', () => {
  assert.deepEqual(U.costPerRateUnit(240, 5, 'sheet'), { value: 48, rate: 'sheet' });
});

test('no original quantity means no rate, rather than a rate from what is left', () => {
  // Dividing by the remainder made the supplier-comparison figure climb as the
  // item emptied — worst on exactly the item about to be reordered.
  assert.equal(U.costPerRateUnit(75, null, 'g'), null);
  assert.equal(U.costPerRateUnit(75, 0, 'g'), null);
  assert.equal(U.costPerRateUnit(75, -5, 'g'), null);
  assert.equal(U.costPerRateUnit(null, 1000, 'g'), null);
});

// ── When is it low ─────────────────────────────────────────────────────────

test('the item\'s own reorder point wins over everything', () => {
  assert.equal(U.lowThreshold({ unit: 'g', reorderPoint: 50 }, { lowStockThreshold: 500 }), 50);
  assert.equal(U.lowThreshold({ unit: 'sheet', reorderPoint: 1 }, {}), 1);
  assert.equal(U.lowThreshold({ unit: 'g', reorderPoint: 0 }, {}), 0, 'zero is a choice');
});

test('the shop-wide threshold is a GRAM figure and is not applied to anything else', () => {
  // It has only ever been asked about filament. A shop that types 500 means
  // five hundred grams; five hundred sheets is a different claim entirely.
  assert.equal(U.lowThreshold({ unit: 'g' }, { lowStockThreshold: 500 }), 500);
  assert.equal(U.lowThreshold({ unit: 'sheet' }, { lowStockThreshold: 500 }), 2);
  assert.equal(U.lowThreshold({ unit: 'ml' }, { lowStockThreshold: 500 }), 150);
});

test('each unit has a default that means something in that unit', () => {
  assert.equal(U.lowThreshold({ unit: 'g' }, {}), 200);
  assert.equal(U.lowThreshold({ unit: 'ml' }, {}), 150);
  assert.equal(U.lowThreshold({ unit: 'sheet' }, {}), 2,
    '200 sheets is not "low", it is a warehouse');
});

// ── The vocabulary is closed ───────────────────────────────────────────────

test('spec() never returns null, whatever it is handed', () => {
  for (const bad of [null, undefined, '', 'nope', 42, {}]) {
    assert.ok(U.spec(bad));
    assert.equal(typeof U.spec(bad).low, 'number');
  }
});

test('every unit is complete', () => {
  for (const unit of U.UNITS) {
    const s = U.spec(unit);
    assert.ok(s.measure && s.rate, unit);
    assert.ok(s.per > 0, unit);
    assert.ok(s.low > 0, unit);
    assert.equal(typeof s.decimals, 'number', unit);
  }
});

test('the locale keys are built here, not assembled by a screen', () => {
  assert.deepEqual(U.keysFor('ml'), { unit: 'unit.ml', rate: 'unit.per_L' });
  assert.deepEqual(U.keysFor('board-feet'), { unit: 'unit.g', rate: 'unit.per_kg' },
    'an unknown unit gets gram keys, not a key naming the unknown unit');
});

test('the word after a quantity and the word after a slash are different keys', () => {
  // Six of them are "6 sheets" and their price is "24.00 / sheet". Reusing one
  // key put "24.00 ﷼ / sheets" on the shelf — invisible for kg and L, which
  // are the same word either way, which is exactly why it survived review.
  const sheet = U.keysFor('sheet');
  assert.notEqual(sheet.unit, sheet.rate);
  assert.equal(sheet.unit, 'unit.sheet');
  assert.equal(sheet.rate, 'unit.per_sheet');
});

// ── The rule that must not move ────────────────────────────────────────────

test('isLowStock answers exactly what it always did for a filament spool', () => {
  // Every item in every existing book is in grams. If any of these change, a
  // shop's low-stock warnings change on the day it updates, unasked.
  const cases = [
    [{ weight: 120 }, {}, true],
    [{ weight: 200 }, {}, true],
    [{ weight: 201 }, {}, false],
    [{ weight: 300 }, { lowStockThreshold: 500 }, true],
    [{ weight: 600 }, { lowStockThreshold: 500 }, false],
    [{ weight: 60, reorderPoint: 50 }, { lowStockThreshold: 500 }, false],
    [{ weight: 40, reorderPoint: 50 }, {}, true],
  ];
  for (const [item, settings, want] of cases) {
    assert.equal(DEDUCTION.isLowStock(item, settings), want, JSON.stringify(item));
  }
});

test('a bottle of resin is low at its own figure, not at the gram one', () => {
  assert.equal(DEDUCTION.isLowStock({ unit: 'ml', weight: 140 }, {}), true);
  assert.equal(DEDUCTION.isLowStock({ unit: 'ml', weight: 300 }, {}), false,
    '300 ml is a print and a half, and 200 g would have called it low');
});

test('two sheets left is low; a hundred and eighty is not', () => {
  assert.equal(DEDUCTION.isLowStock({ unit: 'sheet', weight: 2 }, {}), true);
  assert.equal(DEDUCTION.isLowStock({ unit: 'sheet', weight: 180 }, {}), false,
    'the gram threshold would have called 180 sheets low stock');
});

test("the shop's gram threshold does not reach the sheet shelf", () => {
  assert.equal(DEDUCTION.isLowStock({ unit: 'sheet', weight: 5 }, { lowStockThreshold: 500 }), false);
});
