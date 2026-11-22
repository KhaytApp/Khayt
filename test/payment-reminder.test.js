'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/payment-reminder.js');

const NOW = new Date('2026-06-20T12:00:00').getTime();
const owed = (o) => (o._owed != null ? o._owed : 100);

test('selects overdue unpaid invoices past the grace period', () => {
  const orders = [
    { id: 'A', status: 'completed', dueDate: '2026-06-10', _owed: 100 }, // 10d overdue → due
    { id: 'B', status: 'completed', dueDate: '2026-06-19', _owed: 100 }, // 1d overdue < grace(3) → no
    { id: 'C', status: 'completed', dueDate: '2026-06-01', _owed: 0 },   // paid → no
    { id: 'D', status: 'quote', dueDate: '2026-01-01', _owed: 100 },     // quote → no
    { id: 'E', status: 'completed', dueDate: '2026-06-01', voidedAt: 'x', _owed: 100 }, // void → no
  ];
  const due = R.selectInvoicesDueForReminder(orders, { paymentReminder: { enabled: true } }, owed, NOW);
  assert.deepEqual(due.map((o) => o.id), ['A']);
});

test('cooldown + max count gate repeats', () => {
  const cfg = R.reminderConfig({ paymentReminder: { cooldownDays: 3, maxCount: 2 } });
  const base = { id: 'A', status: 'completed', dueDate: '2026-06-10' };
  // reminded today → within cooldown → not due
  assert.equal(R.isDueForReminder({ ...base, payRemindedAt: '2026-06-20T08:00:00' }, 100, cfg, NOW), false);
  // reminded 4 days ago → cooldown elapsed → due
  assert.equal(R.isDueForReminder({ ...base, payRemindedAt: '2026-06-16T08:00:00' }, 100, cfg, NOW), true);
  // hit max count → not due
  assert.equal(R.isDueForReminder({ ...base, payReminderCount: 2 }, 100, cfg, NOW), false);
});

test('markReminderPatch increments count + stamps time', () => {
  const p = R.markReminderPatch({ payReminderCount: 1 }, NOW);
  assert.equal(p.payReminderCount, 2);
  // payRemindedAt is an INSTANT, stored as UTC ISO and read back with new Date()
  // for the recency check — so assert the instant, not a calendar-day prefix.
  // NOW is parsed without a zone, i.e. local noon; in Kiritimati (UTC+14) that
  // is the previous day in UTC, and the prefix assertion failed on correct code.
  assert.equal(new Date(p.payRemindedAt).getTime(), NOW);
  assert.equal(R.markReminderPatch({}, NOW).payReminderCount, 1);
});

test('daysOverdue handles missing due date', () => {
  assert.equal(R.daysOverdue({}, NOW), null);
  assert.equal(R.daysOverdue({ dueDate: '2026-06-20' }, NOW), 0);
});
