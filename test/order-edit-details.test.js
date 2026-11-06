'use strict';
/**
 * The rest of the order editor — notes, tags, the delivery address, who is on
 * it, and the three terms that move the price — as `lib/order-edit.js` now
 * holds it for both apps. The re-pricing arithmetic is checked against a copy
 * of the desktop's inline original, taken before it moved.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
const E = require('../lib/order-edit.js');

const NOW = Date.parse('2026-11-05T09:00:00.000Z');

/* ── The original, copied from renderer/order-flows.js before the move ─────── */
function originalReprice(order, draft) {
  const prevOldExtra = (order.extraLines || []).reduce((s, l) => s + (+l.amount || 0), 0);
  const newExtraTotal = draft.extraLines.reduce((s, l) => s + Math.max(0, +l.amount || 0), 0);
  if (draft.discountPct !== (order.discountPct || 0) ||
      draft.shippingCost !== (+order.shippingCost || 0) ||
      newExtraTotal !== prevOldExtra) {
    const prevDiscountPct = order.discountPct || 0;
    const prevShipping = +order.shippingCost || 0;
    const sellingBase = order.priceBeforeDiscount ||
      (prevDiscountPct < 100
        ? (+order.price - prevShipping - prevOldExtra) / (1 - prevDiscountPct / 100)
        : (+order.price - prevShipping - prevOldExtra));
    const newPrice = sellingBase * (1 - draft.discountPct / 100) + (+order.agreedAmount || 0) + draft.shippingCost + newExtraTotal;
    order.price = +newPrice.toFixed(2);
    order.discountPct = draft.discountPct;
    order.priceBeforeDiscount = draft.discountPct > 0 ? +sellingBase.toFixed(2) : null;
    order.shippingCost = draft.shippingCost;
  }
}

const JOB = () => ({
  id: 'J1', price: 230, shippingCost: 30, discountPct: 0, paidAmount: 0, paymentStatus: 'unpaid',
  extraLines: [{ id: 'EL1', label: 'Design', amount: 0 }],
});

test('repriceTerms gives the price the desktop editor gave', () => {
  const cases = [
    { discountPct: 10, shippingCost: 30, extraLines: [{ amount: 0 }] },
    { discountPct: 0, shippingCost: 50, extraLines: [{ amount: 0 }] },
    { discountPct: 25, shippingCost: 0, extraLines: [{ amount: 40 }, { amount: 5 }] },
    { discountPct: 100, shippingCost: 10, extraLines: [] },
  ];
  for (const draft of cases) {
    const a = JOB(); const b = JOB();
    originalReprice(a, draft);
    E.repriceTerms(b, draft, {});
    assert.equal(b.price, a.price, JSON.stringify(draft));
    assert.equal(b.priceBeforeDiscount, a.priceBeforeDiscount);
    assert.equal(b.discountPct, a.discountPct);
    assert.equal(b.shippingCost, a.shippingCost);
  }
});

test('repriceTerms keeps a discounted job\'s base and the agreed part amounts', () => {
  const o = { price: 190, priceBeforeDiscount: 200, discountPct: 10, shippingCost: 10, agreedAmount: 0 };
  // 200 base at 10% = 180, + 10 shipping.
  E.repriceTerms(o, { discountPct: 20 }, {});
  assert.equal(o.price, 170);
  assert.equal(o.priceBeforeDiscount, 200);
  const agreed = { price: 150, shippingCost: 0, agreedAmount: 50 };
  E.repriceTerms(agreed, { shippingCost: 20 }, {});
  assert.equal(agreed.price, 220, 'the agreed amount is added on top, never discounted');
});

test('repriceTerms does nothing when none of the three moved', () => {
  const o = JOB();
  assert.equal(E.repriceTerms(o, { discountPct: 0, shippingCost: 30 }, {}), false);
  assert.equal(o.price, 230);
});

test('a lower price caps what was paid and re-reads the status', () => {
  const o = Object.assign(JOB(), { paidAmount: 230, paymentStatus: 'paid' });
  E.repriceTerms(o, { shippingCost: 0 }, {});
  assert.equal(o.price, 200);
  assert.equal(o.paidAmount, 200);
  assert.equal(o.paymentStatus, 'paid');
});

test('applyDetails writes the plain fields the desktop writes, and removes empty ones', () => {
  const o = Object.assign(JOB(), { internalNotes: 'old', courierName: 'DHL' });
  const out = E.applyDetails(o, {
    notes: 'For the window', internalNotes: '', invoiceNotes: 'Thank you',
    courierName: '', trackingNumber: 'TRK1', deliveryAddress: 'Riyadh', operatorId: 'OP1',
    tags: 'resin, urgent, resin',
  }, { now: NOW, id: 'edit-1' });
  assert.equal(out.changed, true);
  assert.equal(o.notes, 'For the window');
  assert.equal('internalNotes' in o, false, 'empty means gone, never ""');
  assert.equal('courierName' in o, false);
  assert.equal(o.invoiceNotes, 'Thank you');
  assert.equal(o.trackingNumber, 'TRK1');
  assert.equal(o.deliveryAddress, 'Riyadh');
  assert.equal(o.operatorId, 'OP1');
  assert.deepEqual(o.tags, ['resin', 'urgent']);
  assert.equal(o.editHistory, undefined, 'none of those is a tracked field');
});

