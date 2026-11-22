/**
 * Will this model go on that bed?
 *
 * The question a maker asks before any other, and until this module it could
 * only be answered during a CONVERSION — by the one app that can run a
 * converter. The arithmetic is six numbers; the reason it was unreachable was
 * that it lived inside 1500 lines of Node-only zip handling.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const F = require('../lib/print-fit.js');
const M = require('../lib/mf-convert.js');

const U1 = { x: 270, y: 270, z: 270 };

test('a model smaller than the bed fits', () => {
  const r = F.check({ x: 100, y: 100, z: 100 }, U1);
  assert.equal(r.ok, true);
  assert.equal(r.known, true);
  assert.equal(r.footprint, false);
  assert.equal(r.height, false);
});

// A real model out of the shop's own library: 555 × 529 mm, on a 270 bed.
test('a model far too wide is refused, and says by how much', () => {
  const r = F.check({ x: 555.51, y: 529.07, z: 47.48 }, U1);
  assert.equal(r.ok, false);
  assert.equal(r.footprint, true);
  assert.equal(r.height, false, 'it is only 47 mm tall');
  assert.equal(Math.round(r.over.x), 286);
  assert.equal(Math.round(r.over.y), 259);
});

test('a model too tall is refused on height alone', () => {
  const r = F.check({ x: 100, y: 100, z: 400 }, U1);
  assert.equal(r.footprint, false);
  assert.equal(r.height, true);
  assert.equal(r.over.z, 130);
});

// Bed sizes are nominal and mesh bounds are floating point, so a hair over is
// a rounding artefact, not a part that will not print.
test('a millimetre of slack, and no more', () => {
  assert.equal(F.check({ x: 270.0001, y: 270, z: 10 }, U1).ok, true);
  assert.equal(F.check({ x: 271, y: 270, z: 10 }, U1).ok, true);
  assert.equal(F.check({ x: 272, y: 270, z: 10 }, U1).ok, false);
});

test('a bed with no height recorded cannot refuse one', () => {
  const r = F.check({ x: 100, y: 100, z: 9999 }, { x: 270, y: 270, z: 0 });
  assert.equal(r.height, false);
  assert.equal(r.ok, true);
});

// ── turned a quarter turn ─────────────────────────────────────────────────

test('a model that fits sideways says so', () => {
  const r = F.check({ x: 290, y: 240, z: 50 }, { x: 250, y: 300, z: 300 });
  assert.equal(r.ok, false);
  assert.equal(r.rotated, true);
});

test('rotating is not offered when it cannot help', () => {
  // Too long on BOTH axes: 300 beats 250 whichever way round it goes.
  assert.equal(F.check({ x: 300, y: 300, z: 50 }, { x: 250, y: 250, z: 250 }).rotated, false);
  // And a model that already fits is not "rotatable" — there is nothing to fix.
  assert.equal(F.check({ x: 100, y: 100, z: 50 }, U1).rotated, false);
});

// ── not knowing is not a refusal ──────────────────────────────────────────
//
// An unmeasured model shown as "too big" would be a warning about a fact
// nobody has. Silence is the only honest answer.
test('an unmeasured model, or a machine with no bed, is not a model that does not fit', () => {
  for (const [bounds, bed] of [
    [null, U1], [{ x: 100, y: 100, z: 100 }, null],
    [{ x: 0, y: 0, z: 0 }, U1], [{ x: 100, y: 100, z: 100 }, { x: 0, y: 0, z: 0 }],
    [undefined, undefined],
  ]) {
    const r = F.check(bounds, bed);
    assert.equal(r.known, false);
    assert.equal(r.ok, true, 'an unknown was reported as a refusal');
  }
});

// ── the machines a shop actually owns ─────────────────────────────────────

test('bestFit prefers a machine it fits outright over one it fits sideways', () => {
  const sideways = { name: 'Narrow', bed: { x: 250, y: 300, z: 300 } };
  const outright = { name: 'Big', bed: { x: 400, y: 400, z: 400 } };
  const bounds = { x: 290, y: 240, z: 50 };
  assert.equal(F.bestFit(bounds, [sideways, outright]).verdict, 'fits');
  assert.equal(F.bestFit(bounds, [sideways, outright]).machine.name, 'Big');
  assert.equal(F.bestFit(bounds, [sideways]).verdict, 'rotate');
});

test('a shop whose machines all refuse it gets none, and a count of what was tried', () => {
  const r = F.bestFit({ x: 555, y: 529, z: 47 }, [{ name: 'U1', bed: U1 }]);
  assert.equal(r.verdict, 'none');
  assert.equal(r.machine, null);
  assert.equal(r.checked, 1);
});

// A machine with no bed recorded is not evidence of anything, so it must not
// be counted as one that was tried and refused.
test('machines with no bed are not counted as having been tried', () => {
  const r = F.bestFit({ x: 555, y: 529, z: 47 }, [{ name: 'Unknown' }, { name: 'Also' }]);
  assert.equal(r.checked, 0);
  assert.equal(r.verdict, 'none');
});

test('no machines at all is not a refusal', () => {
  for (const list of [[], null, undefined]) {
    assert.equal(F.bestFit({ x: 10, y: 10, z: 10 }, list).checked, 0);
  }
});

// ── the converter's wording did not move ──────────────────────────────────
//
// `mf-convert.fitWarnings` now asks this module whether it fits and keeps its
// own sentences. Those sentences are what a maker reads in a conversion report,
// so the extraction has to be invisible to them.
test('the converter still says exactly what it said', () => {
  const target = { name: 'Snapmaker U1', bed: U1 };
  assert.deepEqual(M.fitWarnings({ x: 555.51, y: 529.07, z: 47.48 }, target), [
    "Model footprint 555.51×529.07 mm is larger than Snapmaker U1's bed 270×270 mm — it may not fit. Rotate or rescale in your slicer.",
  ]);
  assert.deepEqual(M.fitWarnings({ x: 100, y: 100, z: 400 }, target), [
    "Model height 400 mm exceeds Snapmaker U1's 270 mm max — it may not fit.",
  ]);
  assert.deepEqual(M.fitWarnings({ x: 100, y: 100, z: 100 }, target), []);
  assert.deepEqual(M.fitWarnings(null, target), []);
});
