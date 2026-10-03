'use strict';
/**
 * The rules that decide which orders count towards a period's figures.
 *
 * Lifted out of `openExecutiveSummary` in renderer/analytics.js so the Mac app
 * could use them instead of inventing its own. The risk in doing that is not
 * that the extraction fails loudly — it is that it changes a shop's revenue by
 * a few riyals and nobody notices for a quarter. So the first test below runs
 * the ORIGINAL inline code and the extracted module over the same orders and
 * compares the rows.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/kpi-rows.js');

/** The money the renderer supplies. Simple here; the point is the selection. */
const money = (o) => ({
  revenue: +o.price || 0,
  cost: (o.parts || []).reduce((s, p) => s + (+p.unitCost || 0), 0),
  outstanding: Math.max(0, (+o.price || 0) - (+o.paidAmount || 0)),
});
const clientName = (o) => o.client || '';

const ORDERS = [
  { id: 'A', date: '2026-09-02', status: 'delivered', price: 100, paidAmount: 100,
    dueDate: '2026-09-05', deliveredAt: '2026-09-03', client: 'Nouf', project: 'Sign' },
  { id: 'B', date: '2026-09-10', status: 'completed', price: 200, paidAmount: 0,
    dueDate: '2026-09-01', completedAt: '2026-09-09', client: 'Maha', project: 'Bracket' },
  { id: 'C', date: '2026-09-11', status: 'quote', price: 900, client: 'Sara' },
  { id: 'D', date: '2026-09-12', status: 'delivered', price: 50, voidedAt: '2026-09-13' },
  { id: 'E', date: '2026-08-20', status: 'delivered', price: 300, dueDate: '2026-08-30',
    deliveredAt: '2026-08-25', client: 'Faisal' },
  { id: 'F', date: '2026-09-14', status: 'printing', price: 400, paidAmount: 150, client: 'Jood' },
  { id: 'G', date: '2026-09-15', status: 'delivered', price: 75, client: 'Hessa' },
];

/** The code exactly as it was, before the extraction. */
function originalRows(orders, from, to, locId, orderLocationId) {
  const inR = (d) => { const x = (d || '').slice(0, 10); if (!x) return !from && !to; return (!from || x >= from) && (!to || x <= to); };
  const inLoc = (o) => !locId || (typeof orderLocationId === 'function' ? orderLocationId(o) === locId : true);
  return orders.filter((o) => !o.voidedAt && o.status !== 'quote' && inR(o.date) && inLoc(o)).map((o) => {
    const done = o.status === 'completed' || o.status === 'delivered';
    const completedAt = (o.completedAt || o.deliveredAt || o.date || '').slice(0, 10);
    const m = money(o);
    return {
      revenue: m.revenue,
      cost: m.cost,
      completed: done,
      onTime: (done && o.dueDate) ? (!!completedAt && completedAt <= o.dueDate) : null,
      outstanding: m.outstanding,
      clientName: clientName(o) || '—',
      productName: o.project || o.id,
    };
  });
}

const extracted = (from, to, locId, locationOf) => R.kpiRows({
  orders: ORDERS, from, to, locationId: locId, locationOf,
  money, clientName, unassigned: '—',
});

test('the extracted rules produce exactly what the inline code produced', () => {
  // Every range the modal offers, plus unbounded, plus a location filter.
  const cases = [
    ['2026-09-01', '2026-09-30', '', null],
    ['2026-08-01', '2026-08-31', '', null],
    ['', '', '', null],
    ['2026-09-01', '', '', null],
    ['', '2026-09-10', '', null],
    ['2026-09-01', '2026-09-30', 'LOC-1', (o) => (o.id === 'A' ? 'LOC-1' : 'LOC-2')],
  ];
  for (const [from, to, locId, locationOf] of cases) {
    assert.deepEqual(
      extracted(from, to, locId, locationOf),
      originalRows(ORDERS, from, to, locId, locationOf),
      `rows differ for ${from || 'any'}..${to || 'any'} loc=${locId || 'all'}`
    );
  }
});

test('quotes and voided orders are not revenue', () => {
  const rows = extracted('', '', '', null);
  const names = rows.map((r) => r.productName);
  assert.ok(!names.includes('C'), 'a quote is not a sale — a hundred open quotes earn nothing');
  assert.ok(!names.includes('D'), 'a voided order should never have been counted, not counted then removed');
  assert.equal(rows.length, ORDERS.length - 2);
});

test('on time is null, never false, when there is nothing to judge against', () => {
  // computeKpis counts null out of the percentage; false counts as a miss. An
  // order with no due date would otherwise drag a shop's on-time score down for
  // a promise it never made.
  assert.equal(R.onTime({ status: 'delivered', deliveredAt: '2026-09-01' }), null);
  assert.equal(R.onTime({ status: 'printing', dueDate: '2026-09-01' }), null);
  assert.equal(R.onTime({ status: 'delivered', dueDate: '2026-09-05', deliveredAt: '2026-09-05' }), true);
  assert.equal(R.onTime({ status: 'delivered', dueDate: '2026-09-05', deliveredAt: '2026-09-06' }), false);
});

