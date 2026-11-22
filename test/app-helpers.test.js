const { test } = require('node:test');
const assert = require('node:assert/strict');

test('payStatus treats gift card discount as payment', () => {
  global.settings = { currency: 'SAR' };
  const { payStatus } = require('../renderer/app-helpers.js');
  assert.equal(payStatus({ price: 100, paidAmount: 40, giftCardDiscount: 60 }), 'paid');
  assert.equal(payStatus({ price: 100, paidAmount: 0 }), 'unpaid');
});

test('payStatus: credit notes reduce the amount due (not the amount paid)', () => {
  global.settings = { currency: 'SAR' };
  const { payStatus } = require('../renderer/app-helpers.js');
  const cn = (n) => ({ creditNotes: [{ amount: n }] });
  // Paid in full, then a partial refund/credit → still settled (effective due drops).
  assert.equal(payStatus({ price: 100, paidAmount: 100, ...cn(30) }), 'paid');
  // Nothing paid, partial credit → still owes the rest.
  assert.equal(payStatus({ price: 100, paidAmount: 0, ...cn(30) }), 'unpaid');
  // Partial payment + partial credit → partial.
  assert.equal(payStatus({ price: 100, paidAmount: 50, ...cn(30) }), 'partial');
  // Credit covers the whole price → settled even with no cash paid.
  assert.equal(payStatus({ price: 100, paidAmount: 0, ...cn(100) }), 'paid');
});

test('getPriorityLevel normalises legacy boolean priority', () => {
  const { getPriorityLevel } = require('../renderer/app-helpers.js');
  assert.equal(getPriorityLevel({ priority: true }), 'high');
  assert.equal(getPriorityLevel({ priorityLevel: 'urgent' }), 'urgent');
  assert.equal(getPriorityLevel({}), 'normal');
});

test('inRange filters by month using date string slice', () => {
  const { inRange } = require('../renderer/app-helpers.js');
  const now = new Date();
  const ym = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  assert.equal(inRange(`${ym}-15`, 'month'), true);
  assert.equal(inRange('1999-01-01', 'month'), false);
});

test('hijriDate returns compact numeric string for valid ISO date', () => {
  const { hijriDate } = require('../renderer/app-helpers.js');
  const out = hijriDate('2026-01-15');
  assert.match(out, /^\d{4}\/\d{2}\/\d{2}$/);
});

test('wouldExceedWipLimit detects full columns', () => {
  const { wouldExceedWipLimit } = require('../renderer/app-helpers.js');
  const orders = [
    { id: 'a', status: 'printing' },
    { id: 'b', status: 'printing' },
    { id: 'c', status: 'pending' },
  ];
  assert.equal(wouldExceedWipLimit(orders, 'c', 'printing', { printing: 2 }), true);
  assert.equal(wouldExceedWipLimit(orders, 'a', 'printing', { printing: 2 }), false);
  assert.equal(wouldExceedWipLimit(orders, 'c', 'completed', { printing: 2 }), false);
});

test('KhaytAppHelpers exports shared helper entry points', () => {
  const helpers = require('../renderer/app-helpers.js');
  assert.equal(typeof helpers.localName, 'function');
  assert.equal(typeof helpers.openCsvImportModal, 'function');
  assert.equal(typeof helpers.toArabicNumerals, 'function');
});

test('parseTags dedupes, trims, and sorts', () => {
  const { parseTags } = require('../renderer/app-helpers.js');
  assert.deepEqual(parseTags(' rush, beta ,rush '), ['beta', 'rush']);
  assert.deepEqual(parseTags(''), []);
});

test('payStatus handles voided orders and credit notes', () => {
  const { payStatus } = require('../renderer/app-helpers.js');
  assert.equal(payStatus({ price: 100, voidedAt: '2026-01-01' }), 'voided');
  // Paid in full, then a 30 credit note (refund/reduction): the customer paid the
  // full price, so the order is settled — the credit reduces the amount DUE, not
  // what they paid. (Previously double-counted as "partial".)
  assert.equal(payStatus({ price: 100, paidAmount: 100, creditNotes: [{ amount: 30 }] }), 'paid');
  // A fully-credited order is settled — must not keep showing outstanding.
  assert.equal(payStatus({ price: 100, paidAmount: 0, creditedAt: '2026-01-01' }), 'voided');
});

test('clientOutstandingBalance sums unpaid non-quote orders', () => {
  require('../renderer/format.js');
  require('../renderer/currency.js');
  const { clientOutstandingBalance } = require('../renderer/app-helpers.js');
  global.settings = { currency: 'SAR' };
  global.clients = [];
  global.printLog = [
    { id: 'O1', clientId: 'c1', status: 'pending', price: 100, paidAmount: 0 },
    { id: 'O2', clientId: 'c1', status: 'completed', price: 50, paidAmount: 50 },
    { id: 'O3', clientId: 'c2', status: 'pending', price: 200, paidAmount: 0 },
  ];
  assert.equal(clientOutstandingBalance('c1'), 100);
  assert.equal(clientOutstandingBalance('c2'), 200);
});

test('machineDowntimeHoursInRange sums overlapping blocks', () => {
  const { machineDowntimeHoursInRange } = require('../renderer/app-helpers.js');
  const machine = {
    downtimeBlocks: [{ from: '2026-05-30T10:00:00Z', to: '2026-05-30T12:00:00Z' }],
  };
  const hours = machineDowntimeHoursInRange(
    machine,
    '2026-05-30T09:00:00Z',
    '2026-05-30T14:00:00Z',
  );
  assert.equal(hours, 2);
});

test('availableHoursUntil returns zero when target is today', () => {
  const { availableHoursUntil } = require('../renderer/app-helpers.js');
  global.settings = {
    workingHours: { sun: 8, mon: 8, tue: 8, wed: 8, thu: 8, fri: 8, sat: 8 },
    holidays: [],
  };
  assert.equal(availableHoursUntil(new Date()), 0);
});

test('inRange supports custom date windows', () => {
  const { inRange, customRangeFrom, customRangeTo } = require('../renderer/app-helpers.js');
  customRangeFrom.log = '2026-05-01';
  customRangeTo.log = '2026-05-31';
  assert.equal(inRange('2026-05-15', 'custom', 'log'), true);
  assert.equal(inRange('2026-06-01', 'custom', 'log'), false);
});

test('localName picks Arabic or English by locale', () => {
  const { localName } = require('../renderer/app-helpers.js');
  global.i18n = { current: 'ar' };
  assert.equal(localName({ nameAr: 'عربي', nameEn: 'English' }), 'عربي');
  global.i18n = { current: 'en' };
  assert.equal(localName({ nameAr: 'عربي', nameEn: 'English' }), 'English');
});

test('prioritySortValue ranks urgent before high before normal', () => {
  const { prioritySortValue } = require('../renderer/app-helpers.js');
  assert.ok(prioritySortValue({ priorityLevel: 'urgent' }) < prioritySortValue({ priorityLevel: 'high' }));
  assert.ok(prioritySortValue({ priorityLevel: 'high' }) < prioritySortValue({}));
});

test('avgDailyWorkingHours averages configured weekly hours', () => {
  const { avgDailyWorkingHours } = require('../renderer/app-helpers.js');
  global.settings = {
    workingHours: { sun: 0, mon: 8, tue: 8, wed: 8, thu: 8, fri: 8, sat: 0 },
  };
  assert.equal(avgDailyWorkingHours(), 40 / 7);
});
