'use strict';
/**
 * A FILED VAT RETURN IS NOT REWRITTEN (the owner's rule, 2026-10-22).
 *
 * An invoice dated in Q3, cancelled in October. Before this rule the Q3 VAT
 * simply vanished from Q3 — even after the shop had filed Q3 with it in. Now,
 * with Q3 marked filed:
 *
 *     Q3   output VAT 15.00   (as filed)
 *     Q4   adjustment −15.00 on sales of −100.00
 *
 * and with Q3 NOT filed, Q3 just drops it, as before. The reversal lands in
 * the first open period on or after the cancel's day; the period length is
 * the shop's filing frequency (quarterly, or monthly over SAR 40M).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/business-scope.js');
require('../lib/order-money.js');
require('../lib/tax.js');
const V = require('../lib/vat-periods.js');
const { pnlByPeriod, vatCorrections, wouldBeTaxPoint, periodsToCsv, periodsToHtml } = require('../lib/pnl-report.js');
const { summarize } = require('../lib/vat-summary.js');
const OS = require('../lib/order-status.js');
const SE = require('../lib/settings-edit.js');

const VAT15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
const NOW = new Date(2027, 1, 15, 12, 0, 0);
/** A local instant on a book day, as the apps stamp `voidedAt`. */
const instant = (y, m, d, h = 12) => new Date(y, m - 1, d, h, 0, 0).toISOString();

const invoice = (over) => ({ id: 'INV-1', invoiceNumber: 'INV-1', status: 'completed', date: '2026-08-10', price: 115, ...over });

function rowsOf(orders, settings, extra) {
  return pnlByPeriod(orders, [], { settings, clients: [], now: NOW, ...(extra || {}) });
}
const row = (rows, key) => rows.find((r) => r.period === key);

test('no filed marks: the book reads exactly as before — no corrections', () => {
  const orders = [invoice({ status: 'cancelled', cancelledAt: '2026-10-05' }), invoice({ id: 'INV-2' })];
  assert.deepEqual(vatCorrections(orders, { settings: VAT15 }), []);
  const rows = rowsOf(orders, VAT15);
  assert.equal(row(rows, '2026-Q3').vatCollected, 15, 'only the live invoice');
  assert.equal(row(rows, '2026-Q4'), undefined);
  assert.equal('vatAdjustment' in row(rows, '2026-Q3'), false, 'no new field on an ordinary row');
});

test('cancelled AFTER Q3 was filed: Q3 keeps its VAT, Q4 carries the reversal', () => {
  const job = invoice();
  // Filed first, while the job was live …
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  assert.deepEqual(settings.vatFiledPeriods, [{ period: '2026-Q3', filedAt: instant(2026, 10, 3), reversedIds: [] }]);
  // … then cancelled.
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-10-05' };
  const rows = rowsOf([cancelled], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 15, 'the filed figure');
  assert.equal(row(rows, '2026-Q3').taxableSales, 100);
  const q4 = row(rows, '2026-Q4');
  assert.equal(q4.vatCollected, -15);
  assert.equal(q4.taxableSales, -100);
  assert.equal(q4.vatAdjustment, -15);
  assert.equal(q4.salesAdjustment, -100);
  assert.equal(q4.adjustments, 1);
  assert.equal(q4.vatDue, -15);

  const q4vat = summarize([q4], { settings, expenses: [] });
  assert.equal(q4vat.output, -15);
  assert.equal(q4vat.adjustment, -15);
  assert.equal(q4vat.salesAdjustment, -100);
  assert.equal(q4vat.adjustments, 1);
  assert.equal(q4vat.position, 'refund');
});

test('cancelled BEFORE Q3 was filed: out of the return, out of Q3, no adjustment', () => {
  const cancelled = invoice({ status: 'cancelled', cancelledAt: '2026-09-20' });
  const live = invoice({ id: 'INV-2', invoiceNumber: 'INV-2' });
  const before = rowsOf([cancelled, live], VAT15);
  const settings = V.markFiled(VAT15, '2026-Q3', [cancelled, live], instant(2026, 10, 3));
  assert.deepEqual(settings.vatFiledPeriods[0].reversedIds, ['INV-1']);
  const after = rowsOf([cancelled, live], settings);
  assert.deepEqual(after, before, 'marking a period filed never changes its figures');
  assert.equal(row(after, '2026-Q3').vatCollected, 15);
});

