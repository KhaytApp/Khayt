'use strict';
/**
 * lib/simple-screens.js — the figures behind Simple's reduced Loyalty,
 * Expenses and Money screens (S4 cards 3–5).
 */
const test = require('node:test');
const assert = require('node:assert');

// The sibling modules assign their globals when required, as the renderer's
// script tags do.
for (const m of ['tax', 'currencies', 'order-status', 'business-scope', 'order-money', 'order-payment', 'payment-terms',
  'receivables', 'content-languages', 'top-lists', 'pnl-report', 'vat-periods', 'vat-return', 'expense-book', 'loyalty']) {
  require(`../lib/${m}.js`);
}
const S = require('../lib/simple-screens.js');

/* ── Loyalty ── */

test('loyaltyView: rows in saved order; three is the most Simple adds', () => {
  const tiers = [{ name: 'Regular', minOrders: 3, discountPct: 5 }, { name: 'Silver', minOrders: 10, discountPct: 8 }];
  const v = S.loyaltyView(tiers);
  assert.deepStrictEqual(v.rows.map((r) => [r.name, r.minOrders, r.discountPct, r.readOnly]), [['Regular', 3, 5, false], ['Silver', 10, 8, false]]);
  assert.strictEqual(v.canAdd, true);
  assert.strictEqual(S.loyaltyView([...tiers, { name: 'Gold', minOrders: 25, discountPct: 12 }]).canAdd, false);
  assert.strictEqual(S.loyaltyView(null).count, 0);
});

test('a tier Professional gave a spend bar or a multiplier is read-only and never dropped', () => {
  const tiers = [{ name: 'VIP', minOrders: 0, minSpend: 5000, discountPct: 10 }, { name: 'Pts', minOrders: 5, discountPct: 0, pointsMultiplier: 2 }, { name: 'Plain', minOrders: 2, discountPct: 3, pointsMultiplier: 1 }];
  assert.deepStrictEqual(S.loyaltyView(tiers).rows.map((r) => r.readOnly), [true, true, false]);
  assert.deepStrictEqual(S.editTier(tiers, 0, { name: 'X', minOrders: 9 }), tiers, 'edit refused');
  assert.deepStrictEqual(S.removeTier(tiers, 1), tiers, 'remove refused');
  assert.strictEqual(S.removeTier(tiers, 2).length, 2);
});

test('editTier keeps what Simple does not show, clamps, and never empties a name', () => {
  const tiers = [{ name: 'Gold', minOrders: 25, discountPct: 12, minSpend: 0, colour: '#fc0' }];
  const out = S.editTier(tiers, 0, { name: '  ', minOrders: '7.8', discountPct: '140' });
  assert.deepStrictEqual(out[0], { name: 'Gold', minOrders: 7, discountPct: 100, minSpend: 0, colour: '#fc0' });
  assert.notStrictEqual(out, tiers, 'a new array');
  assert.strictEqual(tiers[0].minOrders, 25, 'the input is untouched');
  assert.strictEqual(S.editTier(tiers, 0, { name: 'Platinum' })[0].name, 'Platinum');
});

test('addTier: one bar past the highest, nothing past three; the result survives cleanTiers', () => {
  let tiers = S.addTier([], 'Tier 1');
  assert.deepStrictEqual(tiers, [{ name: 'Tier 1', minOrders: 3, minSpend: 0, discountPct: 0 }]);
  tiers = S.addTier(tiers, 'Tier 2');
  assert.strictEqual(tiers[1].minOrders, 8);
  tiers = S.addTier(S.addTier(tiers, 'Tier 3'), 'Tier 4');
  assert.strictEqual(tiers.length, 3);
  assert.strictEqual(globalThis.KhaytLoyalty.cleanTiers(tiers).length, 3);
});

/* ── Expenses ── */

test('expensesThisMonth: this month only, newest first, totalled', () => {
  const v = S.expensesThisMonth([
    { id: 'a', date: '2026-11-09', amount: 640, category: 'filament' },
    { id: 'b', date: '2026-11-01', amount: 1500, category: 'other' },
    { id: 'c', date: '2026-10-28', amount: 270, category: 'maintenance' },
    { id: 'd', date: '2026-11-11', amount: '270', category: 'tools' },
    null,
  ], '2026-11-12');
  assert.deepStrictEqual(v.rows.map((e) => e.id), ['d', 'a', 'b']);
  assert.strictEqual(v.total, 2410);
  assert.strictEqual(v.count, 3);
  assert.strictEqual(v.month, '2026-11');
});

