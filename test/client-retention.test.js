/**
 * lib/client-retention.js — the client retention card, lifted out of
 * `renderClientRetention` (renderer/analytics.js) so the Mac draws the same
 * figures and the arithmetic is tested at all.
 *
 * `original` below is the renderer's arithmetic VERBATIM (only the DOM write
 * removed). Where none of the bugs apply the module must agree with it; each
 * bug then has a test of its own.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const KhaytOrderStatus = require(path.join(ROOT, 'lib/order-status.js'));
const { retention, daysBetween } = require(path.join(ROOT, 'lib/client-retention.js'));

function original(printLog) {
  const completed = printLog.filter(o => KhaytOrderStatus.isFinished(o) && o.clientId && o.date);
  const clientOrders = {};
  for (const o of completed) {
    if (!clientOrders[o.clientId]) clientOrders[o.clientId] = [];
    clientOrders[o.clientId].push(o.date);
  }
  const allClients = Object.entries(clientOrders).map(([id, dates]) => {
    const sorted = [...dates].sort();
    return { id, firstDate: sorted[0], secondDate: sorted[1] || null, total: sorted.length };
  });
  const withAtLeastOne = allClients.length;
  if (withAtLeastOne < 2) return null;
  const withTwo = allClients.filter(c => c.secondDate !== null);
  const daysBetween = (a, b) => Math.round(Math.abs(new Date(b) - new Date(a)) / 86400000);
  const ret30 = withTwo.filter(c => daysBetween(c.firstDate, c.secondDate) <= 30).length;
  const ret60 = withTwo.filter(c => daysBetween(c.firstDate, c.secondDate) <= 60).length;
  const ret90 = withTwo.filter(c => daysBetween(c.firstDate, c.secondDate) <= 90).length;
  const pct = (n) => withAtLeastOne > 0 ? (n / withAtLeastOne * 100).toFixed(1) : '0.0';
  const avgDays = withTwo.length > 0
    ? (withTwo.reduce((s, c) => s + daysBetween(c.firstDate, c.secondDate), 0) / withTwo.length).toFixed(1)
    : '—';
  const topReturning = [...allClients]
    .filter(c => c.total >= 2)
    .sort((a, b) => b.total - a.total)
    .slice(0, 5);
  return { r30: pct(ret30), r60: pct(ret60), r90: pct(ret90), avgDays, top: topReturning.map(c => [c.id, c.total]) };
}

const deps = {
  isFinished: KhaytOrderStatus.isFinished,
  countsForBusiness: (o) => o.nonBusiness !== true,
};
let seq = 0;
const job = (clientId, date, extra = {}) => ({ id: `J${++seq}`, clientId, date, status: 'completed', ...extra });
const TODAY = '2026-10-06';
const pct = (r) => (r == null ? null : (r * 100).toFixed(1));

test('agrees with the original where none of its bugs apply', () => {
  // Every customer's first order is more than 90 days old, one order a day,
  // nothing voided, every count distinct.
  const orders = [
    job('A', '2026-01-01'), job('A', '2026-01-20'), job('A', '2026-03-01'), job('A', '2026-05-01'),
    job('B', '2026-01-05'), job('B', '2026-02-20'),
    job('C', '2026-01-10'), job('C', '2026-04-05'), job('C', '2026-06-01'),
    job('D', '2026-02-01'),
    job('E', '2026-03-01', { status: 'delivered' }), job('E', '2026-03-15', { status: 'delivered' }),
    job('F', '2026-04-01', { status: 'printing' }),
  ];
  const was = original(orders);
  const now = retention({ orders, today: TODAY }, deps);
  assert.deepEqual(now.windows.map(w => pct(w.rate)), [was.r30, was.r60, was.r90]);
  assert.equal(now.avgDaysToReturn.toFixed(1), was.avgDays);
  assert.deepEqual(now.top.map(c => [c.clientId, c.orders]), was.top);
  assert.equal(now.clients, 5);
  assert.equal(now.enough, true);
});

test('a voided order does not make a customer a regular', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-01-10', { voidedAt: '2026-01-11' }), job('B', '2026-01-01')];
  assert.equal(original(orders).r30, '50.0', 'the original counted it');
  const r = retention({ orders, today: TODAY }, deps);
  assert.equal(r.returned, 0);
  assert.equal(r.windows[0].rate, 0);
});

test('a print marked not business does not make a customer a regular', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-01-10', { nonBusiness: true }), job('B', '2026-01-01')];
  assert.equal(retention({ orders, today: TODAY }, deps).returned, 0);
});

test('an archived order is not a return', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-01-10', { archived: true }), job('B', '2026-01-01')];
  assert.equal(retention({ orders, today: TODAY }, deps).returned, 0);
});

test('two orders on the first day are not a return in 0 days', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-01-01'), job('B', '2026-01-01')];
  const was = original(orders);
  assert.equal(was.r30, '50.0');
  assert.equal(was.avgDays, '0.0');
  const r = retention({ orders, today: TODAY }, deps);
  assert.equal(r.returned, 0);
  assert.equal(r.avgDaysToReturn, null);
  assert.deepEqual(r.top, [], 'a customer who never came back is not a returning customer');
});

test('same-day orders, then a real return: the gap is to the later day', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-01-01'), job('A', '2026-01-21'), job('B', '2026-01-01')];
  const r = retention({ orders, today: TODAY }, deps);
  assert.equal(r.avgDaysToReturn, 20);
  assert.deepEqual(r.top, [{ clientId: 'A', orders: 3, visits: 2, firstDay: '2026-01-01' }]);
});

test('a customer who first ordered last week is not counted as lost at 90 days', () => {
  const orders = [
    job('Old', '2026-05-01'), job('Old', '2026-05-15'),
    job('New1', '2026-09-30'), job('New2', '2026-10-01'), job('New3', '2026-10-02'),
  ];
  assert.equal(original(orders).r90, '25.0', 'the original read the growth as churn');
  const r = retention({ orders, today: TODAY }, deps);
  const w90 = r.windows.find(w => w.days === 90);
  assert.equal(w90.eligible, 1);
  assert.equal(w90.rate, 1);
});

test('a window nobody is old enough for has no rate, not 0%', () => {
  const orders = [job('A', '2026-09-20'), job('B', '2026-09-25')];
  const r = retention({ orders, today: TODAY }, deps);
  assert.deepEqual(r.windows.map(w => w.rate), [null, null, null]);
  assert.equal(r.enough, true);
});

test('the window boundary is inclusive: exactly 30 days later counts', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-01-31'), job('B', '2026-01-01')];
  assert.equal(retention({ orders, today: TODAY }, deps).windows[0].returned, 1);
});

test('a date with a time on it is read as its day', () => {
  const orders = [job('A', '2026-01-01T22:00:00'), job('A', '2026-01-02T01:00:00'), job('B', '2026-01-01')];
  assert.equal(retention({ orders, today: TODAY }, deps).avgDaysToReturn, 1);
});

test('top returning customers: ties broken the same way every time', () => {
  const a = [job('Z', '2026-01-01'), job('Z', '2026-02-01'), job('Y', '2026-01-01'), job('Y', '2026-02-01'), job('X', '2026-01-01'), job('X', '2026-01-01'), job('X', '2026-03-01')];
  const r1 = retention({ orders: a, today: TODAY }, deps).top.map(c => c.clientId);
  const r2 = retention({ orders: a.slice().reverse(), today: TODAY }, deps).top.map(c => c.clientId);
  assert.deepEqual(r1, ['X', 'Y', 'Z']);
  assert.deepEqual(r2, r1);
});

test('fewer than two customers is not enough to say anything', () => {
  const r = retention({ orders: [job('A', '2026-01-01'), job('A', '2026-02-01')], today: TODAY }, deps);
  assert.equal(r.enough, false);
});

test('quotes and unfinished work are not orders yet', () => {
  const orders = [job('A', '2026-01-01'), job('A', '2026-02-01', { status: 'quote' }), job('A', '2026-02-02', { status: 'pending' }), job('B', '2026-01-01')];
  assert.equal(retention({ orders, today: TODAY }, deps).returned, 0);
});

test('no today: no customer can be judged, so no window has a rate', () => {
  const r = retention({ orders: [job('A', '2026-01-01'), job('A', '2026-01-05'), job('B', '2026-01-01')] }, deps);
  assert.deepEqual(r.windows.map(w => w.rate), [null, null, null]);
  assert.equal(r.avgDaysToReturn, 4);
});

test('daysBetween does not lose a day to daylight saving', () => {
  assert.equal(daysBetween('2026-03-01', '2026-04-01'), 31);
  assert.equal(daysBetween('2026-10-20', '2026-11-10'), 21);
});
