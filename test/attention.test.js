const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  OFFLINE_AFTER_MISSED_POLLS,
  machineState,
  selectAttention,
} = require('../lib/attention');

// Fixed "now": 2026-07-22T12:00:00 local time.
const NOW = new Date(2026, 6, 22, 12, 0, 0).getTime();
// A day string relative to NOW (offset in whole days).
const ymd = (offsetDays) => {
  const d = new Date(2026, 6, 22 + offsetDays);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};

const machine = (over = {}) => ({ id: 'M1', name: 'Prusa MK4S', ...over });
const order = (over = {}) => ({ id: 'O1', project: 'Enclosure panels', status: 'printing', ...over });

/* ── machineState ──────────────────────────────────────────────── */

test('machineState: no telemetry configured reads idle, not offline', () => {
  assert.equal(machineState(machine(), undefined), 'idle');
  assert.equal(machineState(machine(), null), 'idle');
});

test('machineState: the manual offline flag wins over live telemetry', () => {
  const printing = { state: 'Printing', progress: 61 };
  assert.equal(machineState(machine({ isOffline: true }), printing), 'offline');
});

test('machineState: a missed poll is reconnecting, not offline', () => {
  // This is the false-positive guard. A CORE One takes 20-30s to answer after a
  // power cycle against a 30s poll interval, so misses 1 and 2 hit healthy hardware.
  for (let misses = 1; misses < OFFLINE_AFTER_MISSED_POLLS; misses++) {
    const entry = { error: 'ETIMEDOUT', consecutiveFailures: misses, state: 'Printing', progress: 61 };
    assert.equal(machineState(machine(), entry), 'reconnecting', `${misses} miss(es) must not read offline`);
  }
});

test('machineState: enough consecutive misses does mean offline', () => {
  const entry = { error: 'ETIMEDOUT', consecutiveFailures: OFFLINE_AFTER_MISSED_POLLS };
  assert.equal(machineState(machine(), entry), 'offline');
});

test('machineState: the offline threshold is the caller\'s to set', () => {
  const entry = { error: 'ETIMEDOUT', consecutiveFailures: 2 };
  assert.equal(machineState(machine(), entry, { offlineAfter: 2 }), 'offline');
  assert.equal(machineState(machine(), entry, { offlineAfter: 9 }), 'reconnecting');
  // A nonsense threshold falls back to the default rather than calling everything offline.
  assert.equal(machineState(machine(), entry, { offlineAfter: 0 }), 'reconnecting');
});

test('machineState: reads printing, error and idle from the state string', () => {
  assert.equal(machineState(machine(), { state: 'Printing', progress: 61 }), 'printing');
  assert.equal(machineState(machine(), { state: 'error: thermal runaway' }), 'error');
  assert.equal(machineState(machine(), { state: 'Operational', progress: 0 }), 'idle');
  // Progress without a recognisable state string still means work in flight.
  assert.equal(machineState(machine(), { state: '', progress: 47 }), 'printing');
});

/* ── selectAttention ───────────────────────────────────────────── */

test('selectAttention: a quiet shop produces an empty bar', () => {
  const got = selectAttention({
    machines: [machine(), machine({ id: 'M2' })],
    orders: [order({ dueDate: ymd(3) })],
    statusCache: { M1: { state: 'Printing', progress: 61 } },
    now: NOW,
  });
  assert.equal(got.count, 0);
  assert.deepEqual(got.items, []);
});

test('selectAttention: an offline printer is critical', () => {
  const got = selectAttention({
    machines: [machine()],
    statusCache: { M1: { error: 'ETIMEDOUT', consecutiveFailures: 4 } },
    now: NOW,
  });
  assert.equal(got.count, 1);
  assert.equal(got.items[0].severity, 'crit');
  assert.equal(got.items[0].kind, 'machine');
  assert.equal(got.items[0].name, 'Prusa MK4S');
  assert.equal(got.items[0].state, 'offline');
});

test('selectAttention: a reconnecting printer is NOT an attention item', () => {
  // The whole argument for exception-based design: if the bar fires on a 30s
  // blip the operator mutes it, and then the real fault is missed.
  const got = selectAttention({
    machines: [machine()],
    statusCache: { M1: { error: 'ETIMEDOUT', consecutiveFailures: 1, state: 'Printing', progress: 61 } },
    now: NOW,
  });
  assert.equal(got.count, 0);
});

test('selectAttention: an overdue order is a warning', () => {
  const got = selectAttention({
    orders: [order({ dueDate: ymd(-2) })],
    now: NOW,
  });
  assert.equal(got.count, 1);
  assert.equal(got.items[0].severity, 'warn');
  assert.equal(got.items[0].kind, 'order');
  assert.equal(got.items[0].daysLate, 2);
});

