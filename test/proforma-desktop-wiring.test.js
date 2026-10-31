/**
 * The desktop's proforma is drawn by the shared document (`proforma` in
 * lib/invoice-document.js), the same paper the Mac prints. It used to render a
 * full tax invoice and patch the DOM afterwards, which left the ZATCA QR and the
 * invoice number on a document that is not a tax invoice.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const fn = (src, name) => {
  const at = src.indexOf(name);
  assert.ok(at >= 0, `${name} exists`);
  return src.slice(at, src.indexOf('\n}\n', at));
};

test('generateProformaInvoice asks the document for a proforma and patches nothing', () => {
  const body = fn(read('renderer/invoicing.js'), 'async function generateProformaInvoice(');
  assert.match(body, /renderInvoiceForOrder\(order, \{ proforma: true \}\)/);
  assert.doesNotMatch(body, /querySelector|createElement|textContent/);
});

test('a proforma draws no ZATCA QR, is not auto-submitted, and reaches the document', () => {
  const body = fn(read('renderer/invoicing.js'), 'async function renderInvoiceForOrder(');
  assert.match(body, /settings\.enableZatca && !proforma/);
  assert.match(body, /if \(!proforma\) maybeAutoSubmitZatca\(order\)/);
  assert.match(body, /renderInvoice\(order, \{[^}]*\bproforma \}\)/);
  assert.match(body, /proforma \? String\(order\.id\) : invoiceDocNumber\(order\)/);
});

test('no stylesheet rule fights the document\'s own watermark', () => {
  // The document's watermark is inline-styled; the old rule's transform moved
  // its full-page overlay off the paper.
  assert.doesNotMatch(read('renderer/styles.css'), /\.proforma-watermark/);
});
