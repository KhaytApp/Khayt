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
const { pnlByPeriod, vatCorrections, periodsToCsv, periodsToHtml } = require('../lib/pnl-report.js');
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

test('the snapshot is what the period held, job by job, to the halala', () => {
  const settings = V.markFiled(VAT15, '2026-Q3', [invoice(), invoice({ id: 'INV-2', price: 230 }),
    invoice({ id: 'INV-3', date: '2026-10-02' })], instant(2026, 10, 3));
  assert.deepEqual(settings.vatFiledPeriods, [{
    period: '2026-Q3', filedAt: instant(2026, 10, 3),
    totals: { vat: 45, sales: 300 }, orders: { 'INV-1': [15, 100, 115, 'SAR'], 'INV-2': [30, 200, 230, 'SAR'] },
  }]);
});

test('cancelled AFTER Q3 was filed: Q3 keeps its VAT, Q4 carries the reversal', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
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
  const adj = vatCorrections([cancelled], { settings }).find((c) => c.kind === 'adjustment');
  assert.deepEqual([adj.day, adj.reason, adj.period], ['2026-10-05', 'cancelled', '2026-Q3']);

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
  assert.deepEqual(Object.keys(settings.vatFiledPeriods[0].orders), ['INV-2']);
  const after = rowsOf([cancelled, live], settings);
  assert.deepEqual(after, before, 'marking a period filed never changes its figures');
  assert.deepEqual(vatCorrections([cancelled, live], { settings }), []);
});

test('an amount EDITED after filing: the difference, up or down, is adjusted forward', () => {
  const job = invoice({ price: 230 });
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const up = { ...job, price: 345, updatedAt: instant(2026, 11, 2) };
  const r1 = rowsOf([up], settings);
  assert.equal(row(r1, '2026-Q3').vatCollected, 30, 'as filed');
  assert.equal(row(r1, '2026-Q4').vatAdjustment, 15);
  assert.equal(row(r1, '2026-Q4').salesAdjustment, 100);
  assert.equal(vatCorrections([up], { settings }).find((c) => c.kind === 'adjustment').reason, 'changed');
  const down = { ...job, price: 115, updatedAt: instant(2027, 1, 9) };
  const r2 = rowsOf([down], settings);
  assert.equal(row(r2, '2026-Q3').vatCollected, 30);
  assert.equal(row(r2, '2027-Q1').vatAdjustment, -15, 'on the day it was edited');
  // No stamp at all: the first day after the filed period.
  const unstamped = { ...job, price: 115 };
  const c = vatCorrections([unstamped], { settings }).find((x) => x.kind === 'adjustment');
  assert.equal(c.day, '2026-10-01');
});

test('a NEW invoice backdated into a filed period is added in the first open one', () => {
  const settings = V.markFiled(VAT15, '2026-Q3', [invoice()], instant(2026, 10, 3));
  const late = invoice({ id: 'INV-7', invoiceNumber: 'INV-7', date: '2026-09-12', updatedAt: instant(2026, 10, 15) });
  const rows = rowsOf([invoice(), late], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 15, 'the return held one invoice');
  assert.equal(row(rows, '2026-Q4').vatAdjustment, 15);
  const adj = vatCorrections([invoice(), late], { settings }).find((x) => x.kind === 'adjustment');
  assert.deepEqual([adj.orderId, adj.reason, adj.day], ['INV-7', 'added', '2026-10-15']);
  // With no stamp at all it is still added — on the day after the period.
  const bare = { ...late };
  delete bare.updatedAt;
  const a2 = vatCorrections([invoice(), bare], { settings }).find((x) => x.kind === 'adjustment');
  assert.deepEqual([a2.reason, a2.day, a2.vat], ['added', '2026-10-01', 15]);
});

test('a job removed from the book after filing is reversed forward', () => {
  const settings = V.markFiled(VAT15, '2026-Q3', [invoice()], instant(2026, 10, 3));
  // A deleted job carries no stamp: its reversal is dated today.
  const cors = vatCorrections([], { settings, now: new Date(2026, 11, 3, 12) });
  assert.deepEqual(cors.map((c) => [c.kind, c.reason, c.day, c.vat]),
    [['filed', 'removed', '2026-07-01', 15], ['adjustment', 'removed', '2026-12-03', -15]]);
});

