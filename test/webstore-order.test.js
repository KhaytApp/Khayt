const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/webstore-order.js');
const S = require('../lib/shelf-sale.js');

/*
 * A web-store order, in as a job and back out as progress.
 *
 * The queue item is the shape khayt-cloud's mapPlatformOrder files:
 * { name, contact, title, description, qty, source, ref }.
 */
const medusa = (extra) => Object.assign({
  name: 'Nora Alqahtani', contact: 'nora@example.com',
  title: 'Medusa order — #1042', description: '• Flexi Dragon × 2',
  qty: '2', source: 'medusa', ref: 'medusa:#1042',
}, extra || {});

// ── In: may it become a job by itself? ───────────────────────────────────

test('a placed Medusa order is paid: the store cannot place an unpaid one', () => {
  assert.equal(W.paidState(medusa()), 'paid');
  const d = W.decide(medusa());
  assert.deepEqual(d, { auto: true, platform: 'medusa', paid: true, reason: 'ok' });
});

test('an explicit answer in the payload beats the platform default', () => {
  assert.equal(W.decide(medusa({ paid: false })).reason, 'unpaid');
  assert.equal(W.decide(medusa({ paymentStatus: 'refunded' })).reason, 'unpaid');
  assert.equal(W.decide(medusa({ paymentStatus: 'captured' })).auto, true);
});

test('Salla can place an unpaid (cash on delivery) order, so silence is not a yes', () => {
  const salla = medusa({ source: 'salla', ref: 'salla:SL-9' });
  assert.equal(W.paidState(salla), 'unknown');
  assert.equal(W.decide(salla).reason, 'payment_unknown');
  assert.equal(W.decide(salla).auto, false);
  assert.equal(W.decide({ ...salla, paymentStatus: 'paid' }).auto, true);
});

test('a customer typing a request is never made into a job on its own', () => {
  const d = W.decide({ name: 'A', title: 'Can you print this?', description: 'a vase' });
  assert.equal(d.reason, 'hand_request');
  assert.equal(d.auto, false);
  // …nor a "generic" POST, which can be anybody's form.
  assert.equal(W.decide({ source: 'generic', ref: 'generic:1', paid: true }).auto, false);
});

test('a storefront order with no reference of its own waits for a person', () => {
  const d = W.decide(medusa({ ref: '' }));
  assert.equal(d.reason, 'no_reference');
  assert.equal(d.auto, false);
});

test('the platform is read from the scoped reference when source was lost', () => {
  assert.equal(W.platformOf({ ref: 'medusa:#7' }), 'medusa');
  assert.equal(W.platformOf({ ref: 'nothing:#7' }), '');
});

// ── The customer ────────────────────────────────────────────────────────

const clients = [
  { id: 'CLI-1', nameEn: 'Nora', email: 'NORA@example.com', phone: '' },
  { id: 'CLI-2', nameEn: 'Fahad', email: '', phone: '+966 50 123 4567' },
  { id: 'CLI-3', nameEn: 'Nora Alqahtani', email: 'other@example.com' },
];

test('the same email is the same customer, whatever its case', () => {
  const c = W.customerFor(medusa(), clients);
  assert.equal(c.clientId, 'CLI-1');
  assert.equal(c.matched, 'email');
  assert.equal(c.create, null);
});

test('the same phone is the same customer, however it was written', () => {
  const c = W.customerFor(medusa({ contact: '0501234567', name: 'F' }), clients);
  assert.equal(c.clientId, 'CLI-2');
  assert.equal(c.matched, 'phone');
  assert.equal(W.phoneKey('٠٥٠١٢٣٤٥٦٧'), W.phoneKey('966501234567'));
  assert.equal(W.phoneKey('12'), '', 'two digits find everybody');
});

test('a name alone never matches: two Noras are two customers', () => {
  const c = W.customerFor(medusa({ contact: 'new@example.com' }), clients);
  assert.equal(c.clientId, null);
  assert.deepEqual(c.create, {
    nameEn: 'Nora Alqahtani', nameAr: '', email: 'new@example.com', phone: '', source: 'online',
  });
});

test('an Arabic name is filed as the Arabic name', () => {
  const c = W.customerFor(medusa({ name: 'نورة', contact: 'n2@example.com' }), []);
  assert.equal(c.create.nameAr, 'نورة');
  assert.equal(c.create.nameEn, '');
});

test('no name and no contact is nobody', () => {
  assert.equal(W.customerFor({ source: 'medusa' }, clients), null);
  // An address with no name is called by the address.
  assert.equal(W.customerFor({ contact: 'x@y.z' }, []).create.nameEn, 'x@y.z');
});

// ── Structured lines, when the cloud carries them ─────────────────────────

