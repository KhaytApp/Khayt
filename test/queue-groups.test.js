const { test } = require('node:test');
const assert = require('node:assert/strict');
const { groupQueue, nextMachineFree } = require('../lib/queue-groups');

// Fixed "now": 2026-07-22T12:00:00 local.
const NOW = new Date(2026, 6, 22, 12, 0, 0).getTime();
const ymd = (off) => {
  const d = new Date(2026, 6, 22 + off);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};
const order = (over = {}) => ({ id: 'O1', status: 'pending', printTime: 2, price: 100, ...over });
const groupOf = (res, key) => res.groups.find((g) => g.key === key);

test('statuses land in their group, in the list order the view renders', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'A', status: 'printing' }),
      order({ id: 'B', status: 'pending' }),
      order({ id: 'C', status: 'qc' }),
      order({ id: 'D', status: 'completed' }),
      order({ id: 'E', status: 'on_hold' }),
      order({ id: 'F', status: 'post' }),
      order({ id: 'G', status: 'delivered' }),
    ],
    now: NOW,
  });
  assert.deepEqual(res.groups.map((g) => g.key), ['attention', 'running', 'finishing', 'queued', 'done']);
  assert.deepEqual(groupOf(res, 'running').items.map((i) => i.order.id), ['A']);
  assert.deepEqual(groupOf(res, 'finishing').items.map((i) => i.order.id).sort(), ['C', 'F']);
  assert.deepEqual(groupOf(res, 'queued').items.map((i) => i.order.id).sort(), ['B', 'E']);
  assert.deepEqual(groupOf(res, 'done').items.map((i) => i.order.id).sort(), ['D', 'G']);
});

test('overdue work leaves its status group and leads the list', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'LATE', status: 'printing', dueDate: ymd(-3) }),
      order({ id: 'FINE', status: 'printing', dueDate: ymd(2) }),
    ],
    now: NOW,
  });
  assert.deepEqual(groupOf(res, 'attention').items.map((i) => i.order.id), ['LATE']);
  assert.equal(groupOf(res, 'attention').items[0].reason.kind, 'overdue');
  assert.equal(groupOf(res, 'attention').items[0].reason.daysLate, 3);
  assert.deepEqual(groupOf(res, 'running').items.map((i) => i.order.id), ['FINE']);
});

test('a job on a stopped machine is blocked; a missed poll is not', () => {
  const machines = [{ id: 'DEAD', name: 'Dead' }, { id: 'BLIP', name: 'Blip' }];
  const statusCache = {
    DEAD: { error: 'ETIMEDOUT', consecutiveFailures: 5 },
    BLIP: { error: 'ETIMEDOUT', consecutiveFailures: 1 },
  };
  const res = groupQueue({
    orders: [
      order({ id: 'ON_DEAD', status: 'printing', machineId: 'DEAD' }),
      order({ id: 'ON_BLIP', status: 'printing', machineId: 'BLIP' }),
    ],
    machines, statusCache, now: NOW,
  });
  assert.deepEqual(groupOf(res, 'attention').items.map((i) => i.order.id), ['ON_DEAD']);
  assert.equal(groupOf(res, 'attention').items[0].reason.kind, 'machine_down');
  // The blip's job stays where it was — the queue must not cry wolf either.
  assert.deepEqual(groupOf(res, 'running').items.map((i) => i.order.id), ['ON_BLIP']);
});

test('finished work is never pulled into attention, however late it was', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'DONE', status: 'completed', dueDate: ymd(-30) }),
      order({ id: 'GONE', status: 'delivered', dueDate: ymd(-30) }),
    ],
    now: NOW,
  });
  assert.equal(groupOf(res, 'attention').items.length, 0);
  assert.equal(groupOf(res, 'done').items.length, 2);
});

test('longest-overdue leads the attention group', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'A', dueDate: ymd(-1) }),
      order({ id: 'B', dueDate: ymd(-9) }),
      order({ id: 'C', dueDate: ymd(-4) }),
    ],
    now: NOW,
  });
  assert.deepEqual(groupOf(res, 'attention').items.map((i) => i.order.id), ['B', 'C', 'A']);
});

