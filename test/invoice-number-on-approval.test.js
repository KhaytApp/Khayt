'use strict';
/**
 * An accepted quote is an invoice, and an invoice is numbered by the INVOICE
 * counter — not by its quote id.
 *
 * The native Mac app approved quotes (the board, the customer's LAN page, the
 * portal's "Check response") without ever giving the job an invoice number,
 * and the document printed `order.id` under "No." — so a tax invoice went out
 * numbered `QUO-2026-0007`. Electron numbered it in `approveQuote`; the rule
 * the Mac now runs is `KhaytOrderNew.ensureInvoiceNumber`, and the document
 * prints `KhaytInvoiceDocument.documentNumber`: the invoice number for a job that
 * began as a quote, the id for anything else (a plain job's id IS its number).
 *
 * Also here: the shop's own second-language line is not printed when it says
 * exactly what the first line says (a shop with only an English name printed
 * it twice on every Arabic invoice).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const N = require('../lib/order-new.js');
const { render } = require('./helpers/invoice-harness.js');
const { SHOP, ORDER } = require('./helpers/invoice-cases.js');

/** The value printed beside "No." */
function printedNumber(html) {
  const m = html.match(/<span class="k">No\.?<\/span>\s*<span class="v">([^<]*)</)
    || html.match(/<div class="meta-row">\s*<span class="k">[^<]*<\/span>\s*<span class="v">([^<]*)</);
  return m ? m[1] : null;
}

/* ── the rule ─────────────────────────────────────────────────────────── */

test('an approved quote is owed a number; it gets the next one and the counter moves', () => {
  const settings = { invNumNext: 12, invNumYear: 2026 };
  const order = { id: 'QUO-2026-0007', status: 'pending', quoteAcceptedAt: '2026-10-01' };
  assert.equal(N.invoiceNumberOwed(order, settings), true);
  assert.equal(N.ensureInvoiceNumber(order, settings, 2026), 'INV-2026-0012');
  assert.equal(order.invoiceNumber, 'INV-2026-0012');
  assert.equal(order.invoiceNum, 'INV-2026-0012', 'both spellings, as newOrder writes them');
  assert.equal(settings.invNumNext, 13);
});

test('a second call changes nothing — no number is spent twice', () => {
  const settings = { invNumNext: 5, invNumYear: 2026 };
  const order = { id: 'QUO-2026-0001', status: 'pending', quoteAcceptedAt: '2026-10-01' };
  N.ensureInvoiceNumber(order, settings, 2026);
  assert.equal(N.ensureInvoiceNumber(order, settings, 2026), null);
  assert.equal(order.invoiceNumber, 'INV-2026-0005');
  assert.equal(settings.invNumNext, 6);
});

test('a quote still a quote, or cancelled, is not owed a number', () => {
  const settings = { invNumNext: 3 };
  for (const status of ['quote', 'cancelled']) {
    const order = { id: 'QUO-2026-0002', status, quoteAcceptedAt: '2026-10-01' };
    assert.equal(N.ensureInvoiceNumber(order, settings, 2026), null, status);
    assert.equal(order.invoiceNumber, undefined, status);
  }
  assert.equal(settings.invNumNext, 3, 'the counter did not move');
});

test('a job with either spelling of the number keeps it', () => {
  const settings = { invNumNext: 3 };
  const old = { id: 'QUO-2026-0002', status: 'pending', invoiceNum: 'INV-2026-0001', quoteAcceptedAt: 'x' };
  assert.equal(N.ensureInvoiceNumber(old, settings, 2026), null);
  assert.equal(old.invoiceNum, 'INV-2026-0001');
  assert.equal(settings.invNumNext, 3);
});

test('a job that was never a quote is left alone: its id is its number', () => {
  const settings = { invNumNext: 3 };
  const order = { id: 'ORD-2026-0002', status: 'pending' };
  assert.equal(N.invoiceNumberOwed(order, settings), false);
});

test('the shape the previous Mac build wrote — approved, no number — is owed one', () => {
  // What a LAN approval on alpha.72 left on disk: the approval stamps and
  // nothing else. And a quote dragged to Pending before quoteAcceptedAt was
  // stamped on moves: only the prefix says what it was.
  const settings = { quotePrefix: 'Q', invNumNext: 40, invNumYear: 2026 };
  const lan = { id: 'Q-2026-0003', status: 'completed', clientApprovedAt: '2026-09-02T10:00:00.000Z',
                quoteAcceptedAt: '2026-09-02', invoiceNum: null, invoiceNumber: null };
  const dragged = { id: 'Q-2026-0004', status: 'printing' };
  assert.equal(N.invoiceNumberOwed(lan, settings), true);
  assert.equal(N.invoiceNumberOwed(dragged, settings), true);
  assert.equal(N.ensureInvoiceNumber(lan, settings, 2026), 'INV-2026-0040');
  assert.equal(N.ensureInvoiceNumber(dragged, settings, 2026), 'INV-2026-0041');
});

