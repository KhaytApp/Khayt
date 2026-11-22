'use strict';
/**
 * lib/payment-terms.js — when a customer's invoice falls due.
 *
 * Due = invoice date (the date the invoice prints: `order.date`, else its
 * timestamp) + the customer's `paymentTermsDays`; 0 / absent = due on receipt.
 * Overdue = PAST the due date and not settled.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/payment-terms.js');

test('terms are whole days, and anything unreadable is due on receipt', () => {
  assert.equal(T.termsDays(null), 0);
  assert.equal(T.termsDays({}), 0);
  assert.equal(T.termsDays({ paymentTermsDays: 30 }), 30);
  assert.equal(T.termsDays({ paymentTermsDays: '45' }), 45);
  assert.equal(T.termsDays({ paymentTermsDays: ' 60 ' }), 60);
  assert.equal(T.termsDays({ paymentTermsDays: 30.9 }), 30);
  assert.equal(T.termsDays({ paymentTermsDays: -7 }), 0);
  assert.equal(T.termsDays({ paymentTermsDays: true }), 0, 'Number(true) is 1, and is no agreement');
  assert.equal(T.termsDays({ paymentTermsDays: '0x1e' }), 0, 'Number("0x1e") is 30, and is no agreement');
  assert.equal(T.termsDays({ paymentTermsDays: NaN }), 0);
  assert.equal(T.termsDays({ paymentTermsDays: 1e9 }), T.MAX_DAYS);
  assert.deepEqual(T.PRESETS, [0, 7, 15, 30, 45, 60, 90]);
});

test('the due date is the invoice date plus the terms, across months and years', () => {
  const net30 = { paymentTermsDays: 30 };
  assert.equal(T.dueDate({ date: '2026-09-04' }, net30), '2026-10-04');
  assert.equal(T.dueDate({ date: '2026-12-15' }, net30), '2027-01-14');
  assert.equal(T.dueDate({ date: '2028-02-01' }, { paymentTermsDays: 28 }), '2028-02-29', 'a leap day');
  assert.equal(T.dueDate({ date: '2026-09-04' }, null), '2026-09-04', 'due on receipt');
  assert.equal(T.dueDate({ timestamp: '2026-03-08T10:00:00Z' }, net30), '2026-04-07', 'no date: its timestamp');
  assert.equal(T.dueDate({}, net30), '');
  assert.equal(T.dueDate({ date: '2026-02-30' }, net30), '', 'a day that does not exist is not a date');
});

test('a net-30 customer is not overdue on day one, on the due day, nor until the day after', () => {
  const o = { date: '2026-10-01', status: 'completed' };
  const c = { paymentTermsDays: 30 };
  assert.equal(T.daysPastDue(o, c, '2026-10-02'), -29);
  assert.equal(T.overdue(o, c, '2026-10-02', false), false);
  assert.equal(T.overdue(o, c, '2026-10-31', false), false, 'the due day itself');
  assert.equal(T.overdue(o, c, '2026-11-01', false), true);
  assert.equal(T.overdue(o, c, '2026-11-01', true), false, 'settled is never overdue');
  // Due on receipt: overdue from the next day, as receivables always aged.
  assert.equal(T.overdue(o, null, '2026-10-02', false), true);
});

test('work that cannot owe is never overdue', () => {
  const c = { paymentTermsDays: 7 };
  for (const o of [{ status: 'quote' }, { status: 'cancelled' }, { voidedAt: 'x' }, { creditedAt: 'x' }]) {
    assert.equal(T.overdue(Object.assign({ date: '2020-01-01' }, o), c, '2026-01-01', false), false);
  }
});

test('`today` may be a Date, read as the local day', () => {
  const today = new Date(2026, 10, 1, 23, 30);
  assert.equal(T.daysPastDue({ date: '2026-10-01' }, { paymentTermsDays: 30 }, today), 1);
});

test('receivables ages from the due date: net 30 is not overdue on day one', () => {
  require('../lib/business-scope.js');
  require('../lib/content-languages.js');
  require('../lib/order-money.js');
  require('../lib/order-payment.js');
  const R = require('../lib/receivables.js');
  const clients = [{ id: 'GOV', nameEn: 'Ministry', paymentTermsDays: 30 }, { id: 'WALK', nameEn: 'Walk-in' }];
  const orders = [
    { id: 'A', date: '2026-10-20', price: 100, paidAmount: 0, status: 'completed', clientId: 'GOV' },
    { id: 'B', date: '2026-10-20', price: 100, paidAmount: 0, status: 'completed', clientId: 'WALK' },
    { id: 'C', date: '2026-09-01', price: 100, paidAmount: 0, status: 'completed', clientId: 'GOV' },
  ];
  const out = R.aged(orders, { settings: { currency: 'SAR' }, clients, now: new Date(2026, 9, 30) });
  const row = (id) => out.rows.find((r) => r.id === id);
  assert.equal(row('A').due, '2026-11-19');
  assert.equal(row('A').days, 0);
  assert.equal(row('A').overdue, false);
  assert.equal(row('A').termsDays, 30);
  assert.equal(row('B').due, '2026-10-20');
  assert.equal(row('B').days, 10, 'no terms: aged exactly as before');
  assert.equal(row('B').overdue, true);
  assert.equal(row('C').due, '2026-10-01');
  assert.equal(row('C').days, 29);
  assert.equal(out.total, 300, 'not yet due is still owed');
});

test("payment reminders wait for a customer's terms", () => {
  const PR = require('../lib/payment-reminder.js');
  const settings = { paymentReminder: { enabled: true, graceDays: 0 } };
  const order = { id: 'A', date: '2026-10-01', dueDate: '2026-10-02', status: 'completed', clientId: 'GOV' };
  const now = new Date(2026, 9, 10).getTime();
  const owed = () => 100;
  assert.equal(PR.selectInvoicesDueForReminder([order], settings, owed, now).length, 1,
               "without the customer list: the order's own due date, as before");
  const clients = [{ id: 'GOV', paymentTermsDays: 30 }];
  assert.equal(PR.selectInvoicesDueForReminder([order], settings, owed, now, clients).length, 0,
               'on net 30 it is not due until 31 October');
  const later = new Date(2026, 10, 2).getTime();
  assert.equal(PR.selectInvoicesDueForReminder([order], settings, owed, later, clients).length, 1);
  assert.equal(PR.daysOverdue(order, later, clients[0]), 2);
});
