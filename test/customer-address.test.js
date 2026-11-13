'use strict';
/**
 * A customer's address in fields (Turki, Nov 10; design accepted the same
 * day: ~/Khayt-proposals/customer-address-design.md).
 *
 * The rules these pin:
 *  - nothing is ever parsed out of free text, and the text is always written;
 *  - every row a new build writes is one the old desktop's save can read;
 *  - an old build editing the text of a split row is noticed, and wins;
 *  - the defaults are ids on the client, and a dangling id falls back.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const A = require('../lib/customer-address.js');

/** What the desktop's save did to every row before Nov 2026 (clients.js:1084). */
const oldDesktopSave = (rows) => rows.filter((a) => a.label.trim() || a.address.trim());

const riyadh = {
  id: 'ADDR-1', label: 'Home', address: '',
  buildingNumber: '8228', line1: 'Imam Abdullah Ibn Saud Rd', district: 'Al Mursalat',
  city: 'Riyadh', postalCode: '12345', additionalNumber: '6789', shortAddress: 'RRRD2929', country: 'SA',
};

test('a Saudi address reads as the National Address', () => {
  assert.equal(A.formatAddress(riyadh, { shopCountry: 'SA' }),
    '8228 Imam Abdullah Ibn Saud Rd\nAl Mursalat\nRiyadh 12345-6789\nRRRD2929');
});

test('for display, the postcode after an Arabic city stays one left-to-right number', () => {
  const ar = Object.assign({}, riyadh, { city: 'الرياض', district: 'المرسلات' });
  const plain = A.formatAddress(ar, { shopCountry: 'SA' });
  assert.equal(plain.split('\n')[2], 'الرياض 12345-6789');
  assert.ok(!plain.includes('\u200E'), 'the stored text carries no mark');
  const shown = A.formatAddress(ar, { shopCountry: 'SA', display: true });
  assert.equal(shown.split('\n')[2], 'الرياض \u200E12345-6789');
  // A Latin city needs no mark, nor does a postcode with no separator.
  assert.ok(!A.formatAddress(riyadh, { shopCountry: 'SA', display: true }).includes('\u200E'));
  const noExtra = Object.assign({}, ar, { additionalNumber: '' });
  assert.ok(!A.formatAddress(noExtra, { shopCountry: 'SA', display: true }).includes('\u200E'));
  // Saving never stores the mark, whatever the caller passes.
  const saved = A.applyFields({ id: 'ADDR-9', label: '' }, ar, { shopCountry: 'SA' });
  assert.ok(!saved.address.includes('\u200E') && saved.address === saved.textOf);
  // Elsewhere too: a ZIP+4 after an Arabic place name.
  const us = { line1: '1 Main St', city: 'أوستن', postalCode: '78701-1234', country: 'US' };
  assert.equal(A.formatAddress(us, { shopCountry: 'US', display: true }).split('\n')[1], 'أوستن \u200E78701-1234');
});

test('elsewhere: lines, then "city, region postcode", and the country when it is not the shop\'s', () => {
  const row = { line1: '1 Main St', line2: 'Suite 4', city: 'Austin', region: 'TX', postalCode: '78701', country: 'US' };
  assert.equal(A.formatAddress(row, { shopCountry: 'SA' }), '1 Main St\nSuite 4\nAustin, TX 78701\nUS');
  assert.equal(A.formatAddress(row, { shopCountry: 'SA', countryName: (c) => (c === 'US' ? 'United States' : c) }),
    '1 Main St\nSuite 4\nAustin, TX 78701\nUnited States');
  assert.equal(A.formatAddress(row, { shopCountry: 'US' }), '1 Main St\nSuite 4\nAustin, TX 78701');
});

test('free text is never parsed: an unsplit row stays its text', () => {
  const row = { id: 'ADDR-2', label: 'Work', address: 'King Fahd Rd, Riyadh 12211' };
  assert.equal(A.stateOf(row), 'unstructured');
  assert.equal(A.isStructured(row), false);
  assert.equal(A.textOf(row), 'King Fahd Rd, Riyadh 12211');
  const snap = A.shipTo(row, { phone: '0500000000' });
  assert.equal(snap.city, undefined, 'no city guessed out of the text');
  assert.equal(snap.text, 'King Fahd Rd, Riyadh 12211');
});

