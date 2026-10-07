'use strict';

/**
 * Logged labour is a P&L line (the shop's decision, 2026-10-07).
 *
 * `store.timeEntries` — hours × the operator's rate, frozen as `cost` when
 * the hours were logged (lib/operators.js) — reaches net as its own "Labour"
 * line, in the period the hours were WORKED, with its job's scope. A book
 * with no time log moves by nothing. See lib/pnl-report.js LABOUR.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
require('../lib/calculator-cost.js');
require('../lib/depreciation.js');
const Pnl = require('../lib/pnl-report.js');
const { computePnl, pnlByPeriod, pnlToCsv, labourCostOf, looksLikePayroll } = Pnl;
const { locationPl } = require('../lib/location-pl.js');
const { machineProfit } = require('../lib/machine-pl.js');

const ROOT = path.join(__dirname, '..');
const NOW = new Date(2026, 9, 7, 12);
const job = (id, extra = {}) => ({ id, status: 'completed', date: '2026-09-10', price: 1000, ...extra });
const month = (rows, key) => rows.find((r) => r.period === key);

test('an hour costs what was frozen when it was logged, else hours × rate; nothing for no hours', () => {
  assert.equal(labourCostOf({ hours: 2, hourlyRate: 50, cost: 90 }), 90, 'the frozen cost wins over today\'s arithmetic');
  assert.equal(labourCostOf({ hours: 2, hourlyRate: 50 }), 100);
  assert.equal(labourCostOf({ hours: 0, cost: 40 }), 0);
  assert.equal(labourCostOf({ hours: -1, cost: 40 }), 0);
  assert.equal(labourCostOf({ hours: 'x', cost: 40 }), 0);
  assert.equal(labourCostOf({ hours: 1, cost: -5 }), 0);
  assert.equal(labourCostOf(null), 0);
});

test('the same hour costs the same in the labour card and the P&L', () => {
  const { timeTracking } = require('../lib/operators.js');
  const entries = [{ operatorId: 'A', hours: 2, hourlyRate: 50, cost: 90, date: '2026-09-01' },
                   { operatorId: 'A', hours: 1.5, hourlyRate: 40, date: '2026-09-02' }];
  const card = timeTracking({ timeEntries: entries, orders: [], operators: [] }, {});
  const pnl = entries.reduce((s, e) => s + labourCostOf(e), 0);
  assert.equal(card.totals.cost, pnl);
});

test('labour lands in the month it was WORKED, comes off net, and is its own line', () => {
  const rows = pnlByPeriod([job('J1')], [], {
    now: NOW, granularity: 'month',
    timeEntries: [{ orderId: 'J1', hours: 2, cost: 100, date: '2026-08-28' },
                  { orderId: 'J1', hours: 1, cost: 30, date: '2026-09-11' }],
  });
  const aug = month(rows, '2026-08'), sep = month(rows, '2026-09');
  assert.equal(aug.labour, 100, 'worked in August, before the job finished in September');
  assert.equal(aug.orders, 0, 'a month with only labour still has a row');
  assert.equal(aug.net, -100);
  assert.equal(sep.labour, 30);
  assert.equal(sep.net, Math.round((sep.revenue - sep.cogs - sep.expenses - sep.fixed - 30) * 100) / 100);
  assert.equal(sep.expenses, 0, 'labour is not folded into expenses');
  assert.equal(sep.cogs, 0, 'nor into cost of goods');
});

test('hours on an open job count: they were paid for when they were worked', () => {
  const rows = pnlByPeriod([job('J1', { status: 'printing' })], [], {
    now: NOW, granularity: 'month', timeEntries: [{ orderId: 'J1', hours: 1, cost: 40, date: '2026-09-11' }],
  });
  assert.equal(month(rows, '2026-09').labour, 40);
});

test('hours logged against no job count — a shift, cleaning, setup', () => {
  const rows = pnlByPeriod([], [], { now: NOW, granularity: 'month',
    timeEntries: [{ hours: 4, cost: 120, date: '2026-09-01' }] });
  assert.equal(month(rows, '2026-09').labour, 120);
});

test('hours on a voided or not-business job leave with the job', () => {
  const orders = [job('V', { voidedAt: '2026-09-12' }), job('T', { nonBusiness: true }), job('OK')];
  const rows = pnlByPeriod(orders, [], { now: NOW, granularity: 'month', timeEntries: [
    { orderId: 'V', hours: 1, cost: 10, date: '2026-09-11' },
    { orderId: 'T', hours: 1, cost: 20, date: '2026-09-11' },
    { orderId: 'OK', hours: 1, cost: 40, date: '2026-09-11' },
  ] });
  assert.equal(month(rows, '2026-09').labour, 40);
});

test('hours on a job no longer in the book, or by a deleted operator, still count', () => {
  const rows = pnlByPeriod([], [], { now: NOW, granularity: 'month', timeEntries: [
    { orderId: 'GONE', operatorId: 'OP-deleted', hours: 1, cost: 25, date: '2026-09-11' },
  ] });
  assert.equal(month(rows, '2026-09').labour, 25);
});

test('a caller with a SLICE of the book still knows a voided job through `jobs`', () => {
  const book = [job('V', { voidedAt: '2026-09-12', date: '2026-01-05' })];
  const entry = { orderId: 'V', hours: 1, cost: 10, date: '2026-09-11' };
  const sliced = pnlByPeriod([], [], { now: NOW, granularity: 'month', timeEntries: [entry] });
  assert.equal(month(sliced, '2026-09').labour, 10, 'without the book the job is unknown, and unknown counts');
  const known = pnlByPeriod([], [], { now: NOW, granularity: 'month', timeEntries: [entry], jobs: book });
  assert.equal(known.length, 0, 'with it, the voided job takes its hour out');
});

test('labour beside pay booked as a cost is flagged, never subtracted', () => {
  const entries = [{ hours: 1, cost: 50, date: '2026-09-11' }];
  const base = { now: NOW, granularity: 'month', timeEntries: entries };
  const wages = pnlByPeriod([], [{ date: '2026-09-02', amount: 900, category: 'Salaries' }], base);
  assert.equal(month(wages, '2026-09').labourOverlap, true, 'a payroll-like expense category');
  assert.equal(month(wages, '2026-09').net, -950, 'both still count — the rule cannot know they are the same money');
  const described = pnlByPeriod([], [{ date: '2026-09-02', amount: 900, category: 'other', description: 'رواتب سبتمبر' }], base);
  assert.equal(month(described, '2026-09').labourOverlap, true, 'an Arabic description says so too');
  const overhead = pnlByPeriod([job('J1')], [], { ...base, settings: { fixedCosts: [{ name: 'Staff wages', amount: 3000 }] } });
  assert.equal(month(overhead, '2026-09').labourOverlap, true, 'a payroll-like fixed cost');
  const rent = pnlByPeriod([job('J1')], [{ date: '2026-09-02', amount: 50, category: 'electricity' }],
    { ...base, settings: { fixedCosts: [{ name: 'Workshop rent', amount: 3000 }] } });
  assert.equal(month(rent, '2026-09').labourOverlap, false);
  const noLabour = pnlByPeriod([], [{ date: '2026-09-02', amount: 900, category: 'Salaries' }], { now: NOW, granularity: 'month' });
  assert.equal(month(noLabour, '2026-09').labourOverlap, false, 'no labour, nothing to overlap');
});

test('payroll words: the shop\'s, not its business', () => {
  for (const w of ['Salaries', 'wages', 'Payroll', 'Staff', 'Labour', 'رواتب', 'أجور الموظفين', 'Gehalt', 'Nómina', 'Maaş'])
    assert.ok(looksLikePayroll(w), w);
  for (const w of ['electricity', 'Workshop rent', 'مصاريف أعمال', 'أجرة شحن', 'Accountant', 'filament', ''])
    assert.ok(!looksLikePayroll(w), w);
});

test('the summary (KPI row, CSV export) takes labour off net and lists it', () => {
  const s = computePnl({ orders: [{ revenue: 1000, cogs: 200 }], expenses: [{ amount: 100, category: 'rent' }],
    labour: [{ hours: 2, cost: 150 }, { hours: 0, cost: 99 }] });
  assert.equal(s.labour, 150);
  assert.equal(s.netProfit, 1000 - 200 - 100 - 150);
  assert.equal(s.labourOverlap, false);
  const csv = pnlToCsv(s, { labels: { labour: 'Labour' } });
  assert.match(csv, /"Labour","-150"/);
  assert.equal(computePnl({ orders: [{ revenue: 1000, cogs: 200 }] }).labour, 0);
  assert.doesNotMatch(pnlToCsv(computePnl({ orders: [{ revenue: 1 }] })), /Labour/);
  assert.equal(computePnl({ orders: [], expenses: [{ amount: 1, category: 'wages' }], labour: [{ hours: 1, cost: 5 }] }).labourOverlap, true);
});

test('a branch carries the labour of its jobs; hours on no job are the shop\'s', () => {
  const machines = [{ id: 'M1', locationId: 'L1' }, { id: 'M2', locationId: 'L2' }];
  const orders = [job('A', { machineId: 'M1' }), job('B', { machineId: 'M2' }), job('V', { machineId: 'M1', voidedAt: 'x' })];
  const report = locationPl({
    orders, machines, locations: [{ id: 'L1' }, { id: 'L2' }], now: NOW,
    timeEntries: [{ orderId: 'A', hours: 1, cost: 70, date: '2026-09-11' },
                  { orderId: 'B', hours: 1, cost: 30, date: '2026-09-11' },
                  { orderId: 'V', hours: 1, cost: 999, date: '2026-09-11' },
                  { hours: 1, cost: 5, date: '2026-09-11' }],
  });
  const by = Object.fromEntries(report.rows.map((r) => [r.locationId, r]));
  assert.equal(by.L1.labour, 70, 'the voided job\'s hour is out');
  assert.equal(by.L2.labour, 30);
  assert.equal(by[''].labour, 5);
  assert.equal(by.L1.costs, Math.round((by.L1.cogs + by.L1.expenses + by.L1.waste + by.L1.depreciation + 70) * 100) / 100);
  assert.equal(by.L1.net, Math.round((by.L1.revenue - by.L1.costs) * 100) / 100);
});

test('a branch finds a stretch of labour\'s job in the WHOLE book when the orders were narrowed', () => {
  const machines = [{ id: 'M1', locationId: 'L1' }];
  const old = job('OLD', { machineId: 'M1', date: '2026-03-01' });
  const report = locationPl({
    orders: [], jobs: [old], machines, locations: [{ id: 'L1' }], now: NOW,
    timeEntries: [{ orderId: 'OLD', hours: 1, cost: 40, date: '2026-09-11' }],
  });
  assert.equal(report.rows.find((r) => r.locationId === 'L1').labour, 40);
});

test('a machine is charged the labour logged on its jobs', () => {
  const { rows, totals } = machineProfit({
    machines: [{ id: 'M1', name: 'U1' }],
    completed: [{ id: 'A', machineId: 'M1', status: 'completed', parts: [] }],
    timeEntries: [{ orderId: 'A', hours: 2, cost: 80 }, { hours: 9, cost: 900 }],
  }, { revenueOf: () => 500, partCostOf: () => 0 });
  assert.equal(rows[0].labour, 80, 'hours on no job are not a machine\'s');
  assert.equal(rows[0].net, 420);
  assert.equal(totals.labour, 80);
  const before = machineProfit({ machines: [{ id: 'M1' }], completed: [{ id: 'A', machineId: 'M1', parts: [] }] },
    { revenueOf: () => 500, partCostOf: () => 0 });
  assert.equal(before.rows[0].labour, 0);
  assert.equal(before.rows[0].net, 500);
});

// ── NOTHING ELSE MOVES ─────────────────────────────────────────────────────

const sample = JSON.parse(fs.readFileSync(path.join(ROOT, 'mac/KhaytCore/Sources/KhaytApp/Resources/sample-shop.json'), 'utf8'));
const ctxOf = (extra) => ({
  settings: sample.settings, clients: sample.clients || [], now: NOW, wasteLog: sample.wasteLog || [],
  inventory: sample.inventory || [], machines: sample.machines || [], ...extra,
});

test('the sample book reaches the labour line, and only labour and net move', () => {
  assert.ok((sample.timeEntries || []).length > 0, 'the sample book logs time');
  for (const granularity of ['quarter', 'month']) {
    const without = pnlByPeriod(sample.printLog, sample.expenses || [], ctxOf({ granularity }));
    const empty = pnlByPeriod(sample.printLog, sample.expenses || [], ctxOf({ granularity, timeEntries: [] }));
    assert.deepEqual(empty, without, 'an empty time log is no time log');
    const withLabour = pnlByPeriod(sample.printLog, sample.expenses || [], ctxOf({ granularity, timeEntries: sample.timeEntries }));
    const total = withLabour.reduce((s, r) => s + r.labour, 0);
    assert.ok(total > 100, `labour reached the P&L (${total})`);
    for (const r of without) {
      const w = withLabour.find((x) => x.period === r.period);
      assert.ok(w, r.period);
      const { net: n1, labour: l1, labourOverlap: o1, ...rest1 } = r;
      const { net: n2, labour: l2, labourOverlap: o2, ...rest2 } = w;
      assert.deepEqual(rest2, rest1, `${granularity} ${r.period}: nothing but labour and net moves`);
      assert.equal(l1, 0);
      assert.equal(Math.round((n1 - n2) * 100), Math.round(l2 * 100), `${r.period}: net falls by exactly the labour`);
    }
  }
});

test('the sample book\'s labour is all of its logged cost on business work', () => {
  const rows = pnlByPeriod(sample.printLog, sample.expenses || [], ctxOf({ granularity: 'month', timeEntries: sample.timeEntries }));
  const byId = new Map(sample.printLog.map((o) => [o.id, o]));
  const expected = sample.timeEntries.filter((e) => Pnl.labourCounts(e, byId)).reduce((s, e) => s + labourCostOf(e), 0);
  assert.equal(Math.round(rows.reduce((s, r) => s + r.labour, 0) * 100), Math.round(expected * 100));
});

// ── THE RATCHET: EVERY CALLER PASSES THE TIME LOG ──────────────────────────
//
// Labour reaches a figure only if the caller hands the rule the time log. A
// new screen that calls `pnlByPeriod`, `computePnl`, `machineProfit` or
// `locationPl` without it would print a net that silently leaves the shop's
// people out — the bug class lib/pnl-report.js was centralised to end.

function callsIn(src, name) {
  const out = [];
  const re = new RegExp(`\\b${name}\\s*\\(`, 'g');
  let m;
  while ((m = re.exec(src))) {
    // Skip definitions, and mentions in comments.
    const lineStart = src.lastIndexOf('\n', m.index) + 1;
    const line = src.slice(lineStart, src.indexOf('\n', m.index));
    if (/^\s*(\/\/|\*|\/\*\*?)/.test(line) || /\bfunc\s|\bfunction\s/.test(line)) continue;
    let depth = 0, i = m.index + m[0].length - 1;
    for (; i < src.length; i++) {
      if (src[i] === '(') depth++;
      else if (src[i] === ')' && --depth === 0) break;
    }
    out.push(src.slice(m.index, i + 1));
  }
  return out;
}

function sources() {
  const walk = (dir, ext) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) return d.name === 'JS' || d.name === '.build' ? [] : walk(p, ext);
    return p.endsWith(ext) ? [p] : [];
  });
  return [
    ...walk(path.join(ROOT, 'lib'), '.js'),
    ...walk(path.join(ROOT, 'renderer'), '.js'),
    ...walk(path.join(ROOT, 'mac/KhaytCore/Sources'), '.swift'),
    ...walk(path.join(ROOT, 'ios'), '.swift'),
  ];
}

// Callers that may leave the time log out, each with the reason.
const EXEMPT = new Map([
  // The phone's pulse reads only `revenue` off the rows; it passes no expenses either.
  ['ios/KhaytCompanion/Services/BookReader.swift', 'reads revenue only'],
  // The engine binding itself: it forwards whatever it is handed.
  ['mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift', 'the binding'],
]);

test('every P&L caller hands the rule the time log', () => {
  const missing = [];
  let seen = 0;
  for (const file of sources()) {
    const rel = path.relative(ROOT, file);
    if (EXEMPT.has(rel)) continue;
    const src = fs.readFileSync(file, 'utf8');
    for (const [name, needs] of [['pnlByPeriod', /timeEntries/], ['computePnl', /labour|pnlInputsForRange\(\)/],
                                 ['machineProfit', /timeEntries/], ['locationPl', /timeEntries/]]) {
      if (rel === 'lib/pnl-report.js' || rel === 'lib/machine-pl.js') continue;
      for (const call of callsIn(src, name)) {
        seen++;
        if (!needs.test(call)) missing.push(`${rel}: ${call.split('\n')[0].trim()}`);
      }
    }
  }
  assert.ok(seen >= 10, `the scan found the callers (${seen})`);
  assert.deepEqual(missing, [], 'these callers leave labour out of a net figure');
});

test('the desktop\'s P&L input builder (KPI row, CSV export) carries the labour', () => {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/analytics.js'), 'utf8');
  const start = src.indexOf('function pnlInputsForRange()');
  const body = src.slice(start, src.indexOf('\n}\n', start));
  assert.match(body, /timeEntries/);
  assert.match(body, /labourCounts/, 'with its job\'s scope');
  assert.match(body, /return \{[^}]*\blabour:/, 'and returns it');
});
