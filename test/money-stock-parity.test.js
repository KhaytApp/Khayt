'use strict';
// The shared rules the Mac's money, stock and settings screens were given
// (Nov 2026 parity, batch B). Each is the rule the desktop now calls too, so
// these are the behaviour of BOTH apps.
const test = require('node:test');
const assert = require('node:assert/strict');

require('../lib/business-scope.js');
require('../lib/tax.js');
require('../lib/order-money.js');
const ExpenseBook = require('../lib/expense-book.js');
const SpoolEdit = require('../lib/spool-edit.js');
const SettingsEdit = require('../lib/settings-edit.js');
const Loyalty = require('../lib/loyalty.js');
const WasteEntry = require('../lib/waste-entry.js');
const KpiRows = require('../lib/kpi-rows.js');

// ── Recurring expenses ────────────────────────────────────────────────────

const rent = { id: 'EXP-1', date: '2026-10-05', category: 'other', amount: 1150, vatAmount: 150,
  note: 'Rent', recurring: 'monthly', nextDue: '2026-11-05', locationId: 'LOC-1' };

test('Add files a copy with the tax and the location, and moves the schedule on', () => {
  const out = ExpenseBook.comeRound([rent], 'EXP-1', { add: true, id: 'EXP-2', today: '2026-11-07' });
  assert.equal(out.length, 2);
  const [copy, original] = out;
  assert.deepEqual(copy, { id: 'EXP-2', date: '2026-11-07', category: 'other', amount: 1150, note: 'Rent',
    recurring: null, orderId: null, vatAmount: 150, locationId: 'LOC-1' });
  // From where it stood, not from today: a late answer does not drift.
  assert.equal(original.nextDue, '2026-12-05');
  assert.equal(rent.nextDue, '2026-11-05', 'the list handed in is not changed');
});

test('Skip moves the schedule on and files nothing; a cycle already answered is refused', () => {
  const out = ExpenseBook.comeRound([rent], 'EXP-1', { add: false, id: 'X', today: '2026-11-05' });
  assert.equal(out.length, 1);
  assert.equal(out[0].nextDue, '2026-12-05');
  assert.equal(ExpenseBook.comeRound(out, 'EXP-1', { add: true, id: 'X', today: '2026-11-05' }), null);
  assert.equal(ExpenseBook.comeRound([rent], 'nope', { add: true, id: 'X', today: '2026-11-05' }), null);
});

// ── Stock: adjust and transfer ────────────────────────────────────────────

test('an adjustment writes its row first and never takes the weight below zero', () => {
  const spool = { id: 'INV-1', material: 'PLA', weight: 300, adjustments: [{ id: 'ADJ-0', type: 'add', amount: 5 }] };
  const up = SpoolEdit.adjustStock(spool, { type: 'add', amount: '50', reason: ' count ' }, { id: 'ADJ-1', today: '2026-11-05' });
  assert.equal(up.spool.weight, 350);
  assert.deepEqual(up.spool.adjustments[0], { id: 'ADJ-1', date: '2026-11-05', type: 'add', amount: 50, reason: 'count' });
  assert.equal(up.spool.adjustments.length, 2);
  assert.equal(SpoolEdit.adjustStock(spool, { type: 'remove', amount: 900 }, { id: 'A', today: 'd' }).spool.weight, 0);
  assert.deepEqual(SpoolEdit.adjustStock(spool, { amount: 0 }, {}), { refused: 'amount_required' });
});

test('a transfer moves the whole spool, or splits it with a fresh history', () => {
  const spool = { id: 'INV-1', weight: 800, locationId: 'LOC-A', usageHistory: [{ weightUsed: 200 }],
    adjustments: [{ id: 'ADJ' }], priceHistory: [{ cost: 70, date: '2026-01-01' }] };
  const all = SpoolEdit.transferStock(spool, { dest: '', qty: 800 }, { newId: 'INV-2' });
  assert.equal(all.spools.length, 1);
  assert.equal('locationId' in all.spools[0], false, 'Unassigned is no key at all');
  const part = SpoolEdit.transferStock(spool, { dest: 'LOC-B', qty: 300 }, { newId: 'INV-2' });
  assert.equal(part.spools[0].weight, 500);
  assert.equal(part.spools[0].locationId, 'LOC-A');
  assert.equal(part.spools[1].id, 'INV-2');
  assert.equal(part.spools[1].weight, 300);
  assert.equal(part.spools[1].locationId, 'LOC-B');
  assert.deepEqual(part.spools[1].usageHistory, []);
  assert.deepEqual(part.spools[1].adjustments, []);
  assert.notEqual(part.spools[1].priceHistory, spool.priceHistory, 'a copy, not the same array');
  assert.deepEqual(SpoolEdit.transferStock(spool, { dest: 'LOC-A', qty: 1 }, {}), { refused: 'same_location' });
  assert.deepEqual(SpoolEdit.transferStock(spool, { dest: 'LOC-B', qty: 0 }, {}), { refused: 'qty_invalid' });
  assert.deepEqual(SpoolEdit.transferStock(spool, { dest: 'LOC-B', qty: 801 }, {}), { refused: 'qty_over' });
});

