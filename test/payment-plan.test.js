'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildSchedule,
  scheduledTotal,
  collectedTotal,
  planBalance,
  markInstallmentPaid,
  dueInstallments,
  monthlyPlan,
  collectionTotals,
} = require('../lib/payment-plan');

/**
 * The shop's local day, NOT the UTC one.
 *
 * buildSchedule dates a deposit with localIsoDay(), so a helper using
 * toISOString() only agreed with it while UTC and local happened to fall on the
 * same date. In Riyadh (UTC+3) that is every hour except local midnight to
 * 03:00 — so this suite passed about 21 hours a day and failed the other three,
 * which is exactly what it did the first time a run crossed local midnight.
 *
 * 'en-CA' formats as YYYY-MM-DD, which is why the timezone test at the bottom
 * of this file already uses it. Same rule here.
 */
const today = () => new Date().toLocaleDateString('en-CA');

test('buildSchedule: amounts sum EXACTLY to total (clean division)', () => {
  const s = buildSchedule({ total: 1200, installments: 4, firstDueDate: '2026-01-01', intervalDays: 30 });
  assert.equal(s.length, 4);
  assert.deepEqual(s.map(e => e.amount), [300, 300, 300, 300]);
  assert.equal(scheduledTotal(s), 1200);
});

test('buildSchedule: awkward division 100/3 → 33.33 + 33.33 + 33.34, sums exactly', () => {
  const s = buildSchedule({ total: 100, installments: 3, firstDueDate: '2026-01-01', intervalDays: 7 });
  assert.deepEqual(s.map(e => e.amount), [33.33, 33.33, 33.34]);
  assert.equal(scheduledTotal(s), 100);
  // Last installment absorbs the rounding remainder.
  assert.equal(s[2].amount, 33.34);
});

test('buildSchedule: deposit becomes the first entry, due immediately', () => {
  const s = buildSchedule({ total: 1000, depositAmount: 250, installments: 3, firstDueDate: '2026-03-01', intervalDays: 30 });
  assert.equal(s.length, 4); // deposit + 3 installments
  assert.equal(s[0].amount, 250);
  assert.equal(s[0].dueDate, today()); // deposit due immediately
  assert.equal(s[0].paidAt, null);
  // Remaining 750 split across 3 → 250 each.
  assert.deepEqual(s.slice(1).map(e => e.amount), [250, 250, 250]);
  assert.equal(scheduledTotal(s), 1000);
});

test('buildSchedule: deposit + awkward remainder still sums exactly to total', () => {
  const s = buildSchedule({ total: 100, depositAmount: 10, installments: 3, firstDueDate: '2026-01-01', intervalDays: 30 });
  // remainder 90 / 3 = 30 each → no rounding drama here, deposit 10 + 90 = 100
  assert.equal(s[0].amount, 10);
  assert.equal(scheduledTotal(s), 100);

  const s2 = buildSchedule({ total: 100, depositAmount: 0.01, installments: 3, firstDueDate: '2026-01-01', intervalDays: 30 });
  assert.equal(s2[0].amount, 0.01);
  assert.equal(scheduledTotal(s2), 100); // remainder 99.99 / 3 absorbed in last
});

test('buildSchedule: every entry starts unpaid (paidAt null)', () => {
  const s = buildSchedule({ total: 500, depositAmount: 100, installments: 2, firstDueDate: '2026-01-01', intervalDays: 14 });
  for (const e of s) assert.equal(e.paidAt, null);
});

test('buildSchedule: due dates are spaced by intervalDays', () => {
  const s = buildSchedule({ total: 300, installments: 3, firstDueDate: '2026-01-01', intervalDays: 30 });
  assert.equal(s[0].dueDate, '2026-01-01');
  assert.equal(s[1].dueDate, '2026-01-31');
  assert.equal(s[2].dueDate, '2026-03-02'); // +60 days from 2026-01-01
});