/* ── Money ── */

const clients = [{ id: 'C1', nameEn: 'Najd Architects' }, { id: 'C2', nameEn: 'Red Sea Global' }];
const order = (o) => ({ parts: [], paidAmount: 0, ...o });
const book = {
  clients,
  products: [{ id: 'P1', nameEn: 'Bracket' }],
  orders: [
    // Finished this month, paid: earned.
    order({ id: 'O1', clientId: 'C2', status: 'completed', date: '2026-11-03', price: 1150, paidAmount: 1150, paymentStatus: 'paid', productId: 'P1' }),
    // Finished this month, unpaid and past due (no terms = due on the day).
    order({ id: 'O2', clientId: 'C1', status: 'completed', date: '2026-11-05', price: 230, productId: 'P1' }),
    // Finished in March: this year, not this month.
    order({ id: 'O3', clientId: 'C2', status: 'completed', date: '2026-03-10', price: 2300, paidAmount: 2300, paymentStatus: 'paid' }),
    // Voided: nothing.
    order({ id: 'O4', clientId: 'C1', status: 'completed', date: '2026-11-06', price: 9999, voidedAt: '2026-11-07' }),
    // A quote: not owed.
    order({ id: 'O5', clientId: 'C1', status: 'quote', date: '2026-11-08', price: 500 }),
  ],
  expenses: [
    { id: 'E1', date: '2026-11-09', amount: 640, vatAmount: 0 },
    { id: 'E2', date: '2026-10-02', amount: 115, vatAmount: 15 },
  ],
};
const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
const ctx = { settings, today: '2026-11-12', now: new Date(2026, 10, 12), language: 'en' };

test('moneySummary: earned this month is net of tax and counts finished jobs only', () => {
  const m = S.moneySummary(book, ctx);
  assert.strictEqual(m.month, '2026-11');
  assert.strictEqual(m.earned.jobs, 2);
  assert.ok(Math.abs(m.earned.total - 1200) < 0.01, `1,380 charged incl. 15% = 1,200 earned (${m.earned.total})`);
});

test('moneySummary: owed is gross, overdue counted, who owes summed per customer', () => {
  const m = S.moneySummary(book, ctx);
  assert.ok(Math.abs(m.owed.total - 230) < 0.01, String(m.owed.total));
  assert.strictEqual(m.owed.overdue, 1);
  assert.deepStrictEqual(m.whoOwes.map((r) => [r.clientId, r.name, Math.round(r.owed)]), [['C1', 'Najd Architects', 230]]);
});

test('moneySummary: spent this month; best customers this year; top products this month', () => {
  const m = S.moneySummary(book, ctx);
  assert.deepStrictEqual(m.spent, { total: 640, count: 1 });
  assert.deepStrictEqual(m.bestCustomers.map((r) => r.clientId), ['C2', 'C1']);
  assert.strictEqual(m.topProducts[0].productId, 'P1');
  assert.strictEqual(m.topProducts[0].count, 2);
});

test('moneySummary: VAT due for the quarter holding today, with the Saudi deadline', () => {
  const m = S.moneySummary(book, ctx);
  assert.ok(m.vat, 'a registered shop gets the line');
  assert.strictEqual(m.vat.period, '2026-Q4');
  assert.strictEqual(m.vat.deadline, '2027-01-31');
  // Output on O1 + O2 (1,380 incl. 15% → 180) less input on E2 (Oct, 15) = 165.
  assert.ok(Math.abs(m.vat.due - 165) < 0.01, String(m.vat.due));
  const monthly = S.moneySummary(book, { ...ctx, settings: { ...settings, vatFilingFrequency: 'monthly' } });
  assert.strictEqual(monthly.vat.period, '2026-11');
  assert.strictEqual(monthly.vat.deadline, '2026-12-31');
});

test('moneySummary: a shop that is not registered gets no VAT line', () => {
  const m = S.moneySummary(book, { ...ctx, settings: { currency: 'SAR', enableVat: false } });
  assert.strictEqual(m.vat, null);
});

test('saudiFilingDeadline: the last day of the month after the period', () => {
  assert.strictEqual(S.saudiFilingDeadline('2026-12-31'), '2027-01-31');
  assert.strictEqual(S.saudiFilingDeadline('2027-01-31'), '2027-02-28');
  assert.strictEqual(S.saudiFilingDeadline(''), '');
});
