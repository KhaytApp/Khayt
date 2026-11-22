const { test } = require('node:test');
const assert = require('node:assert/strict');

const E = require('../lib/env-log.js');

test('a form with neither figure is refused, and says so', () => {
  assert.equal(E.check({ temperature: '', humidity: '' }), 'env.need_value');
  assert.equal(E.check({}), 'env.need_value');
  assert.equal(E.entry({}, { id: 'ENV-1', now: 0 }), null);
});

test('out of range is refused with the key the desktop toasts — it used to throw', () => {
  assert.equal(E.check({ temperature: '150' }), 'env.temp_range');
  assert.equal(E.check({ temperature: '-51' }), 'env.temp_range');
  assert.equal(E.check({ temperature: 'warm' }), 'env.temp_range');
  assert.equal(E.check({ humidity: '101' }), 'env.humidity_range');
  assert.equal(E.check({ humidity: -1 }), 'env.humidity_range');
  assert.equal(E.check({ temperature: '22', humidity: '45' }), null);
  assert.equal(E.check({ temperature: 100 }), null);
  assert.equal(E.check({ humidity: '0' }), null);
});

test('the record is the desktop shape, field for field', () => {
  const e = E.entry({ temperature: '22.5', humidity: '', machineId: 'M1', notes: '  door open ' },
    { id: 'ENV-abc', now: Date.UTC(2026, 10, 5, 9, 30) });
  assert.deepEqual(e, {
    id: 'ENV-abc', timestamp: '2026-11-05T09:30:00.000Z',
    temperature: 22.5, humidity: null, machineId: 'M1', notes: 'door open',
  });
  assert.deepEqual(Object.keys(e), ['id', 'timestamp', 'temperature', 'humidity', 'machineId', 'notes']);
  // The room as a whole is null, not "".
  assert.equal(E.entry({ humidity: 40, machineId: '' }, { id: 'x', now: 0 }).machineId, null);
});

test('the list is newest first and capped', () => {
  const logs = [
    { id: 'a', timestamp: '2026-11-01T10:00:00.000Z' },
    { id: 'c', timestamp: '2026-11-03T10:00:00.000Z' },
    null, 'junk',
    { id: 'b', timestamp: '2026-11-02T10:00:00.000Z' },
  ];
  assert.deepEqual(E.recent(logs).map((r) => r.id), ['c', 'b', 'a']);
  assert.deepEqual(E.recent(logs, 2).map((r) => r.id), ['c', 'b']);
  assert.deepEqual(E.recent(undefined), []);
  const many = Array.from({ length: 70 }, (_, i) => ({ id: String(i), timestamp: `2026-01-01T00:${String(i).padStart(2, '0')}:00.000Z` }));
  assert.equal(E.recent(many).length, E.LIST_LIMIT);
});

test('the temperature line is the last twenty readings that have one, oldest first', () => {
  assert.equal(E.temperatureTrend([{ temperature: 20, timestamp: '2026-01-01' }]), null);
  const logs = Array.from({ length: 25 }, (_, i) => ({
    timestamp: `2026-01-${String(i + 1).padStart(2, '0')}T00:00:00Z`, temperature: i,
  }));
  logs.push({ timestamp: '2026-02-01T00:00:00Z', temperature: null, humidity: 50 });
  const t = E.temperatureTrend(logs);
  assert.equal(t.readings.length, 20);
  assert.equal(t.readings[0], 5);
  assert.equal(t.readings[19], 24);
  assert.equal(t.min, 5);
  assert.equal(t.max, 24);
});