// ── Settings sections ─────────────────────────────────────────────────────

test('the invoice counter is set, clamped and reset by its own rule', () => {
  const s = { invNumPrefix: 'INV', invNumNext: 40, invNumFormat: '{prefix}-{year}-{seq4}', invNumYear: 2026, other: 1 };
  const out = SettingsEdit.invoiceNumbering(s, { prefix: '  TAX-INVOICES-2026 ', next: '0', format: 'nonsense' }, { year: 2026 });
  assert.equal(out.invNumPrefix, 'TAX-INVOIC', 'ten characters, the desktop field limit');
  assert.equal(out.invNumNext, 1);
  assert.equal(out.invNumFormat, '{prefix}-{year}-{seq4}', 'an unknown format keeps the stored one');
  assert.equal(out.other, 1);
  assert.equal(SettingsEdit.invoiceNumbering(s, { prefix: '' }, {}).invNumPrefix, 'INV');
  assert.equal(SettingsEdit.invoiceNumbering(s, { next: 57.9, format: '{prefix}-{seq4}' }, {}).invNumNext, 57);
  const reset = SettingsEdit.invoiceNumbering(s, { reset: true }, { year: 2027 });
  assert.equal(reset.invNumNext, 1);
  assert.equal(reset.invNumYear, 2027);
});

test('gaps in the invoice sequence are listed, and two unrelated series are not one gap', () => {
  const orders = [
    { id: 'INV-2026-0001' }, { id: 'X', invoiceNumber: 'INV-2026-0004' }, { id: 'INV-2026-0002' },
    // A LAN-minted id: thirteen digits, which once meant a loop of trillions.
    { id: 'ORD-1767000000000' },
  ];
  assert.deepEqual(SettingsEdit.invoiceNumberGaps(orders), [3]);
  assert.deepEqual(SettingsEdit.invoiceNumberGaps([]), []);
});

test('exchange rates: positive kept, anything else removed, the base never rated', () => {
  const s = { currency: 'SAR', exchangeRates: { USD: 3.75, EUR: 4.1 } };
  const out = SettingsEdit.exchangeRates(s, { USD: '3.7512345', EUR: '', SAR: 1, GBP: 4.8 }, {});
  assert.deepEqual(out.exchangeRates, { USD: 3.7512345, GBP: 4.8 });
  assert.equal(out.exchangeRatesUpdatedAt, undefined);
  const fetched = SettingsEdit.exchangeRates(s, { USD: 3.7512345 }, { fetchedAt: 'Tue, 05 Nov 2026' });
  assert.equal(fetched.exchangeRates.USD, 3.7512);
  assert.equal(fetched.exchangeRatesUpdatedAt, 'Tue, 05 Nov 2026');
});

test('a live feed is inverted to base units per foreign unit, limited to known currencies', () => {
  const body = { result: 'success', time_last_update_utc: 'now', rates: { SAR: 1, USD: 0.2667, EUR: 0.25, XYZ: 9, BAD: 0 } };
  const out = SettingsEdit.ratesFromFeed(body, 'SAR', { USD: {}, EUR: {} });
  assert.deepEqual(Object.keys(out.rates).sort(), ['EUR', 'USD']);
  assert.equal(out.rates.EUR, 4);
  assert.equal(out.updatedAt, 'now');
  assert.deepEqual(SettingsEdit.ratesFromFeed({ result: 'error', 'error-type': 'unsupported-code' }, 'SAR'), { error: 'unsupported-code' });
});

test('loyalty tiers: unnamed rows go, numbers are clamped, other fields ride through', () => {
  const out = Loyalty.cleanTiers([
    { name: ' Gold ', minOrders: '10.7', minSpend: '-5', discountPct: 150, pointsMultiplier: 2 },
    { name: '   ', minOrders: 1 },
    { name: 'Silver', minOrders: '', minSpend: '500', discountPct: '5' },
    null,
  ]);
  assert.deepEqual(out, [
    { name: 'Gold', minOrders: 10, minSpend: 0, discountPct: 100, pointsMultiplier: 2 },
    { name: 'Silver', minOrders: 0, minSpend: 500, discountPct: 5 },
  ]);
});

