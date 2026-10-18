'use strict';
/**
 * Seven money bugs found by one review, each reproduced with node before it
 * was fixed. One test per finding, named for what a shop would have seen.
 *
 *   1. quotes, cancelled jobs, voided and fully credited orders counted as owed
 *   2. a deposit on a tax-on-top shop marked the order paid without its tax
 *   3. the accountant's file exported split parents, voided, cancelled and
 *      not-business orders, and ignored credit notes
 *   4. (Mac-only: the export's currency columns — see AccountingRowsParityTests)
 *   5. a credit note on a tax-on-top shop came off the gross un-taxed
 *   6. an instalment plan listed rows already settled by cash paid outside it
 *   7. splitting a price could hand the last machine a negative share
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/currencies.js');
require('../lib/tax.js');
require('../lib/business-scope.js');
const Money = require('../lib/order-money.js');
const Pay = require('../lib/order-payment.js');
const Receivables = require('../lib/receivables.js');
const Rows = require('../lib/accounting-rows.js');
const { splitMoney } = require('../lib/split-order.js');
const Facts = require('../lib/dashboard-facts.js');
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
const N = require('../lib/order-new.js');

const EXCLUSIVE = {
  currency: 'SAR',
  tax: { name: 'VAT', mode: 'exclusive', rates: [{ id: 'v', label: 'VAT', percent: 10 }] },
};
const NOW = new Date('2026-10-01T12:00:00');

/* ── 1 ──────────────────────────────────────────────────────────────────── */

test('1. a quote, a cancelled job, a voided and a fully credited order owe nothing', () => {
  const owing = [
    { id: 'Q', status: 'quote', price: 100 },
    { id: 'X', status: 'cancelled', price: 100 },
    { id: 'V', status: 'completed', price: 100, voidedAt: '2026-09-01' },
    { id: 'C', status: 'completed', price: 100, creditedAt: '2026-09-01',
      creditNotes: [{ amount: 100 }] },
  ];
  for (const o of owing) {
    assert.equal(Money.orderOwedRaw(o), 0, o.id + ' raw');
    assert.equal(Money.orderOwedBase(o, { settings: {} }), 0, o.id + ' base');
    assert.equal(Money.owesAtAll(o), false, o.id);
  }
  // An ordinary unpaid job still does.
  assert.equal(Money.orderOwedRaw({ id: 'O', status: 'pending', price: 100 }), 100);

  const out = Receivables.aged(owing.concat([{ id: 'O', status: 'pending', price: 100, date: '2026-09-20' }]),
    { settings: {}, now: NOW });
  assert.deepEqual(out.rows.map((r) => r.id), ['O']);
  assert.equal(out.total, 100);
});

test('1. the dashboard strip owes nothing for them either, whatever owedFor says', () => {
  const orders = [
    { id: 'Q', status: 'quote', price: 100 },
    { id: 'X', status: 'cancelled', price: 100 },
    { id: 'V', status: 'completed', price: 100, voidedAt: 'x' },
    { id: 'O', status: 'pending', price: 40 },
  ];
  // A naive owedFor — the guard must not depend on it being the shared rule.
  const facts = Facts.dashboardFacts({
    orders, machines: [], settings: { showMoney: true },
    money: { payStatus: () => 'unpaid', owedFor: (o) => +o.price },
  });
  assert.equal(facts.owed, 40);
});

/* ── 2 ──────────────────────────────────────────────────────────────────── */

const CART = [{ name: 'a', material: 'PLA', baseCost: 100, printTime: 4, qty: 1 }];
const newOrder = (deposit, settings) => N.newOrder(
  { parts: CART, project: 'Job', margin: 0, depositAmount: deposit },
  { settings: Object.assign({}, settings), orders: [], now: NOW, tokens: {} });

test('2. a deposit of the pre-tax price on a tax-on-top shop leaves the tax owed', () => {
  const price = newOrder(0, EXCLUSIVE).price;
  assert.ok(price > 0);
  const o = newOrder(price, EXCLUSIVE);
  assert.equal(o.paidGross, true, 'judged against the gross, and says so');
  assert.equal(o.paidAmount, price);
  assert.equal(o.paymentStatus, 'partial');
  assert.equal(Pay.statusOf(o, { settings: EXCLUSIVE }), 'partial');
  assert.ok(Math.abs(Money.orderOwedRaw(o, { settings: EXCLUSIVE }) - price * 0.1) < 0.011);
});

test('2. a deposit above the bill is clamped to it, and reads paid', () => {
  const price = newOrder(0, EXCLUSIVE).price;
  const gross = Money.orderGrossRaw({ price }, { settings: EXCLUSIVE });
  const o = newOrder(gross + 500, EXCLUSIVE);
  assert.equal(o.paidAmount, +gross.toFixed(2));
  assert.equal(o.paymentStatus, 'paid');
});

test('2. an inclusive shop and a job without a deposit are as they were', () => {
  const price = newOrder(0, {}).price;
  const paid = newOrder(price, {});
  assert.equal(paid.paymentStatus, 'paid');
  assert.equal(paid.paidAmount, price);
  const part = newOrder(10, {});
  assert.equal(part.paymentStatus, 'partial');
  const none = newOrder(0, {});
  assert.equal(none.paymentStatus, 'unpaid');
  assert.equal(none.paidAmount, 0);
  assert.equal('paidGross' in none, false, 'record shape unchanged without a deposit');
});