test('buildSchedule: deposit-only plan (zero installments)', () => {
  const s = buildSchedule({ total: 500, depositAmount: 500, installments: 0 });
  assert.equal(s.length, 1);
  assert.equal(s[0].amount, 500);
  assert.equal(s[0].dueDate, today());
  assert.equal(scheduledTotal(s), 500);
});

test('buildSchedule: deposit smaller than total but zero installments returns deposit only', () => {
  const s = buildSchedule({ total: 1000, depositAmount: 300, installments: 0 });
  assert.equal(s.length, 1);
  assert.equal(s[0].amount, 300);
  // No regular installments requested → schedule sums to the deposit only.
  assert.equal(scheduledTotal(s), 300);
});

test('buildSchedule: deposit clamps to total, remainder zero → deposit only', () => {
  const s = buildSchedule({ total: 200, depositAmount: 999, installments: 3, firstDueDate: '2026-01-01', intervalDays: 30 });
  assert.equal(s.length, 1);
  assert.equal(s[0].amount, 200);
  assert.equal(scheduledTotal(s), 200);
});

test('buildSchedule: zero/garbage total yields empty schedule', () => {
  assert.deepEqual(buildSchedule({ total: 0, installments: 3 }), []);
  assert.deepEqual(buildSchedule({ total: -50, installments: 3 }), []);
  assert.deepEqual(buildSchedule({}), []);
});

test('scheduledTotal / collectedTotal: empty-safe', () => {
  assert.equal(scheduledTotal([]), 0);
  assert.equal(scheduledTotal(undefined), 0);
  assert.equal(scheduledTotal(null), 0);
  assert.equal(collectedTotal([]), 0);
  assert.equal(collectedTotal(undefined), 0);
});

test('collectedTotal: sums only entries with paidAt set', () => {
  const s = buildSchedule({ total: 100, installments: 3, firstDueDate: '2026-01-01', intervalDays: 7 });
  assert.equal(collectedTotal(s), 0);
  const s1 = markInstallmentPaid(s, 0, '2026-01-01');
  assert.equal(collectedTotal(s1), 33.33);
  const s2 = markInstallmentPaid(s1, 2, '2026-01-15');
  assert.equal(collectedTotal(s2), 66.67); // 33.33 + 33.34
});

test('planBalance: scheduled / collected / remaining math', () => {
  const s = buildSchedule({ total: 1000, depositAmount: 250, installments: 3, firstDueDate: '2026-02-01', intervalDays: 30 });
  let b = planBalance(s);
  assert.equal(b.scheduled, 1000);
  assert.equal(b.collected, 0);
  assert.equal(b.remaining, 1000);

  const collected = markInstallmentPaid(s, 0, '2026-01-01'); // deposit 250
  b = planBalance(collected);
  assert.equal(b.collected, 250);
  assert.equal(b.remaining, 750);
});

test('planBalance: remaining clamps to zero, never negative', () => {
  const s = [
    { dueDate: '2026-01-01', amount: 100, paidAt: '2026-01-01' },
    { dueDate: '2026-02-01', amount: 50, paidAt: '2026-02-01' },
  ];
  const b = planBalance(s);
  assert.equal(b.scheduled, 150);
  assert.equal(b.collected, 150);
  assert.equal(b.remaining, 0);
  assert.equal(b.nextDue, null); // all paid
});

test('planBalance.nextDue is the earliest UNPAID entry', () => {
  const s = buildSchedule({ total: 300, installments: 3, firstDueDate: '2026-01-01', intervalDays: 30 });
  // Pay the first → next due becomes the 2026-01-31 entry.
  const s1 = markInstallmentPaid(s, 0, '2026-01-01');
  const b = planBalance(s1);
  assert.deepEqual(b.nextDue, { dueDate: '2026-01-31', amount: 100 });
});

