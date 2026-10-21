/**
 * A quote that leaves the quote column has been accepted.
 *
 * `quoteAcceptedAt` was written by exactly ONE path — the Approve button in
 * the invoicing screen. A shop that drags the card to Pending, or picks
 * Pending from the Job menu, or moves it on the Mac app's board, moved the
 * quote without stamping anything. The field is what the quote conversion
 * rate is computed from, so every quote won by dragging counted as a quote
 * never accepted: a shop that works from the board saw a conversion rate that
 * only ever fell.
 *
 * A DELIBERATE CHANGE to lib/order-status.js, so it has its own tests here.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/assembly.js');
const status = require('../lib/order-status.js');

const AT = Date.parse('2026-09-06T10:00:00.000Z');
// The shop's LOCAL day of that instant: quoteAcceptedAt is the VAT tax point
// (pnl-report taxPointDate), so it is written as the day the shop saw. In
// UTC+14, which CI runs under, 10:00Z on the 6th is already the 7th.
const AT_DAY = (() => { const d = new Date(AT);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; })();

test('a quote dragged out of the quote column is stamped accepted', () => {
  for (const to of ['pending', 'printing', 'post', 'qc', 'completed', 'on_hold']) {
    const order = { id: 'Q1', status: 'quote', quoteSentAt: '2026-09-01', parts: [] };
    status.apply(order, to, { now: AT });
    assert.equal(order.quoteAcceptedAt, AT_DAY, `moving a quote to ${to} accepts it`);
  }
});

test('a date already there is never overwritten', () => {
  // The Approve button's own date, and a customer's approval through the
  // portal — which stamps the day they clicked, not the day the shop noticed.
  const order = { id: 'Q1', status: 'quote', quoteAcceptedAt: '2026-08-01', parts: [] };
  status.apply(order, 'pending', { now: AT });
  assert.equal(order.quoteAcceptedAt, '2026-08-01');
});

test('a quote that is cancelled was not accepted', () => {
  const order = { id: 'Q1', status: 'quote', parts: [] };
  status.apply(order, 'cancelled', { now: AT });
  assert.equal(order.quoteAcceptedAt, undefined);
});

test('a job that was never a quote is not given an acceptance date', () => {
  for (const from of ['pending', 'printing', 'post', 'qc', 'completed', 'on_hold']) {
    const order = { id: 'J1', status: from, parts: [] };
    status.apply(order, 'printing', { now: AT });
    assert.equal(order.quoteAcceptedAt, undefined, `${from} → printing must not invent one`);
  }
});

test('a job moved BACK to a quote keeps the date it was accepted on', () => {
  // Re-quoting is a real thing a shop does — a customer changes the spec — and
  // the original acceptance is still the fact it was.
  const order = { id: 'Q1', status: 'pending', quoteAcceptedAt: '2026-08-01', parts: [] };
  status.apply(order, 'quote', { now: AT });
  assert.equal(order.quoteAcceptedAt, '2026-08-01');
});

test('the conversion rate now counts a quote won on the board', () => {
  // The property, end to end: what the analytics screen actually computes.
  const created = [
    { id: 'Q1', status: 'quote', quoteSentAt: '2026-09-01', parts: [] },
    { id: 'Q2', status: 'quote', quoteSentAt: '2026-09-02', parts: [] },
  ];
  status.apply(created[0], 'pending', { now: AT });          // dragged on the board
  created[1].quoteAcceptedAt = '2026-09-03';                  // approved by the button
  const converted = created.filter((o) => o.quoteAcceptedAt);
  assert.equal(converted.length, 2, 'both were won, and both are counted');
});
