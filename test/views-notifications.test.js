const { test } = require('node:test');
const assert = require('node:assert/strict');
// Every 'is this job finished' question in the renderer goes through this, and
// 'delivered' is the legacy spelling of finished. In the app it is a script tag.
require('../lib/order-status.js'); // globalThis.KhaytOrderStatus

test('getStaleOrders finds printing jobs past stale threshold', () => {
  const old = new Date(Date.now() - 72 * 3600000).toISOString();
  global.settings = { staleHours: { printing: 48 } };
  global.printLog = [{
    id: 'O1',
    status: 'printing',
    printingStartedAt: old,
  }];
  const { getStaleOrders } = require('../renderer/notifications.js');
  assert.equal(getStaleOrders().length, 1);
  assert.equal(getStaleOrders()[0].id, 'O1');
});

test('getPortfolioEntries flattens order photo thumbs', () => {
  global.printLog = [{
    id: 'O1',
    project: 'Widget',
    date: '2026-01-01',
    printPhotos: [{ thumb: 'data:image/png;base64,abc', filename: 'a.png' }],
  }];
  const { getPortfolioEntries } = require('../renderer/views.js');
  const entries = getPortfolioEntries();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].orderId, 'O1');
  assert.equal(entries[0].photoIndex, 0);
});

test('KhaytViews and KhaytNotifications export entry points', () => {
  const views = require('../renderer/views.js');
  const notifications = require('../renderer/notifications.js');
  assert.equal(typeof views.renderScheduleView, 'function');
  assert.equal(typeof views.renderPortfolio, 'function');
  assert.equal(typeof notifications.buildNotifications, 'function');
  assert.equal(typeof notifications.updateTabBadges, 'function');
});

test('buildNotifications surfaces overdue orders and low stock', () => {
  global.settings = { dismissedNotifs: {}, lowStockThreshold: 200, staleHours: { pending: 72 } };
  global.printLog = [{
    id: 'O-overdue',
    project: 'Late job',
    dueDate: '2020-01-01',
    status: 'pending',
    date: '2020-01-01',
  }];
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 50, reorderPoint: 200 }];
  global.machines = [];
  global.consumables = [];
  global.clients = [];
  global.escapeHtml = (s) => String(s ?? '');
  global.t = (k) => k;
  global.switchTab = () => {};
  global.machineServiceStatus = () => ({ due: false, warning: false });
  global.localName = () => '';

  const { buildNotifications } = require('../renderer/notifications.js');
  const types = buildNotifications().map((a) => a.type);
  assert.ok(types.includes('overdue'));
  assert.ok(types.includes('stock'));
});

test('buildNotifications suppresses commerce alerts in enthusiast mode', () => {
  global.settings = { mode: 'enthusiast', dismissedNotifs: {}, lowStockThreshold: 200, staleHours: {} };
  global.printLog = [
    { id: 'Q1', project: 'A quote', status: 'quote', quoteExpiresAt: '2020-01-01' },
    { id: 'O-late', project: 'Late job', dueDate: '2020-01-01', status: 'pending', date: '2020-01-01' },
  ];
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 10, reorderPoint: 200 }];
  global.machines = [];
  global.consumables = [];
  global.clients = [];
  global.escapeHtml = (s) => String(s ?? '');
  global.t = (k) => k;
  global.switchTab = () => {};
  global.machineServiceStatus = () => ({ due: false, warning: false });
  global.localName = () => '';

  const { buildNotifications } = require('../renderer/notifications.js');
  const types = buildNotifications().map((a) => a.type);
  assert.equal(types.includes('quote'), false); // commerce alert suppressed for hobbyist
  assert.ok(types.includes('overdue'));          // personal job alert kept
  assert.ok(types.includes('stock'));            // personal stock alert kept
});

test('buildNotifications respects dismissed alert keys', () => {
  global.settings = {
    dismissedNotifs: { 'overdue:O1': 'forever' },
    lowStockThreshold: 200,
    staleHours: {},
  };
  global.printLog = [{ id: 'O1', project: 'X', dueDate: '2020-01-01', status: 'pending' }];
  global.inventory = [];
  global.machines = [];
  global.consumables = [];
  global.clients = [];
  global.escapeHtml = (s) => String(s ?? '');
  global.t = (k) => k;
  global.switchTab = () => {};
  global.machineServiceStatus = () => ({ due: false, warning: false });
  global.localName = () => '';

  const { buildNotifications } = require('../renderer/notifications.js');
  assert.equal(buildNotifications().some((a) => a.key === 'overdue:O1'), false);
});

