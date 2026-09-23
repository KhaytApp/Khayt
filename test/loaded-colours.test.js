'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const LC = require('../lib/loaded-colours');

// Read off the Snapmaker U1 on the bench (GET /printer/objects/query?print_task_config),
// 2026-09-23: PETG white, PLA grey, PLA Silk teal, PLA white.
const U1 = require('./fixtures/u1-print-task-config.json');

test('a U1 reading becomes four loaded slots, material and colour', () => {
  const slots = LC.fromPrintTaskConfig(U1);
  assert.deepEqual(slots, [
    { slot: 0, hex: '#FFFFFF', material: 'PETG' },
    { slot: 1, hex: '#8C9099', material: 'PLA' },
    { slot: 2, hex: '#4DB6AC', material: 'PLA Silk' },
    { slot: 3, hex: '#FFFFFF', material: 'PLA' },
  ]);
});

test('a head the U1 says is empty is not a loaded slot', () => {
  const slots = LC.fromPrintTaskConfig({ ...U1, filament_exist: [true, false, true, true] });
  assert.deepEqual(slots.map((s) => s.slot), [0, 2, 3]);
});

test('materials compare by family', () => {
  assert.equal(LC.family('PLA+ 2.0'), 'PLA');
  assert.equal(LC.family('PLA Silk'), 'PLA');
  assert.equal(LC.family('PETG HF'), 'PETG');      // not PET
  assert.equal(LC.family('PCTG'), 'PCTG');          // not PC
  assert.equal(LC.family('Generic'), '');
  assert.equal(LC.family(''), '');
});

test('a model whose colours are all loaded can start now', () => {
  const loaded = LC.fromPrintTaskConfig(U1);
  const model = { material: 'PLA', colors: [{ hex: '#8A8F98' }, { hex: '#FEFEFE' }] };
  const f = LC.fit(model, loaded);
  assert.equal(f.fits, true);
  assert.equal(f.swaps, 0);
  // Grey to the grey head, white to the PLA white head, not the PETG one.
  assert.deepEqual(f.matched.map((m) => m.slot), [1, 3]);
});

test('a colour nothing loaded is close to costs one swap, and says which', () => {
  const loaded = LC.fromPrintTaskConfig(U1);
  const f = LC.fit({ material: 'PLA', colors: [{ hex: '#FFFFFF' }, { hex: '#D32F2F' }] }, loaded);
  assert.equal(f.fits, false);
  assert.equal(f.swaps, 1);
  assert.equal(f.missing[0].hex, '#D32F2F');
});

test('the material has to fit, not just the colour', () => {
  // White is loaded twice, but only as PLA and PETG: an ABS white needs a swap.
  const f = LC.fit({ material: 'ABS', colors: [{ hex: '#FFFFFF' }] }, LC.fromPrintTaskConfig(U1));
  assert.equal(f.swaps, 1);
  // With no material on the model, any white will do.
  assert.equal(LC.fit({ colors: [{ hex: '#FFFFFF' }] }, LC.fromPrintTaskConfig(U1)).fits, true);
});

test('more colours than heads never starts without a swap', () => {
  const loaded = [{ hex: '#FFFFFF', material: 'PLA' }];
  const f = LC.fit({ colors: [{ hex: '#FFFFFF' }, { hex: '#FEFEFE' }, { hex: '#000000' }] }, loaded);
  // The two whites are one colour; black is the second, on a one-spool printer.
  assert.equal(f.swaps, 1);
});

test('a model with no colours is not claimed to fit', () => {
  const f = LC.fit({ material: 'PLA', colors: [] }, LC.fromPrintTaskConfig(U1));
  assert.equal(f.known, false);
  assert.equal(f.fits, false);
});

test('ranking puts what can start now first, then one swap away, unknowns last', () => {
  const loaded = LC.fromPrintTaskConfig(U1);
  const ranked = LC.rank([
    { id: 'unknown', colors: [] },
    { id: 'red', material: 'PLA', colors: [{ hex: '#D32F2F' }] },
    { id: 'teal', material: 'PLA', colors: [{ hex: '#4DB6AC' }] },
  ], loaded);
  assert.deepEqual(ranked.map((r) => r.model.id), ['teal', 'red', 'unknown']);
});

test('hand-entered slots read the same as a printer reading', () => {
  const slots = LC.normalizeLoaded([{ color: 'ff0000', material: 'PLA' }, { hex: '' }]);
  assert.deepEqual(slots, [{ slot: 0, hex: '#FF0000', material: 'PLA' }]);
});