test('an UNDATED cancel (an old iPhone) after filing lands on the first day after the filed period', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const fromPhone = { ...job, status: 'cancelled' };   // no cancelledAt, no history
  const cors = vatCorrections([fromPhone], { settings });
  assert.deepEqual(cors.map((c) => [c.kind, c.day, c.vat]), [['filed', '2026-08-10', 15], ['adjustment', '2026-10-01', -15]]);
  assert.equal(V.reversalDayOf(fromPhone), '');
});

test('the change falls in a filed period too: it lands in the next unfiled one, and marking moves nothing', () => {
  const job = invoice();
  let settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-11-02' };
  // Q4 open: the reversal is in Q4.
  const open = rowsOf([cancelled], settings);
  assert.equal(row(open, '2026-Q4').vatAdjustment, -15);
  // Q4 filed WITH that reversal in it: Q4 keeps it, nothing moves on.
  const s2 = V.markFiled(settings, '2026-Q4', [cancelled], instant(2027, 1, 20));
  assert.deepEqual(s2.vatFiledPeriods[1].orders, { 'INV-1': [-15, -100, 115, 'SAR', 1] });
  const filed = rowsOf([cancelled], s2);
  assert.equal(row(filed, '2026-Q3').vatCollected, 15);
  assert.equal(row(filed, '2026-Q4').vatCollected, -15);
  assert.equal(row(filed, '2027-Q1'), undefined, 'the two halves cancel in Q1');
  // Q4 filed BEFORE the cancel arrived: it lands in Q1.
  settings = V.markFiled(settings, '2026-Q4', [job], instant(2027, 1, 20));
  const late = rowsOf([cancelled], settings);
  assert.equal(row(late, '2026-Q4'), undefined, 'Q4 as filed held nothing of it');
  assert.equal(row(late, '2027-Q1').vatAdjustment, -15);
  assert.equal(V.landingDay('2026-11-02', settings), '2027-01-01');
  assert.equal(V.landingPeriod('2026-11-02', settings), '2027-Q1');
});

test('marking a period never changes any period, over a mixed book', () => {
  const book = [
    invoice(),
    invoice({ id: 'INV-2', price: 230, status: 'cancelled', cancelledAt: '2026-10-07' }),
    invoice({ id: 'INV-3', date: '2026-10-12', price: 57.5 }),
    invoice({ id: 'INV-4', date: '2026-11-03', creditNotes: [{ amount: 23, issuedAt: instant(2026, 12, 1) }] }),
  ];
  let settings = V.markFiled(VAT15, '2026-Q2', book, instant(2026, 7, 20));
  for (const key of ['2026-Q3', '2026-Q4']) {
    const before = rowsOf(book, settings);
    settings = V.markFiled(settings, key, book, instant(2027, 1, 25));
    assert.deepEqual(rowsOf(book, settings), before, `marking ${key}`);
  }
});

test('Q3 NOT filed: the figures follow the book, as they always did', () => {
  const settings = V.markFiled(VAT15, '2026-Q2', [], instant(2026, 7, 10));
  const rows = rowsOf([invoice({ status: 'cancelled', cancelledAt: '2026-10-05' })], settings);
  assert.deepEqual(rows, []);
});

test('monthly filer: the change lands in the next open MONTH', () => {
  const monthly = { ...VAT15, vatFilingFrequency: 'monthly' };
  assert.equal(V.frequencyOf(monthly), 'monthly');
  assert.equal(V.frequencyOf(VAT15), 'quarterly');
  const job = invoice();
  const settings = V.markFiled(monthly, '2026-08', [job], instant(2026, 9, 10));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-08-25' };
  const rows = rowsOf([cancelled], settings, { granularity: 'month' });
  assert.equal(row(rows, '2026-08').vatCollected, 15);
  assert.equal(row(rows, '2026-09').vatAdjustment, -15, 'never before the day after the filed month');
  assert.equal(V.landingPeriod('2026-08-25', settings), '2026-09', 'a day inside a filed month walks out of it');
  assert.equal(V.landingDay('2026-09-01', settings), '2026-09-01');
});

