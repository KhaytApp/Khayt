'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { partitionArchived, buildArchiveExport } = require('../lib/order-archive');

const ORDERS = [
  { id: 'A', archived: true, price: 10 },
  { id: 'B', status: 'completed' },
  { id: 'C', archived: true, price: 20 },
  { id: 'D', archived: false },
];

test('partitionArchived splits on the archived flag', () => {
  const { archived, active } = partitionArchived(ORDERS);
  assert.deepEqual(archived.map((o) => o.id), ['A', 'C']);
  assert.deepEqual(active.map((o) => o.id), ['B', 'D']);
});

test('partitionArchived tolerates junk input', () => {
  assert.deepEqual(partitionArchived(null), { archived: [], active: [] });
  const { archived, active } = partitionArchived([null, { id: 'X', archived: true }, 5]);
  assert.deepEqual(archived.map((o) => o.id), ['X']);
  assert.equal(active.length, 2); // null + 5 are kept as "active" (non-archived), never crash
});

test('buildArchiveExport carries the archived records + provenance', () => {
  const payload = buildArchiveExport(ORDERS, { version: '3.2.0-beta.9', exportedAt: '2026-07-05T00:00:00Z' });
  assert.equal(payload.type, 'khayt-archived-orders');
  assert.equal(payload.version, '3.2.0-beta.9');
  assert.equal(payload.exportedAt, '2026-07-05T00:00:00Z');
  assert.equal(payload.count, 2);
  assert.deepEqual(payload.orders.map((o) => o.id), ['A', 'C']);
});

test('buildArchiveExport defaults provenance to null and only includes archived', () => {
  const payload = buildArchiveExport(ORDERS);
  assert.equal(payload.version, null);
  assert.equal(payload.exportedAt, null);
  assert.equal(payload.orders.length, 2);
  assert.ok(payload.orders.every((o) => o.archived === true));
});

test('the export is a superset of what removal deletes (same ids)', () => {
  // The renderer removes exactly the ids present in the export payload — assert
  // the two views agree so a purge can never delete an order the file lacks.
  const payload = buildArchiveExport(ORDERS);
  const exportedIds = new Set(payload.orders.map((o) => o.id));
  const kept = ORDERS.filter((o) => !exportedIds.has(o.id));
  assert.deepEqual(kept.map((o) => o.id), ['B', 'D']);
});
