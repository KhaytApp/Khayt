const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/util.js');
// `renderer/index.html` loads these; `suggestedFailureRate` asks
// lib/failure-rate.js, the rule the Mac's FailureHint asks.
require('../lib/order-status.js');
require('../lib/failure-rate.js');

const _d = new Date();
const today = `${_d.getFullYear()}-${String(_d.getMonth() + 1).padStart(2, '0')}-${String(_d.getDate()).padStart(2, '0')}`;

test('suggestedFailureRate returns null with no history at all', () => {
  global.printLog = [];
  global.wasteLog = [];
  const { suggestedFailureRate } = require('../renderer/build.js');
  assert.equal(suggestedFailureRate('M1', 'PLA'), null);
});

test('suggestedFailureRate says "not enough" under the minimum sample', () => {
  global.printLog = [{ id: 'o1', machineId: 'M1', status: 'completed', material: 'PLA', date: today, completedAt: today }];
  global.wasteLog = [];
  const { suggestedFailureRate } = require('../renderer/build.js');
  const s = suggestedFailureRate('M1', 'PLA');
  assert.equal(s.enough, false);
  assert.equal(s.pct, null);
  assert.equal(s.attempts, 1);
});

test('suggestedFailureRate counts attempts: waste tied to a job, over 90 days', () => {
  global.printLog = Array.from({ length: 20 }, (_, i) => ({
    id: `o${i}`, machineId: 'M1', status: 'completed', material: 'PLA', date: today, completedAt: today,
  }));
  // Five failed attempts at o0..o4 (tied to a job), one row with no job (left out).
  global.wasteLog = [0, 1, 2, 3, 4].map((i) => ({ orderId: `o${i}`, machineId: 'M1', material: 'PLA', date: today }))
    .concat([{ machineId: 'M1', material: 'PLA', date: today }]);
  const { suggestedFailureRate } = require('../renderer/build.js');
  const s = suggestedFailureRate('M1', 'PLA');
  assert.equal(s.enough, true);
  assert.equal(s.scope, 'machine_material');
  assert.equal(s.attempts, 25);
  assert.equal(s.pct, 20);
});
test('KhaytBuild exports calculator entry points', () => {
  const api = require('../renderer/build.js');
  assert.equal(typeof api.renderBuild, 'function');
  assert.equal(typeof api.addPart, 'function');
  assert.equal(typeof api.populateFilamentDropdown, 'function');
});
