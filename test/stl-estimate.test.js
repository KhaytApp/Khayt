/**
 * lib/stl-estimate.js — the geometry-based weight and time estimate.
 *
 * This file had no tests, which is how the shell model stayed wrong through a
 * release. The arithmetic was self-consistent: `shellFactor` was a constant
 * fraction of volume, every expression using it agreed, and a fixture written
 * from the same assumption would have confirmed it forever.
 *
 * What it could not survive is a question about PHYSICS. Walls scale with
 * surface area (L²) and the part with volume (L³), so the shell's share of a
 * part must FALL as the part gets bigger. A constant cannot do that at two
 * sizes at once, and the old default — right at roughly calibration-cube size —
 * quoted a 100 mm cube at 613 g against a physical ~327 g.
 *
 * So these tests assert against values computed from first principles here, not
 * against recorded output.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { estimateFromStl, fromSettings, ESTIMATE_DEFAULTS } = require('../lib/stl-estimate.js');

/** A cube of side `s`, as the parsers would report it. */
const cube = (s) => ({ volumeMm3: s ** 3, areaMm2: 6 * s * s, bbox: { x: s, y: s, z: s } });

/** True shell fraction of a hollow-walled cube, from geometry alone. */
const trueShellFraction = (s, wall) => {
  const inner = Math.max(0, s - 2 * wall) ** 3;
  return (s ** 3 - inner) / s ** 3;
};

test('the shell\'s share of a part falls as the part grows', () => {
  // The invariant the old constant violated, and the whole reason for the fix.
  const fractions = [10, 20, 50, 100, 200].map((s) => estimateFromStl(cube(s)).shellFraction);
  for (let i = 1; i < fractions.length; i++) {
    assert.ok(fractions[i] < fractions[i - 1],
      `shell fraction must decrease with size, got ${JSON.stringify(fractions)}`);
  }
  // And it must actually move, not drift by a rounding step: a 200mm cube's
  // walls are a far smaller share of it than a 10mm cube's.
  assert.ok(fractions[0] > fractions[4] * 10,
    `expected a large spread across 10mm..200mm, got ${JSON.stringify(fractions)}`);
});

test('a large part is estimated within a few percent of its physical weight', () => {
  // 100mm cube, PLA, 20% infill, 1.2mm wall — computed here, not recorded.
  const wall = ESTIMATE_DEFAULTS.wallThicknessMm;
  const s = 100;
  const shell = trueShellFraction(s, wall);
  const effective = shell + (1 - shell) * ESTIMATE_DEFAULTS.infillPct;
  const physicalG = (s ** 3 / 1000) * ESTIMATE_DEFAULTS.densityGPerCm3 * effective
    * (1 + ESTIMATE_DEFAULTS.wastePct);

  const got = estimateFromStl(cube(s)).estWeightG;
  const errPct = Math.abs(got - physicalG) / physicalG * 100;
  assert.ok(errPct < 5,
    `100mm cube: estimated ${got} g vs physical ${physicalG.toFixed(1)} g (${errPct.toFixed(0)}% off)`);
  // The old constant produced 613 g here. Guard the specific regression.
  assert.ok(got < 450, `${got} g is the old constant-shell answer, not a surface-derived one`);
});

test('doubling every dimension does not double the shell fraction', () => {
  // 8× the volume, 4× the area — so the shell fraction must halve. This is the
  // relationship a constant erases, expressed without reference to any default.
  const small = estimateFromStl(cube(50)).shellFraction;
  const big = estimateFromStl(cube(100)).shellFraction;
  assert.ok(Math.abs(big - small / 2) < small * 0.05,
    `expected the shell fraction to halve, got ${small} -> ${big}`);
});

test('a mesh with no surface area falls back to the constant, and says so', () => {
  // Nothing in the repo should hit this now, but a caller holding older geometry
  // must not be priced at zero shell — that would under-quote, silently.
  const withArea = estimateFromStl(cube(100));
  const without = estimateFromStl({ volumeMm3: 100 ** 3, bbox: { x: 100, y: 100, z: 100 } });

  assert.equal(withArea.shellSource, 'surface-area');
  assert.equal(without.shellSource, 'assumed');
  assert.equal(without.shellFraction, ESTIMATE_DEFAULTS.shellFactor);
  assert.notEqual(without.estWeightG, withArea.estWeightG,
    'the two models must not coincidentally agree, or this test proves nothing');
});

test('a thicker wall means a heavier part', () => {
  const thin = estimateFromStl(cube(100), { wallThicknessMm: 0.8 });
  const thick = estimateFromStl(cube(100), { wallThicknessMm: 2.4 });
  assert.ok(thick.estWeightG > thin.estWeightG,
    `${thick.estWeightG} should exceed ${thin.estWeightG}`);
  // Three times the wall, three times the shell — the relationship is linear
  // while the shell is small relative to the part.
  assert.ok(Math.abs(thick.shellFraction - thin.shellFraction * 3) < thin.shellFraction * 0.05,
    `${thin.shellFraction} -> ${thick.shellFraction} is not linear in wall thickness`);
});

test('shell can never exceed the whole part', () => {
  // A thin sheet has enormous area for its volume: 100 x 100 x 0.5mm.
  const sheet = { volumeMm3: 100 * 100 * 0.5, areaMm2: 2 * 100 * 100 + 4 * 100 * 0.5, bbox: { x: 100, y: 100, z: 0.5 } };
  const r = estimateFromStl(sheet, { wallThicknessMm: 2 });
  assert.ok(r.shellFraction <= 1, `shell fraction ${r.shellFraction} exceeds the part`);
  assert.ok(r.estWeightG <= r.solidWeightG * 1.05,
    `a part cannot weigh more than solid (${r.estWeightG} vs ${r.solidWeightG})`);
});

