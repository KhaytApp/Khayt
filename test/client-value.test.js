'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { clientValue } = require('../lib/client-value.js');

const NOW = Date.parse('2026-09-11T00:00:00Z');
const deps = {
  revenueOf: (o) => o.price,
  countsForBusiness: (o) => o.business !== false,
};
const clients = [
  { id: 'c1', name: 'Najd Architects' },
  { id: 'c2', name: 'Asker Dental' },
  { id: 'c3', name: 'Only Ever Asks' },
];
function run(orders, extra = {}) {
  return clientValue({ clients, orders, now: NOW, ...extra }, deps);
}
const of = (r, id) => r.rows.find((x) => x.clientId === id);

/**
 * THE ONE THIS MODULE EXISTS FOR.
 *
 * The table it replaces counted every order carrying the client's id, with no
 * status check at all — so a customer who asked for ten quotes and bought
 * nothing sat at the top of "lifetime value". That is the one place on the
 * screen that must not reward asking.
 */
test('a quote is not lifetime value, however large', () => {
  const r = run([
    { clientId: 'c3', status: 'quote', date: '2026-09-01', price: 90000 },
    { clientId: 'c1', status: 'completed', date: '2026-09-01', price: 500 },
  ]);
  assert.equal(of(r, 'c1').value, 500);
  assert.equal(r.rows[0].clientId, 'c1', 'a quote-only client outranked a paying one');
  assert.equal(of(r, 'c3'), undefined);
});

test('delivered counts as earned, the same as completed', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-09-01', price: 300 },
    { clientId: 'c1', status: 'delivered', date: '2026-08-01', price: 700 },
  ]);
  assert.equal(of(r, 'c1').value, 1000);
  assert.equal(of(r, 'c1').jobs, 2);
  assert.equal(of(r, 'c1').averageJob, 500);
});

test('a voided order is worth nothing, and work outside the trade is not counted', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-09-01', price: 800 },
    { clientId: 'c1', status: 'completed', date: '2026-09-02', price: 5000, voidedAt: '2026-09-03' },
    { clientId: 'c1', status: 'completed', date: '2026-09-04', price: 5000, business: false },
  ]);
  assert.equal(of(r, 'c1').value, 800);
  assert.equal(of(r, 'c1').jobs, 1);
});

/// Work agreed but not finished. Not lifetime value — nothing has been earned —
/// but a customer with a lot in flight is exactly who a shop should not ignore.
test('work in flight is carried separately, and a quote is not in flight', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-09-01', price: 100 },
    { clientId: 'c1', status: 'printing', date: '2026-09-05', price: 4000 },
    { clientId: 'c1', status: 'quote', date: '2026-09-06', price: 90000 },
  ]);
  assert.equal(of(r, 'c1').value, 100);
  assert.equal(of(r, 'c1').inFlight, 4000, 'a quote nobody agreed to is not in flight');
});

test('last seen is the most recent finished job, by time and not by string', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-06-01', price: 100 },
    // A same-day ISO timestamp must not be out-ranked by a plain day string.
    { clientId: 'c1', status: 'completed', date: '2026-09-01',
      completedAt: '2026-09-01T18:00:00.000Z', price: 100 },
  ]);
  assert.equal(of(r, 'c1').daysSince, 9);
});

test('a customer that has not been back is called quiet; one that never bought is not', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-09-09', price: 100 },
    { clientId: 'c2', status: 'completed', date: '2026-01-01', price: 100 },
    { clientId: 'c3', status: 'quote', date: '2026-09-01', price: 100 },
  ]);
  assert.equal(of(r, 'c1').quiet, false);
  assert.equal(of(r, 'c2').quiet, true);
  // c3 has never bought anything, so it has not gone anywhere — putting it on a
  // churn list is how a list a shop is meant to act on fills with new names.
  assert.equal(r.totals.quiet, 1);
});

test('the quiet threshold is the caller’s to choose', () => {
  const orders = [{ clientId: 'c1', status: 'completed', date: '2026-08-01', price: 100 }];
  assert.equal(of(run(orders, { quietDays: 90 }), 'c1').quiet, false);
  assert.equal(of(run(orders, { quietDays: 30 }), 'c1').quiet, true);
});

/// A shop with 60% of its revenue in one customer has a different business from
/// one with 6%, and the table this replaces could not say which it was.
test('the share of revenue says how badly losing the top one would hurt', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-09-01', price: 9000 },
    { clientId: 'c2', status: 'completed', date: '2026-09-01', price: 1000 },
  ]);
  assert.equal(of(r, 'c1').shareOfRevenue, 0.9);
  assert.equal(r.totals.topShare, 0.9);
  assert.equal(r.totals.earned, 10000);
});

test('best first, and the limit is honoured', () => {
  const r = run([
    { clientId: 'c1', status: 'completed', date: '2026-09-01', price: 100 },
    { clientId: 'c2', status: 'completed', date: '2026-09-01', price: 900 },
  ], { limit: 1 });
  assert.equal(r.rows.length, 1);
  assert.equal(r.rows[0].clientId, 'c2');
  assert.equal(r.totals.clients, 2, 'the totals describe the shop, not the page');
});

test('an order naming a client the book does not have is ignored, not a crash', () => {
  const r = run([{ clientId: 'ghost', status: 'completed', date: '2026-09-01', price: 500 }]);
  assert.equal(r.totals.earned, 0);
  assert.deepEqual(r.rows, []);
});

test('nothing at all is an answer, not a throw', () => {
  const r = clientValue(undefined, undefined);
  assert.deepEqual(r.rows, []);
  assert.equal(r.totals.earned, 0);
  assert.equal(r.totals.topShare, 0);
});