test('switching quarterly → monthly keeps the old quarters filed', () => {
  const job = invoice();
  const quarterly = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const monthly = SE.apply(quarterly, { vatFilingFrequency: 'monthly' }, { year: 2026 });
  assert.equal(V.isFiled(monthly, '2026-08'), true, 'a month inside a filed quarter is filed');
  assert.deepEqual(V.markFiled(monthly, '2026-09', [job], instant(2026, 10, 9)), monthly,
    'a month overlapping a filed quarter cannot be marked again');
  const rows = rowsOf([{ ...job, status: 'cancelled', cancelledAt: '2026-10-05' }], monthly, { granularity: 'month' });
  assert.equal(row(rows, '2026-08').vatCollected, 15);
  assert.equal(row(rows, '2026-10').vatAdjustment, -15);
  const s2 = V.markFiled(monthly, '2026-10', [job], instant(2026, 11, 9));
  assert.deepEqual(s2.vatFiledPeriods.map((m) => m.period), ['2026-10', '2026-Q3']);
});

test('the snapshot survives a JSON round trip (the store is JSON)', () => {
  const job = invoice();
  const settings = JSON.parse(JSON.stringify(V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3))));
  const rows = rowsOf([{ ...job, status: 'cancelled', cancelledAt: '2026-10-05' }], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 15);
  assert.equal(row(rows, '2026-Q4').vatAdjustment, -15);
});

test('voided after filing; a void before filing is out of the return', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const voided = { ...job, voidedAt: instant(2026, 12, 1) };
  const cors = vatCorrections([voided], { settings });
  assert.deepEqual(cors.map((c) => [c.kind, c.day, c.vat, c.sales, c.reason]),
    [['filed', '2026-08-10', 15, 100, 'cancelled'], ['adjustment', '2026-12-01', -15, -100, 'cancelled']]);
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
  assert.equal(vatCorrections([part], { settings }).find((c) => c.kind === 'adjustment').reason, 'credited');
  const full = { ...part, creditNotes: part.creditNotes.concat([{ id: 'CN-2', amount: 115, issuedAt: instant(2026, 11, 5) }]),
    creditedAt: instant(2026, 11, 5) };
  const r2 = rowsOf([full], settings);
  assert.equal(row(r2, '2026-Q3').vatCollected, 30);
  assert.equal(row(r2, '2026-Q4').vatAdjustment, -30);
  // A credit note before filing is in the filed figure, not an adjustment.
  const pre = { ...job, creditNotes: [{ id: 'CN-0', amount: 115, issuedAt: instant(2026, 9, 2) }] };
  const s3 = V.markFiled(VAT15, '2026-Q3', [pre], instant(2026, 10, 3));
  assert.deepEqual(vatCorrections([pre], { settings: s3 }), []);
});

test('un-cancelled after filing: the filed period stays without it, the VAT is owed in the open one', () => {
  const cancelled = invoice({ status: 'cancelled', cancelledAt: '2026-09-20' });
  const settings = V.markFiled(VAT15, '2026-Q3', [cancelled], instant(2026, 10, 3));
  const back = { ...cancelled, status: 'completed', updatedAt: instant(2026, 10, 9) };
  delete back.cancelledAt;
  const rows = rowsOf([back], settings);
  assert.equal(row(rows, '2026-Q3').vatCollected, 0, 'as filed: nothing');
  assert.equal(row(rows, '2026-Q4').vatAdjustment, 15);
  assert.equal(vatCorrections([back], { settings }).find((c) => c.kind === 'adjustment').reason, 'added');
});

