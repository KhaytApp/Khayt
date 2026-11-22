'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { planPlates } = require('../lib/plate-nesting.js');

test('packs same-material jobs into plates under the hour limit (FFD)', () => {
  const { plates } = planPlates([
    { id: 'a', hours: 10, material: 'PLA' },
    { id: 'b', hours: 8, material: 'PLA' },
    { id: 'c', hours: 6, material: 'PLA' },
  ], { maxHours: 16, maxGrams: 100000 });
  // 10+6=16 on one plate, 8 on another (FFD): 2 plates
  assert.equal(plates.length, 2);
  assert.ok(plates.every((p) => p.hours <= 16));
  assert.ok(plates.every((p) => p.material === 'PLA'));
});

test('never mixes materials on a plate', () => {
  const { plates } = planPlates([
    { id: 'a', hours: 2, material: 'PLA' },
    { id: 'b', hours: 2, material: 'PETG' },
  ], { maxHours: 24 });
  assert.equal(plates.length, 2);
  assert.deepEqual(plates.map((p) => p.material).sort(), ['PETG', 'PLA']);
});

test('respects max grams per plate', () => {
  const { plates } = planPlates([
    { id: 'a', hours: 1, grams: 600, material: 'PLA' },
    { id: 'b', hours: 1, grams: 600, material: 'PLA' },
  ], { maxHours: 24, maxGrams: 1000 });
  assert.equal(plates.length, 2); // 1200g won't fit on one 1000g plate
});

test('a job larger than a plate gets its own oversize plate', () => {
  const { plates } = planPlates([{ id: 'big', hours: 40, material: 'PLA' }], { maxHours: 24 });
  assert.equal(plates.length, 1);
  assert.equal(plates[0].oversize, true);
});

test('empty input → no plates', () => {
  const r = planPlates([], {});
  assert.deepEqual(r.plates, []);
  assert.equal(r.totalPlates, 0);
});