test('saving fields writes the text too, and textOf, and keeps keys it does not know', () => {
  const before = { id: 'ADDR-3', label: 'Shop', address: 'old text', courierRef: 'x-1' };
  const after = A.applyFields(before, { line1: 'Olaya St', city: 'Riyadh', postalCode: '١٢٣٤٥' }, { shopCountry: 'SA' });
  assert.equal(after.postalCode, '12345', 'Arabic-Indic digits are stored ASCII');
  assert.equal(after.address, 'Olaya St\nRiyadh 12345');
  assert.equal(after.textOf, after.address);
  assert.equal(after.courierRef, 'x-1');
  assert.equal(before.address, 'old text', 'the row passed in is not changed');
  assert.equal(A.stateOf(after), 'structured');
});

test('an old build editing the text of a split row is noticed, and the text wins', () => {
  const split = A.applyFields({ id: 'ADDR-4', label: '' }, { line1: 'Olaya St', city: 'Riyadh' }, {});
  const editedOnOldDesktop = Object.assign({}, split, { address: 'Tahlia St, Jeddah' });
  assert.equal(A.textEditedElsewhere(editedOnOldDesktop), true);
  assert.equal(A.stateOf(editedOnOldDesktop), 'edited_elsewhere');
  assert.equal(A.textOf(editedOnOldDesktop), 'Tahlia St, Jeddah');
  const snap = A.shipTo(editedOnOldDesktop, null);
  assert.equal(snap.text, 'Tahlia St, Jeddah');
  assert.equal(snap.city, undefined, 'stale fields are not shipped');
  // Saving the fields again makes them the address once more.
  const resaved = A.applyFields(editedOnOldDesktop, { city: 'Jeddah', line1: 'Tahlia St' }, {});
  assert.equal(A.stateOf(resaved), 'structured');
  // A split row from somewhere that writes no textOf (Khayt Cloud) is taken as current.
  assert.equal(A.stateOf({ line1: 'A', city: 'B', address: 'anything' }), 'structured');
});

test('every row a new build writes survives the old desktop\'s save, which throws on a missing label', () => {
  assert.throws(() => oldDesktopSave([{ id: 'r', address: 'x' }]), 'the hazard is real');
  const rows = [
    A.applyFields({}, { line1: 'Olaya St', city: 'Riyadh' }, {}),
    A.applyFields({ id: 'ADDR-5' }, { shortAddress: 'rrrd 2929' }, {}),
    A.rowForOldBuilds({ id: 'from-disk', address: 'kept' }),
    A.rowForOldBuilds({ id: 'odd', label: 7, address: null }),
  ];
  for (const r of rows) {
    assert.equal(typeof r.label, 'string');
    assert.equal(typeof r.address, 'string');
  }
  const kept = oldDesktopSave(rows);
  assert.deepEqual(kept.map((r) => r.address),
    ['Olaya St\nRiyadh', 'RRRD2929', 'kept', ''], 'a split row is kept: it has text (and a label of 7 is "7")');
  assert.deepEqual(A.rowsForOldBuilds([null, 'x', { address: 'y' }]).map((r) => [r.label, r.address]), [['', 'y']]);
});

test('clearing every field of a row leaves its text as an unsplit address', () => {
  const split = A.applyFields({ id: 'ADDR-6', label: 'L' }, { line1: 'Olaya St' }, {});
  const cleared = A.applyFields(split, { line1: '' }, {});
  assert.equal(cleared.line1, undefined);
  assert.equal(cleared.textOf, undefined);
  assert.equal(A.stateOf(cleared), 'unstructured');
  assert.equal(cleared.address, 'Olaya St');
});

test('usable = a first line, a short address, or the old text; anything else is a warning, never a refusal', () => {
  assert.equal(A.validate({ city: 'Riyadh' }).ok, false);
  assert.equal(A.validate({ line1: 'x' }).ok, true);
  assert.equal(A.validate({ shortAddress: 'RRRD2929' }).ok, true);
  assert.equal(A.validate({ address: 'free text' }).ok, true);
  const w = A.validate({ line1: 'x', country: 'SA', postalCode: '1234', buildingNumber: '12', additionalNumber: '67890', shortAddress: 'RR2929' });
  assert.deepEqual(w.warnings.map((x) => x.field).sort(), ['additionalNumber', 'buildingNumber', 'postalCode', 'shortAddress']);
  assert.equal(w.ok, true);
  assert.deepEqual(A.validate({ line1: 'x', country: 'US', postalCode: '1234' }, { shopCountry: 'SA' }).warnings, [],
    'the Saudi forms apply to Saudi addresses only');
  assert.deepEqual(A.validate({ line1: 'x', postalCode: '1234' }, { shopCountry: 'SA' }).warnings.map((x) => x.field),
    ['postalCode'], 'no country = the shop\'s');
  assert.deepEqual(A.validate({ line1: 'x', country: 'Saudi' }).warnings.map((x) => x.code), ['country']);
});