test('a mark with no snapshot corrects nothing, but other adjustments land past it', () => {
  const bare = { ...VAT15, vatFiledPeriods: ['2026-Q3'] };
  const cancelled = invoice({ status: 'cancelled', cancelledAt: '2026-10-05' });
  assert.deepEqual(vatCorrections([cancelled], { settings: bare }), [], 'nothing recorded, nothing moved');
  assert.deepEqual(rowsOf([cancelled], bare), []);
  // Q2 snapshot, Q3 bare: a Q2 change made in Q3 lands in Q4.
  const job = invoice({ date: '2026-05-05' });
  const s = { ...V.markFiled(VAT15, '2026-Q2', [job], instant(2026, 7, 3)) };
  s.vatFiledPeriods = s.vatFiledPeriods.concat(['2026-Q3']);
  const cors = vatCorrections([{ ...job, status: 'cancelled', cancelledAt: '2026-08-01' }], { settings: s });
  assert.equal(cors.find((c) => c.kind === 'adjustment').day, '2026-10-01');
});

test('an unregistered shop has no return and no corrections', () => {
  const none = { currency: 'SAR', enableVat: false, vatFiledPeriods: [{ period: '2026-Q3', orders: { 'INV-1': [15, 100] } }] };
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
  const plain = summarize(rowsOf([invoice()], VAT15), { settings: VAT15, expenses: [] });
  assert.doesNotMatch(periodsToCsv(rowsOf([invoice()], VAT15), plain, {}), /Adjustment/);
});

test('un-filing keeps the snapshot, and filing again restores it: off/on changes nothing', () => {
  const live = invoice();
  const s1 = V.markFiled(VAT15, '2026-Q3', [live], instant(2026, 10, 3));
  const cancelled = { ...live, status: 'cancelled', cancelledAt: '2026-10-05' };
  const before = rowsOf([cancelled], s1);
  const off = V.unmarkFiled(s1, '2026-Q3');
  assert.deepEqual(off.vatFiledPeriods, []);
  assert.deepEqual(off.vatUnfiledPeriods, s1.vatFiledPeriods, 'archived, same shape');
  assert.deepEqual(rowsOf([cancelled], off), [], 'unfiled: the period follows the book');
  const on = V.markFiled(off, '2026-Q3', [cancelled], instant(2027, 1, 2));
  assert.deepEqual(on.vatFiledPeriods, s1.vatFiledPeriods, 'the old snapshot, not today\'s book');
  assert.deepEqual(on.vatUnfiledPeriods, []);
  assert.deepEqual(rowsOf([cancelled], on), before);
});

