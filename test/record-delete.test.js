'use strict';
/**
 * Deleting a job or a customer: who may be deleted, and what the delete tidies.
 *
 * The rule is the invoice sequence's: a job with an invoice number, or with
 * any money recorded against it, is cancelled — never deleted.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const D = require('../lib/record-delete.js');

const quote = () => ({ id: 'QUO-2026-0001', status: 'quote', project: 'Vase', invoiceNum: null, invoiceNumber: null, paidAmount: 0 });

test('a quote nobody accepted may be deleted', () => {
  assert.deepEqual(D.canDeleteOrder(quote()), { ok: true, reason: null });
});

test('a job never numbered and never paid may be deleted, whatever its status', () => {
  for (const status of ['pending', 'printing', 'completed', 'cancelled']) {
    assert.equal(D.canDeleteOrder({ id: 'J1', status }).ok, true, status);
  }
});

test('anything invoiced is refused as invoiced', () => {
  const cases = [
    { invoiceNum: 'INV-2026-0003' },
    { invoiceNumber: 'INV-2026-0003' },
    { zatcaUuid: 'abc' },
    { zatcaSubmission: { status: 'cleared' } },
    { creditNotes: [{ amount: 10 }] },
    { voidedAt: '2026-10-01T00:00:00Z' },
    { creditedAt: '2026-10-01' },
  ];
  for (const extra of cases) {
    assert.deepEqual(D.canDeleteOrder({ ...quote(), ...extra }), { ok: false, reason: 'invoiced' }, JSON.stringify(extra));
  }
});

test('anything with a payment is refused as paid', () => {
  const cases = [
    { paidAmount: 5 },
    { depositAmount: 20 },
    { giftCardDiscount: 15 },
    { payments: [{ amount: 3 }] },
    { instalments: [{ amount: 50, paid: true }] },
    { instalments: [{ amount: 50, paidAt: '2026-10-01' }] },
    { paymentPlan: { schedule: [{ amount: 50, paidAt: '2026-10-01' }] } },
  ];
  for (const extra of cases) {
    assert.deepEqual(D.canDeleteOrder({ ...quote(), ...extra }), { ok: false, reason: 'paid' }, JSON.stringify(extra));
  }
});

test('blank and zero values are not an invoice or a payment', () => {
  const o = { ...quote(), invoiceNum: '', invoiceNumber: '  ', paidAmount: '0', depositAmount: 0,
    giftCardDiscount: null, payments: [{ amount: 0 }], instalments: [{ amount: 9, paid: false, paidAt: null }],
    creditNotes: [], zatcaUuid: '' };
  assert.equal(D.canDeleteOrder(o).ok, true);
});

test('invoiced is the reason given when a job is invoiced AND paid', () => {
  assert.equal(D.canDeleteOrder({ id: 'X', invoiceNum: 'INV-1', paidAmount: 9 }).reason, 'invoiced');
});

test('nothing at all is missing', () => {
  assert.deepEqual(D.canDeleteOrder(null), { ok: false, reason: 'missing' });
  assert.deepEqual(D.canDeleteOrder(undefined), { ok: false, reason: 'missing' });
});

function book() {
  return {
    printLog: [
      { id: 'J0', status: 'pending', invoiceNum: 'INV-2026-0001' },
      { id: 'Q1', status: 'quote', photos: ['Q1-0.jpg'], runs: [{ machineId: 'M1' }] },
      { id: 'J2', status: 'completed', paidAmount: 10 },
    ],
    inventory: [
      { id: 'S1', usageHistory: [{ orderId: 'J0', weightUsed: 5 }, { orderId: 'Q1', weightUsed: 12 }, { orderId: 'Q1', weightUsed: 3 }] },
      { id: 'S2', usageHistory: [{ orderId: 'J2', weightUsed: 7 }] },
      { id: 'S3' },
    ],
    expenses: [{ id: 'E1', orderId: 'Q1', amount: 30 }, { id: 'E2', orderId: 'J0', amount: 4 }],
    wasteLog: [{ id: 'W1', orderId: 'Q1', weight: 40 }, { id: 'W2', orderId: null }],
    timeEntries: [{ id: 'T1', orderId: 'Q1', hours: 2 }],
    loyaltyLedger: [{ id: 'L1', orderId: 'Q1', points: 5 }],
  };
}

test('deleting a quote removes only the quote: every row that named it stays, unlinked', () => {
  const b = book();
  const out = D.deleteOrders(b, ['Q1']);
  assert.deepEqual(out.skipped, []);
  assert.equal(out.deleted.length, 1);
  assert.deepEqual(b.printLog.map((o) => o.id), ['J0', 'J2']);
  // The filament was used: the rows stay, grams and all, without the link.
  assert.deepEqual(b.inventory[0].usageHistory,
    [{ orderId: 'J0', weightUsed: 5 }, { orderId: null, weightUsed: 12 }, { orderId: null, weightUsed: 3 }]);
  assert.deepEqual(b.inventory[1].usageHistory, [{ orderId: 'J2', weightUsed: 7 }]);
  // The money was spent: the expense stays, unlinked.
  assert.deepEqual(b.expenses, [{ id: 'E1', orderId: null, amount: 30 }, { id: 'E2', orderId: 'J0', amount: 4 }]);
  // The waste, the hours and the points stay — only the pointer goes.
  assert.deepEqual(b.wasteLog[0], { id: 'W1', orderId: null, weight: 40 });
  assert.deepEqual(b.timeEntries[0], { id: 'T1', orderId: null, hours: 2 });
  assert.deepEqual(b.loyaltyLedger[0], { id: 'L1', orderId: null, points: 5 });
  // Photos and print runs are on the record, and went with it.
  assert.deepEqual(out.deleted[0].order.photos, ['Q1-0.jpg']);
});

test('several at once: only the deletable go, and each refusal says why', () => {
  const b = book();
  const out = D.deleteOrders(b, ['J0', 'Q1', 'J2', 'NOPE', 'Q1']);
  assert.deepEqual(out.deleted.map((d) => d.id), ['Q1']);
  assert.deepEqual(out.skipped, [
    { id: 'J0', reason: 'invoiced' },
    { id: 'J2', reason: 'paid' },
    { id: 'NOPE', reason: 'missing' },
  ]);
  assert.deepEqual(b.printLog.map((o) => o.id), ['J0', 'J2']);
  // A refused job keeps its links.
  assert.equal(b.expenses[1].orderId, 'J0');
  assert.equal(b.inventory[1].usageHistory[0].orderId, 'J2');
});

test('a delete changes no money total and no spool weight', () => {
  const b = book();
  b.inventory[0].weight = 640;
  const sum = (rows, k) => rows.reduce((s, r) => s + (+r[k] || 0), 0);
  const spent = sum(b.expenses, 'amount');
  const used = sum(b.inventory[0].usageHistory, 'weightUsed');
  D.deleteOrders(b, ['Q1']);
  assert.equal(sum(b.expenses, 'amount'), spent);
  assert.equal(sum(b.inventory[0].usageHistory, 'weightUsed'), used);
  assert.equal(b.inventory[0].weight, 640);
});

test('restore puts the job back where it was and relinks every row', () => {
  const before = book();
  const b = book();
  const out = D.deleteOrders(b, ['Q1']);
  // Round-tripped through JSON, as a host's undo holds it.
  D.restoreOrders(b, JSON.parse(JSON.stringify(out.deleted)));
  assert.deepEqual(b, before);
});

test('restore adds nothing twice and leaves a row re-pointed since alone', () => {
  const b = book();
  const out = D.deleteOrders(b, ['Q1']);
  b.wasteLog[0].orderId = 'J0';
  D.restoreOrders(b, out.deleted);
  D.restoreOrders(b, out.deleted);
  assert.equal(b.printLog.filter((o) => o.id === 'Q1').length, 1);
  assert.equal(b.expenses.filter((e) => e.id === 'E1').length, 1);
  assert.equal(b.expenses[0].orderId, 'Q1');
  assert.equal(b.inventory[0].usageHistory.length, 3);
  assert.deepEqual(b.inventory[0].usageHistory.map((h) => h.orderId), ['J0', 'Q1', 'Q1']);
  assert.equal(b.wasteLog[0].orderId, 'J0');
});

test('a book missing collections is handled', () => {
  const b = { printLog: [{ id: 'Q9', status: 'quote' }] };
  const out = D.deleteOrders(b, ['Q9']);
  assert.equal(out.deleted.length, 1);
  assert.deepEqual(b.printLog, []);
  D.restoreOrders(b, out.deleted);
  assert.deepEqual(b.printLog, [{ id: 'Q9', status: 'quote' }]);
});

// ── customers ────────────────────────────────────────────────────────────

const clients = () => [
  { id: 'C1', nameEn: 'Nouf', nameAr: 'نوف' },
  { id: 'C2', nameEn: 'Saad' },
  { id: 'C3', nameEn: 'Reem' },
  { id: 'C4', nameEn: 'Hind' },
];
const orders = () => [
  { id: 'J1', clientId: 'C1', status: 'cancelled' },
  { id: 'J2', clientId: 'C1', status: 'quote', creditNotes: [{ amount: 1 }] },
  { id: 'J3', clientId: null, client: '  saad ' },
  { id: 'J4', clientId: 'C9', client: 'Reem' },
];
const cards = () => [{ id: 'G1', issuedTo: 'C3' }];

test('a customer with jobs in any status is refused, with the count', () => {
  const v = D.canDeleteClient(clients()[0], { orders: orders(), giftCards: cards() });
  assert.equal(v.ok, false);
  assert.equal(v.reason, 'has_jobs');
  assert.equal(v.jobs, 2);
  assert.equal(v.creditNotes, 1);
});

test('an unlinked job carrying their name is theirs; a job linked to someone else is not', () => {
  assert.equal(D.canDeleteClient(clients()[1], { orders: orders() }).jobs, 1);
  const reem = D.canDeleteClient(clients()[2], { orders: orders(), giftCards: cards() });
  assert.equal(reem.jobs, 0);
  assert.equal(reem.reason, 'has_gift_cards');
  assert.equal(reem.giftCards, 1);
});

test('a customer with nothing tied to them may be deleted', () => {
  assert.deepEqual(D.canDeleteClient(clients()[3], { orders: orders(), giftCards: cards() }),
    { ok: true, reason: null, jobs: 0, giftCards: 0, creditNotes: 0 });
});

test('deleteClients removes only the free ones, and restore puts them back in place', () => {
  const b = { clients: clients(), printLog: orders(), giftCards: cards() };
  const before = JSON.parse(JSON.stringify(b));
  const out = D.deleteClients(b, ['C1', 'C4', 'C3']);
  assert.deepEqual(out.deleted.map((d) => d.id), ['C4']);
  assert.deepEqual(out.skipped, [
    { id: 'C1', reason: 'has_jobs', jobs: 2, giftCards: 0 },
    { id: 'C3', reason: 'has_gift_cards', jobs: 0, giftCards: 1 },
  ]);
  assert.deepEqual(b.clients.map((c) => c.id), ['C1', 'C2', 'C3']);
  D.restoreClients(b, out.deleted);
  assert.deepEqual(b, before);
});

test('verdicts lists only the refused', () => {
  const v = D.verdicts({ printLog: [...book().printLog], clients: clients(), giftCards: cards() });
  assert.deepEqual(v.orders, { J0: 'invoiced', J2: 'paid' });
  assert.deepEqual(Object.keys(v.clients).sort(), ['C3']);
  // C1 and C2 own jobs only in `orders()`, not in this book.
  const w = D.verdicts({ printLog: orders(), clients: clients(), giftCards: [] });
  assert.equal(w.clients.C1.reason, 'has_jobs');
  assert.equal(w.clients.C2.jobs, 1);
  assert.equal(w.clients.C4, undefined);
});

test('the desktop\'s two delete paths both go through deleteOrders', () => {
  // Rejecting a quote deletes it. It used to splice printLog by hand, leaving
  // anything booked to the quote pointing at a job that no longer exists.
  const fs = require('fs');
  const path = require('path');
  const bodyOf = (file, fn) => {
    const src = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
    const at = src.indexOf(`async function ${fn}(`);
    return src.slice(at, src.indexOf('\n}', at));
  };
  for (const [file, fn] of [['renderer/order-flows.js', 'deleteLog'], ['renderer/invoicing.js', 'rejectQuote']]) {
    const body = bodyOf(file, fn);
    assert.match(body, /R\.deleteOrders\(/, `${fn} deletes the job itself`);
    assert.match(body, /R\.restoreOrders\(/, `${fn}'s Undo does not relink what it unlinked`);
    assert.doesNotMatch(body, /printLog\.splice\(/, `${fn} splices printLog by hand`);
  }
});
