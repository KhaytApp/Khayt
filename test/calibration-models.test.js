'use strict';
/**
 * lib/calibration-models.js is what the native Mac app runs for the Calibration Assistant;
 * renderer/calibration.js is what Bed Ready runs. They must hand a maker the same tests and the
 * same test models, so this loads the renderer the way the browser does and compares them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const CM = require('../lib/calibration-models');

function loadRenderer() {
  const code = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'calibration.js'), 'utf8');
  const sandbox = {};
  sandbox.globalThis = sandbox;
  vm.runInNewContext(code, sandbox);
  return sandbox.KhaytCalibration;
}

test('every test model is the renderer\'s, byte for byte, for every material', () => {
  const R = loadRenderer();
  assert.ok(R && typeof R._buildModel === 'function', 'renderer/calibration.js no longer exposes _buildModel');
  for (const t of CM.tests) {
    for (const m of CM.materials) {
      assert.equal(CM.modelFor(t, m), R._buildModel(R.TESTS[t].model, m), `${t} / ${m}`);
    }
  }
});

test('the tests say what the renderer says', () => {
  const R = loadRenderer();
  assert.equal(JSON.stringify(Object.keys(R.TESTS)), JSON.stringify(CM.tests));
  for (const t of CM.tests) {
    for (const m of CM.materials) {
      const d = CM.describe(t, m);
      assert.equal(d.name, R.TESTS[t].name);
      assert.equal(d.blurb, R.TESTS[t].blurb);
      assert.equal(d.sweep, R.TESTS[t].sweep(m));
      assert.equal(JSON.stringify(d.steps), JSON.stringify(R.TESTS[t].steps(m)));
    }
  }
});

test('the file name and the log row are the shapes the desktop writes', () => {
  assert.equal(CM.describe('temp', 'PLA+').fileName, 'temp-pla.stl');
  assert.equal(CM.describe('xyz', 'Nylon').fileName, 'xyz-nylon.stl');
  const row = CM.logEntry('flow', 'PETG', ' 0.97 ', '2026-11-05T10:00:00.000Z', 1762336800000);
  assert.deepEqual(row, { id: 'CAL1762336800000', test: 'Flow / extrusion multiplier', material: 'PETG', result: '0.97', date: '2026-11-05T10:00:00.000Z' });
});

test('an unknown test or material falls back rather than throwing', () => {
  assert.equal(CM.describe('nope', 'Wood').test, 'temp');
  assert.equal(CM.describe('nope', 'Wood').material, 'PLA');
  assert.match(CM.modelFor('nope', 'Wood'), /^solid temp_tower\n/);
});