test('settings moving after filing adjust nothing: an exchange rate, the tax mode', () => {
  const usd = { ...VAT15, exchangeRates: { USD: 3.75 } };
  const job = invoice({ currency: 'USD', price: 100, updatedAt: instant(2026, 8, 10) });
  const filed = V.markFiled(usd, '2026-Q3', [job], instant(2026, 10, 3));
  const fx = { ...filed, exchangeRates: { USD: 3.8 } };
  const q3 = rowsOf([job], fx);
  assert.equal(row(q3, '2026-Q3').vatCollected, filed.vatFiledPeriods[0].totals.vat, 'the filed figure');
  assert.deepEqual(vatCorrections([job], { settings: fx }).filter((c) => c.kind === 'adjustment'), []);
  const plain = invoice({ updatedAt: instant(2026, 8, 10) });
  const s2 = V.markFiled(VAT15, '2026-Q3', [plain], instant(2026, 10, 3));
  const exclusive = { ...s2, tax: { country: 'SA', name: 'VAT', mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  assert.deepEqual(vatCorrections([plain], { settings: exclusive }).filter((c) => c.kind === 'adjustment'), []);
  assert.equal(row(rowsOf([plain], exclusive), '2026-Q3').vatCollected, 15);
  // An edited job still adjusts, at today's settings.
  const edited = { ...plain, price: 230, updatedAt: instant(2026, 11, 2) };
  assert.equal(vatCorrections([edited], { settings: exclusive }).filter((c) => c.kind === 'adjustment').length, 1);
});

test('updatedAt is the fallback: a phone cancel with only updatedAt lands when it was made', () => {
  const monthly = { ...VAT15, vatFilingFrequency: 'monthly' };
  const job = invoice({ date: '2026-09-10' });
  const settings = V.markFiled(monthly, '2026-09', [job], instant(2026, 10, 3));
  const phone = { ...job, status: 'cancelled', updatedAt: instant(2026, 12, 15) };
  const adj = vatCorrections([phone], { settings }).find((c) => c.kind === 'adjustment');
  assert.equal(adj.day, '2026-12-15', 'December, not October');
  // An event stamp wins over the sync stamp: the cancel is the change.
  const both = { ...phone, cancelledAt: '2026-10-20' };
  assert.equal(vatCorrections([both], { settings }).find((c) => c.kind === 'adjustment').day, '2026-10-20');
});

test('a save AFTER the cancel never moves the reversal: December cancel, January payment stays in Q4', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-12-20',
    statusHistory: [{ status: 'cancelled', at: instant(2026, 12, 20) }], updatedAt: instant(2027, 1, 3) };
  const adj = vatCorrections([cancelled], { settings }).find((c) => c.kind === 'adjustment');
  assert.deepEqual([adj.day, adj.vat, adj.reason], ['2026-12-20', -15, 'cancelled']);
  const rows = rowsOf([cancelled], settings);
  assert.equal(row(rows, '2026-Q4').vatAdjustment, -15, 'the Q4 return carries the December reversal');
  assert.equal((row(rows, '2027-Q1') || { vatAdjustment: 0 }).vatAdjustment, 0);
  // Q4 filed in January holds the reversal in its snapshot.
  const s4 = V.markFiled(settings, '2026-Q4', [cancelled], instant(2027, 1, 10));
  const q4mark = s4.vatFiledPeriods.find((m) => m.period === '2026-Q4');
  assert.equal(q4mark.totals.vat, -15);
  // Voided / credited: the same — the event stamp, not the later save.
  const voided = { ...job, voidedAt: instant(2026, 12, 20), updatedAt: instant(2027, 1, 3) };
  assert.equal(vatCorrections([voided], { settings }).find((c) => c.kind === 'adjustment').day, '2026-12-20');
  const credited = { ...job, creditNotes: [{ id: 'CN-1', amount: 115, issuedAt: instant(2026, 12, 20) }],
    updatedAt: instant(2027, 1, 3) };
  assert.equal(vatCorrections([credited], { settings }).find((c) => c.kind === 'adjustment').day, '2026-12-20');
  assert.equal(V.reversalDayOf(cancelled), '2026-12-20');
});

test('a credit note added AFTER the cancel moves nothing: the reversal stays in December', () => {
  const job = invoice();
  const settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-12-20',
    statusHistory: [{ status: 'cancelled', at: instant(2026, 12, 20) }],
    creditNotes: [{ id: 'CN-9', amount: 115, issuedAt: instant(2027, 1, 5) }], updatedAt: instant(2027, 1, 5) };
  const adj = vatCorrections([cancelled], { settings }).find((c) => c.kind === 'adjustment');
  assert.equal(adj.day, '2026-12-20');
  // Not reversed: a credit note still dates its own change.
  const credited = { ...job, creditNotes: [{ id: 'CN-9', amount: 115, issuedAt: instant(2027, 1, 5) }] };
  assert.equal(vatCorrections([credited], { settings }).find((c) => c.kind === 'adjustment').day, '2027-01-05');
});

test('un-cancelled after a filed reversal: the un-cancel day is the change, not a later save', () => {
  const job = invoice();
  let settings = V.markFiled(VAT15, '2026-Q3', [job], instant(2026, 10, 3));
  const cancelled = { ...job, status: 'cancelled', cancelledAt: '2026-10-05',
    statusHistory: [{ status: 'completed', at: instant(2026, 8, 10) }, { status: 'cancelled', at: instant(2026, 10, 5) }] };
  settings = V.markFiled(settings, '2026-Q4', [cancelled], instant(2027, 1, 10));
  const back = { ...cancelled, status: 'completed', updatedAt: instant(2027, 4, 2),
    statusHistory: [...cancelled.statusHistory, { status: 'completed', at: instant(2027, 3, 28) }] };
  delete back.cancelledAt;
  const adj = vatCorrections([back], { settings }).filter((c) => c.kind === 'adjustment');
  assert.deepEqual(adj.map((c) => [c.day, c.vat]), [['2027-03-28', 15]], 'Q1, not Q2');
  assert.equal(V.reversalDayOf(back), '', 'no longer reversed');
});

