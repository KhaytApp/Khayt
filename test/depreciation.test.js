/**
 * Machine depreciation: the rule, the wear rate a quote is charged, and the
 * one line it adds to the P&L and to a machine's own P&L.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const D = require('../lib/depreciation.js');
const { ratesFor, DEFAULTS } = require('../lib/print-rates.js');
const { computePartBaseCost } = require('../lib/calculator-cost.js');
const ME = require('../lib/machine-edit.js');
const { pnlByPeriod, computePnl, pnlToCsv } = require('../lib/pnl-report.js');
const { machineProfit } = require('../lib/machine-pl.js');

const perHour = (extra) => ({
  id: 'M1', name: 'U1',
  depreciation: Object.assign({ price: 6000, residual: 1000, life: 5000, lifeUnit: 'hours',
                                method: 'perHour', purchaseDate: '2026-01-01' }, extra),
});
const straight = (extra) => ({
  id: 'M2', name: 'X1C',
  depreciation: Object.assign({ price: 5000, residual: 1400, life: 3, lifeUnit: 'years',
                                method: 'straightLine', purchaseDate: '2026-01-01',
                                monthlyHours: 200 }, extra),
});

// ── The rule ────────────────────────────────────────────────────────────────

test('perHour: (price − residual) ÷ life hours', () => {
  assert.equal(D.hourlyRate(perHour()), 1);          // 5000 / 5000
  assert.equal(D.monthlyCharge(perHour()), null);    // follows hours, not the calendar
});

test('straightLine: monthly = (price − residual) ÷ (years × 12), hourly over monthly hours', () => {
  assert.equal(D.monthlyCharge(straight()), 100);    // 3600 / 36
  assert.equal(D.hourlyRate(straight()), 0.5);       // 100 / 200
});

test('straightLine hours a month: the field, then recent actual, then the daily target', () => {
  const noField = straight({ monthlyHours: null });
  assert.equal(D.hourlyRate(noField, { recentMonthlyHours: 50 }), 2);
  assert.equal(D.hourlyRate(Object.assign(noField, { targetHoursPerDay: 10 })),
               Math.round(100 / (10 * 365.25 / 12) * 10000) / 10000);
  // Nothing known: no figure, rather than a guess.
  assert.equal(D.hourlyRate(straight({ monthlyHours: null })), null);
});

test('a life in the other unit converts through hours a month, or is withheld', () => {
  // perHour with a life in years: 2 years × 12 × 100 h = 2400 h.
  const m = perHour({ life: 2, lifeUnit: 'years', monthlyHours: 100 });
  assert.equal(D.hourlyRate(m), Math.round(5000 / 2400 * 10000) / 10000);
  assert.equal(D.hourlyRate(perHour({ life: 2, lifeUnit: 'years' })), null);
  // straightLine with a life in hours: 3600 h at 100 h a month = 36 months.
  const s = straight({ life: 3600, lifeUnit: 'hours', monthlyHours: 100 });
  assert.equal(D.monthlyCharge(s), 100);
});

test('clean: no price is no depreciation; residual is bounded; method follows the unit', () => {
  assert.equal(D.clean({ life: 5000 }), null);
  assert.equal(D.clean({ price: 0 }), null);
  assert.equal(D.clean({ price: 100, residual: 500 }).residual, 100);
  assert.equal(D.clean({ price: 100, residual: -5 }).residual, 0);
  assert.equal(D.clean({ price: 100, life: 2, lifeUnit: 'years' }).method, 'straightLine');
  assert.equal(D.clean({ price: 100, life: 2 }).method, 'perHour');
  assert.equal(D.clean({ price: 100, purchaseDate: '2026-02-31' }).purchaseDate, '');
  assert.equal(D.clean({ price: 100, method: 'nonsense', lifeUnit: 'weeks' }).lifeUnit, 'hours');
});

test('status perHour: book value, to date and hours left', () => {
  const st = D.status(perHour(), { today: '2026-06-01', hoursRun: 1200 });
  assert.equal(st.toDate, 1200);
  assert.equal(st.bookValue, 4800);
  assert.equal(st.remainingHours, 3800);
  assert.equal(st.fullyDepreciated, false);
  assert.equal(st.needs, null);
  // Past its life: never below the residual.
  const old = D.status(perHour(), { today: '2026-06-01', hoursRun: 9000 });
  assert.equal(old.toDate, 5000);
  assert.equal(old.bookValue, 1000);
  assert.equal(old.remainingHours, 0);
  assert.equal(old.fullyDepreciated, true);
});

test('status straightLine: to date by months owned, and what is missing', () => {
  const st = D.status(straight(), { today: '2027-01-01' });   // 365 days
  assert.equal(st.toDate, Math.round(100 * 365 / 30.4375 * 100) / 100);
  assert.equal(st.bookValue, Math.round((5000 - st.toDate) * 100) / 100);
  assert.ok(Math.abs(st.remainingMonths - (36 - 365 / 30.4375)) < 0.1);
  const undated = D.status(straight({ purchaseDate: '' }), { today: '2027-01-01' });
  assert.equal(undated.toDate, null);
  assert.equal(undated.bookValue, null);
  assert.equal(undated.needs, 'purchaseDate');
  const after = D.status(straight(), { today: '2031-01-01' });
  assert.equal(after.bookValue, 1400);
  assert.equal(after.fullyDepreciated, true);
});

test('machineValues counts hours since purchase from finished, unvoided work', () => {
  const orders = [
    { id: 'a', machineId: 'M1', status: 'completed', date: '2026-02-01', printTime: 10 },
    { id: 'b', machineId: 'M1', status: 'delivered', date: '2026-03-01', printTime: 5, actualPrintTime: 6 },
    { id: 'c', machineId: 'M1', status: 'completed', date: '2025-12-01', printTime: 99 }, // before purchase
    { id: 'd', machineId: 'M1', status: 'completed', date: '2026-03-02', printTime: 99, voidedAt: 'x' },
    { id: 'e', machineId: 'M1', status: 'printing', date: '2026-03-02', printTime: 99 },
    { id: 'f', machineId: 'M9', status: 'completed', date: '2026-03-02', printTime: 99 },
  ];
  const out = D.machineValues([perHour(), { id: 'M3', name: 'plain' }], orders, { today: '2026-03-10' });
  assert.deepEqual(Object.keys(out), ['M1']);
  assert.equal(out.M1.hoursRun, 16);
  assert.equal(out.M1.toDate, 16);
  assert.equal(out.M1.recentMonthlyHours, Math.round(16 / 90 * 30.4375 * 100) / 100);
});

// ── Quotes ──────────────────────────────────────────────────────────────────

test('ratesFor: a machine with depreciation replaces the flat wear rate', () => {
  assert.equal(ratesFor({ machine: perHour() }).wearRate, 1);
  assert.equal(ratesFor({ machine: straight() }).wearRate, 0.5);
  // Over the machine's own typed figure and over a preset, as the machine's
  // wear rate already was.
  assert.equal(ratesFor({ machine: Object.assign(perHour(), { wearRate: 3 }),
                         preset: { wearRate: 2 } }).wearRate, 1);
  // straightLine through what the caller says it printed lately.
  assert.equal(ratesFor({ machine: straight({ monthlyHours: null }), recentMonthlyHours: 25 }).wearRate, 4);
  assert.equal(ratesFor({ machine: Object.assign(straight({ monthlyHours: null }), { recentMonthlyHours: 50 }) }).wearRate, 2);
});

test('ratesFor: UNCHANGED when the fields are absent or cannot be worked out', () => {
  assert.deepEqual(ratesFor({ machine: { id: 'x', wearRate: 1.2, powerDraw: 200 } }),
                   Object.assign({}, DEFAULTS, { wearRate: 1.2, powerDraw: 200 }));
  assert.deepEqual(ratesFor({}), Object.assign({}, DEFAULTS));
  // Straight line with no hours a month anywhere: the flat default stands.
  assert.equal(ratesFor({ machine: straight({ monthlyHours: null }) }).wearRate, DEFAULTS.wearRate);
  // A price and nothing else.
  assert.equal(ratesFor({ machine: { id: 'x', depreciation: { price: 3000 } } }).wearRate, DEFAULTS.wearRate);
});

test('a part that carries its own wearRate still wins over the derived one', () => {
  const rates = ratesFor({ machine: perHour() });
  const part = { printTime: 10, wearRate: 0.2 };
  const costed = Object.assign({}, rates, part, { failureRate: 0, laborRate: 0, powerDraw: 0 });
  assert.equal(computePartBaseCost(costed, { inventory: [], settings: {} }), 2);
  const derived = Object.assign({}, rates, { printTime: 10, failureRate: 0, laborRate: 0, powerDraw: 0 });
  assert.equal(computePartBaseCost(derived, { inventory: [], settings: {} }), 10);
});

test('machine-edit writes the cleaned block, and a blank price removes it', () => {
  const m = { id: 'M1', name: 'U1' };
  ME.applyEdit(m, { depreciation: { price: '6000', residual: '1000', life: '5000', lifeUnit: 'hours',
                                    method: 'perHour', purchaseDate: '2026-01-01', monthlyHours: '' } });
  assert.deepEqual(m.depreciation, { price: 6000, purchaseDate: '2026-01-01', life: 5000, lifeUnit: 'hours',
                                     residual: 1000, method: 'perHour', monthlyHours: null });
  ME.applyEdit(m, { name: 'U1 again' });
  assert.ok(m.depreciation, 'an edit that does not send the block leaves it alone');
  ME.applyEdit(m, { depreciation: { price: '' } });
  assert.equal(m.depreciation, undefined);
});

test('wearInCost: the wear inside a frozen part cost, buffer and quantity included', () => {
  assert.equal(D.wearInCost({ printTime: 10, wearRate: 1, failureRate: 10, qty: 2 }), 22);
  assert.equal(D.wearInCost({}), 0);
});

// ── Reports: the ONE place machine wear enters the P&L ──────────────────────

const job = (id, machineId, date, hours, price) => ({
  id, machineId, date, status: 'completed', printTime: hours, price, costBasis: 0,
});

test('periodCharge perHour: rate × hours, never past the life', () => {
  assert.equal(D.periodCharge(perHour(), { hours: 100 }), 100);
  assert.equal(D.periodCharge(perHour(), { hours: 100 }, { hoursBefore: 4950 }), 50);
  assert.equal(D.periodCharge(perHour(), { hours: 100 }, { hoursBefore: 6000 }), 0);
});

test('periodCharge straightLine: pro-rated by the days owned and inside its life', () => {
  const m = straight();
  assert.equal(D.periodCharge(m, { from: '2026-03-01', to: '2026-03-31' }),
               Math.round(100 * 31 / 30.4375 * 100) / 100);
  // Bought mid-period: only the days owned.
  assert.equal(D.periodCharge(straight({ purchaseDate: '2026-03-17' }), { from: '2026-03-01', to: '2026-03-31' }),
               Math.round(100 * 15 / 30.4375 * 100) / 100);
  // Before it was bought, and long after its life.
  assert.equal(D.periodCharge(m, { from: '2025-01-01', to: '2025-12-31' }), 0);
  assert.equal(D.periodCharge(m, { from: '2030-01-01', to: '2030-12-31' }), 0);
  // No purchase date: nothing to pro-rate from.
  assert.equal(D.periodCharge(straight({ purchaseDate: '' }), { from: '2026-03-01', to: '2026-03-31' }), 0);
});

test('pnlByPeriod: perHour depreciation is the rate × hours printed in the month, and in net', () => {
  const orders = [job('a', 'M1', '2026-03-05', 40, 500), job('b', 'M1', '2026-04-05', 10, 100)];
  const base = pnlByPeriod(orders, [], { now: new Date(2026, 4, 15), granularity: 'month' });
  const rows = pnlByPeriod(orders, [], { now: new Date(2026, 4, 15), granularity: 'month', machines: [perHour()] });
  const march = rows.find((r) => r.period === '2026-03');
  const april = rows.find((r) => r.period === '2026-04');
  assert.equal(march.depreciation, 40);
  assert.equal(april.depreciation, 10);
  assert.equal(march.net, base.find((r) => r.period === '2026-03').net - 40);
});

test('pnlByPeriod: straightLine depreciation is the monthly amount, pro-rated in the month running', () => {
  const orders = [job('a', 'M2', '2026-03-05', 40, 500), job('b', 'M2', '2026-05-05', 10, 100)];
  const rows = pnlByPeriod(orders, [], { now: new Date(2026, 4, 15, 12), granularity: 'month', machines: [straight()] });
  assert.equal(rows.find((r) => r.period === '2026-03').depreciation, Math.round(100 * 31 / 30.4375 * 100) / 100);
  assert.equal(rows.find((r) => r.period === '2026-05').depreciation, Math.round(100 * 15 / 30.4375 * 100) / 100);
  const q = pnlByPeriod(orders, [], { now: new Date(2026, 8, 1), machines: [straight()] });
  assert.equal(q.find((r) => r.period === '2026-Q1').depreciation, Math.round(100 * 90 / 30.4375 * 100) / 100);
});

test('pnlByPeriod: no machines, or none with depreciation, is the old report plus a zero', () => {
  const orders = [job('a', 'M1', '2026-03-05', 40, 500)];
  const plain = pnlByPeriod(orders, [], { now: new Date(2026, 4, 15) });
  const withPlain = pnlByPeriod(orders, [], { now: new Date(2026, 4, 15), machines: [{ id: 'M1' }] });
  assert.deepEqual(plain, withPlain);
  assert.equal(plain[0].depreciation, 0);
});

test('computePnl and its CSV carry the depreciation line only when there is one', () => {
  const s = computePnl({ orders: [{ revenue: 1000, cogs: 200 }], expenses: [], depreciation: 50 });
  assert.equal(s.depreciation, 50);
  assert.equal(s.netProfit, 750);
  assert.match(pnlToCsv(s), /Machine depreciation","-50"/);
  const none = computePnl({ orders: [{ revenue: 1000, cogs: 200 }], expenses: [] });
  assert.equal(none.netProfit, 800);
  assert.doesNotMatch(pnlToCsv(none), /depreciation/);
});

test('machine P&L: depreciation per machine, in its net, both methods', () => {
  const machines = [perHour(), straight(), { id: 'M3', name: 'plain' }];
  const completed = [job('a', 'M1', '2026-03-05', 40, 500), job('b', 'M2', '2026-03-06', 10, 300),
                     job('c', 'M3', '2026-03-07', 10, 300)];
  const deps = { revenueOf: (o) => o.price, partCostOf: () => 0 };
  const out = machineProfit({ machines, completed, range: { from: '2026-03-01', to: '2026-03-31' } }, deps);
  const by = Object.fromEntries(out.rows.map((r) => [r.machineId, r]));
  assert.equal(by.M1.depreciation, 40);
  assert.equal(by.M1.net, 460);
  assert.equal(by.M2.depreciation, Math.round(100 * 31 / 30.4375 * 100) / 100);
  assert.equal(by.M3.depreciation, 0);
  assert.equal(by.M3.net, 300);
  assert.equal(out.totals.depreciation, by.M1.depreciation + by.M2.depreciation);
  // No range: a straight-line machine has nothing to pro-rate over.
  const bare = machineProfit({ machines, completed }, deps);
  assert.equal(bare.rows.find((r) => r.machineId === 'M2').depreciation, 0);
});

// ── The machine P&L charges a perHour machine what the shop P&L does ────────
//
// It charged `rate × hours in range` with no `hoursBefore` and no purchase-date
// filter, so a machine already past its life, or a job dated before the
// machine was bought, read 50 in the machine P&L and 0 in the shop's.

const small = (extra) => ({
  id: 'M1', name: 'U1',
  depreciation: Object.assign({ price: 600, residual: 100, life: 100, lifeUnit: 'hours',
                                method: 'perHour', purchaseDate: '2026-01-01' }, extra),
});
const septPnl = (machines, orders) => pnlByPeriod(orders, [], { now: new Date(2026, 8, 30, 12),
  granularity: 'month', machines }).find((r) => r.period === '2026-09').depreciation;
const deps0 = { revenueOf: (o) => o.price, partCostOf: () => 0 };
const sept = { from: '2026-09-01', to: '2026-09-30' };

test('machine P&L perHour: hours already printed count against its life, as in the shop P&L', () => {
  const machines = [small()];
  const orders = [job('old', 'M1', '2026-05-10', 100, 1000), job('sep', 'M1', '2026-09-10', 10, 200)];
  const completed = orders.filter((o) => o.date >= sept.from);
  const shop = septPnl(machines, orders);
  assert.equal(shop, 0);
  const out = machineProfit({ machines, completed, range: sept, orders }, deps0);
  assert.equal(out.rows[0].depreciation, shop);
  // Half-way through its life, the rest of the rate still applies.
  const half = [job('old', 'M1', '2026-05-10', 95, 1000), job('sep', 'M1', '2026-09-10', 10, 200)];
  const halfOut = machineProfit({ machines, completed: half.slice(1), range: sept, orders: half }, deps0);
  assert.equal(halfOut.rows[0].depreciation, septPnl(machines, half));
  assert.equal(halfOut.rows[0].depreciation, 25);
});

test('machine P&L perHour: a job before the purchase date is not charged, as in the shop P&L', () => {
  const machines = [small({ purchaseDate: '2026-09-20' })];
  const orders = [job('early', 'M1', '2026-09-10', 10, 200)];
  const shop = septPnl(machines, orders);
  assert.equal(shop, 0);
  assert.equal(machineProfit({ machines, completed: orders, range: sept, orders }, deps0)
    .rows[0].depreciation, shop);
  // An older caller that passes no book still leaves the pre-purchase job out.
  assert.equal(machineProfit({ machines, completed: orders, range: sept }, deps0)
    .rows[0].depreciation, 0);
  // And one after the purchase date is charged.
  const later = [job('late', 'M1', '2026-09-25', 10, 200)];
  assert.equal(machineProfit({ machines, completed: later, range: sept, orders: later }, deps0)
    .rows[0].depreciation, 50);
});

test('a residual equal to the price derives no wear rate, and the flat one stands', () => {
  // (price − residual) is 0, so the derived rate was 0 and quoted wear as free.
  assert.equal(D.hourlyRate(perHour({ residual: 6000 })), 0);
  assert.equal(ratesFor({ machine: perHour({ residual: 6000 }) }).wearRate, DEFAULTS.wearRate);
  assert.equal(ratesFor({ machine: Object.assign(perHour({ residual: 6000 }), { wearRate: 2 }) }).wearRate, 2);
  assert.equal(ratesFor({ machine: straight({ residual: 5000 }) }).wearRate, DEFAULTS.wearRate);
});

test('periodCharges perHour with no purchase date stops at the machine\'s life', () => {
  // 1000 over 1000 h. 600 h in Q1 and 600 h in Q2 is 1200 h — 200 past the
  // life — and the hours before Q2 were not counted without a purchase date,
  // so Q2 charged its full 600 and the machine was depreciated to 1200.
  const m = { id: 'M9', depreciation: { price: 1000, residual: 0, life: 1000, lifeUnit: 'hours', method: 'perHour' } };
  const orders = [
    { id: 'A', status: 'completed', machineId: 'M9', date: '2026-02-01', printTime: 600 },
    { id: 'B', status: 'completed', machineId: 'M9', date: '2026-05-01', printTime: 600 },
  ];
  const out = D.periodCharges([m], orders, [
    { key: 'Q1', from: '2026-01-01', to: '2026-03-31' },
    { key: 'Q2', from: '2026-04-01', to: '2026-06-30' },
  ]);
  assert.equal(out.Q1.total, 600);
  assert.equal(out.Q2.total, 400);
  assert.equal(out.Q1.total + out.Q2.total, 1000);
});