test('a basket line naming its product by id comes off that shelf, with its options', () => {
  const book = {
    products: [{ id: 'PRD-A', nameEn: 'Flexi Dragon' }, { id: 'PRD-B', nameEn: 'Hood' }],
    stock: { 'PRD-A': 5, 'PRD-B': 1 },
  };
  const r = S.read(medusa({ lines: [
    // The store calls it something else; the id is what decides.
    { name: 'Dragon (large)', qty: 2, productId: 'PRD-A', options: { Colour: 'Red' } },
    // An id this shop does not have falls back to the name.
    { name: 'Hood', qty: 1, productId: 'PRD-GONE' },
  ] }), book);
  assert.equal(r.lines[0].productId, 'PRD-A');
  assert.deepEqual(r.lines[0].options, { Colour: 'Red' });
  assert.equal(r.lines[0].fromShelf, 2);
  assert.equal(r.lines[1].productId, 'PRD-B');
  assert.equal(r.allFromShelf, true);
  // Without `lines`, the description is still read as before.
  assert.equal(S.read(medusa(), book).lines[0].name, 'Flexi Dragon');
});

test('options arrive as a list or an object and come out as one shape', () => {
  assert.deepEqual(S.structuredLines([{ name: 'A', options: [{ name: 'Size', value: 'L' }] }])[0].options,
    { Size: 'L' });
  assert.equal(S.structuredLines([{ name: 'A', options: {} }])[0].options, undefined);
});

// ── Out: what the store is told ──────────────────────────────────────────

const job = (extra) => Object.assign({
  id: 'INV-2026-0042', status: 'pending', source: 'medusa', sourceOrderId: 'medusa:#1042',
  timestamp: '2026-09-26T08:00:00.000Z', statusHistory: [],
}, extra || {});

test('only web-store jobs are told to a store', () => {
  assert.equal(W.statusFor(job({ source: 'walk_in', sourceOrderId: null })), null);
  assert.equal(W.statusFor(job({ sourceOrderId: '' })), null);
});

test('the six words a store understands', () => {
  assert.equal(W.statusFor(job()).status, 'received');
  assert.equal(W.statusFor(job({ status: 'qc' })).status, 'printing');
  assert.equal(W.statusFor(job({ status: 'completed' })).status, 'ready');
  assert.equal(W.statusFor(job({ status: 'completed', shippedAt: '2026-09-27T10:00:00Z' })).status, 'shipped');
  assert.equal(W.statusFor(job({ status: 'completed', shippedAt: 'x', deliveredAt: '2026-09-28T10:00:00Z' })).status,
    'delivered');
  assert.equal(W.statusFor(job({ status: 'delivered' })).status, 'delivered', 'the legacy status');
  assert.equal(W.statusFor(job({ status: 'cancelled' })).status, 'cancelled');
});

test('a shipped job carries its tracking number and a link to follow it', () => {
  const u = W.statusFor(job({
    status: 'completed', shippedAt: '2026-09-27T10:00:00Z',
    carrier: 'smsa', trackingNumber: 'SM123', shippingStatus: 'in_transit',
  }));
  assert.equal(u.trackingNumber, 'SM123');
  assert.equal(u.carrier, 'smsa');
  assert.match(u.trackingUrl, /smsaexpress\.com.*SM123/);
  assert.equal(u.updatedAt, '2026-09-27T10:00:00Z');
  // Nothing a customer should not see.
  for (const k of ['price', 'notes', 'client', 'clientId', 'cost']) assert.ok(!(k in u), k);
});

test('a job not yet shipped says nothing about a parcel', () => {
  const u = W.statusFor(job({ status: 'printing', trackingNumber: 'EARLY' }));
  assert.equal(u.trackingNumber, null);
});

test('a Salla webhook job, whose reference is unscoped, is told under the scoped one', () => {
  assert.equal(W.statusFor(job({ source: 'salla', sourceOrderId: 'SL-9' })).ref, 'salla:SL-9');
});

test('what was already told is not told again; a change is', () => {
  const log = [job(), job({ id: 'J2', sourceOrderId: 'medusa:#2', status: 'printing' })];
  const first = W.pending(log, {});
  assert.equal(first.length, 2);
  const sent = Object.fromEntries(first.map((u) => [u.ref, W.fingerprint(u)]));
  assert.equal(W.pending(log, sent).length, 0);
  log[0] = job({ status: 'printing' });
  const next = W.pending(log, sent);
  assert.equal(next.length, 1);
  assert.equal(next[0].status, 'printing');
});

test('old finished business is not news; old unfinished work still is', () => {
  const log = [
    job({ id: 'OLD', sourceOrderId: 'medusa:#1', status: 'delivered', timestamp: '2025-01-01T00:00:00Z' }),
    job({ id: 'STUCK', sourceOrderId: 'medusa:#2', status: 'pending', timestamp: '2025-01-01T00:00:00Z' }),
  ];
  const owed = W.pending(log, {}, { notBefore: '2026-01-01T00:00:00Z' });
  assert.deepEqual(owed.map((u) => u.jobId), ['STUCK']);
});

// ── What the order comes to ──────────────────────────────────────────────
//
// The Mac priced three of a product with a typed price of 50 as a job of 50,
// and a basket of two products at the first one's margin. Each line is priced
// at what the catalogue PUBLISHED for it, times how many were ordered.

for (const m of ['content-languages', 'product-images', 'product-specs']) require(`../lib/${m}.js`);
require('../lib/storefront-catalog.js');

