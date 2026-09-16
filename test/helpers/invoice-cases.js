'use strict';
/**
 * The invoices worth photographing.
 *
 * Between them they reach every branch of the document: both languages and
 * both directions, a shop with and without a tax registration, inclusive and
 * exclusive tax, a discount, a rush fee, shipping, a paid stamp, a bank block,
 * a multi-part job, a quote rather than an invoice, and the ZATCA QR — plus the
 * case where the QR could not be drawn, which must SAY so rather than print an
 * empty box.
 */
const SHOP = {
  currency: 'SAR',
  bizEn: 'Tuwaiq Additive', bizAr: 'تويق أدتف',
  addrEn: 'Riyadh', addrAr: 'الرياض',
  vat: '300000000000003',
  enableVat: true, vatRate: 15,
  invAccentColor: '#5E2E14',
};

const PARTS = [
  { name: 'Bracket', qty: 2, printWeight: 180, unitCost: 100, material: 'PLA' },
  { name: 'Lid', qty: 1, printWeight: 40, unitCost: 25, material: 'PETG' },
];

/** A customer the book holds, for the one case that bills a job to one. */
const ORDER = {
  id: 'INV-2026-0021', invoiceNumber: 'INV-2026-0021',
  date: '2026-09-04', timestamp: '2026-09-04T09:15:00.000Z',
  project: 'Bracket set', client: 'Acme Prototyping',
  price: 1150, paidAmount: 0, paymentStatus: 'unpaid',
  printTime: 8, parts: PARTS, currency: 'SAR',
};

const CASES = [
  { name: 'plain-en', order: ORDER, opts: { settings: SHOP } },
  {
    name: 'plain-ar',
    order: ORDER,
    opts: { settings: Object.assign({}, SHOP, { contentLangs: ['ar', 'en'] }), language: 'ar' },
  },
  {
    name: 'no-tax-registration',
    order: ORDER,
    opts: { settings: Object.assign({}, SHOP, { enableVat: false, vat: '' }) },
  },
  {
    name: 'discount-rush-shipping',
    order: Object.assign({}, ORDER, {
      discountPct: 12.5, priceBeforeDiscount: 1300, rushFeeAmount: 90, shippingCost: 60,
    }),
    opts: { settings: SHOP },
    money: { shipping: 60, subtotalShown: '1150.00' },
  },
  {
    // One part at the price the customer agreed, the other at cost plus
    // margin. 2 × 50 for the brackets, whatever the arithmetic said; the lid
    // takes the rest of the pool.
    name: 'agreed-part',
    order: Object.assign({}, ORDER, {
      price: 132.5, agreedAmount: 100,
      parts: [Object.assign({}, PARTS[0], { agreedPrice: 50 }), PARTS[1]],
    }),
    opts: { settings: SHOP },
  },
  {
    name: 'paid-with-bank',
    order: Object.assign({}, ORDER, { paidAmount: 1150, paymentStatus: 'paid' }),
    opts: {
      settings: Object.assign({}, SHOP, {
        bankName: 'Al Rajhi', iban: 'SA0380000000608010167519', accountHolder: 'Tuwaiq Additive',
      }),
    },
  },
  {
    name: 'zatca-qr',
    order: ORDER,
    opts: { settings: Object.assign({}, SHOP, { enableZatca: true }) },
  },
  {
    name: 'zatca-qr-refused',
    order: ORDER,
    opts: { settings: Object.assign({}, SHOP, { enableZatca: true }) },
    money: { qrSvg: '', qrProblem: 'VAT registration number' },
  },
  {
    name: 'quote',
    order: Object.assign({}, ORDER, { status: 'quote', invoiceNumber: null, id: 'QUO-2026-0007' }),
    opts: { settings: SHOP },
  },
  {
    name: 'exclusive-tax',
    order: ORDER,
    opts: {
      settings: Object.assign({}, SHOP, {
        tax: { country: 'US', name: 'Sales Tax', mode: 'exclusive',
               rates: [{ id: 's', label: 'Sales Tax', percent: 8.875 }] },
      }),
    },
    money: { total: '1252.06', vatAmount: '102.06', subtotal: '1150.00', vatRate: 8.875 },
  },
  {
    // A job billed to a customer the book actually holds. Every other case
    // here is a walk-in, so the contact line under the bill-to name — the
    // document's own rule since the Mac app started printing these — rendered
    // in no fixture at all.
    name: 'linked-customer',
    order: Object.assign({}, ORDER, { clientId: 'C1' }),
    opts: {
      settings: SHOP,
      clients: [{ id: 'C1', name: 'Acme Prototyping',
                  phone: '+966 50 123 4567', email: 'shop@acme.example' }],
    },
  },
  {
    name: 'no-parts',
    order: Object.assign({}, ORDER, { parts: [] }),
    opts: { settings: SHOP },
  },
];

module.exports = { CASES, SHOP, ORDER, PARTS };