test('planBalance.nextDue picks earliest by date regardless of array order', () => {
  const s = [
    { dueDate: '2026-05-01', amount: 100, paidAt: null },
    { dueDate: '2026-01-01', amount: 100, paidAt: null },
    { dueDate: '2026-03-01', amount: 100, paidAt: null },
  ];
  assert.deepEqual(planBalance(s).nextDue, { dueDate: '2026-01-01', amount: 100 });
});

test('planBalance: empty-safe', () => {
  const b = planBalance([]);
  assert.deepEqual(b, { scheduled: 0, collected: 0, remaining: 0, nextDue: null });
  assert.deepEqual(planBalance(undefined), { scheduled: 0, collected: 0, remaining: 0, nextDue: null });
});

test('markInstallmentPaid: non-mutating, returns new schedule + new entry', () => {
  const s = buildSchedule({ total: 100, installments: 2, firstDueDate: '2026-01-01', intervalDays: 30 });
  const snapshot = JSON.parse(JSON.stringify(s));
  const updated = markInstallmentPaid(s, 0, '2026-01-05');

  // Original untouched.
  assert.deepEqual(s, snapshot);
  assert.equal(s[0].paidAt, null);
  assert.notEqual(updated, s);          // new array
  assert.notEqual(updated[0], s[0]);    // new entry object

  // Updated entry reflects payment.
  assert.equal(updated[0].paidAt, '2026-01-05');
  assert.equal(updated[1].paidAt, null);
});

test('markInstallmentPaid: updates collected total', () => {
  const s = buildSchedule({ total: 100, installments: 2, firstDueDate: '2026-01-01', intervalDays: 30 });
  assert.equal(collectedTotal(s), 0);
  const updated = markInstallmentPaid(s, 1, '2026-02-01');
  assert.equal(collectedTotal(updated), 50);
});

test('markInstallmentPaid: out-of-range index returns equivalent schedule (no crash)', () => {
  const s = buildSchedule({ total: 100, installments: 2, firstDueDate: '2026-01-01', intervalDays: 30 });
  const updated = markInstallmentPaid(s, 99, '2026-02-01');
  assert.deepEqual(updated, s);
  assert.equal(collectedTotal(updated), 0);
});

test('markInstallmentPaid: empty-safe', () => {
  assert.deepEqual(markInstallmentPaid([], 0, '2026-01-01'), []);
  assert.deepEqual(markInstallmentPaid(undefined, 0, '2026-01-01'), []);
});

test('dueInstallments: returns unpaid entries with dueDate <= now, earliest first', () => {
  const s = [
    { dueDate: '2026-01-01', amount: 100, paidAt: null }, // overdue
    { dueDate: '2026-06-18', amount: 100, paidAt: null }, // due today
    { dueDate: '2026-12-01', amount: 100, paidAt: null }, // future
  ];
  const due = dueInstallments(s, '2026-06-18');
  assert.equal(due.length, 2);
  assert.deepEqual(due.map(e => e.dueDate), ['2026-01-01', '2026-06-18']);
});

test('dueInstallments: excludes already-paid entries even if overdue', () => {
  const s = [
    { dueDate: '2026-01-01', amount: 100, paidAt: '2026-01-02' },
    { dueDate: '2026-02-01', amount: 100, paidAt: null },
  ];
  const due = dueInstallments(s, '2026-06-18');
  assert.equal(due.length, 1);
  assert.equal(due[0].dueDate, '2026-02-01');
});

test('dueInstallments: honors the injected `now`', () => {
  const s = [
    { dueDate: '2026-03-01', amount: 100, paidAt: null },
    { dueDate: '2026-09-01', amount: 100, paidAt: null },
  ];
  assert.equal(dueInstallments(s, '2026-01-01').length, 0); // nothing due yet
  assert.equal(dueInstallments(s, '2026-03-01').length, 1); // first due
  assert.equal(dueInstallments(s, '2026-12-01').length, 2); // both due
});

