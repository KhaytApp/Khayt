'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { materialCost, rateOf, familyOf } = require('../lib/material-cost.js');

const spool = (id, material, cost, held, at, left = held) =>
  ({ id, material, cost, spoolWeight: held, weight: left, openedAt: at, unit: 'g' });
const of = (r, material) => r.rows.find((x) => x.material === material);

/**
 * `weight` on a spool is what REMAINS — it goes down as the shop prints — so
 * dividing the purchase cost by it makes a half-used roll look twice as
 * expensive as the identical new one beside it, and worst on exactly the item
 * about to be reordered.
 */
test('the rate is what the item held when it ARRIVED, not what is left', () => {
  const full = materialCost({ inventory: [spool('a', 'PLA', 75, 1000, '2026-01-01', 1000)] }, {});
  const nearlyGone = materialCost({ inventory: [spool('b', 'PLA', 75, 1000, '2026-01-01', 40)] }, {});
  assert.equal(of(full, 'PLA').perUnit, 75);
  assert.equal(of(nearlyGone, 'PLA').perUnit, 75, 'the price climbed as the roll emptied');
});

/**
 * A per-kilo figure for everything is nonsense on half the shelf: the sample
 * shop's acrylic came out at 42,000 "per kg" because a sheet is not weighed.
 */
test('each item is priced in its own unit — kilos, litres, sheets', () => {
  const r = materialCost({ inventory: [
    { id: 'a', material: 'PLA', cost: 75, spoolWeight: 1000, unit: 'g' },
    { id: 'b', material: 'Resin', cost: 360, spoolWeight: 1000, unit: 'ml' },
    { id: 'c', material: 'Acrylic', cost: 42, spoolWeight: 1, unit: 'sheet' },
  ] }, {});
  assert.equal(of(r, 'PLA').rate, 'kg');
  assert.equal(of(r, 'Resin').rate, 'L');
  assert.equal(of(r, 'Acrylic').rate, 'sheet');
  assert.equal(of(r, 'Acrylic').perUnit, 42);
});

/// A shop comparing PLA+ prices does not mean to compare "PLA+ 2.0" against
/// "PLA+ 2.1" as two materials.
test('a vendor version number is not a different material', () => {
  assert.equal(familyOf({ material: 'PLA+ 2.0' }), 'PLA+');
  assert.equal(familyOf({ material: 'PLA+ v3' }), 'PLA+');
  assert.equal(familyOf({ material: 'PA-CF' }), 'PA-CF');
  // And a name that is ONLY a number stays whole rather than becoming empty.
  assert.equal(familyOf({ material: '1.75' }), '1.75');

  const r = materialCost({ inventory: [
    spool('a', 'PLA+ 2.0', 62, 1000, '2026-01-01'),
    spool('b', 'PLA+', 75, 1000, '2026-06-01'),
  ] }, {});
  assert.equal(r.rows.length, 1);
  assert.equal(of(r, 'PLA+').spoolCount, 2);
});

/// What a shop quotes against is what it is paying NOW, not an average over
/// years of buying.
test('the current rate is the most recently bought', () => {
  const r = materialCost({ inventory: [
    spool('a', 'PLA', 60, 1000, '2026-01-01'),
    spool('b', 'PLA', 90, 1000, '2026-08-01'),
    spool('c', 'PLA', 75, 1000, '2026-04-01'),
  ] }, {});
  assert.equal(of(r, 'PLA').perUnit, 90);
});

/**
 * A shop buying irregularly has two rolls a month apart from different sellers,
 * and the gap between those is noise rather than a trend.
 */
test('the change is first against last, and needs more than one purchase', () => {
  const one = materialCost({ inventory: [spool('a', 'PLA', 75, 1000, '2026-01-01')] }, {});
  assert.equal(of(one, 'PLA').changePct, null);
  assert.equal(one.totals.anyChangeKnown, false);

  const many = materialCost({ inventory: [
    spool('a', 'PLA', 60, 1000, '2026-01-01'),
    spool('b', 'PLA', 90, 1000, '2026-03-01'),
    spool('c', 'PLA', 75, 1000, '2026-08-01'),
  ] }, {});
  assert.equal(of(many, 'PLA').changePct, 25, 'first 60 to last 75');
  assert.equal(many.totals.anyChangeKnown, true);
});

test('a fall is reported as a fall, and only a rise is the steepest', () => {
  const r = materialCost({ inventory: [
    spool('a', 'PETG', 100, 1000, '2026-01-01'),
    spool('b', 'PETG', 80, 1000, '2026-08-01'),
    spool('c', 'PLA', 60, 1000, '2026-01-01'),
    spool('d', 'PLA', 72, 1000, '2026-08-01'),
  ] }, {});
  assert.equal(of(r, 'PETG').changePct, -20);
  assert.equal(r.totals.steepest.material, 'PLA', 'a fall was named as the steepest rise');
});

/// A sample roll a supplier sent for free really did cost nothing, and
/// `inventory-units` is right to allow it — but a shop asking what PLA costs
/// does not mean to average the free one in.
test('an item with no cost, no quantity or no material is skipped, not counted as free', () => {
  const r = materialCost({ inventory: [
    { id: 'a', material: 'PLA', cost: 0, spoolWeight: 1000, unit: 'g' },
    { id: 'b', material: 'PLA', cost: 75, spoolWeight: 0, unit: 'g' },
    { id: 'c', material: '', cost: 75, spoolWeight: 1000, unit: 'g' },
    { id: 'd', material: 'PLA', cost: 75, spoolWeight: 1000, unit: 'g' },
  ] }, {});
  assert.equal(of(r, 'PLA').spoolCount, 1);
  assert.equal(r.totals.materials, 1);
});

test('the dearest is within one unit, because a sheet and a kilo are not comparable', () => {
  const r = materialCost({ inventory: [
    { id: 'a', material: 'PLA', cost: 75, spoolWeight: 1000, unit: 'g' },
    { id: 'b', material: 'Acrylic', cost: 42, spoolWeight: 1, unit: 'sheet' },
  ] }, {});
  // Grouped by unit, so the rows never interleave two kinds of price.
  const units = r.rows.map((x) => x.rate);
  assert.deepEqual([...units].sort(), units);
});

test('nothing at all is an answer, not a throw', () => {
  const r = materialCost(undefined, undefined);
  assert.deepEqual(r.rows, []);
  assert.equal(r.totals.materials, 0);
  assert.equal(r.totals.steepest, null);
  assert.equal(r.totals.anyChangeKnown, false);
});
