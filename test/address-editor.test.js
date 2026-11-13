'use strict';
/**
 * The desktop address editor's pure helpers (renderer/address-editor.js). The
 * rule itself is lib/customer-address.js; these pin what the screen does with
 * it: the form's layout per country, what a stored row becomes, and that free
 * text is never split.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const A = require('../lib/customer-address.js');
const E = require('../renderer/address-editor.js');

const SA = { shopCountry: 'SA' };

test('Saudi Arabia draws the National Address block; elsewhere it is gone and the order changes', () => {
  const sa = E.editorLayout('SA');
  assert.deepEqual(sa.national, ['shortAddress', 'buildingNumber', 'additionalNumber']);
  assert.deepEqual(sa.fields, ['line1', 'line2', 'line3', 'district', 'city', 'postalCode', 'region']);
  const ae = E.editorLayout('AE');
  assert.deepEqual(ae.national, []);
  assert.deepEqual(ae.fields, ['line1', 'line2', 'line3', 'district', 'city', 'region', 'postalCode']);
  for (const lay of [sa, ae]) assert.ok(!lay.fields.includes('country'), 'country is drawn first, on its own');
});

test('line 1 and the region read differently in Saudi Arabia; the stored key is the same', () => {
  assert.equal(E.fieldLabelKey('line1', 'SA'), 'addr.f.line1_sa');
  assert.equal(E.fieldLabelKey('line1', 'AE'), 'addr.f.line1');
  assert.equal(E.fieldLabelKey('region', 'SA'), 'addr.f.region');
  assert.equal(E.fieldLabelKey('region', 'US'), 'addr.f.region_intl');
  assert.equal(E.fieldLabelKey('city', 'SA'), 'addr.f.city');
  assert.equal(E.warningKey('sa_postalCode'), 'addr.warn.sa_postalCode');
});

test('a form saves its fields and the text; a bad postal code is a warning, not a refusal', () => {
  const r = E.rowFromForm({ id: 'ADDR-1' }, {
    label: 'Workshop', country: 'SA',
    fields: { shortAddress: 'rrrd 2929', buildingNumber: '2929', additionalNumber: '7241', line1: 'Prince Sultan Road',
      district: 'Al Olaya', city: 'Riyadh', postalCode: '1221', recipientName: 'Sample Recipient' },
  }, 'fields', SA);
  assert.equal(r.empty, false);
  assert.deepEqual(r.warnings, [{ field: 'postalCode', code: 'sa_postalCode' }]);
  assert.equal(r.row.shortAddress, 'RRRD2929');
  assert.equal(r.row.address, '2929 Prince Sultan Road\nAl Olaya\nRiyadh 1221-7241\nRRRD2929');
  assert.equal(r.row.textOf, r.row.address);
  assert.equal(r.row.label, 'Workshop');
  assert.equal(r.row.recipientName, 'Sample Recipient');
  assert.equal(A.stateOf(r.row), 'structured');
});

test('leaving Saudi Arabia clears the National Address it no longer draws', () => {
  const r = E.rowFromForm({ id: 'ADDR-2' }, {
    label: '', country: 'AE',
    fields: { shortAddress: 'RRRD2929', buildingNumber: '2929', line1: 'Office 12', city: 'Dubai' },
  }, 'fields', SA);
  assert.equal(r.row.shortAddress, undefined);
  assert.equal(r.row.buildingNumber, undefined);
  assert.equal(r.row.country, 'AE');
  assert.equal(r.row.address, 'Office 12\nDubai\nAE');
});

test('nothing that says where is empty; a country alone does not make a row structured', () => {
  const r = E.rowFromForm({ id: 'ADDR-3' }, { label: 'x', country: 'SA', fields: {} }, 'fields', SA);
  assert.equal(r.empty, true);
  assert.equal(r.row.country, undefined);
  // An old free-text row whose fields were left blank keeps its text.
  const old = { id: 'ADDR-4', label: 'Old shop', address: 'Sample Street near the sample mall, Jeddah' };
  const kept = E.rowFromForm(old, { label: 'Old shop', country: 'SA', fields: {} }, 'fields', SA);
  assert.equal(kept.empty, false);
  assert.equal(kept.row.address, old.address);
  assert.equal(A.stateOf(kept.row), 'unstructured');
});

test('a free-text row edited as text stays text: nothing is split out of it', () => {
  const old = { id: 'ADDR-5', label: 'Old shop', address: 'Sample Street, Jeddah 21577' };
  const r = E.rowFromForm(old, { label: 'Old shop', text: 'Sample Street 2, Jeddah 21577', fields: { recipientName: 'Sample' } }, 'text', SA);
  assert.equal(r.row.address, 'Sample Street 2, Jeddah 21577');
  assert.equal(r.row.city, undefined);
  assert.equal(r.row.postalCode, undefined);
  assert.equal(r.row.recipientName, 'Sample');
  assert.equal(A.stateOf(r.row), 'unstructured');
});

test('one line on screen: fields for display, the text when unsplit or edited elsewhere', () => {
  const row = A.applyFields({ id: 'ADDR-6' }, { line1: 'Olaya St', city: 'الرياض', postalCode: '12345', additionalNumber: '6789' }, SA);
  assert.equal(E.oneLine(row, SA), 'Olaya St, الرياض ‎12345-6789');
  assert.ok(!row.address.includes('‎'), 'the stored text has no mark');
  assert.equal(E.oneLine({ address: 'line a\nline b' }, SA), 'line a, line b');
  const elsewhere = Object.assign({}, row, { address: 'Tahlia St, Jeddah' });
  assert.equal(E.oneLine(elsewhere, SA), 'Tahlia St, Jeddah');
  assert.deepEqual(E.rowHint(elsewhere), { badge: 'check', note: 'addr.edited_elsewhere', tone: 'warn' });
  assert.equal(E.rowHint({ address: 'x' }).note, 'addr.unsplit');
  assert.equal(E.rowHint(row).note, null);
});

test('the country picker knows every code and keeps an unknown one', () => {
  assert.equal(E.COUNTRY_CODES.length, 249);
  const opts = E.countryOptions('en', 'XK');
  assert.ok(opts.some((o) => o.code === 'XK'));
  assert.equal(E.countryName('AE', 'en'), 'United Arab Emirates');
  assert.ok(E.LTR_FIELDS.includes('recipientPhone') && E.LTR_FIELDS.includes('postalCode'));
});
