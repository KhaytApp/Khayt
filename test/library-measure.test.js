const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const M = require('../lib/library-measure');
const G = require('../lib/gcode-parse');

const V = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'docs', 'library-measure.vectors.json'), 'utf8'));

test('which engine measures: Automatic order, Prusa never automatic, a missing choice falls back and says so', () => {
  assert.ok(V.choose.length >= 8);
  for (const c of V.choose) assert.deepEqual(M.choose(c.setting, c.available), c.expect, c.name);
});

test('Bambu result.json (verified on 02.08): 0 g with a length is derived and marked; slots keep their numbers', () => {
  for (const c of V.bambu) assert.deepEqual(M.fromBambuResult(c.result, c.opts), c.expect, c.name);
});

test('a G-code summary: grams from the length when the slicer said 0; the mislabelled volume line never read', () => {
  for (const c of V.gcode) {
    const text = c.lines.join('\n');
    const slots = G.parseFilaments(text);
    const got = M.fromGcodeSummary(slots, c.timeMins, c.changes);
    assert.deepEqual(got, c.expect, c.name);
    assert.ok(!JSON.stringify(got).includes('2964'), 'the volume line (mm³ labelled cm³) is not a figure here');
  }
});

test('a measurement is stale when the engine, its version or the profiles differ', () => {
  for (const c of V.stale) assert.equal(M.isStale(M.stamp(c.a), c.b), c.stale, c.name);
  assert.equal(M.isStale(null, { engine: 'orca' }), true);
});

test('prices already quoted or invoiced never move', () => {
  for (const c of V.reprice) assert.equal(M.mayReprice(c.order), c.may, c.name);
});

test('the stamp: names only, PrusaSlicer results always say they used Prusa settings', () => {
  const s = M.stamp({ engine: 'prusa', version: '3.0.0-alpha11', at: '2026-11-16T10:00:00Z',
    profiles: { machine: 'Original Prusa MK4', process: '0.20mm SPEED', filaments: ['Prusament PLA'], key: 'x' },
    figures: { plates: [] } });
  assert.equal(s.prusaSettings, true);
  assert.deepEqual(Object.keys(s.profiles), ['machine', 'process', 'filaments']);
  assert.equal(M.stamp({ engine: 'bogus' }).engine, 'builtin');
});

test('grams from length: the arithmetic, and no density means no grams', () => {
  assert.equal(M.gramsFromLength(1000, 1.24, 1.75), Math.round(1000 * Math.PI * 0.875 ** 2 / 1000 * 1.24 * 100) / 100);
  assert.equal(M.gramsFromLength(1000, null), null);
  assert.equal(M.gramsFromLength(0, 1.24), null);
});