test('the LAN approval rule plus the number: what the Mac runs inside its write', () => {
  const Q = require('../lib/lan-quote-page.js');
  const store = {
    settings: { invNumNext: 9, invNumYear: 2026 },
    printLog: [{ id: 'QUO-2026-0009', status: 'quote', invoiceNum: null }],
  };
  const r = Q.applyQuoteApprovalToStore(store, 'QUO-2026-0009', '2026-10-15T09:00:00.000Z');
  assert.equal(r.order.status, 'pending');
  assert.equal(N.ensureInvoiceNumber(r.order, store.settings, 2026), 'INV-2026-0009');
  assert.equal(store.printLog[0].invoiceNumber, 'INV-2026-0009');
});

/* ── the document ─────────────────────────────────────────────────────── */

test('an invoice for an accepted quote prints its INVOICE number, not QUO-…', () => {
  const order = Object.assign({}, ORDER, { id: 'QUO-2026-0007', status: 'pending',
                                           invoiceNumber: 'INV-2026-0031', invoiceNum: 'INV-2026-0031' });
  const html = render(order, { settings: SHOP });
  assert.equal(printedNumber(html), 'INV-2026-0031');
  assert.ok(!html.includes('QUO-2026-0007</span>'), 'the quote id is not the document number');
});

test('the older spelling alone is honoured', () => {
  const order = Object.assign({}, ORDER, { id: 'QUO-2026-0007', status: 'pending',
                                           invoiceNumber: undefined, invoiceNum: 'INV-2026-0030' });
  assert.equal(printedNumber(render(order, { settings: SHOP })), 'INV-2026-0030');
});

test('a quote document keeps its quote number', () => {
  const order = Object.assign({}, ORDER, { id: 'QUO-2026-0007', status: 'quote',
                                           invoiceNumber: 'INV-2026-0099' });
  assert.equal(printedNumber(render(order, { settings: SHOP })), 'QUO-2026-0007');
});

test('a record with no number at all still prints its id', () => {
  const order = Object.assign({}, ORDER, { invoiceNumber: undefined, invoiceNum: undefined });
  assert.equal(printedNumber(render(order, { settings: SHOP })), 'INV-2026-0021');
});

/* ── the shop's second line ───────────────────────────────────────────── */

const occurrences = (hay, needle) => hay.split(needle).length - 1;

test('a name with no Arabic twin is printed once on an Arabic invoice, not twice', () => {
  // shopField falls back across languages, so the Arabic primary IS the
  // English name — and the English secondary line read the same field.
  const settings = Object.assign({}, SHOP, {
    bizAr: '', addrAr: '', taglineEn: 'Parts that fit', taglineAr: '',
    footerEn: 'Thanks for printing with us', footerAr: '',
  });
  const html = render(ORDER, { settings, language: 'ar' });
  assert.equal(occurrences(html, 'Tuwaiq Additive'), 1);
  assert.equal(occurrences(html, '>Riyadh<'), 1);
  assert.equal(occurrences(html, 'Parts that fit'), 1);
  assert.equal(occurrences(html, 'Thanks for printing with us'), 1);
});

test('a real translation is still printed beside the original', () => {
  const settings = Object.assign({}, SHOP, { invoiceBilingual: 'both' });
  const html = render(ORDER, { settings, language: 'en' });
  assert.ok(html.includes('Tuwaiq Additive'));
  assert.ok(html.includes('تويق أدتف'));
});

/* ── which number a document prints: documentNumber ───────────────────── */
//
// alpha.74 review, B1. #1868 printed `invoiceNumber || invoiceNum || id` for
// EVERY non-quote, and a plain job's id is built from `settings.invPrefix`
// while its invoiceNumber comes off the counter's `invNumPrefix`. A shop with
// the prefix ATH saw ATH-2026-0012 become INV-2026-0012 on a reprint of an
// invoice it had already sent. Only a job that began as a quote prints the
// invoice counter's number.

