'use strict';
/**
 * lib/location-pl.js — the shop's P&L, split by site.
 *
 * Three kinds of test. The differential cases run the desktop's
 * `renderLocationPL` as it stood before the lift, verbatim, against the
 * rewired one, on books where the lift was meant to change nothing. The bug
 * tests are each named for what the original got wrong. And the invariant:
 * the sites add up to the shop, because they ARE the shop's P&L in piles.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
require('../lib/calculator-cost.js');
require('../lib/order-status.js');
const { pnlByPeriod } = require('../lib/pnl-report.js');
const LP = require('../lib/location-pl.js');

const NOW = new Date(2026, 8, 30);
const SAR = { currency: 'SAR' };
const MAIN = { id: 'LOC-main', name: 'Main', address: '' };
const SITE2 = { id: 'LOC-two', name: 'Site 2', address: '' };
const machines = [
  { id: 'm1', name: 'U1', locationId: 'LOC-main' },
  { id: 'm2', name: 'CORE One', locationId: 'LOC-two' },
  { id: 'm3', name: 'Laser', locationId: '' },
];
const job = (id, machineId, price, extra = {}) =>
  ({ id, status: 'completed', date: '2026-09-10', price, machineId, ...extra });

function run(book) {
  return LP.locationPl({ locations: [MAIN, SITE2], machines, settings: SAR, now: NOW, ...book });
}
const row = (r, id) => r.rows.find((x) => x.locationId === id);

// ── THE ORIGINAL, VERBATIM ───────────────────────────────────────────────
//
// renderer/analytics.js renderLocationPL before its arithmetic moved to
// lib/location-pl.js.
const ORIGINAL = `
function renderLocationPL() {
  const container = document.getElementById('locationPlChart');
  if (!container) return;

  if (!locations.length) {
    container.innerHTML = \`<p style="color:var(--text-muted);font-size:13px;padding:12px 0;">\${t('an.no_locations')}</p>\`;
    return;
  }

  // Map machineId → locationId and machineName → locationId
  const machLocById  = {};
  const machLocByName = {};
  machines.forEach(m => {
    if (m.locationId) { machLocById[m.id] = m.locationId; machLocByName[m.name] = m.locationId; }
  });

  const locTotals = {}; // locationId | '__none__' → { revenue, matCost, expenses, waste, orders }
  const getD = id => { if (!locTotals[id]) locTotals[id] = { revenue: 0, matCost: 0, expenses: 0, waste: 0, orders: 0 }; return locTotals[id]; };

  // Orders
  printLog.filter(o => KhaytOrderStatus.isFinished(o) && !o.voidedAt && _countsForBusiness(o) && inRange(o.date || (o.timestamp || '').slice(0,10), analyticsRange, 'analytics')).forEach(o => {
    const lid = (o.machineId && machLocById[o.machineId]) || (o.machine && machLocByName[o.machine]) || '__none__';
    const d = getD(lid);
    d.revenue += orderNetRevenueBase(o);
    d.orders++;
    (o.parts || []).forEach(p => { d.matCost += (typeof partTotalCost === 'function' ? (partTotalCost(p) || 0) : 0); });
  });

  // Expenses
  // Filament bought is stock: it reaches a location's figures as its jobs'
  // material cost (matCost above), not again as an expense (lib/pnl-report.js).
  expenses.filter(e => inRange(e.date, analyticsRange, 'analytics') && !KhaytPnl.isInventoryPurchase(e)).forEach(e => {
    getD(e.locationId || '__none__').expenses += +e.amount || 0;
  });
  // Filament lost to failed prints, at the location of the machine it failed on.
  (typeof wasteLog !== 'undefined' ? wasteLog : []).filter(w => w && inRange(w.date, analyticsRange, 'analytics')).forEach(w => {
    getD((w.machineId && machLocById[w.machineId]) || '__none__').waste += Math.max(0, +w.cost || 0);
  });

  // Build rows
  const nameMap = { '__none__': t('an.unassigned_location') };
  locations.forEach(l => { nameMap[l.id] = l.name; });

  const rows = Object.entries(locTotals)
    .map(([lid, d]) => ({ lid, name: nameMap[lid] || lid, ...d, net: d.revenue - d.matCost - d.expenses - d.waste }))
    .sort((a, b) => b.revenue - a.revenue);

  if (!rows.length) {
    container.innerHTML = \`<p style="color:var(--text-muted);font-size:13px;padding:12px 0;">\${t('an.no_data')}</p>\`;
    return;
  }

  const cur = currencySymbol();
  const maxRev = Math.max(...rows.map(r => r.revenue), 1);
  const tableRows = rows.map(r => {
    const margin = r.revenue > 0 ? (r.net / r.revenue * 100).toFixed(1) + '%' : '—';
    return [r.name, r.orders, cur + fmtMoney(r.revenue), cur + fmtMoney(r.matCost + r.expenses + r.waste), cur + fmtMoney(r.net), margin].join('|');
  }).join('\\n');
  container.innerHTML = tableRows;
}`;

// The rewired renderer's table, read back as the same "|"-joined lines the
// original above was trimmed to print. Only the figures are compared: the
// chart's SVG is unchanged and is not what the lift touched.
function readTable(html) {
  const rows = [...html.matchAll(/<tr>([\s\S]*?)<\/tr>/g)].map((m) =>
    [...m[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)]
      .map((c) => c[1].replace(/<[^>]+>/g, '').trim()).join('|'));
  return rows.join('\n');
}

let dom;
beforeEach(() => { dom = require('./helpers/dom.js').setupDom(); });
afterEach(() => { dom.teardown(); });

function stage(book) {
  dom.loadI18n();
  require('../renderer/format.js');
  require('../renderer/currency.js');
  require('../renderer/app-helpers.js');
  require('../lib/expense-categories.js');
  require('../lib/order-deduction.js');
  require('../renderer/expenses.js');
  require('../renderer/dashboard.js');
  dom.seedState({ settings: { ...SAR, fixedCosts: [] }, ...book });
  return require('../renderer/analytics.js');
}

const SAME = {
  'two sites and an unassigned machine, jobs and expenses at each': {
    locations: [MAIN, SITE2], machines,
    printLog: [job('a', 'm1', 900), job('b', 'm2', 400), job('c', 'm3', 100),
      job('d', null, 50, { machine: 'U1' })],
    expenses: [{ id: 'e1', date: '2026-09-02', amount: 120, category: 'Rent', locationId: 'LOC-main' },
      { id: 'e2', date: '2026-09-03', amount: 40, category: 'Power', locationId: 'LOC-two' }],
    wasteLog: [{ id: 'w1', date: '2026-09-04', cost: 12.5, machineId: 'm2' }],
  },
  'voided, unfinished and out-of-trade jobs count nowhere': {
    locations: [MAIN, SITE2], machines,
    printLog: [job('a', 'm1', 900), job('b', 'm2', 400, { voidedAt: '2026-09-11' }),
      job('c', 'm2', 300, { status: 'printing' }), job('d', 'm2', 200, { nonBusiness: true }),
      job('e', 'm2', 150, { status: 'delivered' })],
  },
};

for (const [name, book] of Object.entries(SAME)) {
  test(`location P&L lift prints what the original printed: ${name}`, () => {
    const api = stage(book);
    // analytics.js's own module-scoped helper, which the original read.
    global._countsForBusiness = (o) => KhaytBusinessScope.countsForBusiness(o);
    const original = vm.runInThisContext('(' + ORIGINAL + ')');
    original();
    const a = $('#locationPlChart').innerHTML;
    api.renderLocationPL();
    const b = readTable($('#locationPlChart').innerHTML);
    assert.ok(a.includes('|'), 'the original drew a table: ' + a);
    assert.equal(b, a);
  });
}

// ── WHAT THE ORIGINAL GOT WRONG ─────────────────────────────────────────

// 100 g of a 20-a-kilo spool = 2.00 material; the rest is pricing estimates.
const part = { spoolCost: 20, spoolWeight: 1000, printWeight: 100, printTime: 2, wearRate: 0.5,
  powerDraw: 200, elecRate: 0.2, prepTime: 0.5, laborRate: 10, failureRate: 10, qty: 1 };
const whole = (2 + 1 + 0.08 + 5) * 1.1;

test('a job costs its site what it costs the shop: the stocked share of its frozen cost', () => {
  const frozen = 44.44;
  const o = job('a', 'm1', 100, { costBasis: frozen, parts: [{ ...part, baseCost: whole }] });
  const r = run({ orders: [o] });
  const [shop] = pnlByPeriod([o], [], { settings: SAR, now: NOW });
  assert.equal(row(r, 'LOC-main').cogs, shop.cogs);
  assert.equal(shop.cogs, Math.round(frozen * (2 / whole) * 100) / 100,
    'not partTotalCost — power, wear and labour are the bills, not the job');
});

test('the tax a registered shop reclaims on a purchase is not a site’s cost', () => {
  const r = run({
    settings: { currency: 'SAR', enableVat: true, vatRate: 15 },
    expenses: [{ id: 'e', date: '2026-09-02', amount: 230, vatAmount: 30, category: 'Tools', locationId: 'LOC-two' }],
  });
  assert.equal(row(r, 'LOC-two').expenses, 200);
});

test('a job’s own location wins over its machine’s', () => {
  const r = run({ orders: [job('a', 'm1', 500, { locationId: 'LOC-two' })] });
  assert.equal(row(r, 'LOC-two').revenue, 500);
  assert.equal(row(r, 'LOC-main').revenue, 0);
});

test('an id that names no location is unassigned, not a branch called LOC-…', () => {
  const r = run({
    machines: [...machines, { id: 'm4', name: 'Old', locationId: 'LOC-gone' }],
    orders: [job('a', 'm4', 70)],
    expenses: [{ id: 'e', date: '2026-09-02', amount: 10, category: 'X', locationId: 'LOC-gone' }],
  });
  assert.ok(!r.rows.some((x) => x.locationId === 'LOC-gone'));
  assert.equal(row(r, LP.UNASSIGNED).revenue, 70);
  assert.equal(row(r, LP.UNASSIGNED).expenses, 10);
});

test('waste on a job with no machine goes to the job’s site', () => {
  const r = run({
    orders: [job('a', 'm2', 100)],
    wasteLog: [{ id: 'w', date: '2026-09-04', cost: 9, orderId: 'a', machineId: null }],
  });
  assert.equal(row(r, 'LOC-two').waste, 9);
});

test('a site that earned nothing is a row of zeros, not missing', () => {
  const r = run({ orders: [job('a', 'm1', 100)] });
  const two = row(r, 'LOC-two');
  assert.ok(two, 'Site 2 is a site whether or not it sold anything');
  assert.equal(two.revenue, 0);
  assert.equal(two.marginPct, null, 'no margin where nothing was billed — not 0%');
  assert.equal(r.rows.at(-1).locationId, 'LOC-two', 'below the site that sold');
  assert.ok(!row(r, LP.UNASSIGNED), 'and an empty unassigned row is not drawn');
});

test('a machine’s depreciation is charged to its site', () => {
  const dep = { ...machines[1], depreciation: { price: 3600, life: 10, lifeUnit: 'years', purchaseDate: '2025-01-01' } };
  const r = run({ machines: [machines[0], dep], orders: [job('b', 'm2', 400)] });
  const [shop] = pnlByPeriod([job('b', 'm2', 400)], [], { settings: SAR, now: NOW, machines: [dep], granularity: 'month' });
  assert.ok(shop.depreciation > 0, 'the fixture depreciates');
  assert.equal(row(r, 'LOC-two').depreciation, shop.depreciation);
  assert.equal(row(r, 'LOC-main').depreciation, 0, 'and not at the other site');
});

test('the sites add up to the shop', () => {
  const orders = [
    job('a', 'm1', 900, { costBasis: 120 }), job('b', 'm2', 400, { costBasis: 60 }),
    job('c', 'm3', 100, { costBasis: 10 }), job('d', 'm1', 300, { status: 'delivered', costBasis: 50 }),
    job('e', 'm2', 1000, { voidedAt: '2026-09-12', costBasis: 1 }),
    job('f', 'm2', 250, { date: '2026-08-02', costBasis: 20, locationId: 'LOC-main' }),
  ];
  const expenses = [
    { id: 'e1', date: '2026-09-02', amount: 120, category: 'Rent', locationId: 'LOC-main' },
    { id: 'e2', date: '2026-08-03', amount: 40, category: 'Power', locationId: 'LOC-two' },
    { id: 'e3', date: '2026-09-05', amount: 75, category: 'Tools' },
    { id: 'e4', date: '2026-09-06', amount: 500, category: 'filament', locationId: 'LOC-two' },
  ];
  const wasteLog = [{ id: 'w1', date: '2026-09-04', cost: 12.5, machineId: 'm2' },
    { id: 'w2', date: '2026-09-05', cost: 3, machineId: 'm3' }];
  const r = run({ orders, expenses, wasteLog });
  const shop = pnlByPeriod(orders, expenses, { settings: SAR, now: NOW, wasteLog, granularity: 'month' });
  const total = (rows, k) => Math.round(rows.reduce((s, x) => s + x[k], 0) * 100) / 100;
  for (const k of ['orders', 'revenue', 'cogs', 'expenses', 'waste']) {
    assert.equal(total(r.rows, k), total(shop, k), k);
  }
});

test('a book with no locations draws no report', () => {
  assert.deepEqual(LP.locationPl({ locations: [], orders: [job('a', 'm1', 1)] }), { rows: [], located: false });
});

test('inRange narrows the jobs, the expenses and the waste alike', () => {
  const r = run({
    orders: [job('a', 'm1', 100), job('b', 'm1', 999, { date: '2026-07-01' })],
    expenses: [{ id: 'e', date: '2026-07-02', amount: 50, category: 'X', locationId: 'LOC-main' }],
    wasteLog: [{ id: 'w', date: '2026-07-03', cost: 5, machineId: 'm1' }],
    inRange: (d) => d >= '2026-09-01',
  });
  const main = row(r, 'LOC-main');
  assert.deepEqual([main.revenue, main.expenses, main.waste], [100, 0, 0]);
});

// ── A DELETE CLEARS WHAT POINTED AT IT ───────────────────────────────────

test('deleting a location clears machines, spools, expenses and jobs that named it', () => {
  const book = {
    machines: [{ id: 'm1', locationId: 'LOC-two' }, { id: 'm2', locationId: 'LOC-main' }],
    inventory: [{ id: 's1', locationId: 'LOC-two' }],
    expenses: [{ id: 'e1', locationId: 'LOC-two' }],
    printLog: [{ id: 'o1', locationId: 'LOC-two' }, { id: 'o2' }],
  };
  const changed = LP.unpoint(book, 'LOC-two');
  assert.deepEqual(changed.map((c) => c.collection + ':' + c.id).sort(),
    ['expenses:e1', 'inventory:s1', 'machines:m1', 'printLog:o1']);
  assert.equal(book.machines[0].locationId, '');
  assert.equal(book.machines[1].locationId, 'LOC-main', 'another site is untouched');
  assert.equal(book.printLog[1].locationId, undefined, 'a job that named nothing is not given a field');
});

test('the desktop delete clears them too', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'wire-events.js'), 'utf8');
  const at = src.indexOf("btn.dataset.act === 'del-loc'");
  assert.ok(at > 0);
  assert.match(src.slice(at, at + 1200), /KhaytLocationPl\.unpoint\(/);
});
