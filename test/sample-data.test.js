'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildSampleData, SAMPLE_COLLECTIONS } = require('../lib/sample-data.js');

test('buildSampleData returns realistic, flagged, dedup-safe records', () => {
  const d = buildSampleData({ today: '2026-06-20' });
  for (const c of SAMPLE_COLLECTIONS) assert.ok(Array.isArray(d[c]) && d[c].length, `${c} present`);
  // every record carries the sample flag + a DEMO id
  for (const c of SAMPLE_COLLECTIONS) {
    for (const r of d[c]) { assert.equal(r.sample, true); assert.match(r.id, /^DEMO-/); }
  }
  // orders span a range of statuses + reference demo clients
  const statuses = new Set(d.printLog.map((o) => o.status));
  assert.ok(statuses.has('quote') && statuses.has('completed') && statuses.has('printing'));
  assert.ok(d.printLog.every((o) => d.clients.some((c) => c.id === o.clientId)));
});

test('deterministic for a given today; dates are on/before today', () => {
  const a = JSON.stringify(buildSampleData({ today: '2026-06-20' }));
  const b = JSON.stringify(buildSampleData({ today: '2026-06-20' }));
  assert.equal(a, b);
  const d = buildSampleData({ today: '2026-06-20' });
  assert.ok(d.printLog.every((o) => o.date <= '2026-06-20'));
});

test('ids are unique across each collection (re-merge is idempotent by id)', () => {
  const d = buildSampleData({ today: '2026-01-01' });
  for (const c of SAMPLE_COLLECTIONS) {
    assert.equal(new Set(d[c].map((r) => r.id)).size, d[c].length, `${c} ids unique`);
  }
});