test('reversalDayOf takes the LATEST event stamp', () => {
  const o = invoice({ status: 'cancelled', cancelledAt: '2026-10-05', voidedAt: instant(2026, 11, 2), updatedAt: instant(2027, 1, 3) });
  assert.equal(V.reversalDayOf(o), '2026-11-02');
});

test('an overlapping period cannot be marked, and says what it is part of', () => {
  const s = V.markFiled(VAT15, '2026-Q3', [], instant(2026, 10, 3));
  assert.equal(V.overlapOf(s, '2026-08'), '2026-Q3');
  assert.equal(V.overlapOf(s, '2026-Q3'), '');
  const months = V.filingPeriods({ ...s, vatFilingFrequency: 'monthly' }, { today: '2026-10-22', from: '2026-08-01', to: '2026-10-31' });
  assert.deepEqual(months.map((p) => [p.period, p.filed, p.partOf]), [['2026-09', true, '2026-Q3'], ['2026-08', true, '2026-Q3']]);
  assert.equal(V.filingPeriods(s, { today: '2026-10-22', count: 1 })[0].partOf, '');
});

test('a payment after filing is not a change: a later FX move adjusts nothing', () => {
  const usd = { ...VAT15, exchangeRates: { USD: 3.75 } };
  const job = invoice({ currency: 'USD', price: 100 });
  const filed = V.markFiled(usd, '2026-Q3', [job], instant(2026, 10, 3));
  const paid = { ...job, paidAmount: 100, paymentStatus: 'paid', updatedAt: instant(2026, 10, 20) };
  const fx = { ...filed, exchangeRates: { USD: 3.8 } };
  assert.deepEqual(vatCorrections([paid], { settings: fx }).filter((c) => c.kind === 'adjustment'), []);
  assert.equal(row(rowsOf([paid], fx), '2026-Q3').vatCollected, filed.vatFiledPeriods[0].totals.vat);
});

test('chained: edited after Q3, Q4 filed with the adjustment, then FX — nothing moves', () => {
  const usd = { ...VAT15, exchangeRates: { USD: 3.75 } };
  const job = invoice({ currency: 'USD', price: 100 });
  let s = V.markFiled(usd, '2026-Q3', [job], instant(2026, 10, 3));
  const edited = { ...job, price: 200, updatedAt: instant(2026, 11, 2) };
  const q4open = rowsOf([edited], s);
  assert.ok(row(q4open, '2026-Q4').vatAdjustment > 0);
  s = V.markFiled(s, '2026-Q4', [edited], instant(2027, 1, 10));
  const before = rowsOf([edited], s);
  const fx = { ...s, exchangeRates: { USD: 3.8 } };
  const paid = { ...edited, updatedAt: instant(2027, 1, 20) };
  assert.deepEqual(vatCorrections([paid], { settings: fx }).filter((c) => c.kind === 'adjustment'), [],
    'judged against the LATEST snapshot holding it (Q4), not the first');
  assert.deepEqual(rowsOf([paid], fx).map((r) => [r.period, r.vatCollected]), before.map((r) => [r.period, r.vatCollected]));
});

test('a currency change at the same price is a change, and adjusts', () => {
  const usd = { ...VAT15, exchangeRates: { USD: 3.75 } };
  const job = invoice({ price: 115 });
  const s = V.markFiled(usd, '2026-Q3', [job], instant(2026, 10, 3));
  const moved = { ...job, currency: 'USD', updatedAt: instant(2026, 11, 2) };
  const adj = vatCorrections([moved], { settings: s }).find((c) => c.kind === 'adjustment');
  assert.ok(adj && adj.vat > 0, 'priced in USD now: 115 USD is more VAT');
  assert.equal(adj.reason, 'changed');
});

