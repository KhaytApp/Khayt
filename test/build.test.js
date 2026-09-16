const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/util.js');
// `renderer/index.html` loads this; `suggestedFailureRate` asks it whether a
// job is finished, in either of the two spellings.
require('../lib/order-status.js');

test('suggestedFailureRate returns null with insufficient completed jobs', () => {
  global.printLog = [
    { machineId: 'M1', status: 'completed', material: 'PLA' },
  ];
  global.wasteLog = [];
  const { suggestedFailureRate } = require('../renderer/build.js');
  assert.equal(suggestedFailureRate('M1', 'PLA'), null);
});

test('suggestedFailureRate computes rate from waste vs completed', () => {
  global.printLog = Array.from({ length: 5 }, (_, i) => ({
    id: `o${i}`,
    machineId: 'M1',
    status: 'completed',
    material: 'PLA',
  }));
  global.wasteLog = [{ machineId: 'M1', material: 'PLA' }];
  const { suggestedFailureRate } = require('../renderer/build.js');
  const sugg = suggestedFailureRate('M1', 'PLA');
  assert.ok(sugg);
  assert.equal(sugg.rate, 20);
  assert.equal(sugg.n, 5);
});

test('KhaytBuild exports calculator entry points', () => {
  const api = require('../renderer/build.js');
  assert.equal(typeof api.renderBuild, 'function');
  assert.equal(typeof api.addPart, 'function');
  assert.equal(typeof api.populateFilamentDropdown, 'function');
});