test('dueInstallments: entries without dueDate are never due; empty-safe', () => {
  const s = [{ amount: 100, paidAt: null }, { dueDate: null, amount: 50, paidAt: null }];
  assert.deepEqual(dueInstallments(s, '2026-06-18'), []);
  assert.deepEqual(dueInstallments([], '2026-06-18'), []);
  assert.deepEqual(dueInstallments(undefined, '2026-06-18'), []);
});

test('dueInstallments: does not mutate the input array order', () => {
  const s = [
    { dueDate: '2026-05-01', amount: 100, paidAt: null },
    { dueDate: '2026-01-01', amount: 100, paidAt: null },
  ];
  const snapshot = s.slice();
  dueInstallments(s, '2026-06-18');
  assert.deepEqual(s, snapshot); // original order preserved
});

test('integration: deposit + 3 installments, collect over time', () => {
  const s = buildSchedule({ total: 1000, depositAmount: 100, installments: 3, firstDueDate: '2026-01-01', intervalDays: 30 });
  assert.equal(scheduledTotal(s), 1000);

  // Collect deposit.
  let cur = markInstallmentPaid(s, 0, '2026-01-01');
  assert.equal(planBalance(cur).remaining, 900);

  // Collect first two installments (300 each → 600).
  cur = markInstallmentPaid(cur, 1, '2026-01-01');
  cur = markInstallmentPaid(cur, 2, '2026-02-01');
  const b = planBalance(cur);
  assert.equal(b.collected, 700);
  assert.equal(b.remaining, 300);
  assert.deepEqual(b.nextDue, { dueDate: '2026-03-02', amount: 300 });

  // Collect the last → fully collected.
  cur = markInstallmentPaid(cur, 3, '2026-03-02');
  assert.equal(planBalance(cur).remaining, 0);
  assert.equal(collectedTotal(cur), 1000);
});

test('a plan is dated by the LOCAL calendar day, not UTC', () => {
  // Riyadh is UTC+3, so toISOString() shifted the day backwards for any plan built
  // between 00:00 and 03:00 local — the deposit and first installment were dated
  // yesterday and were overdue the instant the plan was created.
  const RealDate = Date;
  const fixed = new RealDate('2026-07-19T22:30:00Z'); // 01:30 on the 20th in Riyadh
  global.Date = class extends RealDate {
    constructor(...a) { return a.length ? new RealDate(...a) : new RealDate(fixed); }
    static now() { return fixed.getTime(); }
  };
  try {
    const schedule = buildSchedule({ total: 1000, depositAmount: 300, installments: 2, intervalDays: 30 });
    const localDay = new RealDate(fixed).toLocaleDateString('en-CA'); // YYYY-MM-DD, local
    assert.equal(schedule[0].dueDate, localDay,
      'the deposit must be dated today in the shop’s own timezone');
  } finally {
    global.Date = RealDate;
  }
});


/* ── monthlyPlan: the plan a shop is offered ─────────────────────────────── */

test('monthlyPlan: three payments covering what is owed, a month then 30 days apart', () => {
  const s = monthlyPlan({ owed: 900, today: new Date(2026, 4, 10) }); // 10 May
  assert.equal(s.length, 3);
  assert.deepEqual(s.map(e => e.amount), [300, 300, 300]);
  assert.equal(scheduledTotal(s), 900);
  assert.equal(s[0].dueDate, '2026-06-10', 'the first payment falls a calendar month out');
  assert.equal(s[1].dueDate, '2026-07-10');
  assert.equal(s[2].dueDate, '2026-08-09', 'the rest follow at 30 days, not calendar months');
});

