'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('../lib/full-spectrum');
const mm = require('../lib/mf-mesh');

test('mixRgb: subtractive pigment blend (blue + yellow → greenish, not grey)', () => {
  const { mixRgb } = require('../lib/filament-mixer');
  const g = mixRgb([0, 0, 255], [255, 255, 0], 0.5);
  assert.ok(g[1] > g[0] && g[1] > g[2], 'green channel dominates a blue/yellow mix');
});

test('deltaE: identical colours = 0, black↔white large', () => {
  const lab = (h) => fs.rgbToLab(fs.hexToRgb(h));
  assert.ok(fs.deltaE(lab('#3366CC'), lab('#3366CC')) < 1e-9);
  assert.ok(fs.deltaE(lab('#000000'), lab('#FFFFFF')) > 90);
});

test('bestMix: a pure base reproduces itself with ~0 ΔE', () => {
  const m = fs.bestMix('#E02020', ['#FFFFFF', '#000000', '#E02020', '#F0C000']);
  assert.strictEqual(m.a, m.b, 'pure single base chosen');
  assert.ok(m.deltaE < 1, 'near-zero error for an exact base');
});

test('bestPhysicalSet: <=4 colours returns all; >4 drops to exactly 4', () => {
  assert.deepStrictEqual(
    fs.bestPhysicalSet(['#FFFFFF', '#000000', '#FF0000'], [3, 2, 1]).sort(),
    [0, 1, 2],
  );
  const keep = fs.bestPhysicalSet(['#FFFFFF', '#000000', '#FF0000', '#00FF00', '#0000FF'], [5, 4, 3, 2, 1]);
  assert.strictEqual(keep.length, 4);
});

test('planFullSpectrum: 5 colours → 4 physical + ≥1 mixDef, stateMap remaps extras off the base slots', () => {
  const colors = ['#FFFFFF', '#111111', '#E02020', '#F0C000', '#20A040'];
  const plan = fs.planFullSpectrum(colors, [5000, 3000, 800, 400, 120]);
  assert.strictEqual(plan.physical.length, 4);
  assert.strictEqual(plan.physicalHex.length, 4);
  assert.ok(plan.mixDefs.length >= 1, 'the 5th colour becomes a mix');
  // Every source state maps to a valid 1-based slot; physical ones map into 1..4.
  for (let s = 1; s <= 5; s++) assert.ok(plan.stateMap(s) >= 1);
  assert.strictEqual(plan.stateMap(0), 0, 'base state stays base');
});

test('planFullSpectrum: caps the palette so a pathological colour count cannot blow up the O(n³) reducer', () => {
  // bestPhysicalSet drops colours one at a time, re-scoring every remaining mix each pass —
  // O(n³). An adversarial 3MF with thousands of colours would wedge the main process, so the
  // planner refuses an over-large palette outright rather than trying to reduce it.
  const huge = [];
  for (let i = 0; i < 300; i++) huge.push('#' + (i * 977 % 0x1000000).toString(16).padStart(6, '0'));
  assert.strictEqual(fs.planFullSpectrum(huge, []), null, 'over-cap palette rejected');
  // A palette that the paint encoding can actually represent still plans normally.
  //
  // This used to assert 32 colours ("2x a full 4-unit AMS") still plans — but measuring the
  // planner showed 32 colours produces slot numbers up to 32, and the 3MF paint field tops
  // out at 18 (it stores state-3 in four bits). Those plans encoded SILENTLY WRONG COLOURS:
  // slot 19 decoded as 3, slot 24 as 8. The real ceiling is the encoding, not MAX_FS_COLORS,
  // so the planner now declines above it and this asserts an encodable palette instead.
  const encodable = huge.slice(0, 12);
  assert.ok(fs.planFullSpectrum(encodable, []), 'an encodable palette still plans');
  assert.strictEqual(fs.planFullSpectrum(huge.slice(0, 32), []), null,
    'a palette whose slots exceed the paint encoding must decline, not emit wrong colours');
});

test('serializeMixedDefs: matches the Orca token format', () => {
  const s = fs.serializeMixedDefs([{ componentA: 1, componentB: 2, mixBPercent: 35, stableId: 1 }]);
  assert.strictEqual(s, '1,2,1,1,35,0,g,w,m2,z0,xa0,xb0,d0,o0,u1,cm0');
});

test('remapPaintCode: a solid state remaps through stateMap and decodes to the new slot', () => {
  const map = (s) => (s === 3 ? 5 : s); // send filament 3 to virtual slot 5
  const code = mm.encodeSolidPaint(3);
  const out = fs.remapPaintCode(code, map);
  assert.strictEqual(mm.dominantState(out), 5);
});

test('a slot beyond the paint encoding is refused, never silently wrapped', () => {
  // The 3MF paint field stores (state - 3) in FOUR BITS, so 18 is the highest slot it can
  // represent. MAX_FS_COLORS is 32 and mix slots run past the physical heads, so a large
  // palette could emit slot 19+ — which wrapped to a DIFFERENT VALID filament with no
  // error at all: 19 decoded as 3, 24 as 8. The wrong colour simply printed.
  const mesh = require('../lib/mf-mesh.js');
  const solid = mesh.encodeSolidPaint(1);
  for (const slot of [3, 10, 18]) {
    const back = mesh.dominantState(fs.remapPaintCode(solid, () => slot));
    assert.equal(back, slot, `slot ${slot} must round-trip`);
  }
  for (const slot of [19, 24, 31]) {
    assert.throws(() => fs.remapPaintCode(solid, () => slot), /exceeds the 3MF paint encoding/,
      `slot ${slot} must be refused rather than wrapped`);
  }
});

test('a palette needing more slots than the encoding allows declines the plan', () => {
  // planFullSpectrum returning null is the caller's fallback signal — mf-convert guards
  // every use with `if (paintPlan …)`, so declining degrades to a plain retarget.
  const many = Array.from({ length: 24 }, (_, i) => '#' + String(i % 10).repeat(6));
  const plan = fs.planFullSpectrum(many, many.map(() => 1), { maxPhysical: 4 });
  assert.equal(plan, null, 'an unencodable palette must decline, not emit wrong colours');

  // A palette that does fit still plans normally.
  const few = ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#ff00ff', '#00ffff'];
  const ok = fs.planFullSpectrum(few, few.map(() => 1), { maxPhysical: 4 });
  assert.ok(ok && ok.physical.length + ok.mixDefs.length <= 18, 'a normal palette must still plan');
});
