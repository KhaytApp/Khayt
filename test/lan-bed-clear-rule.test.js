'use strict';
// lib/lan-rest.js machineBedClear: the shared rule behind POST
// /api/printer/{id}/bed-clear (docs/LAN_API.md), pure.
const test = require('node:test');
const assert = require('node:assert/strict');
const LanRest = require('../lib/lan-rest.js');

test('machineBedClear stamps the one machine, copies, and says so to the window', () => {
  const cur = Object.freeze({ machines: Object.freeze([Object.freeze({ id: 'a' }), Object.freeze({ id: 'b', bedClearedAt: '2026-01-01T00:00:00.000Z' })]) });
  const out = LanRest.machineBedClear(cur, 'b', { nowMs: Date.parse('2026-11-22T14:07:05.120Z') });
  assert.equal(out.status, 200);
  assert.deepEqual(out.body, { ok: true, bedClearedAt: '2026-11-22T14:07:05.120Z' });
  assert.equal(out.store.machines[1].bedClearedAt, '2026-11-22T14:07:05.120Z');
  assert.equal(out.store.machines[0], cur.machines[0], 'the others untouched');
  assert.deepEqual(out.emit, { channel: 'lan-machine-bed-cleared', payload: { id: 'b', bedClearedAt: '2026-11-22T14:07:05.120Z' } });
});

test('machineBedClear: not found for no id, an unknown id, a retired printer, or no machines', () => {
  const nf = { status: 404, body: { ok: false, reason: 'not-found' } };
  assert.deepEqual(LanRest.machineBedClear({ machines: [{ id: 'a' }] }, '', {}), nf);
  assert.deepEqual(LanRest.machineBedClear({ machines: [{ id: 'a' }] }, 'z', {}), nf);
  assert.deepEqual(LanRest.machineBedClear({ machines: [{ id: 'a', retiredAt: '2026-01-01' }] }, 'a', {}), nf);
  assert.deepEqual(LanRest.machineBedClear({ machines: [{ id: 'a', status: 'retired' }] }, 'a', {}), nf);
  assert.deepEqual(LanRest.machineBedClear({}, 'a', {}), nf);
  assert.deepEqual(LanRest.machineBedClear(null, 'a', {}), nf);
});
