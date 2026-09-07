'use strict';
/**
 * The Saudi Riyal mark on the document a customer is handed.
 *
 * The app prints U+20C1 and can afford to: it asks CoreText at runtime whether
 * the face it is drawing in has the glyph, and says "SAR" when it does not. A
 * PDF cannot ask. It is opened on a machine this app will never see, in a
 * reader whose fonts it cannot inspect, and the codepoint only arrived with the
 * mark in 2025 — so on anything older there is nothing at that position and a
 * price renders as an empty box on a customer's invoice.
 *
 * So the document draws the mark instead. These tests pin the two halves of
 * that decision, because both are the kind that break quietly: the riyal is
 * geometry, and every other currency is still its own plain symbol.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { render } = require('./helpers/invoice-harness.js');

const ORDER = {
  id: 'ORD-1', date: '2026-07-02', project: 'Bracket', clientId: null,
  price: 1150, paymentStatus: 'unpaid', currency: 'SAR',
  parts: [{ name: 'Bracket', qty: 1, amount: 1000 }],
};

test('a riyal invoice draws the mark rather than trusting a font', () => {
  const html = render(ORDER);
  assert.match(html, /<svg class="riyal"/,
    'the drawn mark is missing — a SAR invoice is relying on U+20C1 again');
  // The viewBox is the shape's own; a wrong one squashes the mark rather than
  // failing, so it is worth naming.
  assert.match(html, /viewBox="0 0 1124\.14 1256\.39"/);
  // Screen readers and anything reading the PDF's accessibility tree still get
  // a currency out of it, which is the whole reason the label is there.
  assert.match(html, /aria-label="SAR"/);
  assert.match(html, /<title>SAR<\/title>/);
});

test('the mark is drawn everywhere money is shown, not just the total', () => {
  const html = render(ORDER);
  const drawn = (html.match(/<svg class="riyal"/g) || []).length;
  // Line amount, subtotal, VAT and total at the very least. The exact count is
  // the fixtures' job; this only refuses the case where one call site was
  // converted and the rest were left printing letters beside it.
  assert.ok(drawn >= 4, `only ${drawn} figures carry the mark — some still say SAR`);
});

test('every other currency keeps its own symbol and gets no riyal', () => {
  for (const [code, expected] of [['EUR', '€'], ['USD', '$'], ['AED', 'AED']]) {
    const html = render(Object.assign({}, ORDER, { currency: code }));
    assert.doesNotMatch(html, /<svg class="riyal"/,
      `${code} drew the Saudi Riyal mark — the branch is unconditional`);
    assert.ok(html.includes(expected),
      `${code} lost its symbol (${expected}) from the document`);
  }
});

test('the mark is display only and never reaches the ZATCA payload', () => {
  // The QR carries the total and the tax as numbers; `zatca-qr.js` builds its
  // TLV from String(total). If the drawn mark ever appeared in that data a
  // scanner would read a broken invoice, so this refuses it outright.
  const html = render(ORDER, {}, { total: '1150.00', vatAmount: '150.00' });
  const qr = html.slice(html.indexOf('id="zatca-qr"'));
  assert.doesNotMatch(qr.slice(0, 200), /riyal/,
    'the drawn mark leaked into the ZATCA QR element');
});
