/**
 * Invoice and quote numbering.
 *
 * Under ZATCA — Saudi Arabia's e-invoicing mandate, and this product's primary
 * market — an invoice number has to be unique and the sequence has to be
 * unbroken. A duplicate is not a cosmetic glitch; it is a compliance failure on
 * a document the shop has already handed to a customer, and it cannot be
 * corrected by editing the record afterwards.
 *
 * The ZATCA TLV and XML builders were covered. The thing that decides what goes
 * ON the invoice was not: `nextInvoiceNumber()` and `nextQuoteSeq()` had no
 * tests at all. No defect was found writing these — they are here because
 * "correct today" and "guarded" are different things, and this is code where the
 * cost of a regression is measured in tax filings.
 */
const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/format.js');

// The module reads `settings` and calls `saveAll()` off the global, as the
// renderer provides them.
globalThis.saveAll = () => {};
globalThis.settings = {};
const { nextInvoiceNumber, nextQuoteSeq } = require('../renderer/invoicing.js');

const YEAR = new Date().getFullYear();

beforeEach(() => {
  globalThis.settings = {
    invNumPrefix: 'INV', invNumNext: 1, invNumYear: YEAR,
    invNumFormat: '{prefix}-{year}-{seq4}',
    quoteNumNext: 1, quoteNumYear: YEAR,
  };
});

test('consecutive invoices never share a number', () => {
  const seen = new Set();
  for (let i = 0; i < 500; i++) {
    const n = nextInvoiceNumber();
    assert.ok(!seen.has(n), `duplicate invoice number ${n} at call ${i + 1}`);
    seen.add(n);
  }
  assert.equal(seen.size, 500);
});

test('the sequence is unbroken — no gaps', () => {
  // A gap is as awkward to explain to an auditor as a duplicate.
  const nums = Array.from({ length: 20 }, () => nextInvoiceNumber());
  const seqs = nums.map((n) => Number(n.split('-').pop()));
  assert.deepEqual(seqs, Array.from({ length: 20 }, (_, i) => i + 1));
});

test('the sequence is padded to four digits', () => {
  assert.equal(nextInvoiceNumber(), `INV-${YEAR}-0001`);
  globalThis.settings.invNumNext = 42;
  assert.equal(nextInvoiceNumber(), `INV-${YEAR}-0042`);
  globalThis.settings.invNumNext = 1234;
  assert.equal(nextInvoiceNumber(), `INV-${YEAR}-1234`);
});

test('past four digits the number grows rather than truncating', () => {
  // Truncating would wrap round to a number already issued.
  globalThis.settings.invNumNext = 10000;
  assert.equal(nextInvoiceNumber(), `INV-${YEAR}-10000`);
});

test('a new year restarts the sequence at one', () => {
  globalThis.settings.invNumYear = YEAR - 1;
  globalThis.settings.invNumNext = 873;
  assert.equal(nextInvoiceNumber(), `INV-${YEAR}-0001`, 'the counter resets with the year');
  assert.equal(globalThis.settings.invNumYear, YEAR, 'and the stored year moves with it');
  assert.equal(nextInvoiceNumber(), `INV-${YEAR}-0002`);
});

test('the year comes from the local calendar, not UTC', () => {
  // Same class as the date fixes: on 31 December a shop east of London would
  // otherwise still be issuing last year's sequence for the first hours of the
  // new year — and the year is part of the invoice number.
  const n = nextInvoiceNumber();
  assert.ok(n.includes(String(new Date().getFullYear())),
    `expected the local year in ${n}`);
});

test('the shop\'s chosen prefix and format are honoured', () => {
  globalThis.settings.invNumPrefix = 'KHT';
  globalThis.settings.invNumFormat = '{prefix}-{seq4}';
  assert.equal(nextInvoiceNumber(), 'KHT-0001');
  assert.equal(nextInvoiceNumber(), 'KHT-0002');
});

test('missing settings fall back rather than producing "undefined"', () => {
  // A store restored from an older version has none of these keys, and
  // "undefined-undefined-0001" would go out on a real invoice.
  globalThis.settings = {};
  const n = nextInvoiceNumber();
  assert.ok(!/undefined|NaN/.test(n), `unusable invoice number: ${n}`);
  assert.equal(n, `INV-${YEAR}-0001`);
});

// MARK: - quotes

test('quotes have their own sequence and never collide', () => {
  const seen = new Set();
  for (let i = 0; i < 200; i++) {
    const q = nextQuoteSeq();
    assert.ok(!seen.has(q), `duplicate quote sequence ${q}`);
    seen.add(q);
  }
});

test('issuing quotes does NOT consume invoice numbers', () => {
  // A quote is not an invoice. Advancing the invoice counter for one would
  // leave gaps in the invoice sequence for documents that never existed.
  const before = globalThis.settings.invNumNext;
  nextQuoteSeq(); nextQuoteSeq(); nextQuoteSeq();
  assert.equal(globalThis.settings.invNumNext, before, 'the invoice counter must not move');
});

test('a new year restarts the quote sequence too', () => {
  globalThis.settings.quoteNumYear = YEAR - 1;
  globalThis.settings.quoteNumNext = 99;
  assert.equal(Number(nextQuoteSeq()), 1);
});

test('the desktop numbers with the shared rule, not a copy of it', () => {
  // lib/order-new.js allocateInvoiceNumber is what the Mac and the recurring
  // orders use. Same settings in, same number out — and the same counter left.
  const N = require('../lib/order-new.js');
  for (const fmt of ['{prefix}-{year}-{seq4}', '{year}/{seq4}', '{prefix}{seq4}']) {
    const a = { invNumPrefix: 'F', invNumNext: 41, invNumYear: YEAR - 1, invNumFormat: fmt };
    const b = { ...a };
    globalThis.settings = a;
    const desk = nextInvoiceNumber();
    assert.equal(desk, N.allocateInvoiceNumber(b, YEAR), fmt);
    assert.deepEqual(a, b, `${fmt}: the counter is left the same`);
  }
});
