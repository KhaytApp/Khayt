const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/format.js');
const { buildZatcaTLV, formatPrintDate, buildZatcaInvoiceXml, buildZatcaPhase2TLV } = require('../renderer/invoicing.js');

test('buildZatcaTLV returns base64 payload', () => {
  const b64 = buildZatcaTLV({
    sellerName: 'Khayt Shop',
    vatNumber: '300000000000003',
    timestamp: '2026-05-30T12:00:00Z',
    total: '115.00',
    vatAmount: '15.00',
  });
  assert.match(b64, /^[A-Za-z0-9+/]+=*$/);
  assert.ok(Buffer.from(b64, 'base64').length > 20);
});

test('buildZatcaInvoiceXml includes invoice id', () => {
  const xml = buildZatcaInvoiceXml({
    invoiceNumber: 'INV-2026-0001',
    uuid: 'uuid-1',
    issueDate: '2026-05-30',
    issueTime: '12:00:00',
    sellerName: 'Shop',
    sellerStreet: 'Street',
    sellerCity: 'Riyadh',
    vatNumber: '300000000000003',
    buyerName: 'Buyer',
    total: 115,
    subtotal: 100,
    vatAmount: 15,
    vatRate: 15,
    itemName: 'Print job',
    invoiceCounter: 1,
    pih: 'hash',
  });
  assert.match(xml, /<cbc:ID>INV-2026-0001<\/cbc:ID>/);
});

test('formatPrintDate formats ISO date', () => {
  assert.match(formatPrintDate('2026-05-30'), /2026/);
  assert.equal(formatPrintDate(''), '');
});

test('buildZatcaTLV handles long seller names', () => {
  const longName = 'A'.repeat(140);
  const b64 = buildZatcaTLV({
    sellerName: longName,
    vatNumber: '300000000000003',
    timestamp: '2026-05-30T12:00:00Z',
    total: '115.00',
    vatAmount: '15.00',
  });
  const bytes = Buffer.from(b64, 'base64');
  assert.ok(bytes.length > 140);
});

test('buildZatcaPhase2TLV encodes >255-byte value with 0x82 two-byte length', async () => {
  // No signing backend: skip tags 6–8, exercise tag-1 length encoding only.
  global.window = { hubAPI: { zatcaSignInvoice: async () => ({ ok: false }) } };
  const longName = 'A'.repeat(300); // 300 ASCII bytes → exceeds 255
  const b64 = await buildZatcaPhase2TLV({
    sellerName: longName,
    vatNumber: '300000000000003',
    timestamp: '2026-05-30T12:00:00Z',
    total: '115.00',
    vatAmount: '15.00',
    canonicalData: '',
  });
  const bytes = Buffer.from(b64, 'base64');
  // First field is tag 1 (seller name). With len=300 (>255) the header must be
  // [0x01, 0x82, 0x01, 0x2C] (300 = 0x012C) followed by the 300 value bytes.
  assert.equal(bytes[0], 0x01);
  assert.equal(bytes[1], 0x82);
  assert.equal(bytes[2], (300 >> 8) & 0xff); // 0x01
  assert.equal(bytes[3], 300 & 0xff);        // 0x2C
  assert.equal(bytes[4], 0x41);              // 'A'
  // Header (4) + value (300) for tag 1 alone.
  assert.ok(bytes.length >= 304);
  delete global.window;
});

test('ZATCA XML balances: TaxExclusive + Tax === TaxInclusive at every VAT rate', () => {
  // subtotal and VAT were rounded INDEPENDENTLY from the unrounded split, so the document
  // could be a cent out — invalid UBL. Zero mismatches at Saudi's 15% over 2M amounts,
  // but the rate is configurable and enableZatca defaults to true: a shop at 20% hit it
  // on ~12.6% of totals.
  const pick = (xml, tag) => {
    const m = xml.match(new RegExp(`<cbc:${tag}[^>]*>([\\d.]+)</cbc:${tag}>`));
    return m ? +m[1] : null;
  };
  for (const rate of [15, 20, 12, 5]) {
    for (const total of [1.05, 1.26, 9.99, 100, 1234.56, 0.03]) {
      const vatAmount = total * rate / (100 + rate);
      const xml = buildZatcaInvoiceXml({
        invoiceNumber: 'INV-1', uuid: 'u', issueDate: '2026-07-21', issueTime: '10:00:00',
        sellerName: 'S', vatNumber: '300000000000003', buyerName: 'B',
        total, subtotal: total - vatAmount, vatAmount, vatRate: rate,
        itemName: 'item', invoiceCounter: 1, pih: 'x',
      });
      const excl = pick(xml, 'TaxExclusiveAmount');
      const tax = pick(xml, 'TaxAmount');
      const incl = pick(xml, 'TaxInclusiveAmount');
      assert.ok(excl !== null && tax !== null && incl !== null, 'amounts present in the XML');
      assert.equal((excl + tax).toFixed(2), incl.toFixed(2),
        `unbalanced at ${rate}% on ${total}: ${excl} + ${tax} !== ${incl}`);
      assert.equal(pick(xml, 'PayableAmount').toFixed(2), incl.toFixed(2), 'payable matches inclusive');
    }
  }
});
