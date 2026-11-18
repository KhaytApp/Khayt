'use strict';
/**
 * Milestone proformas after a re-price (Turki, Nov 17 2026): an issued one is
 * kept as sent and a difference proforma is offered; one not issued follows
 * the new price. Shared vectors: test/fixtures/milestone-gap-vectors.json.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/payment-reminder.js');
const { cases } = require('./fixtures/milestone-gap-vectors.json');

for (const c of cases) {
  test(c.why, () => {
    const order = JSON.parse(JSON.stringify(c.order));
    const before = JSON.stringify(order);
    const g = R.milestoneGap(order);
    assert.deepEqual({ stale: g.stale, issuedDiff: g.issuedDiff, unissuedDiff: g.unissuedDiff, rows: g.rows.map((r) => [r.id, r.expected, r.diff, r.issued]) }, c.want.gap);
    assert.deepEqual(R.refreshedMilestones(order).map((m) => m.amount), c.want.refreshed);
    assert.deepEqual(R.differenceProforma(order, c.differenceFor, { id: 'MS-NEW' }), c.want.difference);
    assert.equal(JSON.stringify(order), before, 'nothing here changes the order');
  });
}

test('an issued milestone is never changed by the refresh', () => {
  const o = { price: 999, milestoneInvoices: [{ id: 'M1', label: 'Deposit', percentage: 50, amount: 10, issuedAt: '2026-11-10' }] };
  assert.equal(R.refreshedMilestones(o)[0], o.milestoneInvoices[0]);
});

test('a difference row counts as a milestone the job pays down', () => {
  const o = { price: 200, paidAmount: 100, milestoneInvoices: [
    { id: 'M1', label: 'Deposit', percentage: 50, amount: 50, issuedAt: '2026-11-10' },
    { id: 'D1', label: 'Deposit', percentage: null, amount: 50, kind: 'difference', forMilestoneId: 'M1' },
    { id: 'M2', label: 'Rest', percentage: 50, amount: 100 }] };
  assert.deepEqual(R.milestoneBalances(o).map((b) => b.unpaid), [0, 0, 100]);
});
