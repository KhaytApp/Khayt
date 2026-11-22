'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');

// The file is a renderer IIFE that assigns globalThis.BedReadyFilamentSwatches — requiring it runs it.
require('../renderer/filament-swatches.js');
const SWATCHES = globalThis.BedReadyFilamentSwatches;

test('bundled filament swatch library is well-formed', () => {
  assert.ok(Array.isArray(SWATCHES) && SWATCHES.length > 50, `substantial library, got ${SWATCHES && SWATCHES.length}`);
  const seen = new Set();
  for (const s of SWATCHES) {
    assert.ok(s.brand && s.name && s.material, `complete entry: ${JSON.stringify(s)}`);
    assert.match(s.hex, /^#[0-9A-Fa-f]{6}$/, `6-digit hex for ${s.brand} ${s.name}: ${s.hex}`);
    const key = s.brand + '|' + s.name;
    assert.ok(!seen.has(key), `unique brand+name: ${key}`);
    seen.add(key);
  }
});

test('swatch library spans multiple brands and materials', () => {
  const brands = new Set(SWATCHES.map((s) => s.brand));
  const materials = new Set(SWATCHES.map((s) => s.material));
  assert.ok(brands.size >= 5, `several brands, got ${brands.size}`);
  assert.ok(materials.has('PLA') && materials.has('PETG'), 'covers at least PLA + PETG');
});