test('an old snapshot entry without its currency falls back to the stamps', () => {
  const job = invoice({ updatedAt: instant(2026, 8, 10) });
  const s = { ...VAT15, vatFiledPeriods: [{ period: '2026-Q3', filedAt: instant(2026, 10, 3), orders: { 'INV-1': [15, 100, 115] } }] };
  assert.deepEqual(vatCorrections([job], { settings: { ...s, tax: { country: 'SA', name: 'VAT', mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } } })
    .filter((c) => c.kind === 'adjustment'), [], 'no stamp after filing: untouched');
  const touched = { ...job, updatedAt: instant(2026, 10, 20) };
  const ex = { ...s, tax: { country: 'SA', name: 'VAT', mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  assert.equal(vatCorrections([touched], { settings: ex }).filter((c) => c.kind === 'adjustment').length, 1);
});

test('filing again FRESH records the book as it is now (an amended return)', () => {
  const live = invoice();
  const s1 = V.markFiled(VAT15, '2026-Q3', [live], instant(2026, 10, 3));
  const cancelled = { ...live, status: 'cancelled', cancelledAt: '2026-10-05' };
  const off = V.unmarkFiled(s1, '2026-Q3');
  assert.equal(V.filingPeriods(off, { today: '2026-10-22', count: 1 })[0].archived, true);
  const fresh = V.markFiled(off, '2026-Q3', [cancelled], instant(2026, 11, 1), {}, { fresh: true });
  assert.deepEqual(fresh.vatFiledPeriods[0].orders, {}, 'the amended return holds nothing of it');
  assert.equal(fresh.vatFiledPeriods[0].filedAt, instant(2026, 11, 1));
  assert.deepEqual(fresh.vatUnfiledPeriods, [], 'the archived snapshot is dropped');
  assert.deepEqual(rowsOf([cancelled], fresh), []);
});

test('a period cannot be un-filed while a later one is filed (no double count)', () => {
  const live = invoice();
  const s1 = V.markFiled(VAT15, '2026-Q3', [live], instant(2026, 10, 3));
  const cancelled = { ...live, status: 'cancelled', cancelledAt: '2026-10-05' };
  const s2 = V.markFiled(s1, '2026-Q4', [cancelled], instant(2027, 1, 5));
  assert.equal(V.laterFiledOf(s2, '2026-Q3'), '2026-Q4');
  assert.deepEqual(V.unmarkFiled(s2, '2026-Q3'), s2, 'refused: Q4 already corrects Q3');
  assert.equal(V.laterFiledOf(s2, '2026-Q4'), '');
  const q4off = V.unmarkFiled(s2, '2026-Q4');
  assert.equal(V.laterFiledOf(q4off, '2026-Q3'), '');
  assert.equal(V.unmarkFiled(q4off, '2026-Q3').vatFiledPeriods.length, 0, 'newest first, then it goes');
});

test('size: 300 invoices a quarter for three years is about 160 KB', () => {
  const book = [];
  for (let q = 0; q < 12; q++) {
    for (let i = 0; i < 300; i++) {
      const y = 2024 + Math.floor(q / 4), m = (q % 4) * 3 + 1 + (i % 3);
      book.push(invoice({ id: `INV-${y}-${String(q * 300 + i).padStart(4, '0')}`, date: `${y}-${String(m).padStart(2, '0')}-1${i % 9}`,
        price: 50 + (i * 37) % 900 + 0.35 }));
    }
  }
  let settings = VAT15;
  for (let q = 0; q < 12; q++) settings = V.markFiled(settings, `${2024 + Math.floor(q / 4)}-Q${(q % 4) + 1}`, book, instant(2027, 1, 5));
  const bytes = JSON.stringify(settings.vatFiledPeriods).length;
  assert.equal(settings.vatFiledPeriods.length, 12);
  assert.ok(bytes < 200000, `${bytes} bytes`);
  console.log(`  [vat-filed-periods] 3,600 invoices over 12 filed quarters: ${bytes} bytes`);
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