test('an UNDATED cancel (an old iPhone) after filing lands on the first day after the filed period', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const fromPhone = { ...job, status: 'cancelled' };   // no cancelledAt, no history
  const cors = vatCorrections([fromPhone], { settings });
  assert.deepEqual(cors.map((c) => [c.kind, c.day, c.vat]), [['filed', '2026-08-10', 15], ['adjustment', '2026-10-01', -15]]);
  assert.equal(V.reversalDayOf(fromPhone), '');
});

test('the cancel day falls in a filed period too: it lands in the next unfiled one', () => {
  const job = invoice();
  let settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-11-02' };
  settings = V.markFiled(settings, '2026-Q4', [job], instant(2027, 1, 20));
  const rows = rowsOf([cancelled], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 15);
  assert.equal(row(rows, '2026-Q4'), undefined, 'Q4 as filed held nothing of it');
  assert.equal(row(rows, '2027-Q1').vatAdjustment, -15);
  assert.equal(V.landingDay('2026-11-02', settings), '2027-01-01');
  assert.equal(V.landingPeriod('2026-11-02', settings), '2027-Q1');
});

test('Q3 NOT filed: the VAT drops out of Q3, as it always did', () => {
  const settings = V.markFiled(VAT15, '2026-Q2', [], instant(2026, 7, 10));
  const rows = rowsOf([invoice({ status: 'cancelled', cancelledAt: '2026-10-05' })], settings);
  assert.deepEqual(rows, []);
});

test('monthly filer: the reversal lands in the next open MONTH', () => {
  const monthly = { ...VAT15, vatFilingFrequency: 'monthly' };
  assert.equal(V.frequencyOf(monthly), 'monthly');
  assert.equal(V.frequencyOf(VAT15), 'quarterly');
  const job = invoice();
  const settings = V.markFiled(monthly, '2026-08', [job], instant(2026, 9, 10));
  // Cancelled 25 Aug — still inside filed August — so it moves to September.
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-08-25' };
  const rows = rowsOf([cancelled], settings, { granularity: 'month' });
  assert.equal(row(rows, '2026-08').vatCollected, 15);
  assert.equal(row(rows, '2026-09').vatAdjustment, -15);
  assert.equal(V.landingPeriod('2026-08-25', settings), '2026-09');
});

test('a quarterly filer\'s monthly P&L shows the adjustment in the month it landed', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const rows = rowsOf([{ ...job, status: 'cancelled', cancelledAt: '2026-11-14' }], settings, { granularity: 'month' });
  assert.equal(row(rows, '2026-08').vatCollected, 15);
  assert.equal(row(rows, '2026-11').vatAdjustment, -15);
});

test('voided after filing, from its voidedAt; a void before filing is out of the return', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const voided = { ...job, voidedAt: instant(2026, 12, 1) };
  const cors = vatCorrections([voided], { settings });
  assert.deepEqual(cors.map((c) => [c.kind, c.day, c.vat, c.sales]),
    [['filed', '2026-08-10', 15, 100], ['adjustment', '2026-12-01', -15, -100]]);

  const early = { ...job, voidedAt: instant(2026, 9, 1) };
  const s2 = V.markFiled(VAT15, '2026-Q3', [early], instant(2026, 10, 3));
  assert.deepEqual(vatCorrections([early], { settings: s2 }), []);
});

test('a partial credit note after filing is a partial adjustment; full credit reverses the rest', () => {
  const job = invoice({ price: 230 });
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const part = { ...job, creditNotes: [{ id: 'CN-1', amount: 115, issuedAt: instant(2026, 10, 20) }] };
  const rows = rowsOf([part], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 30, 'filed with the whole 230');
  assert.equal(row(rows, '2026-Q4').vatAdjustment, -15);
  assert.equal(row(rows, '2026-Q4').salesAdjustment, -100);

  const full = { ...part, creditNotes: part.creditNotes.concat([{ id: 'CN-2', amount: 115, issuedAt: instant(2026, 11, 5) }]),
    creditedAt: instant(2026, 11, 5) };
  const r2 = rowsOf([full], settings);
  assert.equal(row(r2, '2026-Q3').vatCollected, 30);
  assert.equal(row(r2, '2026-Q4').vatAdjustment, -30);
  assert.equal(row(r2, '2026-Q4').adjustments, 2);
  // A credit note before filing is in the filed figure, not an adjustment.
  const pre = { ...job, creditNotes: [{ id: 'CN-0', amount: 115, issuedAt: instant(2026, 9, 2) }] };
  const s3 = V.markFiled(VAT15, '2026-Q3', [pre], instant(2026, 10, 3));
  assert.deepEqual(vatCorrections([pre], { settings: s3 }), []);
});