const D = require('../lib/invoice-document.js');

test('documentNumber: a plain job with a custom invPrefix prints its id, not the counter', () => {
  const order = { id: 'ATH-2026-0012', status: 'pending',
                  invoiceNum: 'INV-2026-0012', invoiceNumber: 'INV-2026-0012' };
  assert.equal(D.documentNumber(order, { invPrefix: 'ATH', quotePrefix: 'QUO' }), 'ATH-2026-0012');
});

test('documentNumber: an accepted quote prints its invoice number', () => {
  const order = { id: 'QUO-2026-0007', status: 'pending', quoteAcceptedAt: '2026-10-01',
                  invoiceNumber: 'INV-2026-0031' };
  assert.equal(D.documentNumber(order, {}), 'INV-2026-0031');
  const online = { id: 'ATH-2026-0008', status: 'completed', clientApprovedAt: '2026-10-01T09:00:00Z',
                   invoiceNum: 'INV-2026-0030' };
  assert.equal(D.documentNumber(online, {}), 'INV-2026-0030', 'the older spelling, approved online');
  const custom = { id: 'Q-2026-0004', status: 'printing', invoiceNumber: 'INV-2026-0041' };
  assert.equal(D.documentNumber(custom, { quotePrefix: 'Q' }), 'INV-2026-0041', "the shop's own quote prefix");
});

test('documentNumber: a quote prints its quote id', () => {
  const order = { id: 'QUO-2026-0007', status: 'quote', invoiceNumber: 'INV-2026-0099' };
  assert.equal(D.documentNumber(order, {}), 'QUO-2026-0007');
});

test('documentNumber: missing settings reads the default quote prefix, and nothing throws', () => {
  const accepted = { id: 'QUO-2026-0007', status: 'pending', invoiceNumber: 'INV-2026-0031' };
  assert.equal(D.documentNumber(accepted), 'INV-2026-0031');
  assert.equal(D.documentNumber(accepted, null), 'INV-2026-0031');
  const plain = { id: 'ATH-2026-0012', status: 'pending', invoiceNumber: 'INV-2026-0012' };
  assert.equal(D.documentNumber(plain), 'ATH-2026-0012');
  assert.equal(D.documentNumber(null), '');
  assert.equal(D.documentNumber(undefined, {}), '');
});

test('documentNumber: hasQuote alone is not a quote, and an accepted quote with no number prints its id', () => {
  const held = { id: 'ATH-2026-0013', status: 'pending', hasQuote: true, invoiceNumber: 'INV-2026-0013' };
  assert.equal(D.documentNumber(held, {}), 'ATH-2026-0013');
  const unnumbered = { id: 'QUO-2026-0002', status: 'pending', quoteAcceptedAt: '2026-10-01' };
  assert.equal(D.documentNumber(unnumbered, {}), 'QUO-2026-0002');
});

test('the printed invoice of a plain job with a custom invPrefix keeps its id', () => {
  const order = Object.assign({}, ORDER, { id: 'ATH-2026-0012', status: 'pending',
                                           invoiceNum: 'INV-2026-0012', invoiceNumber: 'INV-2026-0012' });
  const settings = Object.assign({}, SHOP, { invPrefix: 'ATH' });
  assert.equal(printedNumber(render(order, { settings })), 'ATH-2026-0012');
});

/* ── an unapproved quote On hold is owed nothing (review S3a) ─────────── */

test('On hold with a quote attached and no yes is not owed a number', () => {
  const settings = { invNumNext: 7 };
  for (const id of ['ATH-2026-0014', 'QUO-2026-0014']) {
    const order = { id, status: 'on_hold', hasQuote: true };
    assert.equal(N.invoiceNumberOwed(order, settings), false, id);
    assert.equal(N.ensureInvoiceNumber(order, settings, 2026), null, id);
  }
  assert.equal(settings.invNumNext, 7, 'the counter did not move');
});

test('On hold after the customer said yes is owed one', () => {
  const settings = { invNumNext: 7, invNumYear: 2026 };
  const order = { id: 'ATH-2026-0015', status: 'on_hold', hasQuote: true, clientApprovedAt: '2026-10-02T08:00:00Z' };
  assert.equal(N.invoiceNumberOwed(order, settings), true);
});

test('hasQuote alone, off hold, does not make a plain job owed', () => {
  const order = { id: 'ATH-2026-0016', status: 'pending', hasQuote: true };
  assert.equal(N.invoiceNumberOwed(order, {}), false);
});
