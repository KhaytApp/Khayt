'use strict';
/**
 * Voiding an invoice and issuing a credit note, as `lib/invoice-reversal.js`
 * holds them for both apps. The record shapes are the ones every money figure
 * in lib/ already reads: `voidedAt`, `creditNotes[]`, `creditedAt`.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/order-money.js');
const Pay = require('../lib/order-payment.js');
const R = require('../lib/invoice-reversal.js');

const NOW = '2026-11-05T09:00:00.000Z';
const JOB = () => ({
  id: 'ORD-1', project: 'Lamp', status: 'completed', price: 200, paidAmount: 50, paymentStatus: 'partial',
  material: 'PLA', machineId: 'M1', parts: [{ printWeight: 120 }, { weightG: 30 }],
  statusHistory: [{ status: 'completed', at: '2026-11-01T10:00:00.000Z' }],
});

test('a void stamps the job, keeps its status and says voided', () => {
  const o = JOB();
  const out = R.voidInvoice(o, { reason: '  duplicate ', now: NOW });
  assert.equal(out.ok, true);
  assert.equal(o.voidedAt, NOW);
  assert.equal(o.voidedReason, 'duplicate');
  assert.equal(o.status, 'completed');
  assert.equal(o.paymentStatus, 'voided');
  assert.deepEqual(o.statusHistory.at(-1), { status: 'voided', at: NOW });
  assert.equal(out.waste, null, 'no waste row unless asked for');
  assert.equal(Pay.statusOf(o), 'voided');
});

test('a void with no reason says "Voided", and a second void is refused', () => {
  const o = JOB();
  R.voidInvoice(o, { reason: '', now: NOW });
  assert.equal(o.voidedReason, 'Voided');
  assert.deepEqual(R.voidInvoice(o, { now: NOW }), { ok: false, error: 'already_voided' });
});

test('the material a voided job used can be booked as waste', () => {
  const out = R.voidInvoice(JOB(), { now: NOW, logWaste: true, wasteId: 'W-1', today: '2026-11-05', wasteNote: 'voided' });
  assert.deepEqual(out.waste, {
    id: 'W-1', date: '2026-11-05', orderId: 'ORD-1', machineId: 'M1', material: 'PLA',
    weight: 150, failureType: 'operator_error', notes: 'voided', cost: 0,
  });
  const noWeight = R.voidInvoice({ id: 'x', parts: [] }, { now: NOW, logWaste: true });
  assert.equal(noWeight.waste, null);
});

test('a credit note reduces what is due once, and never touches what was paid', () => {
  const o = JOB();
  const out = R.creditNote(o, { amount: 60, reason: ' defect ', now: NOW, id: 'CN-a' });
  assert.deepEqual(out.note, { id: 'CN-a', amount: 60, reason: 'defect', issuedAt: NOW });
  assert.equal(o.paidAmount, 50);
  assert.equal(o.creditedAt, undefined);
  assert.equal(R.credited(o), 60);
  assert.equal(R.creditRoom(o), 140);
});

test('credit is capped at what is left, and in full it reads as voided', () => {
  const o = JOB();
  R.creditNote(o, { amount: 150, now: NOW, id: 'a' });
  const second = R.creditNote(o, { amount: 500, now: NOW, id: 'b' });
  assert.equal(second.note.amount, 50, 'two notes cannot credit a job twice over');
  assert.equal(o.creditedAt, NOW);
  assert.equal(Pay.statusOf(o), 'voided');
  assert.deepEqual(R.creditNote(o, { amount: 1, now: NOW, id: 'c' }), { ok: false, error: 'nothing_to_credit' });
  const blank = JOB();
  assert.equal(R.creditNote(blank, { amount: '', now: NOW, id: 'd' }).note.amount, 200, 'empty means the rest');
});

test('the credit note document names the job it reverses', () => {
  const o = JOB();
  const { note } = R.creditNote(o, { amount: 60, reason: '<b>defect</b>', now: NOW, id: 'CN-a' });
  const doc = R.creditNoteHtml(o, note, {
    t: (k) => ({ 'doc.credit_note': 'Credit Note', 'cn.reversal_of': 'Reversal of Invoice' })[k] || k,
    shopName: 'Athar', currencySymbol: 'SAR', invoiceNumber: 'INV-2026-0001', jobRef: 'ORD-1',
    fmtMoney: (n) => n.toFixed(2), today: '2026-11-05',
  });
  assert.match(doc.html, /CN-ORD-1/);
  assert.match(doc.html, /Reversal of Invoice: <strong>#INV-2026-0001<\/strong>/);
  assert.match(doc.html, /−60\.00/);
  assert.match(doc.html, /&lt;b&gt;defect&lt;\/b&gt;/, 'the reason is escaped');
  assert.equal(doc.arabicNumerals, false);
  assert.equal(R.creditNoteNumber(o), 'CN-ORD-1');
});

test('the desktop voids and credits through the shared rule', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(require.resolve('../renderer/invoicing.js'), 'utf8');
  for (const call of ['Reversal().voidInvoice(', 'R.creditNote(', 'R.creditNoteHtml(', 'Reversal().creditRoom(']) {
    assert.ok(src.includes(call), `renderer/invoicing.js no longer calls ${call}`);
  }
  const html = fs.readFileSync(require.resolve('../renderer/index.html'), 'utf8');
  assert.ok(html.indexOf('../lib/invoice-reversal.js') > 0
    && html.indexOf('../lib/invoice-reversal.js') < html.indexOf('"invoicing.js"'));
});