// ── Waste ─────────────────────────────────────────────────────────────────

test('the jobs that wasted most, and waste against revenue with the desktop colours', () => {
  const log = [
    { orderId: 'A', cost: 10 }, { orderId: 'B', cost: 30 }, { orderId: 'A', cost: 25.555 }, { cost: 99 },
  ];
  assert.deepEqual(WasteEntry.topOrders(log, 5), [
    { orderId: 'A', cost: 35.56, count: 2 }, { orderId: 'B', cost: 30, count: 1 },
  ]);
  assert.equal(WasteEntry.topOrders(log, 1).length, 1);
  assert.equal(WasteEntry.shareOfRevenue(10, 0), null);
  assert.deepEqual(WasteEntry.shareOfRevenue(1, 100), { pct: 1, tone: 'ok' });
  assert.equal(WasteEntry.shareOfRevenue(3, 100).tone, 'warn');
  assert.equal(WasteEntry.shareOfRevenue(6, 100).tone, 'bad');
});

// ── The revenue goal ──────────────────────────────────────────────────────

test('trade revenue leaves out voided, Not business, unfinished and out-of-span jobs, net of VAT', () => {
  const settings = { enableVat: true, vatRate: 15,
    tax: { country: 'SA', name: 'VAT', mode: 'inclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  const orders = [
    { status: 'completed', date: '2026-11-02', price: 1150 },
    { status: 'delivered', date: '2026-11-03', price: 115 },
    { status: 'completed', date: '2026-11-04', price: 575, voidedAt: '2026-11-05' },
    { status: 'completed', date: '2026-11-04', price: 575, nonBusiness: true },
    { status: 'printing', date: '2026-11-04', price: 575 },
    { status: 'cancelled', date: '2026-11-04', price: 575 },
    { status: 'completed', date: '2026-10-31', price: 575 },
  ];
  assert.equal(KpiRows.tradeRevenue({ orders, settings, from: '2026-11-01', to: '2026-11-30' }), 1100);
  assert.equal(KpiRows.tradeRevenue({ orders, settings, from: '', to: '' }), 1600);
  // An exclusive-VAT shop's price IS the net figure.
  const exclusive = { ...settings, tax: { ...settings.tax, mode: 'exclusive' } };
  assert.equal(KpiRows.tradeRevenue({ orders, settings: exclusive, from: '2026-11-01', to: '2026-11-30' }), 1265);
});

test('trade revenue is the KPI tiles’ revenue for the month — one figure, two screens', () => {
  const settings = { enableVat: true, vatRate: 15,
    tax: { country: 'SA', name: 'VAT', mode: 'inclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  const orders = [
    { id: 'a', status: 'completed', date: '2026-11-02', price: 1150 },
    { id: 'b', status: 'completed', date: '2026-11-02', price: 230, voidedAt: 'x' },
    { id: 'c', status: 'delivered', date: '2026-11-09', price: 99.99 },
  ];
  const M = require('../lib/order-money.js');
  const ctx = { settings, clients: [] };
  const rows = KpiRows.kpiRows({ orders, from: '2026-11-01', to: '2026-11-30', settings,
    money: (o) => ({ revenue: M.orderNetRevenueBase(o, ctx) }) });
  const kpi = rows.filter((r) => r.completed).reduce((s, r) => s + r.revenue, 0);
  assert.equal(KpiRows.tradeRevenue({ orders, settings, from: '2026-11-01', to: '2026-11-30' }),
    Math.round(kpi * 100) / 100);
});

test('the goal pace: share, month-end forecast and the change from last month', () => {
  const p = KpiRows.goalPace({ revenue: 1000, previous: 800, goal: 4000, day: 10, days: 30 });
  assert.equal(p.pct, 25);
  assert.equal(p.forecast, 3000);
  assert.equal(p.deltaPct, 25);
  assert.equal(p.reached, false);
  assert.equal(KpiRows.goalPace({ revenue: 1000, goal: 4000, day: 30, days: 30 }).forecast, null, 'the last day');
  assert.equal(KpiRows.goalPace({ revenue: 0, goal: 4000, day: 5, days: 30 }).forecast, null);
  assert.equal(KpiRows.goalPace({ revenue: 1000, previous: 0, goal: 4000, day: 5, days: 30 }).deltaPct, null);
  const over = KpiRows.goalPace({ revenue: 5000, goal: 4000, day: 5, days: 30 });
  assert.equal(over.pct, 100);
  assert.equal(over.reached, true);
});