const PRODUCTS = [
  { id: 'P-TYPED', nameEn: 'Hood', priceOverride: 50 },
  { id: 'P-PUB', nameEn: 'Vase', price: 80, priceOverride: 75 },
  { id: 'P-BASE', nameEn: 'Lamp', basePrice: 33.3 },
  { id: 'P-NONE', nameEn: 'Clip' },
];

test('three of a 50 product is 150, not 50', () => {
  const out = W.linePrices([{ productId: 'P-TYPED', qty: 3 }], { products: PRODUCTS, settings: {} });
  assert.equal(out.total, 150);
  assert.deepEqual(out.lines[0], { productId: 'P-TYPED', qty: 3, unit: 50, total: 150, source: 'typed' });
});

test('a basket keeps each product\'s own price', () => {
  const out = W.linePrices([
    { productId: 'P-TYPED', qty: 2 }, { productId: 'P-PUB', qty: 1 }, { productId: 'P-BASE', qty: 3 },
  ], { products: PRODUCTS, settings: {} });
  assert.deepEqual(out.lines.map((l) => [l.unit, l.source]),
    [[50, 'typed'], [80, 'published'], [33.3, 'published']]);
  assert.equal(out.total, 100 + 80 + 99.9);
});

test('the storefront\'s own price is the one the customer saw, and wins', () => {
  const settings = { storefront: { prices: { 'P-TYPED': '45', 'P-PUB': 0 } } };
  const out = W.linePrices([{ productId: 'P-TYPED', qty: 2 }, { productId: 'P-PUB', qty: 1 }],
    { products: PRODUCTS, settings });
  assert.deepEqual(out.lines.map((l) => [l.unit, l.source]), [[45, 'published'], [0, 'published']],
    '0 is a price — a giveaway is a decision');
  assert.equal(out.total, 90);
});

test('a product nothing published is priced by the host\'s computed figure, else left unpriced', () => {
  const out = W.linePrices([{ productId: 'P-NONE', qty: 2 }, { name: 'a stranger\'s thing', qty: 1 }],
    { products: PRODUCTS, settings: {}, computed: { 'P-NONE': 12.5 } });
  assert.deepEqual(out.lines.map((l) => [l.unit, l.total, l.source]),
    [[12.5, 25, 'computed'], [null, 0, 'none']]);
  assert.equal(out.total, 25);
  assert.equal(out.priced, true);
  const bare = W.linePrices([{ name: 'x', qty: 1 }], { products: PRODUCTS, settings: {} });
  assert.equal(bare.priced, false);
  assert.equal(bare.total, 0);
});

test('the published price is the catalogue builder\'s own rule, not a copy of it', () => {
  const SC = require('../lib/storefront-catalog.js');
  const settings = { storefront: { prices: { 'P-TYPED': '45' } } };
  const built = SC.build({ products: PRODUCTS, settings, withPhotos: false });
  for (const item of built.items) {
    const line = W.linePrices([{ productId: item.id, qty: 1 }], { products: PRODUCTS, settings }).lines[0];
    if (item.price === undefined) assert.notEqual(line.source, 'published', item.id);
    else assert.equal(line.unit, Number(item.price), `${item.id} is published at ${item.price}`);
  }
});

test('what the platform says was paid: every line priced, or nothing said', () => {
  assert.equal(W.paidTotal({ lines: [{ name: 'Hood', qty: 3, unitPrice: 50 }, { name: 'Vase', qty: 1, unitPrice: '80' }] }), 230);
  assert.equal(W.paidTotal({ lines: [{ name: 'Hood', qty: 3, unitPrice: 50 }, { name: 'Vase', qty: 1 }] }), null,
    'half a basket priced is not a total');
  assert.equal(W.paidTotal({ lines: [] }), null);
  assert.equal(W.paidTotal(medusa()), null, 'an open form names no price');
  assert.equal(W.paidTotal({ paidTotal: 99.5, lines: [{ qty: 1, unitPrice: 1 }] }), 99.5);
});

test('paidTotal on a tax-on-top shop is the lines plus the tax the customer paid', () => {
  require('../lib/tax.js');
  require('../lib/order-money.js');
  const salesTax = { currency: 'USD', tax: { name: 'Sales Tax', mode: 'exclusive',
    rates: [{ id: 'st', label: 'Sales tax', percent: 8.25 }] } };
  const vat15 = { currency: 'SAR', enableVat: true, vatRate: 15 };
  const order = { lines: [{ name: 'Hood', qty: 2, unitPrice: 50 }] };
  // Recorded bare, the job read 8.25 short and could never settle.
  assert.equal(W.paidTotal(order, { settings: salesTax }), 108.25);
  // Inclusive: the price already holds the VAT.
  assert.equal(W.paidTotal(order, { settings: vat15 }), 100);
  // No settings: the old answer.
  assert.equal(W.paidTotal(order), 100);
  // An explicit total is already the money that moved.
  assert.equal(W.paidTotal({ paidTotal: 100, lines: order.lines }, { settings: salesTax }), 100);
});