test('due today is not overdue', () => {
  const res = groupQueue({ orders: [order({ dueDate: ymd(0) })], now: NOW });
  assert.equal(groupOf(res, 'attention').items.length, 0);
  assert.equal(groupOf(res, 'queued').items.length, 1);
});

test('quotes and voided orders stay out of the queue entirely', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'Q', status: 'quote' }),
      order({ id: 'V', status: 'pending', voidedAt: '2026-07-01T00:00:00Z' }),
      order({ id: 'U', status: 'weird_unknown_status' }),
    ],
    now: NOW,
  });
  assert.equal(res.groups.reduce((n, g) => n + g.items.length, 0), 0);
});

test('aggregates sum hours and money per group', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'A', status: 'printing', printTime: 2.5, price: 100 }),
      order({ id: 'B', status: 'printing', printTime: 1.25, price: 50.5 }),
    ],
    now: NOW,
  });
  const running = groupOf(res, 'running').aggregate;
  assert.equal(running.count, 2);
  assert.equal(running.hours, 3.8);        // 3.75 rounded to one decimal
  assert.equal(running.money, 150.5);
});

test('money is omitted for commerce-free modes', () => {
  const res = groupQueue({ orders: [order()], now: NOW, money: false });
  assert.equal(groupOf(res, 'queued').aggregate.money, undefined);
  assert.equal(res.footer.money, undefined);
  assert.equal(groupOf(res, 'queued').aggregate.hours, 2);
});

test('the footer totals open work only — finished work is not outstanding', () => {
  const res = groupQueue({
    orders: [
      order({ id: 'A', status: 'pending', printTime: 3, price: 100 }),
      order({ id: 'B', status: 'completed', printTime: 9, price: 999 }),
    ],
    now: NOW,
  });
  assert.equal(res.footer.count, 1);
  assert.equal(res.footer.hours, 3);
  assert.equal(res.footer.money, 100);
});

test('revenueOf overrides the default price field', () => {
  const res = groupQueue({
    orders: [order({ price: 100, myTotal: 42 })],
    now: NOW,
    revenueOf: (o) => o.myTotal,
  });
  assert.equal(res.footer.money, 42);
});

/* ── next machine free ─────────────────────────────────────────── */

test('nextMachineFree: an idle machine means free now, not a future time', () => {
  const machines = [{ id: 'M1' }, { id: 'M2' }];
  const cache = { M1: { state: 'Printing', timeRemaining: 3600 } };
  assert.equal(nextMachineFree(machines, cache, [], NOW), null);
});

test('nextMachineFree: earliest finisher wins, from live telemetry', () => {
  const machines = [{ id: 'M1' }, { id: 'M2' }];
  const cache = {
    M1: { state: 'Printing', timeRemaining: 7200 },
    M2: { state: 'Printing', timeRemaining: 1800 },
  };
  assert.equal(nextMachineFree(machines, cache, [], NOW), NOW + 1800 * 1000);
});

test('nextMachineFree: falls back to the order estimate when telemetry is silent', () => {
  const machines = [{ id: 'M1' }];
  const started = new Date(NOW - 3600 * 1000).toISOString();     // one hour in
  const orders = [{ id: 'A', status: 'printing', machineId: 'M1', printTime: 3, printingStartedAt: started }];
  assert.equal(nextMachineFree(machines, {}, orders, NOW), NOW + 2 * 3600 * 1000);
});

test('nextMachineFree: no machines at all yields null rather than throwing', () => {
  assert.equal(nextMachineFree([], {}, [], NOW), null);
  assert.equal(nextMachineFree(null, {}, [], NOW), null);
});

test('groupQueue tolerates missing input entirely', () => {
  assert.equal(groupQueue().groups.length, 5);
  assert.equal(groupQueue({}).footer.count, 0);
  assert.equal(groupQueue({ orders: [null], machines: [null], now: NOW }).footer.count, 0);
});