test('applyDetails touches only the fields it is handed', () => {
  const o = Object.assign(JOB(), { notes: 'keep', tags: ['a'], deliveryAddress: 'Jeddah' });
  E.applyDetails(o, { trackingNumber: 'X' }, { now: NOW, id: 'e' });
  assert.equal(o.notes, 'keep');
  assert.deepEqual(o.tags, ['a']);
  assert.equal(o.deliveryAddress, 'Jeddah');
  assert.equal(o.price, 230);
});

test('one history entry for the due date, discount, shipping and priority; the price is its own', () => {
  const o = JOB();
  const out = E.applyDetails(o, {
    dueDate: '2026-11-20', discountPct: 10, priorityLevel: 'urgent', price: 199,
  }, { now: NOW, id: 'edit-1', priceId: 'edit-2' });
  assert.equal(o.editHistory.length, 2);
  assert.deepEqual(Object.keys(o.editHistory[0].fields).sort(),
    ['discountPct', 'dueDate', 'priority', 'priorityLevel']);
  assert.equal(o.editHistory[0].id, 'edit-1');
  assert.equal(o.editHistory[1].id, 'edit-2');
  assert.equal(o.price, 199, 'a typed total is the last word, after the arithmetic');
  assert.equal(o.priceSource, 'override');
  assert.equal(o.priority, true);
  assert.equal(o.dueDate, '2026-11-20');
  assert.ok(out.changes.price && out.changes.dueDate);
});

test('an editor opened and closed changes nothing', () => {
  const o = Object.assign(JOB(), { notes: 'n', tags: ['a'] });
  const out = E.applyDetails(o, { notes: 'n', tags: ['a'], discountPct: 0, shippingCost: 30 },
    { now: NOW, id: 'e' });
  assert.equal(out.changed, false);
  assert.equal(o.editHistory, undefined);
});

test('extra lines are cleaned, priced in, and removed when emptied', () => {
  const o = JOB();
  E.applyDetails(o, { extraLines: [{ id: 'EL1', label: 'Paint', amount: 25 }, { label: 'x', amount: -4 }] },
    { now: NOW, id: 'e' });
  assert.equal(o.price, 255);
  assert.deepEqual(o.extraLines.map((l) => l.amount), [25, 0]);
  E.applyDetails(o, { extraLines: [] }, { now: NOW, id: 'e2' });
  assert.equal(o.price, 230);
  assert.equal('extraLines' in o, false);
});

test('editLog lists the edits newest first, field by field', () => {
  const o = { editHistory: [
    { id: 'a', at: '2026-11-01T10:00:00.000Z', fields: { dueDate: { from: null, to: '2026-11-09' } } },
    { id: 'b', at: '2026-11-02T10:00:00.000Z', fields: { price: { from: 100, to: 120 } } },
  ] };
  const log = E.editLog(o);
  assert.deepEqual(log.map((h) => h.id), ['b', 'a']);
  assert.deepEqual(log[0].fields, [{ field: 'price', from: '100', to: '120' }]);
  assert.deepEqual(log[1].fields, [{ field: 'dueDate', from: '', to: '2026-11-09' }]);
  assert.deepEqual(E.editLog({}), []);
});

test('timeline says how long each stage took, the current one up to now', () => {
  const o = { statusHistory: [
    { status: 'pending', at: '2026-11-01T08:00:00.000Z' },
    { status: 'printing', at: '2026-11-01T10:00:00.000Z' },
    { status: 'completed', at: '2026-11-02T10:00:00.000Z' },
    { status: 'bogus', at: 'not a date' },
  ] };
  const line = E.timeline(o, Date.parse('2026-11-02T11:00:00.000Z'));
  assert.deepEqual(line.steps.map((s) => s.status), ['pending', 'printing', 'completed']);
  assert.deepEqual(line.steps.map((s) => s.ms), [2 * 3600000, 24 * 3600000, 3600000]);
  assert.deepEqual(line.steps.map((s) => s.current), [false, false, true]);
  assert.equal(line.totalMs, 26 * 3600000);
  assert.deepEqual(E.timeline({}, 0), { steps: [], totalMs: 0 });
});

test('custom order fields merge one key at a time; blanks go, and nothing left takes customData away', () => {
  const o = Object.assign(JOB(), { customData: { CF1: 'PO-7', CFgone: 'kept: a field removed from Settings' } });
  E.applyDetails(o, { customData: { CF1: '  PO-8 ', CF2: 'Blue' } }, { now: NOW, id: 'e' });
  assert.deepEqual(o.customData, { CF1: 'PO-8', CFgone: 'kept: a field removed from Settings', CF2: 'Blue' });
  assert.equal(o.editHistory, undefined, 'not a tracked field');
  E.applyDetails(o, { customData: { CF1: '', CF2: '  ', CFgone: '' } }, { now: NOW, id: 'e' });
  assert.equal('customData' in o, false);
  const p = JOB();
  E.applyDetails(p, { notes: 'x' }, { now: NOW, id: 'e' });
  assert.equal('customData' in p, false, 'not handed, not written');
});