test('the day the work left falls back through the chain', () => {
  // An order marked delivered with no delivery stamp still has a day. Losing it
  // would turn a late job into an unjudgeable one.
  assert.equal(R.doneOn({ completedAt: '2026-01-01', deliveredAt: '2026-02-02', date: '2026-03-03' }), '2026-01-01');
  assert.equal(R.doneOn({ deliveredAt: '2026-02-02', date: '2026-03-03' }), '2026-02-02');
  assert.equal(R.doneOn({ date: '2026-03-03' }), '2026-03-03');
  assert.equal(R.doneOn({}), '');
});

test('an undated order belongs only to "all"', () => {
  assert.equal(R.inRange('', '', ''), true);
  assert.equal(R.inRange('', '2026-01-01', '2026-12-31'), false);
});

test('the ranges are local months, and inclusive at both ends', () => {
  // A shop closing its books on the 31st means its own 31st, not UTC's.
  const sep4 = new Date(2026, 8, 4);
  assert.deepEqual(R.bounds('month', sep4), ['2026-09-01', '2026-09-30']);
  assert.deepEqual(R.bounds('last_month', sep4), ['2026-08-01', '2026-08-31']);
  assert.deepEqual(R.bounds('quarter', sep4), ['2026-07-01', '2026-09-30']);
  assert.deepEqual(R.bounds('year', sep4), ['2026-01-01', '2026-12-31']);
  assert.deepEqual(R.bounds('all', sep4), ['', '']);
  // The turn of a year, where month arithmetic goes wrong if it is done on
  // month numbers rather than on dates.
  assert.deepEqual(R.bounds('last_month', new Date(2026, 0, 15)), ['2025-12-01', '2025-12-31']);
  // A leap February, taken from the calendar rather than from a table.
  assert.deepEqual(R.bounds('month', new Date(2028, 1, 10)), ['2028-02-01', '2028-02-29']);
});

test('a location filter with no way to read a location does not empty the book', () => {
  const rows = R.kpiRows({ orders: ORDERS, locationId: 'LOC-1', locationOf: null, money, clientName });
  assert.ok(rows.length > 0, 'filtering by a location it cannot read must not hide everything');
});

test('a job marked Not business is not counted, as the P&L does not count it', () => {
  require('../lib/business-scope.js');
  const S = globalThis.KhaytBusinessScope;
  const personal = { id: 'N1', status: 'completed', date: '2026-09-10', price: 0, parts: [] };
  S.setNonBusiness(personal, true);
  const sale = { id: 'S1', status: 'completed', date: '2026-09-10', price: 50, parts: [] };
  const rows = R.kpiRows({ orders: [personal, sale], from: '', to: '', money, clientName });
  assert.equal(rows.length, 1, 'the personal print is still in the tiles');
});

test('a cancelled job is not an order, and owes nothing', () => {
  // `orderCount` is rows.length and `outstanding` is summed over every row, so
  // a cancelled 400 SAR job still counted as an order and as 400 owed.
  const rows = R.kpiRows({
    orders: [
      { id: 'X', date: '2026-09-02', status: 'cancelled', price: 400, paidAmount: 0 },
      { id: 'Y', date: '2026-09-03', status: 'printing', price: 100, paidAmount: 0 },
    ],
    money,
  });
  assert.deepEqual(rows.map((r) => r.productName), ['Y']);
  assert.equal(R.counts({ status: 'cancelled' }), false);
});

test('on time is judged on the shop\'s local day, as the On-time card judges it', () => {
  const was = process.env.TZ;
  process.env.TZ = 'Asia/Riyadh';
  try {
    // Finished at 01:30 Riyadh on the 6th, due the 5th: LATE. The UTC day of
    // the stamp is the 5th, which called it on time.
    const late = { status: 'completed', dueDate: '2026-09-05', completedAt: '2026-09-05T22:30:00.000Z' };
    assert.equal(R.doneOn(late), '2026-09-06');
    assert.equal(R.onTime(late), false);
    // A bare day is already local and is read as written.
    assert.equal(R.doneOn({ completedAt: '2026-09-05' }), '2026-09-05');
  } finally {
    if (was === undefined) delete process.env.TZ; else process.env.TZ = was;
  }
});

test('a job\'s cost: the parts as costed, stocked share only, plus shipping — one rule for both apps', () => {
  const settings = { currency: 'SAR', exchangeRates: { USD: 3.75 } };
  // A part with costing inputs, and a part priced only from a product's unit
  // cost (the LAN and public-quote paths write those) — the Mac used to count
  // only the second, and Khayt only the first.
  const o = {
    id: 'Z', currency: 'USD', shippingCost: 10,
    parts: [
      { spoolCost: 100, spoolWeight: 1000, printWeight: 200, qty: 2 },
      { unitCost: 5, qty: 3 },
    ],
  };
  const cost = R.orderCost(o, { settings, inventory: [] });
  // 2 × 20 (material) + 3 × 5 + 10 USD shipping at 3.75 = 55 + 37.5
  assert.equal(Math.round(cost * 100) / 100, 92.5);
});
