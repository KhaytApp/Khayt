const { test } = require('node:test');
const assert = require('node:assert/strict');

test('ensureDefaultLocation seeds Main when empty', () => {
  global.locations = [];
  global.settings = {};
  global.uid = (p) => p + '-test';
  global.saveAll = () => {};
  const { ensureDefaultLocation } = require('../renderer/ops-locations.js');
  ensureDefaultLocation();
  assert.equal(locations.length, 1);
  assert.equal(locations[0].name, 'Main');
});

test('KhaytOpsLocations exports operator and location helpers', () => {
  const ops = require('../renderer/ops-locations.js');
  assert.equal(typeof ops.openLocationEditor, 'function');
  assert.equal(typeof ops.applyProductionPause, 'function');
  assert.equal(typeof ops.openPinPadModal, 'function');
  assert.equal(typeof ops.hashPin, 'function');
});
