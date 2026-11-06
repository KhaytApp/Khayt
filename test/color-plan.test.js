'use strict';
/**
 * lib/color-plan.js — the multicolour planner's rules, shared by the desktop's
 * modal (renderer/color-planner.js) and the native Mac's planner sheet.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const CP = require('../lib/color-plan.js');

const shelf = [
  { id: 'red', color: '#E01010', cost: 100, weight: 1000, material: 'PLA' },
  { id: 'blue', color: '#1030D0', cost: 80, weight: 1000, material: 'PLA' },
  { id: 'white', color: '#FAFAFA', cost: 60, weight: 500, material: 'PLA' },
  { id: 'nocolour', color: '', cost: 10, weight: 1000 },
];

test('only spools with a readable colour are candidates', () => {
  assert.deepEqual(CP.colouredFilaments(shelf).map((x) => x.id), ['red', 'blue', 'white']);
  assert.deepEqual(CP.colouredFilaments(null), []);
});

test('each colour starts on the nearest spool, labelled by position when unlabelled', () => {
  const cands = CP.colouredFilaments(shelf);
  const plan = CP.initialPlan([{ hex: '#FF0000', grams: 12 }, { hex: '#0000FF', grams: 3, label: 'Sky' }, { grams: 5 }], [], cands);
  assert.deepEqual(plan, [
    { hex: '#FF0000', label: '#1', grams: 12, filamentId: 'red' },
    { hex: '#0000FF', label: 'Sky', grams: 3, filamentId: 'blue' },
  ]);
});

test('a saved choice wins while its spool is still on the shelf, matched by hex ignoring case', () => {
  const cands = CP.colouredFilaments(shelf);
  const saved = [{ hex: '#ff0000', filamentId: 'white', grams: 40 }, { hex: '#0000FF', filamentId: 'gone', grams: 9 }];
  const plan = CP.initialPlan([{ hex: '#FF0000', grams: 12 }, { hex: '#0000FF', grams: 3 }], saved, cands);
  assert.equal(plan[0].filamentId, 'white');
  assert.equal(plan[0].grams, 40);
  // The spool went, so the nearest is chosen again — but the grams the shop typed stay.
  assert.equal(plan[1].filamentId, 'blue');
  assert.equal(plan[1].grams, 9);
});

test('costs, totals and the slot map', () => {
  const cands = CP.colouredFilaments(shelf);
  const plan = [
    { hex: '#FF0000', filamentId: 'red', grams: 10 },
    { hex: '#EE0000', filamentId: 'red', grams: 5 },
    { hex: '#0000FF', filamentId: 'blue', grams: 0 },
    { hex: '#FFFFFF', filamentId: 'white', grams: 2 },
    { hex: '#000000', filamentId: '', grams: 4 },
  ];
  const s = CP.summarise(plan, cands);
  assert.equal(s.rows[0].cost, 1);
  assert.equal(s.rows[3].cost, 0.24);
  assert.equal(s.rows[4].cost, null);
  assert.equal(s.rows[4].deltaE, null);
  assert.equal(s.totalGrams, 21);
  assert.ok(Math.abs(s.totalCost - (1 + 0.5 + 0 + 0.24)) < 1e-9);
  // One slot per distinct spool with grams, in colour order; blue has no grams.
  assert.deepEqual(s.slots, ['red', 'white']);
  assert.equal(s.overflow, 0);
});

test('more spools than one AMS holds are counted as hand swaps', () => {
  const many = Array.from({ length: 6 }, (_, i) => ({ id: 'f' + i, color: '#' + String(i).repeat(6), cost: 1, weight: 1 }));
  const plan = many.map((f) => ({ hex: f.color, filamentId: f.id, grams: 1 }));
  const s = CP.summarise(plan, many);
  assert.equal(s.slots.length, 6);
  assert.equal(s.overflow, 6 - CP.AMS_SLOTS);
});

test('closeness bands, saved shape and the assigned rows', () => {
  assert.equal(CP.closeness(2), 'good');
  assert.equal(CP.closeness(8), 'ok');
  assert.equal(CP.closeness(30), 'far');
  assert.equal(CP.closeness(null), '');
  const plan = [{ hex: '#FF0000', label: '#1', filamentId: 'red', grams: 3 }, { hex: '#0000FF', label: '#2', filamentId: '', grams: 2 }];
  assert.deepEqual(CP.toSaved(plan), [{ hex: '#FF0000', filamentId: 'red', grams: 3 }, { hex: '#0000FF', filamentId: '', grams: 2 }]);
  assert.deepEqual(CP.assigned(plan).map((p) => p.filamentId), ['red']);
});

test('the cost per gram never divides by zero', () => {
  assert.equal(CP.costPerGram({ cost: 20, weight: 0 }), 20);
  assert.equal(CP.costPerGram(null), 0);
});