test('un-cancelled after filing: the filed period stays without it, the VAT is owed in the open one', () => {
  const cancelled = invoice({ status: 'cancelled', cancelledAt: '2026-09-20' });
  const settings = V.markFiled(VAT15, '2026-Q3', [cancelled], instant(2026, 10, 3));
  const back = { ...cancelled, status: 'completed' };
  delete back.cancelledAt;
  const rows = rowsOf([back], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 0, 'as filed: nothing');
  assert.equal(row(rows, '2026-Q4').vatAdjustment, 15);
});

test('a QUOTE cancelled before anyone said yes never had an invoice — nothing to reverse', () => {
  const quote = { id: 'QUO-2026-0001', status: 'cancelled', date: '2026-08-10', price: 115, statusHistory: [{ status: 'cancelled', at: instant(2026, 10, 5) }] };
  assert.equal(wouldBeTaxPoint(quote, VAT15), false);
  const settings = V.markFiled(VAT15, '2026-Q3', [], instant(2026, 10, 3));
  assert.deepEqual(vatCorrections([quote], { settings }), []);
  // An accepted quote, then cancelled, did have one.
  const accepted = { ...quote, quoteAcceptedAt: '2026-08-10', statusHistory: [{ status: 'pending', at: instant(2026, 8, 10) }, { status: 'cancelled', at: instant(2026, 10, 5) }] };
  assert.equal(wouldBeTaxPoint(accepted, VAT15), true);
  assert.equal(V.reversalDayOf(accepted), '2026-10-05', 'read off the history when cancelledAt is missing');
});

test('a mark with no snapshot falls back to dates; an undated reversal is never moved', () => {
  const bare = { ...VAT15, vatFiledPeriods: ['2026-Q3'] };
  const undated = invoice({ status: 'cancelled' });
  assert.deepEqual(vatCorrections([undated], { settings: bare }), [], 'what Khayt showed is what was filed');
  const dated = invoice({ status: 'cancelled', cancelledAt: '2026-10-05' });
  assert.equal(vatCorrections([dated], { settings: bare }).length, 2, 'after the period ended: after filing');
  const withDate = { ...VAT15, vatFiledPeriods: [{ period: '2026-Q3', filedAt: instant(2026, 10, 20) }] };
  assert.deepEqual(vatCorrections([dated], { settings: withDate }), [], 'cancelled before the filing day');
});

test('an unregistered shop has no return and no corrections', () => {
  const none = { currency: 'SAR', enableVat: false, vatFiledPeriods: [{ period: '2026-Q3', reversedIds: [] }] };
  assert.deepEqual(vatCorrections([invoice({ status: 'cancelled' })], { settings: none }), []);
});

test('the span: an adjustment counts where it LANDED, not where the invoice is dated', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-10-05' };
  const q3 = rowsOf([cancelled], settings, { range: { from: '2026-07-01', to: '2026-09-30' } });
  assert.equal(summarize(q3, { settings, expenses: [] }).output, 15);
  const q4 = rowsOf([cancelled], settings, { range: { from: '2026-10-01', to: '2026-12-31' } });
  const vat = summarize(q4, { settings, expenses: [] });
  assert.equal(vat.output, -15);
  assert.equal(vat.adjustment, -15);
});

test('the exported statement has the adjustment as its own line', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const rows = rowsOf([{ ...job, status: 'cancelled', cancelledAt: '2026-10-05' },
    invoice({ id: 'INV-9', invoiceNumber: 'INV-9', date: '2026-10-09', price: 230 })], settings,
  { range: { from: '2026-10-01', to: '2026-12-31' } });
  const vat = summarize(rows, { settings, expenses: [] });
  assert.equal(vat.output, 15, '30 on the new invoice, −15 reversed');
  const csv = periodsToCsv(rows, vat, {});
  assert.match(csv, /"Output VAT on sales",30\r\n"Adjustment for a filed period",-15\r\n/);
  assert.match(csv, /"Sales, net of VAT",200\r\n/);
  const html = periodsToHtml(rows, vat, {});
  assert.match(html, /Adjustment for a filed period<\/th><td>−15\.00/);
  // No adjustment, no line.
  const plain = summarize(rowsOf([invoice()], VAT15), { settings: VAT15, expenses: [] });
  assert.doesNotMatch(periodsToCsv(rowsOf([invoice()], VAT15), plain, {}), /Adjustment/);
});