test('buildNotifications surfaces due recurring maintenance tasks', () => {
  require('../lib/maintenance.js'); // sets global.KhaytMaintenance (dual-export)
  global.settings = { dismissedNotifs: {}, staleHours: {} };
  global.printLog = [];
  global.inventory = [];
  global.consumables = [];
  global.clients = [];
  global.machines = [{ id: 'm1', name: 'Printer 1' }];
  global.machineHoursMeter = () => 600;                 // 600h on the machine
  global.machineServiceStatus = () => ({ due: false, warning: false });
  global.machMaintTasks = [
    { id: 'tk1', machineId: 'm1', name: 'Nozzle', intervalHours: 500, lastDoneHours: 0 }, // 600>=500 -> due
    { id: 'tk2', machineId: 'm1', name: 'Belt', intervalHours: 5000, lastDoneHours: 0 },  // not due
  ];
  global.escapeHtml = (s) => String(s ?? '');
  global.t = (k) => k;
  global.switchTab = () => {};
  global.localName = () => '';

  const { buildNotifications } = require('../renderer/notifications.js');
  const alerts = buildNotifications();
  const due = alerts.find((a) => a.key === 'mtask:tk1');
  assert.ok(due, 'a due maintenance task produces an alert');
  assert.equal(due.type, 'service');
  assert.equal(alerts.some((a) => a.key === 'mtask:tk2'), false, 'not-yet-due task produces no alert');
});

test('buildNotifications surfaces due recurring-order subscriptions (lib/subscriptions)', () => {
  require('../lib/subscriptions.js'); // sets global.KhaytSubscriptions (dual-export)
  global.settings = { dismissedNotifs: {}, staleHours: {} };
  global.printLog = [];
  global.inventory = [];
  global.consumables = [];
  global.machines = [];
  global.machineServiceStatus = () => ({ due: false, warning: false });
  global.machMaintTasks = [];
  global.clients = [
    { id: 'c1', name: 'Acme', recurring: { enabled: true, interval: 'monthly', nextDue: '2020-01-01' } }, // overdue
    { id: 'c2', name: 'Beta', recurring: { enabled: true, interval: 'monthly', nextDue: '2999-01-01' } }, // future
    { id: 'c3', name: 'Gamma', recurring: { enabled: false, interval: 'monthly', nextDue: '2020-01-01' } }, // disabled
  ];
  global.escapeHtml = (s) => String(s ?? '');
  global.t = (k) => k;
  global.switchTab = () => {};
  global.localName = () => '';

  const { buildNotifications } = require('../renderer/notifications.js');
  const alerts = buildNotifications();
  assert.ok(alerts.find((a) => a.key === 'recurdue:c1'), 'overdue recurring client alerts');
  assert.equal(alerts.some((a) => a.key === 'recurdue:c2'), false, 'future recurring → no alert');
  assert.equal(alerts.some((a) => a.key === 'recurdue:c3'), false, 'disabled recurring → no alert');
});

test('buildNotifications surfaces due/overdue installments (payment-plan)', () => {
  require('../lib/payment-plan.js'); // sets global.KhaytPaymentPlan
  global.settings = { dismissedNotifs: {}, staleHours: {} };
  global.inventory = [];
  global.consumables = [];
  global.clients = [];
  global.machines = [];
  global.machineServiceStatus = () => ({ due: false, warning: false });
  global.machMaintTasks = [];
  global.payStatus = () => 'partial'; // not fully paid → installments matter
  global.printLog = [
    { id: 'o1', project: 'A', instalments: [{ amount: 50, dueDate: '2020-01-01', paid: false }] }, // overdue
    { id: 'o2', project: 'B', instalments: [{ amount: 50, dueDate: '2999-01-01', paid: false }] }, // future
    { id: 'o3', project: 'C', instalments: [{ amount: 50, dueDate: '2020-01-01', paid: true }] },  // paid
  ];
  global.escapeHtml = (s) => String(s ?? '');
  global.t = (k) => k;
  global.switchTab = () => {};
  global.localName = () => '';

  const { buildNotifications } = require('../renderer/notifications.js');
  const alerts = buildNotifications();
  assert.ok(alerts.find((a) => a.key === 'instdue:o1'), 'overdue installment alerts');
  assert.equal(alerts.some((a) => a.key === 'instdue:o2'), false, 'future installment → no alert');
  assert.equal(alerts.some((a) => a.key === 'instdue:o3'), false, 'paid installment → no alert');
});