test('monthlyPlan: a plan generated on the 31st does not skip a month', () => {
  // new Date(2026, 1, 31) is the 3rd of MARCH — so the first payment used to
  // land two months out and February was never billed.
  const s = monthlyPlan({ owed: 300, today: new Date(2026, 0, 31) }); // 31 Jan
  assert.equal(s[0].dueDate, '2026-02-28', 'clamped to the last day February has');

  const leap = monthlyPlan({ owed: 300, today: new Date(2028, 0, 31) }); // 31 Jan 2028
  assert.equal(leap[0].dueDate, '2028-02-29', 'and a leap year has one more');

  const thirty = monthlyPlan({ owed: 300, today: new Date(2026, 2, 31) }); // 31 Mar
  assert.equal(thirty[0].dueDate, '2026-04-30', 'April has 30');
});

test('monthlyPlan: a day string is read in the shop\'s own calendar, not UTC', () => {
  // new Date('2026-01-31') is UTC midnight — the 30th for any shop west of
  // Greenwich, so its first payment landed a month out from the wrong day.
  const fromString = monthlyPlan({ owed: 300, today: '2026-01-31' });
  const fromDate = monthlyPlan({ owed: 300, today: new Date(2026, 0, 31) });
  assert.deepEqual(fromString.map(e => e.dueDate), fromDate.map(e => e.dueDate));
  assert.equal(fromString[0].dueDate, '2026-02-28');
});

test('monthlyPlan: nothing owed is no plan, not a plan of zeroes', () => {
  assert.deepEqual(monthlyPlan({ owed: 0, today: new Date(2026, 4, 10) }), []);
  assert.deepEqual(monthlyPlan({ owed: -50, today: new Date(2026, 4, 10) }), []);
  assert.deepEqual(monthlyPlan({}), []);
});

test('monthlyPlan: the count and interval are the caller\'s when it has an opinion', () => {
  const s = monthlyPlan({ owed: 400, today: new Date(2026, 4, 10), installments: 4, intervalDays: 7 });
  assert.equal(s.length, 4);
  assert.equal(s[1].dueDate, '2026-06-17');
});

/* ── collectionTotals: what collected rows do to the order's cash ────────── */

test('collectionTotals: a generated plan collects ON TOP of the deposit', () => {
  // The plan covers the BALANCE, so its rows are money beyond what the order
  // already held.
  const out = collectionTotals({
    price: 3000, paidAmount: 1000, instalmentBase: 1000,
    instalments: [{ amount: 666.67, paid: true }, { amount: 666.67, paid: false },
                  { amount: 666.66, paid: false }],
  });
  assert.equal(out.collected, 666.67);
  assert.equal(out.paidAmount, 1666.67);
  assert.equal(out.paymentStatus, 'partial');
});

test('collectionTotals: a hand-built plan with no base keeps the old rule', () => {
  // Its amounts mean whatever the shop decided, and such a schedule has always
  // spanned the whole price.
  const out = collectionTotals({
    price: 2000, paidAmount: 500,
    instalments: [{ amount: 2000, paid: true }],
  });
  assert.equal(out.paidAmount, 2000);
  assert.equal(out.paymentStatus, 'paid');
});

test('collectionTotals: cash taken at the counter since is never destroyed', () => {
  const out = collectionTotals({
    price: 3000, paidAmount: 2500, instalmentBase: 1000,
    instalments: [{ amount: 500, paid: true }],
  });
  assert.equal(out.paidAmount, 2500, 'base + collected would have been 1500');
});

test('collectionTotals: an empty or absent plan reports what the order holds', () => {
  assert.equal(collectionTotals({ price: 1000, paidAmount: 250 }).paidAmount, 250);
  assert.equal(collectionTotals({ price: 1000, paidAmount: 250 }).paymentStatus, 'partial');
  assert.equal(collectionTotals({ price: 1000, paidAmount: 0 }).paymentStatus, 'unpaid');
});

test('collectionTotals: sub-cent drift settles an order', () => {
  const out = collectionTotals({
    price: 2000, paidAmount: 0,
    instalments: [{ amount: 1999.999, paid: true }],
  });
  assert.equal(out.paymentStatus, 'paid');
});
