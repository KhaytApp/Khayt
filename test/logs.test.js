const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { getFilteredLogs } = require('../renderer/logs.js');

function resetLogFilters() {
  global.logSearchTerm = '';
  global.logStatusFilter = '';
  global.logPayFilter = '';
  global.logTagFilter = '';
  global.logClientFilter = '';
  global.logOperatorFilter = '';
  global.logRangeFilter = 'all';
  global.logSortCol = 'date';
  global.logSortDir = 'desc';
  global.showArchivedOrders = false;
  global.inRange = () => true;
  global.clients = [];
}

beforeEach(() => {
  resetLogFilters();
  global.printLog = [
    { id: 'A', date: '2026-01-10', project: 'Alpha', status: 'pending', price: 100, archived: false },
    { id: 'B', date: '2026-02-01', project: 'Beta', status: 'completed', price: 50, archived: false, tags: ['rush'] },
    { id: 'C', date: '2026-01-20', project: 'Gamma', status: 'pending', price: 0, archived: true },
  ];
});

test('getFilteredLogs excludes archived unless showArchivedOrders', () => {
  let ids = getFilteredLogs().map((o) => o.id);
  assert.deepEqual(ids, ['B', 'A']);

  global.showArchivedOrders = true;
  ids = getFilteredLogs().map((o) => o.id);
  assert.equal(ids.length, 3);
});

test('getFilteredLogs filters by status and search term', () => {
  global.logStatusFilter = 'pending';
  assert.deepEqual(getFilteredLogs().map((o) => o.id), ['A']);

  resetLogFilters();
  global.printLog = global.printLog.filter((o) => o.id !== 'C');
  global.logSearchTerm = 'beta';
  assert.deepEqual(getFilteredLogs().map((o) => o.id), ['B']);
});

test('getFilteredLogs sorts by price ascending', () => {
  global.logSortCol = 'price';
  global.logSortDir = 'asc';
  global.printLog = global.printLog.filter((o) => o.id !== 'C');
  const prices = getFilteredLogs().map((o) => +o.price);
  assert.deepEqual(prices, [50, 100]);
});