test('selectAttention: due today is not yet overdue', () => {
  const got = selectAttention({ orders: [order({ dueDate: ymd(0) })], now: NOW });
  assert.equal(got.count, 0);
});

test('selectAttention: completed, quoted and voided work cannot be overdue', () => {
  const got = selectAttention({
    orders: [
      order({ id: 'A', status: 'completed', dueDate: ymd(-5) }),
      order({ id: 'B', status: 'quote', dueDate: ymd(-5) }),
      order({ id: 'C', status: 'printing', dueDate: ymd(-5), voidedAt: '2026-07-01T00:00:00Z' }),
    ],
    now: NOW,
  });
  assert.equal(got.count, 0);
});

test('selectAttention: an order with no due date is never overdue', () => {
  const got = selectAttention({
    orders: [order({ dueDate: null }), order({ id: 'O2' }), order({ id: 'O3', dueDate: 'not-a-date' })],
    now: NOW,
  });
  assert.equal(got.count, 0);
});

test('selectAttention: machines outrank orders, and the longest-late order leads', () => {
  const got = selectAttention({
    machines: [machine()],
    orders: [
      order({ id: 'O1', dueDate: ymd(-1) }),
      order({ id: 'O2', dueDate: ymd(-9) }),
      order({ id: 'O3', dueDate: ymd(-4) }),
    ],
    statusCache: { M1: { error: 'ETIMEDOUT', consecutiveFailures: 5 } },
    now: NOW,
  });
  assert.equal(got.count, 4);
  assert.deepEqual(got.items.map(i => i.kind), ['machine', 'order', 'order', 'order']);
  assert.deepEqual(got.items.slice(1).map(i => i.id), ['O2', 'O3', 'O1']);
});

test('selectAttention: tolerates missing input entirely', () => {
  assert.equal(selectAttention().count, 0);
  assert.equal(selectAttention({}).count, 0);
  assert.equal(selectAttention({ machines: null, orders: null }).count, 0);
  // A null in the list must not throw.
  assert.equal(selectAttention({ machines: [null], orders: [null], now: NOW }).count, 0);
});

// ── Filament about to run out ───────────────────────────────────────────────

const DEDUCTION = require('../lib/order-deduction.js');
const lowStock = (item) => DEDUCTION.isLowStock(item, {});

test('a spool at or below its reorder point needs the operator', () => {
  const { items } = selectAttention({
    inventory: [
      { id: 's1', material: 'PA-CF', colourVariant: 'Carbon Grey', weight: 120 },
      { id: 's2', material: 'PLA+', colourVariant: 'Galaxy Black', weight: 860 },
    ],
    lowStock, now: Date.UTC(2026, 8, 8),
  });
  const stock = items.filter(i => i.kind === 'stock');
  assert.equal(stock.length, 1);
  assert.equal(stock[0].id, 's1');
  assert.equal(stock[0].severity, 'warn');
  assert.equal(stock[0].grams, 120);
  assert.equal(stock[0].variant, 'Carbon Grey');
});

test('the emptiest spool leads, because it stops the next job first', () => {
  const { items } = selectAttention({
    inventory: [
      { id: 'b', material: 'PETG', weight: 180 },
      { id: 'a', material: 'PA-CF', weight: 40 },
      { id: 'c', material: 'ASA', weight: 90 },
    ],
    lowStock, now: Date.UTC(2026, 8, 8),
  });
  assert.deepEqual(items.filter(i => i.kind === 'stock').map(i => i.id), ['a', 'c', 'b']);
});

test('no inventory means no stock warnings, not an error', () => {
  // The same contract `nozzleWear` has: a caller that supplies nothing gets
  // today's behaviour rather than a thrown module.
  assert.equal(selectAttention({ lowStock }).items.filter(i => i.kind === 'stock').length, 0);
  assert.equal(selectAttention({ inventory: [{ id: 's', weight: 0 }] })
    .items.filter(i => i.kind === 'stock').length, 0,
    'inventory with no lowStock function decides nothing');
});

test('a spool warning never outranks a machine that has stopped', () => {
  const { items } = selectAttention({
    machines: [{ id: 'M1', name: 'X1C', isOffline: true }],
    inventory: [{ id: 's1', material: 'PA-CF', weight: 40 }],
    lowStock, now: Date.UTC(2026, 8, 8),
  });
  assert.equal(items[0].kind, 'machine');
  assert.equal(items[0].severity, 'crit');
  assert.ok(items.some(i => i.kind === 'stock' && i.severity === 'warn'));
});
