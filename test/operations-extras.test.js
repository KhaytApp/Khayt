const { test } = require('node:test');
const assert = require('node:assert/strict');

test('processRecurringOrders clones due recurring jobs', () => {
  global.localDateStr = () => '2026-05-30';
  global.uid = (p) => p + '-1';
  global.saveAll = () => {};
  global.toast = () => {};
  global.t = (k, p) => k + (p ? JSON.stringify(p) : '');
  global.printLog = [{
    id: 'R1',
    isRecurring: true,
    nextDueDate: '2026-05-30',
    recurringInterval: 'weekly',
    status: 'completed',
    project: 'Monthly part',
    price: 100,
  }];
  global.settings = {}; global.clients = [];
  require('../renderer/currency.js'); // stampJobCurrency, orderCurrency, as index.html loads them
  const { processRecurringOrders } = require('../renderer/operations-extras.js');
  processRecurringOrders();
  assert.equal(printLog.length, 2);
  assert.equal(printLog[1].parentRecurringId, 'R1');
  assert.equal(printLog[1].status, 'pending');
});

test('KhaytOperationsExtras exports batch feature entry points', () => {
  const ops = require('../renderer/operations-extras.js');
  assert.equal(typeof ops.renderGiftCards, 'function');
  assert.equal(typeof ops.openShiftChecklistModal, 'function');
  assert.equal(typeof ops.renderSlicerProfiles, 'function');
});
