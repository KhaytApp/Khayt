/**
 * The log tab's client dropdown, and the complexity it must not regress to.
 *
 * It used to be `clients.filter(c => printLog.some(o => o.clientId === c.id))` —
 * every order scanned for every client, rebuilt on each render, from a function
 * with 64 call sites. Measured before the fix: 15 ms for 2,000 clients over 20k
 * orders, 100 ms at 5,000 over 50k, against 4 ms for the set-based form.
 *
 * The complexity test here deliberately does NOT time anything. A timing
 * assertion on CI is either flaky or so loose it catches nothing; counting
 * property reads is exact, fast, and fails for the right reason. A linear
 * implementation touches each record about once, a quadratic one touches them
 * clients x orders times, and no amount of machine noise blurs those two.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { clientsWithAnyOrder } = require('../renderer/logs.js');

test('only clients that appear on an order are offered', () => {
  const clients = [{ id: 'c1' }, { id: 'c2' }, { id: 'c3' }];
  const printLog = [{ clientId: 'c1' }, { clientId: 'c3' }, { clientId: 'c1' }];
  assert.deepEqual(clientsWithAnyOrder(clients, printLog).map((c) => c.id), ['c1', 'c3']);
});

test('client order is preserved — a human reads this dropdown', () => {
  const clients = [{ id: 'z' }, { id: 'a' }, { id: 'm' }];
  const printLog = [{ clientId: 'm' }, { clientId: 'z' }, { clientId: 'a' }];
  assert.deepEqual(clientsWithAnyOrder(clients, printLog).map((c) => c.id), ['z', 'a', 'm'],
    'the caller sorts, not this');
});

test('a client is listed once however many orders they have', () => {
  const clients = [{ id: 'c1' }];
  const printLog = Array.from({ length: 50 }, () => ({ clientId: 'c1' }));
  assert.equal(clientsWithAnyOrder(clients, printLog).length, 1);
});

test('orders with no client, and junk records, are ignored', () => {
  // Walk-in orders carry no clientId; a store can also hold nulls after a bad
  // import. Neither may crash a dropdown or invent a client.
  const clients = [{ id: 'c1' }, null, { id: 'c2' }];
  const printLog = [{ clientId: 'c1' }, {}, null, { clientId: null }, { clientId: undefined }];
  assert.deepEqual(clientsWithAnyOrder(clients, printLog).map((c) => c.id), ['c1']);
});

test('empty and missing inputs return an empty list, not a throw', () => {
  // This runs during a render, before any store validation.
  assert.deepEqual(clientsWithAnyOrder([], []), []);
  assert.deepEqual(clientsWithAnyOrder(null, null), []);
  assert.deepEqual(clientsWithAnyOrder(undefined, undefined), []);
  assert.deepEqual(clientsWithAnyOrder([{ id: 'c1' }], []), []);
});

test('COMPLEXITY: each record is read about once, not once per client', () => {
  const N = 300;   // clients
  const M = 900;   // orders
  let reads = 0;

  // Getters count every property access. A nested scan reads `clientId` once per
  // (client, order) pair — 270,000 times here — while a set-based pass reads it
  // once per order.
  const clients = Array.from({ length: N }, (_, i) => ({
    get id() { reads++; return `c${i}`; },
  }));
  const printLog = Array.from({ length: M }, (_, i) => ({
    get clientId() { reads++; return `c${i % N}`; },
  }));

  const out = clientsWithAnyOrder(clients, printLog);
  assert.equal(out.length, N, 'every client has an order in this fixture');

  // Linear is ~N + M reads. Allow generous slack for implementation detail, but
  // stay far below the quadratic figure, which is three orders of magnitude up.
  const linear = N + M;
  assert.ok(reads <= linear * 4,
    `expected roughly linear reads (~${linear}), got ${reads} — this looks like a nested scan (${N * M} would be quadratic)`);
});
