'use strict';
/**
 * ONE INVOICE, ONE DATE.
 *
 * The shop's rule (decided Oct 21 2026): VAT is due on ISSUED invoices. A
 * plain job is invoiced the day it is booked; a job that began as a quote is
 * invoiced the day the customer accepts it, while its `date` stays the
 * quote's.
 *
 * Four readers answered that differently. A quote dated 2026-09-28 and
 * accepted 2026-10-02 put its VAT in Q4 on the VAT summary
 * (lib/pnl-report.js taxPointDate read the acceptance), in Q3 in the
 * accountant's CSV (lib/accounting-rows.js read `date`), printed "28 Sep"
 * (lib/invoice-document.js read `date`), and fell due 30 days after 28 Sep
 * (lib/payment-terms.js read `date`).
 *
 * They now share `KhaytPaymentTerms.invoiceDate`, and this file pins all four
 * to it, for the accepted quote and for a plain job.
 */
// Riyadh, where a UTC slice of an acceptance stamped after midnight local
// time lands on the day before.
process.env.TZ = 'Asia/Riyadh';

const { test } = require('node:test');
const assert = require('node:assert/strict');

const PT = require('../lib/payment-terms.js');
const Pnl = require('../lib/pnl-report.js');
const AR = require('../lib/accounting-rows.js');
const DOC = require('../lib/invoice-document.js');
const { CURRENCIES } = require('../lib/currencies.js');
// The document reads this sibling off the global, as both apps load it.
require('../lib/invoice-language.js');

const CLIENT = { id: 'c1', name: 'Najd Architects', paymentTermsDays: 30 };

/** The four readers' answers for one order. */
function readers(order) {
  const csv = AR.ordersToInvoiceRows([order], {
    settings: { currency: 'SAR' }, clients: [CLIENT], tax: { rate: 15, mode: 'inclusive' },
  });
  // Every date the paper prints goes through `formatPrintDate`, so a marker
  // around it shows exactly which day the document chose.
  const { html } = DOC.invoiceHtml(order, {
    qrSvg: '', qrProblem: null, payQrSvg: '', total: '115.00', vatAmount: '15.00',
    subtotal: '100.00', vatRate: 15,
    settings: { currency: 'SAR' }, clients: [CLIENT], CURRENCIES, i18n: { current: 'en' },
    formatPrintDate: (d) => `[[${d}]]`,
  });
  const printed = [...html.matchAll(/\[\[([^\]]*)\]\]/g)].map((m) => m[1]);
  return {
    vatSummary: Pnl.taxPointDate(order),
    accountantCsv: csv.length ? csv[0].date : null,
    printed: printed[0],
    printedDue: printed[1],
    due: PT.dueDate(order, CLIENT),
    dueOnReceipt: PT.dueDate(order, { id: 'c1' }),
  };
}

function assertAllAgree(order, day, what) {
  const r = readers(order);
  assert.equal(r.vatSummary, day, `${what}: the VAT summary`);
  assert.equal(r.accountantCsv, day, `${what}: the accountant's CSV`);
  assert.equal(r.printed, day, `${what}: the date the invoice prints`);
  assert.equal(r.dueOnReceipt, day, `${what}: due on receipt is the invoice day`);
  assert.equal(r.due, PT.addDays(day, 30), `${what}: net 30 counts from the invoice day`);
  assert.equal(r.printedDue, r.due, `${what}: the due date on the paper`);
  assert.equal(PT.invoiceDate(order), day, `${what}: the rule itself`);
}

const base = {
  clientId: 'c1', project: 'Turbine bracket', price: 115, status: 'completed',
  date: '2026-09-28', timestamp: '2026-09-28T09:15:00.000Z',
};

test('a quote of 28 Sep accepted 2 Oct is an invoice of 2 Oct to every reader', () => {
  const order = {
    ...base, id: 'QUO-2026-0005', hasQuote: true,
    quoteAcceptedAt: '2026-10-02', invoiceNumber: 'INV-2026-0001',
  };
  assertAllAgree(order, '2026-10-02', 'accepted quote');
  // Q4 on the VAT summary and in the CSV alike.
  const r = readers(order);
  assert.equal(r.vatSummary.slice(0, 7), '2026-10');
  assert.equal(r.accountantCsv.slice(0, 7), '2026-10');
});

test('a plain job is an invoice of its own date to every reader', () => {
  assertAllAgree({ ...base, id: 'INV-2026-0002-abcd', jobNumber: 'INV-2026-0002' },
    '2026-09-28', 'plain job');
});

test('an acceptance stamped as an instant is the LOCAL day it fell on', () => {
  // 22:30 UTC on 30 Sep is 01:30 on 1 Oct in Riyadh: the UTC slice said Q3.
  const order = {
    ...base, id: 'QUO-2026-0006', hasQuote: true,
    clientApprovedAt: '2026-09-30T22:30:00.000Z', invoiceNumber: 'INV-2026-0003',
  };
  assertAllAgree(order, '2026-10-01', 'acceptance as an instant');
});

test('the older spelling, clientApprovedAt, as a bare day', () => {
  assertAllAgree({
    ...base, id: 'QUO-2026-0007', hasQuote: true,
    clientApprovedAt: '2026-10-05', invoiceNum: 'INV-2026-0004',
  }, '2026-10-05', 'clientApprovedAt');
});

test('a stamp that is not a day is passed over, not printed', () => {
  assertAllAgree({ ...base, id: 'QUO-2026-0008', hasQuote: true, quoteAcceptedAt: 'yes' },
    '2026-09-28', 'junk stamp');
});

test('the paper prints the acceptance time beside the acceptance day, never the quote\'s', () => {
  const order = {
    ...base, id: 'QUO-2026-0009', hasQuote: true,
    quoteAcceptedAt: '2026-10-02', invoiceNumber: 'INV-2026-0005',
  };
  const { html } = DOC.invoiceHtml(order, {
    qrSvg: '', total: '115.00', vatAmount: '15.00', subtotal: '100.00', vatRate: 15,
    settings: { currency: 'SAR' }, clients: [CLIENT], CURRENCIES, i18n: { current: 'en' },
  });
  // 09:15 UTC is the QUOTE's time (12:15 in Riyadh); a bare-day acceptance
  // has no time of its own to print.
  assert.doesNotMatch(html, /12:15/);
  const plain = DOC.invoiceHtml({ ...base, id: 'INV-2026-0006' }, {
    qrSvg: '', total: '115.00', vatAmount: '15.00', subtotal: '100.00', vatRate: 15,
    settings: { currency: 'SAR' }, clients: [CLIENT], CURRENCIES, i18n: { current: 'en' },
  });
  assert.match(plain.html, /12:15/, 'a plain job still prints the time it was booked');
});
