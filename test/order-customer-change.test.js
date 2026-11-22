'use strict';
/**
 * Changing a job's customer — Turki's rule of Nov 10 (option C).
 *
 * Changeable until the invoice is submitted to ZATCA, voided, credited or
 * paid; then locked. A job with no customer can always be given one. Being
 * numbered is not a lock: every booked job has an invoice number from the
 * moment it is booked, so that would lock everything but quotes.
 *
 * The Mac (KhaytEngine) and the desktop editor both call this one rule.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/record-delete.js');
const E = require('../lib/order-edit.js');

const NOW = Date.parse('2026-11-10T09:00:00.000Z');
const clients = [
  { id: 'C1', nameEn: 'Acme', currency: 'SAR' },
  { id: 'C2', nameEn: 'Beta Co' },
  { id: 'C3', name: 'Euro GmbH', currency: 'EUR' },
];
const ctx = { now: NOW, id: 'E-1', clients, settings: { currency: 'SAR' } };
const booked = (extra) => Object.assign({ id: 'J1', clientId: 'C1', invoiceNumber: 'INV-1001', price: 100, status: 'printing' }, extra);

test('a booked, numbered, unpaid job can change customer — the number is not a lock', () => {
  const o = booked();
  assert.equal(E.customerLocked(o), null);
  const r = E.changeCustomer(o, 'C2', ctx);
  assert.equal(r.ok, true);
  assert.equal(o.clientId, 'C2');
  assert.equal(o.invoiceNumber, 'INV-1001', 'the number stays');
  assert.equal(o.price, 100, 'the agreed price stays');
  assert.deepEqual(o.editHistory, [{ id: 'E-1', at: new Date(NOW).toISOString(), fields: { clientId: { from: 'C1', to: 'C2' } } }]);
});

test('each lock, and the order they are said in', () => {
  const cases = [
    [{ zatcaUuid: 'u-1' }, 'zatca'],
    [{ zatcaSubmission: { icv: 3 } }, 'zatca'],
    [{ voidedAt: '2026-11-01' }, 'voided'],
    [{ creditedAt: '2026-11-01' }, 'credited'],
    [{ creditNotes: [{ id: 'CN-1' }] }, 'credited'],
    [{ paidAmount: 50 }, 'paid'],
    [{ depositAmount: 20 }, 'paid'],
    [{ payments: [{ amount: 10 }] }, 'paid'],
    [{ instalments: [{ paidAt: '2026-11-02' }] }, 'paid'],
    [{ paymentPlan: { schedule: [{ paidAt: '2026-11-02' }] } }, 'paid'],
    [{ giftCardDiscount: 15 }, 'paid'],
    [{ zatcaUuid: 'u', voidedAt: 'x', paidAmount: 5 }, 'zatca'],
    [{ voidedAt: 'x', paidAmount: 5 }, 'voided'],
  ];
  for (const [extra, reason] of cases) {
    const o = booked(extra);
    const before = JSON.stringify(o);
    assert.equal(E.customerLocked(o), reason, JSON.stringify(extra));
    const r = E.changeCustomer(o, 'C2', ctx);
    assert.deepEqual([r.ok, r.reason], [false, reason]);
    assert.equal(JSON.stringify(o), before, 'a refused change leaves the job as it was');
  }
  // Zero is not paid: a payment row of 0, a paid amount of '0'.
  assert.equal(E.customerLocked(booked({ paidAmount: '0', payments: [{ amount: 0 }] })), null);
});

test('a job with no customer can always be given one, even locked', () => {
  for (const extra of [{}, { paidAmount: 100, paymentStatus: 'paid' }, { zatcaUuid: 'u-1' }, { voidedAt: 'x' }]) {
    const o = booked(Object.assign({ clientId: null }, extra));
    const r = E.changeCustomer(o, 'C1', ctx);
    assert.equal(r.ok, true, JSON.stringify(extra));
    assert.equal(o.clientId, 'C1');
  }
  const blank = booked({ clientId: '' });
  assert.equal(E.changeCustomer(blank, 'C2', ctx).ok, true, "'' is no customer");
});

test('taking the customer off is a change like any other — allowed unlocked, refused locked', () => {
  const o = booked();
  assert.equal(E.changeCustomer(o, null, ctx).ok, true);
  assert.equal(o.clientId, null);
  assert.equal(E.changeCustomer(booked({ paidAmount: 1 }), null, ctx).reason, 'paid');
});

test('the same customer, an unknown one, or no job is refused and nothing is written', () => {
  const o = booked();
  assert.equal(E.changeCustomer(o, 'C1', ctx).reason, 'same');
  assert.equal(E.changeCustomer(o, 'NOPE', ctx).reason, 'unknown');
  assert.equal(o.editHistory, undefined);
  assert.equal(E.canChangeCustomer(null, 'C1', ctx).reason, 'missing');
  // Without a client list the id is taken on trust (a caller that has none).
  assert.equal(E.canChangeCustomer(booked(), 'C9', { now: NOW }).ok, true);
});

test('the name is written only on a record that carries one', () => {
  const lan = booked({ client: 'Acme' });
  E.changeCustomer(lan, 'C3', ctx);
  assert.equal(lan.client, 'Euro GmbH');
  assert.deepEqual(lan.editHistory[0].fields.client, { from: 'Acme', to: 'Euro GmbH' });
  const desk = booked();
  E.changeCustomer(desk, 'C2', ctx);
  assert.equal(Object.prototype.hasOwnProperty.call(desk, 'client'), false, 'a desktop/Mac job gets no name field');
  const named = booked({ client: 'Acme' });
  E.changeCustomer(named, 'C2', Object.assign({}, ctx, { nameOf: (c) => `[${c.nameEn}]` }));
  assert.equal(named.client, '[Beta Co]', "the caller's way of naming wins");
});

test('the price and currency stay; another currency is flagged, never converted', () => {
  const o = booked();
  const r = E.changeCustomer(o, 'C3', ctx);
  assert.equal(r.currencyDiffers, true);
  assert.equal(o.currency, undefined);
  assert.equal(o.price, 100);
  assert.equal(E.changeCustomer(booked({ currency: 'EUR' }), 'C3', ctx).currencyDiffers, false);
  assert.equal(E.changeCustomer(booked(), 'C2', ctx).currencyDiffers, false, 'no currency on the customer = the shop’s');
});