/* ── 3 ──────────────────────────────────────────────────────────────────── */

test('3. the export skips split parents, voided, cancelled and not-business orders', () => {
  const orders = [
    { id: 'P', status: 'split', price: 300, splitInto: ['P-1', 'P-2'] },
    { id: 'P-1', status: 'completed', price: 150 },
    { id: 'P-2', status: 'completed', price: 150 },
    { id: 'V', status: 'completed', price: 100, voidedAt: '2026-09-01' },
    { id: 'X', status: 'cancelled', price: 100 },
    { id: 'G', status: 'completed', price: 100, nonBusiness: true },
    { id: 'Q', status: 'quote', price: 100 },
    { id: 'C', status: 'completed', price: 100, creditedAt: 'x', creditNotes: [{ amount: 100 }] },
  ];
  const rows = Rows.ordersToInvoiceRows(orders, { tax: { rate: 15, mode: 'inclusive' } });
  assert.deepEqual(rows.map((r) => r.id), ['P-1', 'P-2']);
});

test('3. a credit note nets off the exported price', () => {
  const rows = Rows.ordersToInvoiceRows(
    [{ id: 'A', status: 'completed', price: 115, creditNotes: [{ amount: 15 }, { amount: '5' }] }],
    { tax: { rate: 15, mode: 'inclusive' }, toBase: (a) => a * 2 });
  assert.equal(rows[0].price, 95);
  assert.equal(rows[0].baseAmount, 190);
});

/* ── 5 ──────────────────────────────────────────────────────────────────── */

test('5. a credit note on a tax-on-top shop comes off with its tax', () => {
  const ctx = { settings: EXCLUSIVE };
  const o = { id: 'E', status: 'completed', price: 100, creditNotes: [{ amount: 50 }] };
  assert.equal(Money.orderOwedRaw(o, ctx), 55);
  assert.equal(Money.orderOwedBase(o, ctx), 55);
  assert.equal(Pay.cashDue(o, ctx).cash, 55);
  assert.equal(Pay.statusOf(Object.assign({}, o, { paidAmount: 55, paidGross: true }), ctx), 'paid');
  // Inclusive: the credit is already in the price's terms.
  assert.equal(Money.orderOwedRaw(o, { settings: {} }), 50);
  // Credited in full: nothing owed, whatever the arithmetic.
  assert.equal(Money.orderOwedRaw(Object.assign({}, o, { creditedAt: 'x' }), ctx), 0);
});

/* ── 6 ──────────────────────────────────────────────────────────────────── */

test('6. cash paid outside a plan settles its oldest rows first', () => {
  const o = {
    id: 'I', status: 'completed', price: 300, paidAmount: 150, date: '2026-06-01',
    instalments: [
      { amount: 100, dueDate: '2026-07-01', paid: false },
      { amount: 100, dueDate: '2026-08-01', paid: false },
      { amount: 100, dueDate: '2026-09-01', paid: false },
    ],
  };
  const out = Receivables.aged([o], { settings: {}, now: NOW });
  assert.equal(out.total, 150);
  assert.deepEqual(out.rows.map((r) => r.owed).sort(), [100, 50]);
  // The July row is gone, the August row is half paid.
  assert.equal(out.rows.find((r) => r.owed === 50).days, daysSince('2026-08-01'));

  const settled = Receivables.aged([Object.assign({}, o, { paidAmount: 300 })], { settings: {}, now: NOW });
  assert.equal(settled.rows.length, 0);
  assert.equal(settled.total, 0);
});

function daysSince(ymd) { return Receivables.daysSince(ymd, NOW); }

/* ── 7 ──────────────────────────────────────────────────────────────────── */

test('7. no share of a split is ever negative, and the shares add back up', () => {
  const shares = splitMoney({ price: 100.01, paid: 100.01, costs: [1, 1, 1, 0.0001] });
  for (const s of shares) {
    assert.ok(s.price >= 0, JSON.stringify(shares));
    assert.ok(s.paidAmount >= 0);
  }
  const sum = (k) => Math.round(shares.reduce((t, s) => t + s[k], 0) * 100) / 100;
  assert.equal(sum('price'), 100.01);
  assert.equal(sum('paidAmount'), 100.01);

  const third = splitMoney({ price: 1000.03, costs: [1, 1, 1] });
  assert.equal(Math.round(third.reduce((t, s) => t + s.price, 0) * 100) / 100, 1000.03);
  assert.ok(third.every((s) => s.price >= 333.34 - 0.011 && s.price <= 333.35));

  // Weighted: the remainder lands where the rounding lost most.
  const w = splitMoney({ price: 10, costs: [1, 2] });
  assert.deepEqual(w.map((s) => s.price), [3.33, 6.67]);
  // Even split when nothing is costed.
  assert.deepEqual(splitMoney({ price: 1, costs: [0, 0, 0] }).map((s) => s.price), [0.34, 0.33, 0.33]);
});
