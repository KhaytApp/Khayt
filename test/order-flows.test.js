const { test } = require('node:test');
const assert = require('node:assert/strict');
// renderer/util.js registers localDateStr() and friends as globals. These
// modules format dates with it — in the browser util.js is loaded first by
// index.html; under node the test has to establish the same contract.
require('../renderer/util.js');
const flows = require('../renderer/order-flows.js');

test('KhaytOrderFlows exports order lifecycle functions', () => {
  for (const name of [
    'logPrint',
    'updateStatus',
    'openOrderEditor',
    'openPaymentModal',
    'duplicateOrder',
    'recordOrderEdit',
    'splitOrderAcrossMachines',
    'openChangeOrderModal',
  ]) {
    assert.equal(typeof flows[name], 'function', name);
  }
});

test('H5: resumeFromHold clears hold flags on a direct hold → completed', () => {
  global.toast = () => {}; global.t = (k) => k;
  const o = { status: 'on_hold', holdReason: 'waiting on client', heldAt: '2026-01-01T00:00:00Z', dueDate: '2026-02-01' };
  flows.resumeFromHold(o, 'on_hold', 'completed');
  assert.equal(o.holdReason, undefined);
  assert.equal(o.heldAt, undefined);
  assert.equal(o.dueDate, '2026-02-01'); // not extended when completing
});

test('H5: resumeFromHold extends due date + clears hold when resuming to active', () => {
  global.toast = () => {}; global.t = (k) => k;
  // ~3 full days on hold. The exact day count is timing/timezone-sensitive
  // (ceil of the elapsed ms), so assert the due date moved forward — not an exact
  // date — to keep the test deterministic across runners.
  const heldAt = new Date(Date.now() - 3 * 86400000).toISOString();
  const before = '2026-02-01';
  const o = { status: 'on_hold', holdReason: 'x', heldAt, dueDate: before };
  flows.resumeFromHold(o, 'on_hold', 'printing');
  assert.equal(o.holdReason, undefined);
  assert.equal(o.heldAt, undefined);
  assert.ok(o.dueDate > before, `due date should extend past ${before}, got ${o.dueDate}`);
});

test('H4: reopening a completed order clears stale completion state', () => {
  const order = {
    id: 'O1', status: 'completed', clientId: null, parts: [],
    completedAt: '2026-01-01T10:00:00Z', materialDeducted: true,
    printingStartedAt: '2026-01-01T08:00:00Z',
  };
  global.printLog = [order];
  global.settings = {};
  global.inventory = []; global.clients = [];
  global.toast = () => {}; global.t = (k) => k;
  global.wouldExceedWipLimit = () => false;
  global.saveAll = () => {};
  global.renderKanban = () => {}; global.renderLogs = () => {};
  global.renderAnalytics = () => {}; global.renderDashboard = () => {};
  global.autoExportStatusPage = () => {}; global.autoSendEmailNotification = () => {};
  global.sendTelegramForOrder = () => {}; global.fireWebhook = () => {};
  global.fireStatusWebhook = () => {};
  global.fireOrderWebhook = () => {};

  flows.updateStatus('O1', 'printing');

  assert.equal(order.status, 'printing');
  assert.equal(order.completedAt, undefined);
  assert.equal(order.materialDeducted, undefined);
  // a fresh print-start timestamp is set, not the stale one
  assert.ok(order.printingStartedAt && order.printingStartedAt !== '2026-01-01T08:00:00Z');
});