test('cancelling stamps cancelledAt as the LOCAL day; un-cancelling takes it off', () => {
  const o = { id: 'INV-1', status: 'pending', date: '2026-10-01' };
  const late = new Date(2026, 9, 5, 23, 30, 0).getTime();   // 23:30 local
  OS.apply(o, 'cancelled', { now: late });
  assert.equal(o.cancelledAt, '2026-10-05');
  assert.equal(V.reversalDayOf(o), '2026-10-05');
  OS.apply(o, 'cancelled', { now: late + 86400000 * 3 });
  assert.equal(o.cancelledAt, '2026-10-05', 'a second move into Cancelled is not a new cancel');
  OS.apply(o, 'pending', { now: late + 86400000 * 4 });
  assert.equal('cancelledAt' in o, false);
  // Straight back to Completed takes it off too.
  OS.apply(o, 'cancelled', { now: late });
  OS.apply(o, 'completed', { now: late + 1000 });
  assert.equal('cancelledAt' in o, false);
});

test('settings: the filing frequency is quarterly unless monthly; the marks ride through a save', () => {
  const stored = { ...VAT15, vatFiledPeriods: [{ period: '2026-Q3', filedAt: 'x', reversedIds: [] }] };
  const monthly = SE.apply(stored, { vatFilingFrequency: 'monthly' }, { year: 2026 });
  assert.equal(monthly.vatFilingFrequency, 'monthly');
  assert.deepEqual(monthly.vatFiledPeriods, stored.vatFiledPeriods);
  assert.equal(SE.apply(stored, { vatFilingFrequency: 'weekly' }, { year: 2026 }).vatFilingFrequency, 'quarterly');
  assert.equal('vatFilingFrequency' in SE.apply(stored, { phone: '1' }, { year: 2026 }), false);
});

test('periods: keys, bounds, the walk, what can be marked', () => {
  assert.equal(V.periodKeyOf('2026-11-30', 'quarterly'), '2026-Q4');
  assert.equal(V.periodKeyOf('2026-11-30', 'monthly'), '2026-11');
  assert.deepEqual(V.periodBounds('2024-02'), { from: '2024-02-01', to: '2024-02-29' });
  assert.deepEqual(V.periodBounds('2026-Q4'), { from: '2026-10-01', to: '2026-12-31' });
  assert.equal(V.periodBounds('2026-Q5'), null);
  assert.equal(V.nextPeriodKey('2026-Q4'), '2027-Q1');
  assert.equal(V.nextPeriodKey('2026-12'), '2027-01');
  assert.deepEqual(V.periodsBetween('2026-02-15', '2026-07-01', 'quarterly'), ['2026-Q1', '2026-Q2', '2026-Q3']);
  // A monthly mark inside a quarterly filer's quarter only covers its month.
  const mixed = { vatFiledPeriods: ['2026-10'] };
  assert.equal(V.landingDay('2026-10-15', mixed), '2026-11-01');
  assert.equal(V.isFiled(mixed, '2026-Q4'), false);
  assert.equal(V.isFiled({ vatFiledPeriods: ['2026-Q4'] }, '2026-11'), true);
  // Only periods that have ENDED are offered; newest first.
  const list = V.filingPeriods({ vatFiledPeriods: ['2026-Q2'] }, { today: '2026-10-22', count: 3 });
  assert.deepEqual(list.map((p) => [p.period, p.filed]), [['2026-Q3', false], ['2026-Q2', true], ['2026-Q1', false]]);
  const inSpan = V.filingPeriods({ vatFilingFrequency: 'monthly' }, { today: '2026-10-22', from: '2026-07-01', to: '2026-12-31' });
  assert.deepEqual(inSpan.map((p) => p.period), ['2026-09', '2026-08', '2026-07']);
  // Unmark, and re-mark replaces rather than duplicates.
  let s = V.markFiled({}, '2026-Q3', [], instant(2026, 10, 3));
  s = V.markFiled(s, '2026-Q3', [], instant(2026, 10, 4));
  assert.equal(s.vatFiledPeriods.length, 1);
  assert.deepEqual(V.unmarkFiled(s, '2026-Q3').vatFiledPeriods, []);
  assert.equal(V.localDay(''), '');
  assert.equal(V.localDay('2026-10-05'), '2026-10-05');
});
