'use strict';
/**
 * test/fixtures/payment-plan-apply-vectors.json through lib/payment-plan.js
 * applyPlan and recordRowPayment (Dev Hub, Nov 18; old-editor retirement
 * step 6). A refusal writes nothing; applyPlan never moves paidAmount; a
 * legacy row (ticked paid, no payment recorded) stays paid, locked and
 * counted exactly as before. The Mac and the phone run the same file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'calculator-cost', 'order-new', 'order-edit']) require('../lib/' + f + '.js');
const PP = require('../lib/payment-plan.js');
const V = require('./fixtures/payment-plan-apply-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));
const ctx = { settings: {}, today: '2026-11-18' };

for (const c of V.cases) {
  test(c.why, () => {
    const order = Object.assign(clone(V.base), clone(c.order));
    const before = clone(order);
    const r = c.op === 'apply' ? PP.applyPlan(order, clone(c.rows), ctx)
      : c.op === 'record' ? PP.recordRowPayment(order, c.rowId, clone(c.payment), ctx)
      : c.op === 'cover' ? PP.coverRow(order, c.rowId, ctx)
      : c.op === 'due' ? { ok: true, due: PP.dueRows(order, c.now).map((x) => x.id) }
      : Object.assign({ ok: true }, PP.allocate(order));
    assert.equal(r.ok, c.want.ok, r.reason);
    if (!c.want.ok) {
      assert.equal(r.reason, c.want.reason);
      if (c.want.over !== undefined) assert.equal(r.over, c.want.over);
      assert.deepEqual(order, before, 'a refusal writes nothing');
      return;
    }
    if (c.want.paidAmount !== undefined) assert.equal(order.paidAmount, c.want.paidAmount, 'paidAmount');
    if (c.op === 'apply') {
      assert.equal(order.paymentStatus, before.paymentStatus, 'applyPlan never touches the payment status');
      assert.equal(order.paidAmount, before.paidAmount, 'applyPlan never moves paidAmount');
    }
    if (c.want.instalmentBase !== undefined) assert.equal(order.instalmentBase, c.want.instalmentBase);
    if (c.want.rows !== undefined) assert.equal((order.instalments || []).length, c.want.rows);
    if (c.want.changed !== undefined) assert.equal(r.changed, c.want.changed, 'changed');
    if (c.want.sameRows) assert.deepEqual(order.instalments, before.instalments, 'every row exactly as stored');
    if (c.want.legacyRow) {
      const row = order.instalments.find((x) => x.id === c.want.legacyRow);
      assert.equal(PP.rowState(row), 'legacy');
      assert.deepEqual(row, before.instalments.find((x) => x.id === c.want.legacyRow), 'the legacy row is not rewritten');
    }
    if (c.want.collectionTotalsPaid !== undefined) {
      const tot = PP.collectionTotals({ price: order.price, paidAmount: order.paidAmount, instalments: order.instalments, instalmentBase: order.instalmentBase });
      assert.equal(tot.paidAmount, c.want.collectionTotalsPaid, 'collectionTotals keeps the legacy book\'s paidAmount: no rise, no drop');
    }
    if (c.want.unallocated !== undefined) assert.equal(r.unallocated, c.want.unallocated, 'unallocated');
    if (c.want.due) assert.deepEqual(r.due, c.want.due, 'the rows a reminder chases');
    if (c.want.states) {
      const got = Object.fromEntries(PP.allocate(order).rows.map((x) => [x.id, x.state]));
      assert.deepEqual(got, c.want.states, 'each row\'s state (allocate)');
    }
    if (c.op === 'cover' || c.op === 'allocate' || c.op === 'due') assert.equal(order.paidAmount, before.paidAmount, 'no money moves');
    if (c.want.rowRecorded) {
      const row = order.instalments.find((x) => x.id === c.want.rowRecorded);
      assert.equal(PP.rowState(row), 'recorded');
      if (c.op === 'record') assert.equal(order.paymentStatus, c.want.paymentStatus);
      if (c.op === 'record') assert.ok(Array.isArray(r.effects) && r.effects.some((e) => e.type === 'save'), 'recordPayment\'s own effects come back for the host');
      if (c.op === 'cover') assert.equal(r.effects, undefined, 'a cover moves no money: no payment effects');
    }
  });
}
