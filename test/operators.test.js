/**
 * lib/operators.js — the per-operator table and the labour table, lifted out
 * of `renderOperatorAnalytics` and `renderTimeAnalytics`
 * (renderer/analytics.js) so the Mac draws the same figures and the arithmetic
 * is tested at all; and the delete both apps share.
 *
 * `originalPerformance` and `originalTime` are the renderer's arithmetic
 * VERBATIM (only the DOM writes removed). Where none of the bugs apply the
 * module must agree with them; each bug then has a test of its own.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const KhaytOrderStatus = require(path.join(ROOT, 'lib/order-status.js'));
const Ops = require(path.join(ROOT, 'lib/operators.js'));

function originalPerformance(operators, printLog, wasteLog) {
  if (operators.length === 0) return null;
  const completed = printLog.filter(o => KhaytOrderStatus.isFinished(o) && o.operatorId);
  if (completed.length === 0) return [];
  const rows = operators.map(op => {
    const jobs = completed.filter(o => o.operatorId === op.id);
    const wasteEntries = wasteLog.filter(w => {
      return jobs.some(j => j.id === w.orderId);
    });
    const accuracyScores = jobs
      .filter(o => o.actualPrintTime != null && o.printTime > 0)
      .map(o => (1 - Math.abs(+o.actualPrintTime - +o.printTime) / +o.printTime) * 100);
    const avgAccuracy = accuracyScores.length > 0
      ? (accuracyScores.reduce((s, v) => s + v, 0) / accuracyScores.length).toFixed(1) + '%'
      : '—';
    return { op, jobs: jobs.length, wasteEntries: wasteEntries.length, avgAccuracy };
  }).filter(r => r.jobs > 0);
  return rows;
}

function originalTime(timeEntries, printLog) {
  const totalHours = timeEntries.reduce((s, e) => s + (+e.hours || 0), 0);
  const totalCost  = timeEntries.reduce((s, e) => s + (+e.cost  || 0), 0);
  const orderIds   = [...new Set(timeEntries.map(e => e.orderId).filter(Boolean))];
  const avgHrsPerOrder = orderIds.length > 0 ? (totalHours / orderIds.length) : 0;
  const opStats = {};
  for (const entry of timeEntries) {
    const oid = entry.operatorId;
    if (!opStats[oid]) opStats[oid] = { name: entry.operatorName, hours: 0, cost: 0, orderIds: new Set() };
    opStats[oid].hours += +entry.hours || 0;
    opStats[oid].cost  += +entry.cost  || 0;
    if (entry.orderId) opStats[oid].orderIds.add(entry.orderId);
  }
  const opRows = Object.entries(opStats).map(([, s]) => {
    const ordersWorked = [...s.orderIds];
    const revenue = ordersWorked.reduce((sum, oid) => {
      const o = printLog.find(x => x.id === oid);
      return sum + (+o?.price || 0);
    }, 0);
    const avgRevPerHr = s.hours > 0 ? revenue / s.hours : 0;
    const avgHrs      = s.orderIds.size > 0 ? s.hours / s.orderIds.size : 0;
    return { ...s, orders: s.orderIds.size, avgHrs: avgHrs.toFixed(2), avgRevPerHr: avgRevPerHr.toFixed(2) };
  });
  const orderHours = {};
  for (const e of timeEntries) {
    if (!e.orderId) continue;
    if (!orderHours[e.orderId]) orderHours[e.orderId] = { hours: 0, ops: new Set() };
    orderHours[e.orderId].hours += +e.hours || 0;
    orderHours[e.orderId].ops.add(e.operatorName);
  }
  const top3 = Object.entries(orderHours)
    .sort((a, b) => b[1].hours - a[1].hours)
    .slice(0, 3)
    .map(([oid, v]) => {
      const o = printLog.find(x => x.id === oid);
      return { name: o?.project || oid, hours: v.hours.toFixed(2), ops: [...v.ops].join(', ') };
    });
  return { totalHours, totalCost, avgHrsPerOrder, opRows, top3 };
}

const measured = { time: 'moonraker' };
const deps = {
  isFinished: (o) => KhaytOrderStatus.isFinished(o),
  countsForBusiness: (o) => o.nonBusiness !== true,
  revenueOf: (o) => +o.price || 0,
};

const OPERATORS = [
  { id: 'OP-a', name: 'Ali', role: 'Technician', active: true, hourlyRate: 40 },
  { id: 'OP-b', name: 'Sara', role: 'Finisher', active: true, hourlyRate: 30 },
];
const job = (id, op, extra = {}) => ({
  id, project: 'P ' + id, status: 'completed', operatorId: op, price: 100,
  printTime: 4, actualPrintTime: 4, actualsSource: measured, ...extra,
});
const entry = (id, op, orderId, hours, extra = {}) => {
  const rate = OPERATORS.find((o) => o.id === op)?.hourlyRate || 0;
  return { id, operatorId: op, operatorName: OPERATORS.find((o) => o.id === op)?.name || '',
           orderId, hours, hourlyRate: rate, cost: hours * rate, date: '2026-09-01', ...extra };
};

// ── Agreement where none of the bugs apply ────────────────────────────────

test('performance agrees with the original on a book none of the bugs touch', () => {
  const orders = [
    job('J1', 'OP-a'), job('J2', 'OP-a', { actualPrintTime: 5 }), job('J3', 'OP-b', { actualPrintTime: 3 }),
    job('J4', 'OP-b', { status: 'delivered' }),
  ];
  const waste = [{ id: 'W1', orderId: 'J2', weight: 50, cost: 5 }, { id: 'W2', orderId: 'J3', weight: 20, cost: 2 }];
  const was = originalPerformance(OPERATORS, orders, waste);
  const now = Ops.performance({ operators: OPERATORS, orders, wasteLog: waste }, deps).rows;
  assert.equal(now.length, was.length);
  now.forEach((r, k) => {
    assert.equal(r.operatorId, was[k].op.id);
    assert.equal(r.jobs, was[k].jobs);
    assert.equal(r.wasteEntries, was[k].wasteEntries);
    assert.equal(r.accuracyPct.toFixed(1) + '%', was[k].avgAccuracy);
  });
});

test('time tracking agrees with the original on a book none of the bugs touch', () => {
  // One operator per job, every job finished, every entry on a job.
  const orders = [job('J1', 'OP-a', { price: 300 }), job('J2', 'OP-b', { price: 120 }), job('J3', 'OP-a', { price: 80 })];
  const entries = [entry('T1', 'OP-a', 'J1', 3), entry('T2', 'OP-b', 'J2', 2), entry('T3', 'OP-a', 'J3', 1), entry('T4', 'OP-a', 'J1', 1)];
  const was = originalTime(entries, orders);
  const now = Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS }, deps);
  assert.equal(now.totals.hours, was.totalHours);
  assert.equal(now.totals.cost, was.totalCost);
  assert.equal(now.totals.avgHoursPerOrder, was.avgHrsPerOrder);
  assert.equal(now.operators.length, was.opRows.length);
  for (const r of now.operators) {
    const w = was.opRows.find((x) => x.name === r.name);
    assert.ok(w, r.name);
    assert.equal(r.hours, w.hours);
    assert.equal(r.cost, w.cost);
    assert.equal(r.orders, w.orders);
    assert.equal(r.avgHoursPerOrder.toFixed(2), w.avgHrs);
    assert.equal(r.revenuePerHour.toFixed(2), w.avgRevPerHr);
  }
  assert.deepEqual(now.topOrders.map((t) => [t.project, t.hours.toFixed(2), t.operators.join(', ')]),
                   was.top3.map((t) => [t.name, t.hours, t.ops]));
});

// ── performance(): one test per bug ───────────────────────────────────────

test('a print three times its estimate scores 0, not −100%', () => {
  const orders = [job('J1', 'OP-a'), job('J2', 'OP-a'), job('J3', 'OP-a', { actualPrintTime: 12 })];
  const was = originalPerformance(OPERATORS, orders, []);
  assert.equal(was[0].avgAccuracy, '33.3%', 'the original: one bad job cancelled two perfect ones');
  const r = Ops.performance({ operators: OPERATORS, orders }, deps).rows[0];
  assert.equal(r.accuracyPct.toFixed(1), '66.7');
});

test('a typed actual is not scored; how many jobs were scored is said', () => {
  const orders = [job('J1', 'OP-a', { actualPrintTime: 6 }), job('J2', 'OP-a', { actualsSource: { time: 'manual' } })];
  const r = Ops.performance({ operators: OPERATORS, orders }, deps).rows[0];
  assert.equal(r.jobs, 2);
  assert.equal(r.scored, 1);
  assert.equal(r.accuracyPct, 50);
});

test('waste is grams and cost, and counts on a job that never finished', () => {
  const orders = [job('J1', 'OP-a'), job('J2', 'OP-a', { status: 'cancelled' })];
  const waste = [
    { id: 'W1', orderId: 'J1', weight: 1, cost: 0.1 },
    { id: 'W2', orderId: 'J2', weight: 900, cost: 20, costFull: 31.5 },
  ];
  const was = originalPerformance(OPERATORS, orders, waste);
  assert.equal(was[0].wasteEntries, 1, 'the original: the cancelled job\'s kilogram was nobody\'s');
  const r = Ops.performance({ operators: OPERATORS, orders, wasteLog: waste }, deps).rows[0];
  assert.equal(r.wasteEntries, 2);
  assert.equal(r.wasteGrams, 901);
  assert.equal(r.wasteCost, 31.6);
});

test('voided, archived and not-business jobs are not counted', () => {
  const orders = [
    job('J1', 'OP-a'), job('J2', 'OP-a', { voidedAt: '2026-09-01' }),
    job('J3', 'OP-a', { archived: true }), job('J4', 'OP-a', { nonBusiness: true }),
  ];
  assert.equal(originalPerformance(OPERATORS, orders, [])[0].jobs, 4);
  assert.equal(Ops.performance({ operators: OPERATORS, orders }, deps).rows[0].jobs, 1);
});

test('work by a deleted operator is a row of its own, after the list', () => {
  const orders = [job('J1', 'OP-a'), job('J2', 'OP-gone'), job('J3', 'OP-gone')];
  assert.equal(originalPerformance(OPERATORS, orders, []).length, 1, 'the original dropped it');
  const rows = Ops.performance({ operators: OPERATORS, orders }, deps).rows;
  assert.deepEqual(rows.map((r) => [r.operatorId, r.known, r.jobs]), [['OP-a', true, 1], ['OP-gone', false, 2]]);
});

test('no operators: nothing to draw', () => {
  const p = Ops.performance({ operators: [], orders: [job('J1', 'OP-a')] }, deps);
  assert.equal(p.hasOperators, false);
});

// ── timeTracking(): one test per bug ──────────────────────────────────────

test('two people on one job share its revenue by their hours, so the rows add up', () => {
  const orders = [job('J1', null, { price: 1000 })];
  const entries = [entry('T1', 'OP-a', 'J1', 3), entry('T2', 'OP-b', 'J1', 1)];
  const was = originalTime(entries, orders);
  assert.equal(Math.round(was.opRows.reduce((s, r) => s + (+r.avgRevPerHr) * r.hours, 0)), 2000,
               'the original credited 1,000 to each');
  const t = Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS }, deps);
  assert.deepEqual(t.operators.map((r) => r.revenue), [750, 250]);
});

test('revenue is the order\'s earned revenue, and only from work that reached the customer', () => {
  const orders = [
    job('J1', null, { price: 500 }),
    job('J2', null, { price: 500, status: 'printing' }),
    job('J3', null, { price: 500, voidedAt: '2026-09-02' }),
    job('J4', null, { price: 500, status: 'quote' }),
  ];
  const entries = ['J1', 'J2', 'J3', 'J4'].map((o, k) => entry('T' + k, 'OP-a', o, 1));
  const t = Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS },
                             { ...deps, revenueOf: (o) => (+o.price) / 1.15 });
  const r = t.operators[0];
  assert.equal(r.revenue.toFixed(2), (500 / 1.15).toFixed(2));
  assert.equal(r.earningHours, 1);
  assert.equal(r.hours, 4, 'every hour worked is still counted, and costed');
});

test('revenue per hour is over the hours that have earned', () => {
  const orders = [job('J1', null, { price: 400 }), job('J2', null, { price: 400, status: 'printing' })];
  const entries = [entry('T1', 'OP-a', 'J1', 2), entry('T2', 'OP-a', 'J2', 6)];
  assert.equal(originalTime(entries, orders).opRows[0].avgRevPerHr, '100.00');
  assert.equal(Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS }, deps)
    .operators[0].revenuePerHour, 200);
});

test('average hours per order leaves out time logged against no job', () => {
  const orders = [job('J1', null)];
  const entries = [entry('T1', 'OP-a', 'J1', 2), entry('T2', 'OP-a', null, 6)];
  assert.equal(originalTime(entries, orders).avgHrsPerOrder, 8);
  const t = Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS }, deps);
  assert.equal(t.totals.avgHoursPerOrder, 2);
  assert.equal(t.totals.hours, 8);
  assert.equal(t.operators[0].avgHoursPerOrder, 2);
});

test('a renamed operator shows their current name; a removed one keeps the frozen name', () => {
  const orders = [job('J1', null)];
  const entries = [entry('T1', 'OP-a', 'J1', 1, { operatorName: 'Ali (old)' }),
                   entry('T2', 'OP-gone', 'J1', 1, { operatorName: 'Former' })];
  const t = Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS }, deps);
  assert.deepEqual(t.operators.map((r) => [r.name, r.known]), [['Ali', true], ['Former', false]]);
  assert.deepEqual(t.topOrders[0].operators, ['Ali', 'Former']);
});

test('equal hours list in a stable order', () => {
  const orders = [job('J2', null), job('J1', null)];
  const entries = [entry('T1', 'OP-a', 'J2', 1), entry('T2', 'OP-a', 'J1', 1)];
  const t = Ops.timeTracking({ timeEntries: entries, orders, operators: OPERATORS }, deps);
  assert.deepEqual(t.topOrders.map((x) => x.orderId), ['J1', 'J2']);
});

test('an entry with no hours, or nonsense hours, is not counted; a missing cost is hours × rate', () => {
  const entries = [
    entry('T1', 'OP-a', null, 0), entry('T2', 'OP-a', null, -3), entry('T3', 'OP-a', null, 'x'),
    { id: 'T4', operatorId: 'OP-a', hours: 2, hourlyRate: 25 },
  ];
  const t = Ops.timeTracking({ timeEntries: entries, orders: [], operators: OPERATORS }, deps);
  assert.equal(t.entries, 1);
  assert.equal(t.totals.cost, 50);
});

// ── The delete both apps share ────────────────────────────────────────────

test('an operator with work on record is made inactive, everything else on the record kept', () => {
  const book = {
    operators: [{ id: 'OP-a', name: 'Ali', roleKey: 'manager', pinHash: 'p2$1$ab$cd', extra: 7 }],
    printLog: [job('J1', 'OP-a')], timeEntries: [],
  };
  assert.deepEqual(Ops.references(book, 'OP-a'), { jobs: 1, timeEntries: 0 });
  const out = Ops.remove(book, 'OP-a');
  assert.equal(out.outcome, 'deactivated');
  assert.deepEqual(out.operators[0],
    { id: 'OP-a', name: 'Ali', roleKey: 'manager', pinHash: 'p2$1$ab$cd', extra: 7, active: false });
});

test('an operator named on a time entry alone is kept too', () => {
  const book = { operators: [{ id: 'OP-a' }], printLog: [], timeEntries: [entry('T1', 'OP-a', null, 1)] };
  assert.equal(Ops.remove(book, 'OP-a').outcome, 'deactivated');
});

test('an operator with no work is removed', () => {
  const book = { operators: [{ id: 'OP-a' }, { id: 'OP-b' }], printLog: [job('J1', 'OP-b')] };
  const out = Ops.remove(book, 'OP-a');
  assert.equal(out.outcome, 'removed');
  assert.deepEqual(out.operators.map((o) => o.id), ['OP-b']);
  assert.equal(Ops.remove(book, 'OP-zz').outcome, 'missing');
});