test('fields are cut to Khayt Cloud\'s caps; the old text never is', () => {
  const long = 'x'.repeat(400);
  const row = A.applyFields({ address: long }, { district: long, shortAddress: 'ABCD1234EFGH99', recipientPhone: '٠'.repeat(50) }, {});
  assert.equal(row.district.length, 200);
  assert.equal(row.shortAddress.length, 12);
  assert.equal(row.recipientPhone, '0'.repeat(40));
  assert.equal(A.rowForOldBuilds({ address: 'y'.repeat(900) }).address.length, 900);
});

test('the defaults are ids on the client; a dangling id falls back to the first row; the old top-level text is last', () => {
  const rows = [{ id: 'a', label: '', address: 'First' }, { id: 'b', label: '', address: 'Second' }];
  assert.equal(A.defaultRow({ addresses: rows, defaultShippingId: 'b' }, 'shipping').id, 'b');
  assert.equal(A.defaultRow({ addresses: rows, defaultShippingId: 'b' }, 'billing').id, 'a');
  assert.equal(A.defaultRow({ addresses: rows, defaultBillingId: 'gone' }, 'billing').id, 'a');
  assert.equal(A.defaultRow({ addresses: [{ id: 'blank', label: 'x', address: ' ' }], address: 'CSV text', city: 'Dammam' }, 'shipping').address, 'CSV text');
  assert.equal(A.shipTo(A.defaultRow({ address: 'CSV text', city: 'Dammam' }, 'shipping'), {}).city, 'Dammam',
    'a CSV city was a column of its own, not a guess');
  assert.equal(A.defaultRow({}, 'shipping'), null);
});

test('a job keeps a copy of where it ships; the recipient falls back to the customer', () => {
  const client = { nameEn: 'Acme', phone: '0501112222' };
  const snap = A.shipTo(riyadh, client, { nameOf: (c) => c.nameEn });
  assert.equal(snap.addressId, 'ADDR-1');
  assert.equal(snap.city, 'Riyadh');
  assert.equal(snap.shortAddress, 'RRRD2929');
  assert.equal(snap.recipientName, 'Acme');
  assert.equal(snap.recipientPhone, '0501112222');
  const gift = A.shipTo(Object.assign({}, riyadh, { recipientName: 'Sara', recipientPhone: '٠٥٠٩٩٩', deliveryNotes: 'Gate 3' }), client, {});
  assert.deepEqual([gift.recipientName, gift.recipientPhone, gift.deliveryNotes], ['Sara', '050999', 'Gate 3']);
  assert.equal(A.shipTo({ line1: 'x' }, null, { shopCountry: 'AE' }).country, 'AE', 'the shop\'s country is written down');
  assert.equal(A.shipTo(null, client), null);
});

test('where a job goes: its snapshot, else its typed text, else the customer\'s default', () => {
  const client = { addresses: [{ id: 'a', label: '', address: 'Default row' }] };
  assert.equal(A.shipAddressOf({ shipTo: { text: 'Snap' }, deliveryAddress: 'Typed' }, client), 'Snap');
  assert.equal(A.shipAddressOf({ deliveryAddress: 'Typed' }, client), 'Typed');
  assert.equal(A.shipAddressOf({}, client), 'Default row');
  assert.equal(A.shipAddressOf({}, null), '');
});

test('the form puts the National Address first in Saudi Arabia', () => {
  assert.deepEqual(A.fieldOrder('SA').slice(0, 3), ['country', 'shortAddress', 'buildingNumber']);
  assert.deepEqual(A.fieldOrder('GB').slice(0, 2), ['country', 'line1']);
  assert.deepEqual([...A.fieldOrder('SA')].sort(), [...A.ADDRESS_FIELDS].sort(), 'Saudi Arabia shows every field');
  assert.deepEqual([...A.fieldOrder('US')].sort(), [...A.FIELDS].sort(), 'elsewhere, every field but the National Address');
});

test('the shop\'s country is the tax country it chose, else Saudi Arabia', () => {
  assert.equal(A.shopCountry({ tax: { country: 'ae' } }), 'AE');
  assert.equal(A.shopCountry({}), 'SA');
});
