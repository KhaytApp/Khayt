'use strict';
/**
 * A model we could not measure was quoted as reliable, and free.
 *
 * `1e999` in an ASCII STL parses to Infinity. The parser reports SUCCESS — it
 * returns a triangle — and the geometry comes back with `volumeMm3: NaN` and a
 * null dimension:
 *
 *     tri 1  vol NaN  area NaN  bbox {"x":null,"y":2,"z":2}
 *
 * Every figure downstream is clamped with `Math.max(0, +x || 0)`, so no NaN ever
 * reached a price. What reached the caller instead was a confident estimate of
 * 0 g and 0 hours, marked `reliable: true`, because reliability was judged only
 * on the shell fraction.
 *
 * That number is shown to CUSTOMERS. lib/public-quote.js and the LAN intake form
 * both print it, and the intake only warns when `reliable === false`. So a
 * stranger uploading a malformed model was quoted essentially nothing, and the
 * one flag that would have said "do not trust this" said the opposite.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { parseStl } = require('../lib/stl-parse.js');
const { estimateFromStl } = require('../lib/stl-estimate.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

const OPTS = { density: 1.24, infillPct: 20, wallMm: 1.2, layerMm: 0.2 };
const facet = (v) => `facet normal 0 0 0\nouter loop\n${v}\nendloop\nendfacet\n`;
const one = (first) => Buffer.from(`solid x\n${facet(`vertex ${first}\nvertex 1 1 1\nvertex 2 2 2`)}endsolid x`);

/** A real 10 mm cube, so "unreliable" cannot be reached by breaking everything. */
function cube() {
  const V = [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0], [0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10]];
  const F = [[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6], [0, 4, 5], [0, 5, 1],
    [1, 5, 6], [1, 6, 2], [2, 6, 7], [2, 7, 3], [3, 7, 4], [3, 4, 0]];
  let a = 'solid c\n';
  for (const f of F) a += facet(f.map((i) => `vertex ${V[i].join(' ')}`).join('\n'));
  return Buffer.from(`${a}endsolid c`);
}

test('an Infinity coordinate is not a measurement', () => {
  const geom = parseStl(one('1e999 0 0'));
  assert.equal(Number.isFinite(geom.volumeMm3), false, 'setup: the parse is expected to yield NaN volume');
  const est = estimateFromStl(geom, OPTS);
  assert.equal(est.reliable, false,
    'a model with no finite volume was reported as a sound estimate — and shown to a customer');
});

test('a real model is still reliable', () => {
  // The failure mode of this fix is marking everything unreliable, which would
  // put a warning on every honest quote and train shops to ignore it.
  const est = estimateFromStl(parseStl(cube()), OPTS);
  assert.equal(est.reliable, true, 'an ordinary cube is now called unmeasurable');
  assert.ok(est.estWeightG > 0);
  assert.deepEqual(est.dimsMm, { x: 10, y: 10, z: 10 });
});

test('a non-finite dimension alone is enough', () => {
  // volumeMm3 can come back finite while a bbox axis does not, and a dimension
  // is what a customer reads on the quote.
  const est = estimateFromStl({ volumeMm3: 1000, areaMm2: 600, triangleCount: 12, bbox: { x: 10, y: NaN, z: 10 } }, OPTS);
  assert.equal(est.reliable, false);
});

test('missing geometry is not reliable either', () => {
  for (const geom of [null, undefined, {}, { volumeMm3: 1000 }]) {
    assert.equal(estimateFromStl(geom, OPTS).reliable, false,
      `estimateFromStl(${JSON.stringify(geom)}) claimed a sound estimate`);
  }
});

test('the shell-fraction rule still applies on top', () => {
  // A thin-walled part whose shell model is out of range stays unreliable, which
  // is the check this one is added ALONGSIDE, not in place of.
  const thin = estimateFromStl({ volumeMm3: 100, areaMm2: 100000, triangleCount: 12, bbox: { x: 100, y: 100, z: 1 } }, OPTS);
  assert.equal(thin.reliable, false, 'the original shell check was replaced rather than joined');
});

test('the callers that show this to a customer check the flag', () => {
  // Without that, the flag is a field nobody reads.
  assert.match(code('lib/intake-view.js'), /est\.reliable === false/,
    'the intake form no longer warns on an unreliable estimate');
  assert.match(code('lib/public-quote.js'), /est\.reliable !== false/,
    'the public quote no longer reads the flag');
  // The page moved out of the server into the shared module the Mac serves too.
  assert.match(code('lib/lan-intake.js'), /j\.reliable===false/,
    'the LAN intake page no longer reads the flag');
});
