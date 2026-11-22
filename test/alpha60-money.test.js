'use strict';
/**
 * The alpha.60 review's money findings, one test each, and the rule that makes
 * them impossible to reintroduce: the location card's rows add up — to the
 * shop's P&L for what the P&L dates by period (revenue, cost of goods,
 * expenses, waste, labour), and to the machine P&L's charge for depreciation,
 * which both cards now take over the chosen range.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
require('../lib/calculator-cost.js');
require('../lib/order-status.js');
const Pnl = require('../lib/pnl-report.js');
const D = require('../lib/depreciation.js');
const LP = require('../lib/location-pl.js');
const { machineProfit } = require('../lib/machine-pl.js');

const NOW = new Date(2026, 9, 7);
const SAR = { currency: 'SAR' };
const MAIN = { id: 'LOC-main', name: 'Main' };
const SITE2 = { id: 'LOC-two', name: 'Site 2' };
const straight = (id, locationId) => ({
  id, name: id, locationId,
  depreciation: { method: 'straightLine', price: 3600, life: 3, lifeUnit: 'years', purchaseDate: '2025-01-01' },
});
const job = (id, machineId, price, extra = {}) =>
  ({ id, status: 'completed', date: '2026-09-10', price, machineId, ...extra });
const row = (r, id) => r.rows.find((x) => x.locationId === id);
const cents = (n) => Math.round(n * 100);
const sum = (rows, k) => rows.reduce((s, r) => s + (+r[k] || 0), 0);

function sites(book, range) {
  return LP.locationPl({ locations: [MAIN, SITE2], settings: SAR, now: NOW, range, ...book });
}
const charge = (m, range) => D.periodCharge(m, range, {});

// ── 1. DEPRECIATION ─────────────────────────────────────────────────────

test('a machine with no site still loses value: it is charged to unassigned', () => {
  const laser = straight('m3', '');
  const range = { from: '2026-09-01', to: '2026-09-30' };
  const r = sites({ machines: [straight('m1', 'LOC-main'), laser], orders: [job('a', 'm1', 90)] }, range);
  const none = row(r, LP.UNASSIGNED);
  assert.ok(none, 'the unassigned row is drawn for the machine with no site');
  assert.equal(none.depreciation, charge(laser, range));
  assert.equal(none.net, -charge(laser, range));
});

test('a machine naming a deleted site is charged to unassigned, not lost', () => {
  const ghost = straight('m4', 'LOC-gone');
  const range = { from: '2026-09-01', to: '2026-09-30' };
  const r = sites({ machines: [ghost], orders: [] }, range);
  assert.equal(row(r, LP.UNASSIGNED).depreciation, charge(ghost, range));
});

test('a straight-line machine is charged whether or not its site had work that month', () => {
  // The machine stands at Main; its only job was filed to Site 2.
  const m1 = straight('m1', 'LOC-main');
  const range = { from: '2026-09-01', to: '2026-09-30' };
  const r = sites({ machines: [m1], orders: [job('a', 'm1', 400, { locationId: 'LOC-two' })] }, range);
  assert.equal(row(r, 'LOC-main').depreciation, charge(m1, range), 'Main was charged nothing before');
  assert.equal(row(r, 'LOC-two').depreciation, 0);
});

test('a range shorter than a month is charged for its days, as the machine P&L charges it', () => {
  // About 100 a month.
  const m1 = { ...straight('m1', 'LOC-main'), depreciation: { method: 'straightLine', price: 1200, life: 1, lifeUnit: 'years', purchaseDate: '2026-01-01' } };
  const range = { from: '2026-09-26', to: '2026-10-02' };
  const r = sites({ machines: [m1], orders: [job('a', 'm1', 300, { date: '2026-09-29' })] }, range);
  const { rows } = machineProfit({ machines: [m1], completed: [job('a', 'm1', 300, { date: '2026-09-29' })], range }, {});
  assert.ok(rows[0].depreciation > 0 && rows[0].depreciation < 30, 'a week, not September');
  assert.equal(row(r, 'LOC-main').depreciation, rows[0].depreciation, 'the two cards agree about one printer');
});

test('nothing is charged past today', () => {
  const m1 = straight('m1', 'LOC-main');
  const r = sites({ machines: [m1], orders: [] }, { from: '2026-10-01', to: '2026-12-31' });
  assert.equal(row(r, 'LOC-main').depreciation, charge(m1, { from: '2026-10-01', to: '2026-10-07' }));
});

// ── 3. A STALE ID, AND WASTE ────────────────────────────────────────────

test('a job still naming a deleted site falls back to its machine’s site', () => {
  const r = sites({ machines: [{ id: 'm1', locationId: 'LOC-main' }],
    orders: [job('a', 'm1', 100, { locationId: 'LOC-gone' })] });
  assert.equal(row(r, 'LOC-main').revenue, 100);
  assert.ok(!row(r, LP.UNASSIGNED), 'not unassigned');
  assert.equal(LP.orderLocationId({ locationId: 'LOC-gone', machineId: 'm1' },
    [{ id: 'm1', locationId: 'LOC-main' }], new Set(['LOC-main'])), 'LOC-main');
});

test('waste follows its job’s site before its machine’s, as the job’s revenue does', () => {
  const r = sites({
    machines: [{ id: 'm1', locationId: 'LOC-main' }],
    orders: [job('a', 'm1', 100, { locationId: 'LOC-two' })],
    wasteLog: [{ id: 'w1', date: '2026-09-11', orderId: 'a', machineId: 'm1', grams: 100, costPerGram: 0.3, cost: 30 }],
  });
  assert.equal(row(r, 'LOC-main').waste, 0, 'Main read −30 for scrap from a Site 2 job');
  assert.ok(row(r, 'LOC-two').waste > 0);
});

// ── 2. LABOUR ON A MACHINE ──────────────────────────────────────────────

const labourBook = () => ({
  machines: [{ id: 'm1', name: 'U1' }, { id: 'm2', name: 'CORE One' }],
  orders: [
    job('late', 'm1', 500, { date: '2026-09-28' }),
    job('void', 'm2', 100, { date: '2026-10-01', voidedAt: '2026-10-03' }),
  ],
  timeEntries: [
    { id: 'TE1', orderId: 'late', operatorId: 'OP1', hours: 10, hourlyRate: 20, cost: 200, date: '2026-10-02' },
    { id: 'TE2', orderId: 'void', operatorId: 'OP1', hours: 2, hourlyRate: 20, cost: 40, date: '2026-10-03' },
    { id: 'TE3', orderId: '', operatorId: 'OP1', hours: 1, hourlyRate: 20, cost: 20, date: '2026-10-04' },
  ],
});
const inOctober = (d) => String(d).slice(0, 7) === '2026-10';

test('labour lands on its job’s machine in the month it was worked, though the job was filed in another', () => {
  const b = labourBook();
  const completed = b.orders.filter((o) => inOctober(o.date) && !o.voidedAt);
  const { rows } = machineProfit({
    machines: b.machines, completed, orders: b.orders,
    timeEntries: b.timeEntries.filter((e) => inOctober(e.date)),
    range: { from: '2026-10-01', to: '2026-10-31' },
  }, {});
  const u1 = rows.find((r) => r.machineId === 'm1');
  assert.ok(u1, 'the U1 has a row: people worked on its job in October');
  assert.equal(u1.labour, 200, 'it was 0 in September AND October before');
  const sept = machineProfit({
    machines: b.machines, completed: b.orders.filter((o) => o.date.startsWith('2026-09')), orders: b.orders,
    timeEntries: b.timeEntries.filter((e) => e.date.startsWith('2026-09')),
  }, {});
  assert.equal(sept.rows.find((r) => r.machineId === 'm1').labour, 0, 'not in September, when nobody worked on it');
});

test('a voided job’s labour is not a machine’s, as it is not the P&L’s', () => {
  const b = labourBook();
  const { rows } = machineProfit({
    machines: b.machines, completed: [], orders: b.orders, timeEntries: b.timeEntries,
  }, {});
  assert.ok(!rows.find((r) => r.machineId === 'm2'), 'the voided job’s hours charged the CORE One');
});

test('the machines and the hours on no job add up to the P&L’s labour line', () => {
  const b = labourBook();
  const entries = b.timeEntries.filter((e) => inOctober(e.date));
  const { totals } = machineProfit({ machines: b.machines, completed: [], orders: b.orders, timeEntries: entries }, {});
  const shop = Pnl.pnlByPeriod([], [], { settings: SAR, now: NOW, granularity: 'month', timeEntries: entries, jobs: b.orders });
  const unjobbed = entries.filter((e) => !e.orderId).reduce((s, e) => s + Pnl.labourCostOf(e), 0);
  assert.equal(cents(totals.labour + unjobbed), cents(sum(shop, 'labour')));
});

// ── 5. ONE TEST FOR "READS AS PAY" ──────────────────────────────────────

test('a payroll-named fixed cost of nothing is not pay, in the summary as in the periods', () => {
  const labour = [{ id: 'TE1', hours: 1, hourlyRate: 10, cost: 10, date: '2026-10-01' }];
  assert.equal(Pnl.computePnl({ labour, fixedCosts: [{ name: 'Wages', amount: 0 }] }).labourOverlap, false);
  assert.equal(Pnl.computePnl({ labour, fixedCosts: [{ name: 'Wages', amount: 900 }] }).labourOverlap, true);
});

test('pay typed into an expense’s note is seen as pay — both apps write `note`', () => {
  const labour = [{ id: 'TE1', hours: 1, hourlyRate: 10, cost: 10, date: '2026-09-10' }];
  const wages = { id: 'x1', date: '2026-09-05', amount: 900, category: 'Other', note: 'Staff wages September' };
  assert.equal(Pnl.computePnl({ labour, expenses: [wages] }).labourOverlap, true, 'the summary');
  const [sep] = Pnl.pnlByPeriod([], [wages], { settings: SAR, now: NOW, granularity: 'month', timeEntries: labour });
  assert.equal(sep.labourOverlap, true, 'the periods');
  // An old record's `description` still counts.
  const old = { id: 'x2', date: '2026-09-05', amount: 900, category: 'Other', description: 'رواتب' };
  assert.equal(Pnl.computePnl({ labour, expenses: [old] }).labourOverlap, true);
  // And a note that is not pay raises nothing.
  const tape = { ...wages, note: 'Painter’s tape' };
  assert.equal(Pnl.computePnl({ labour, expenses: [tape] }).labourOverlap, false);
});

// ── THE RATCHET: THE ROWS ADD UP ────────────────────────────────────────

const sample = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json'), 'utf8'));

const RANGES = [
  { from: '2026-01-01', to: '2026-12-31' },
  { from: '2026-07-01', to: '2026-09-30' },
  { from: '2026-09-01', to: '2026-09-30' },
  { from: '2026-09-26', to: '2026-10-02' },
];

for (const range of RANGES) {
  test(`the sample shop's sites add up, ${range.from}..${range.to}`, () => {
    const inR = (d) => { const s = String(d || '').slice(0, 10); return s >= range.from && s <= range.to; };
    const orders = (sample.printLog || []).filter((o) => inR(o.date));
    const expenses = (sample.expenses || []).filter((e) => inR(e.date));
    const wasteLog = (sample.wasteLog || []).filter((w) => inR(w.date));
    const timeEntries = (sample.timeEntries || []).filter((e) => inR(e.date));
    const machines = sample.machines || [];
    const now = NOW;
    const r = LP.locationPl({
      orders, expenses, wasteLog, timeEntries, machines, jobs: sample.printLog,
      locations: sample.locations, settings: sample.settings, clients: sample.clients,
      inventory: sample.inventory, now, range,
    });
    assert.ok(r.located);
    const shop = Pnl.pnlByPeriod(orders, expenses, {
      settings: Object.assign({}, sample.settings, { fixedCosts: [] }), clients: sample.clients,
      inventory: sample.inventory, now, granularity: 'month', wasteLog, timeEntries, jobs: sample.printLog,
    });
    for (const k of ['revenue', 'cogs', 'expenses', 'waste', 'labour', 'orders']) {
      assert.ok(Math.abs(cents(sum(r.rows, k)) - cents(sum(shop, k))) <= r.rows.length,
        `${k}: sites ${sum(r.rows, k)} vs shop ${sum(shop, k)}`);
    }
    const today = '2026-10-07';
    const to = range.to < today ? range.to : today;
    const wear = machines.reduce((s, m) => {
      const st = D.settingsOf(m);
      if (!st) return s;
      if (st.method === 'perHour') {
        const out = D.periodCharges([m], sample.printLog, [{ key: 'r', from: range.from, to }], {});
        return s + ((out.r && out.r.byMachine[m.id]) || 0);
      }
      return s + D.periodCharge(m, { from: range.from, to }, {});
    }, 0);
    assert.equal(cents(sum(r.rows, 'depreciation')), cents(wear), 'every machine’s wear, once, on some row');
  });
}