test('wall thickness is a shop setting, and a nonsense value is refused', () => {
  assert.equal(fromSettings({ estimator: { wallThicknessMm: 2.4 } }).wallThicknessMm, 2.4);
  // Out of range → the default, not the bad value, and not NaN.
  assert.equal(fromSettings({ estimator: { wallThicknessMm: 0 } }).wallThicknessMm,
    ESTIMATE_DEFAULTS.wallThicknessMm);
  assert.equal(fromSettings({ estimator: { wallThicknessMm: 'thick' } }).wallThicknessMm,
    ESTIMATE_DEFAULTS.wallThicknessMm);
  // Per-field fallback: setting only the wall must not reset the density.
  assert.equal(fromSettings({ estimator: { wallThicknessMm: 2.4 } }).densityGPerCm3,
    ESTIMATE_DEFAULTS.densityGPerCm3);
});

test('time still follows weight, so a lighter estimate is a shorter print', () => {
  // The shell change moves weight; time is derived from it and must move with it,
  // or the two numbers on a quote start disagreeing with each other.
  const a = estimateFromStl(cube(100), { wallThicknessMm: 0.8 });
  const b = estimateFromStl(cube(100), { wallThicknessMm: 2.4 });
  assert.ok(b.estPrintTimeH > a.estPrintTimeH);
  assert.ok(Math.abs((b.estPrintTimeH / a.estPrintTimeH) - (b.estWeightG / a.estWeightG)) < 0.02,
    'time and weight must scale together');
});

/**
 * Reliability. Scored against PrusaSlicer in scripts/verify-estimator.mjs: a
 * blocky part lands within ~13%, but a 3mm plate came out +58% and a HueForge
 * relief -66%, because a slicer lays a minimum extrusion width no matter how
 * thin the geometry is. No volume-based model can see that, so the only honest
 * option is to stop claiming the number.
 */
test('a blocky part is reported as reliable, a relief is not', () => {
  const blocky = estimateFromStl(cube(40));
  assert.equal(blocky.reliable, true, 'a 40mm cube is squarely in range');

  // A HueForge relief: area/volume ~5.7, which is not a shape this model can
  // describe — its raw shell comes out far above 1 and gets clamped.
  const relief = estimateFromStl({ volumeMm3: 2419, areaMm2: 2419 * 5.656, bbox: { x: 100, y: 100, z: 2 } });
  assert.equal(relief.reliable, false);
  assert.ok(relief.rawShell > 1,
    'the clamp is the signal: a shell above 1 means "more than entirely wall"');
  assert.equal(relief.shellFraction, 1, 'and the reported fraction is still clamped to something sane');
});

test('reliability is about the geometry, not about the wall setting alone', () => {
  // The same part, quoted by a shop that prints thick walls, becomes harder to
  // estimate — because more of it is wall. The flag has to follow that.
  const thin = estimateFromStl(cube(40), { wallThicknessMm: 0.8 });
  const thick = estimateFromStl(cube(40), { wallThicknessMm: 8 });
  assert.equal(thin.reliable, true);
  assert.equal(thick.reliable, false);
});

test('geometry with no surface area is not branded unreliable', () => {
  // It falls back to the constant, which is a different weakness and already
  // reported through shellSource. Flagging it here too would make the warning
  // mean two things at once.
  const r = estimateFromStl({ volumeMm3: 1000, bbox: { x: 10, y: 10, z: 10 } });
  assert.equal(r.shellSource, 'assumed');
  assert.equal(r.reliable, true);
  assert.equal(r.rawShell, null);
});

test('a thin, wide plate with no measured area (a HueForge relief) is priced solid and said to be unreliable', () => {
  // 200x200x4.56 mm, about 120 cm3: the assumed 35%/20% mix priced it at under
  // half its plastic and about 2 h, marked reliable.
  const relief = estimateFromStl({ volumeMm3: 120000, bbox: { x: 200, y: 200, z: 4.56 } });
  assert.equal(relief.shellSource, 'plate');
  assert.equal(relief.shellFraction, 1);
  assert.equal(relief.reliable, false, 'a relief must say to slice it');
  const assumed = estimateFromStl({ volumeMm3: 120000, bbox: { x: 200, y: 200, z: 40 } });
  assert.equal(assumed.shellSource, 'assumed', 'a tall part keeps the assumption');
  assert.ok(relief.estPrintTimeH > assumed.estPrintTimeH * 2, `${relief.estPrintTimeH} h`);
  // Time still follows printed plastic.
  const rate = (r) => r.estPrintTimeH / r.estWeightG;
  assert.ok(Math.abs(rate(relief) / rate(assumed) - 1) < 0.02, 'hours per gram moved');
  // A measured area still decides: the plate rule is only for the no-area case.
  const measured = estimateFromStl({ volumeMm3: 120000, areaMm2: 90000, bbox: { x: 200, y: 200, z: 4.56 } });
  assert.equal(measured.shellSource, 'surface-area');
  // A small coin is not a plate (50 mm / 4 mm is under 15:1)... nor a 10 mm cube.
  assert.equal(estimateFromStl({ volumeMm3: 7000, bbox: { x: 50, y: 50, z: 4 } }).shellSource, 'assumed');
});
