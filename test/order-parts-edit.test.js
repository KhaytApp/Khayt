'use strict';
/**
 * lib/order-edit.js — changing the parts of a job that already exists
 * (S1 B2): `partsLock`, `marginOf`, `applyParts`, `applyJobEdit`.
 *
 * Turki's rules (Nov 11): parts are free until printing; in production the
 * sheet asks about the price; locked once filament is deducted; fully locked
 * after ZATCA, a void or a credit; a price below what was paid is refused.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/product-price.js');
const Pricing = require('../lib/pricing.js');
require('../lib/order-money.js');
require('../lib/order-payment.js');
const E = require('../lib/order-edit.js');

const part = (id, baseCost, extra) => Object.assign({
  id, name: `Part ${id}`, material: 'PLA', filamentId: 'sp-1', printWeight: 100, supportWeight: 0,
  printTime: 2, qty: 1, unitCost: baseCost, baseCost, partStatus: 'pending',
}, extra || {});

/** A job priced the way newOrder prices one: quoteTotal over its parts. */
function jobOf(parts, terms, extra) {
  const t = Object.assign({ margin: 50, discountPct: 0, shippingCost: 0, extraLines: [], rushEnabled: false, rushPct: 25 }, terms || {});
  const costed = parts.reduce((s, p) => s + (p.agreedPrice != null ? 0 : p.baseCost), 0);
  const agreed = parts.reduce((s, p) => s + (p.agreedPrice != null ? p.agreedPrice * (p.qty || 1) : 0), 0);
  const q = Pricing.quoteTotal(Object.assign({}, t, { baseCost: costed, agreedAmount: agreed, qty: 1 }));
  const rush = q.rushFee > 0 ? +q.rushFee.toFixed(2) : 0;
  return Object.assign({
    id: 'J1', status: 'pending', project: 'Bracket', parts: parts.map((p) => Object.assign({}, p)),
    price: +q.total.toFixed(2), discountPct: t.discountPct,
    priceBeforeDiscount: t.discountPct > 0 ? +q.priceBeforeDiscount.toFixed(2) : null,
    shippingCost: t.shippingCost, extraLines: t.extraLines,
    printTime: parts.reduce((s, p) => s + p.printTime, 0), material: 'PLA', paidAmount: 0,
  }, agreed > 0 ? { agreedAmount: agreed } : {}, rush > 0 ? { rushFee: rush, rushFeeAmount: rush } : { rushFeeAmount: 0 },
  q.priceSource !== 'base' ? { computedPrice: +q.computedTotal.toFixed(2), priceSource: q.priceSource } : {},
  q.priceSource === 'rounded' ? { priceRound: t.priceRound } : {},
  q.priceSource === 'override' ? { priceOverride: +q.total.toFixed(2) } : {}, extra || {});
}
const fresh = (parts, terms) => jobOf(parts, terms).price;

// ── partsLock ─────────────────────────────────────────────────────────────

test('partsLock: free until printing, asked in production, name only once deducted, nothing after the invoice left', () => {
  const lock = (o) => E.partsLock(Object.assign({ status: 'pending' }, o));
  for (const st of ['quote', 'pending', 'on_hold']) {
    assert.deepEqual(lock({ status: st }), { code: null, edit: true, addRemove: true, nameOnly: false, askPrice: false }, st);
  }
  for (const st of ['printing', 'post', 'qc']) {
    const l = lock({ status: st });
    assert.equal(l.code, null, st);
    assert.equal(l.addRemove, true, st);
    assert.equal(l.askPrice, true, `${st}: the sheet asks about the price`);
  }
  for (const o of [{ status: 'completed' }, { status: 'delivered' }, { materialDeducted: true }, { costBasis: 40 }]) {
    assert.deepEqual(lock(o), { code: 'deducted', edit: true, addRemove: false, nameOnly: true, askPrice: false });
  }
  const none = { edit: false, addRemove: false, nameOnly: false, askPrice: false };
  assert.deepEqual(lock({ zatcaUuid: 'u-1' }), Object.assign({ code: 'zatca' }, none));
  assert.deepEqual(lock({ zatcaSubmission: { status: 'cleared' } }), Object.assign({ code: 'zatca' }, none));
  assert.deepEqual(lock({ voidedAt: '2026-11-01' }), Object.assign({ code: 'voided' }, none));
  assert.deepEqual(lock({ creditedAt: '2026-11-01' }), Object.assign({ code: 'credited' }, none));
  assert.deepEqual(lock({ creditNotes: [{ id: 'CN-1' }] }), Object.assign({ code: 'credited' }, none));
  assert.deepEqual(lock({ status: 'cancelled' }), Object.assign({ code: 'cancelled' }, none));
  // ZATCA is said first: it is the one the shop cannot undo.
  assert.equal(lock({ zatcaUuid: 'u', voidedAt: 'x', status: 'completed' }).code, 'zatca');
  assert.equal(E.partsLock(null).code, 'missing');
  // Money taken does NOT lock parts (it locks the customer): the guard is the refusal below.
  assert.equal(lock({ paidAmount: 50 }).code, null);
});

// ── marginOf ──────────────────────────────────────────────────────────────

test('marginOf: read off the job, to two places', () => {
  assert.equal(E.marginOf(jobOf([part('A', 80)], { margin: 50 })), 50);
  assert.equal(E.marginOf(jobOf([part('A', 80), part('B', 20)], { margin: 35 })), 35);
  // The discount, shipping, extras and a rush fee sit on top and do not bend it.
  assert.equal(E.marginOf(jobOf([part('A', 80)], { margin: 40, discountPct: 10, shippingCost: 15,
    extraLines: [{ amount: 7 }], rushEnabled: true })), 40);
  // A stored margin is the answer, whatever the arithmetic would say.
  assert.equal(E.marginOf(Object.assign(jobOf([part('A', 80)], { margin: 50 }), { marginPct: 30 })), 30);
  assert.equal(E.marginOf(jobOf([part('A', 80)], { margin: 0 })), 0, 'at cost is a margin of nothing, not unknown');
});

test('marginOf: null where it cannot be said — typed price, zero price, no parts, nothing costed', () => {
  assert.equal(E.marginOf(jobOf([part('A', 80)], { margin: 50, priceOverride: 200 })), null, 'a typed price');
  // Edited by hand without a marker: seen when the record holds what the
  // price was built from (a discounted job stores its base)…
  const hand = jobOf([part('A', 80)], { margin: 50, discountPct: 10 }); hand.price = 137;
  assert.equal(E.marginOf(hand), null, 'edited by hand without a marker');
  // …and NOT seen otherwise: with no stored base the price is the only
  // evidence, and the margin read is simply the one that price implies.
  const implied = jobOf([part('A', 80)], { margin: 50 }); implied.price = 137;
  assert.equal(E.marginOf(implied), 71.25);
  assert.equal(E.marginOf(Object.assign(jobOf([part('A', 80)]), { price: 0 })), null, 'a zero price');
  assert.equal(E.marginOf({ id: 'J', status: 'pending', price: 100, parts: [] }), null, 'no parts');
  assert.equal(E.marginOf({ id: 'J', status: 'pending', price: 100 }), null, 'no parts field at all');
  assert.equal(E.marginOf(jobOf([part('A', 0, { agreedPrice: 60 })])), null, 'every part has an agreed price');
  assert.equal(E.marginOf(jobOf([part('A', 0)], { margin: 50 })), null, 'parts that cost nothing');
  assert.equal(E.marginOf(jobOf([part('A', 80)], { margin: 50, discountPct: 100 })), null, 'a 100% discount hides it');
  assert.equal(E.marginOf(null), null);
});

// ── applyParts: the price goes forward ────────────────────────────────────

test('adding a part: the price is what a fresh job of the same parts would be', () => {
  const terms = { margin: 50, discountPct: 10, shippingCost: 12, extraLines: [{ label: 'Box', amount: 5 }], rushEnabled: true };
  const a = part('A', 80);
  const o = jobOf([a], terms);
  const b = part(undefined, 40, { name: 'Clip' });
  const r = E.applyParts(o, [a, b], { ids: ['P-new'], now: Date.UTC(2026, 10, 14) });
  assert.equal(r.ok, true);
  assert.equal(o.price, fresh([a, part('P-new', 40)], terms));
  assert.equal(o.parts.length, 2);
  assert.equal(o.parts[1].id, 'P-new', 'a new part takes an id from ctx.ids');
  assert.equal(o.parts[1].partStatus, 'pending');
  assert.equal(o.printTime, 4);
  assert.deepEqual(r.changes.price, { from: fresh([a], terms), to: o.price });
  assert.equal(r.changes.parts.to, 'Part A ×1; Clip ×1');
  // One history entry, with both.
  assert.equal(o.editHistory.length, 1);
  assert.deepEqual(Object.keys(o.editHistory[0].fields).sort(), ['parts', 'price']);
  // The rush fee followed the new subtotal.
  const q = Pricing.quoteTotal(Object.assign({}, terms, { baseCost: 120, qty: 1, rushPct: 25 }));
  assert.equal(o.rushFeeAmount, +q.rushFee.toFixed(2));
  assert.equal(o.priceBeforeDiscount, +q.priceBeforeDiscount.toFixed(2));
});

test('removing a part, and changing one, go forward the same way', () => {
  const terms = { margin: 25 };
  const a = part('A', 80), b = part('B', 40);
  const o = jobOf([a, b], terms);
  assert.equal(E.applyParts(o, [a], {}).ok, true);
  assert.equal(o.price, fresh([a], terms));
  const bigger = Object.assign({}, a, { printWeight: 200, unitCost: 120, baseCost: 120 });
  assert.equal(E.applyParts(o, [bigger], {}).ok, true);
  assert.equal(o.price, fresh([part('A', 120)], terms));
  assert.equal(o.editHistory.length, 2);
});

test('a part that did not change keeps the cost it was frozen at', () => {
  const a = part('A', 80), b = part('B', 40);
  const o = jobOf([a, b], { margin: 50 });
  // The caller re-costed A at today's filament price, and renamed it. Only B changed.
  const recosted = Object.assign({}, a, { name: 'Body', unitCost: 95, baseCost: 95 });
  const changedB = Object.assign({}, b, { qty: 2, unitCost: 40, baseCost: 80 });
  E.applyParts(o, [recosted, changedB], {});
  assert.equal(o.parts[0].baseCost, 80, 'frozen');
  assert.equal(o.parts[0].name, 'Body', 'the label still moves');
  assert.equal(o.parts[1].baseCost, 80);
  assert.equal(o.price, fresh([part('A', 80), part('B', 80)], { margin: 50 }));
});

test('agreed prices are added once and never multiplied by the margin', () => {
  const a = part('A', 80), agreed = part('B', 30, { agreedPrice: 200, qty: 2 });
  const o = jobOf([a], { margin: 50, discountPct: 10 });
  E.applyParts(o, [a, agreed], {});
  assert.equal(o.price, fresh([a, agreed], { margin: 50, discountPct: 10 }));
  assert.equal(o.agreedAmount, 400);
});

test('a rounded job is rounded again by its own rule', () => {
  const terms = { margin: 50, priceRound: { step: 10, mode: 'up' } };
  const a = part('A', 81);
  const o = jobOf([a], terms);
  assert.equal(o.priceSource, 'rounded');
  E.applyParts(o, [a, part('B', 33)], {});
  assert.equal(o.price, fresh([a, part('B', 33)], terms));
  assert.equal(o.price % 10, 0);
  assert.equal(o.computedPrice, 171);
});

test('a typed price stays as typed; only the arithmetic beside it moves', () => {
  const a = part('A', 80);
  const o = jobOf([a], { margin: 50, priceOverride: 150 });
  const r = E.applyParts(o, [a, part('B', 40)], {});
  assert.equal(r.ok, true);
  assert.equal(o.price, 150);
  assert.equal(o.priceSource, 'override');
  assert.equal(o.computedPrice, 180);
  assert.equal(r.changes.price, undefined);
  assert.deepEqual(Object.keys(o.editHistory[0].fields), ['parts']);
});

test('in production the sheet may keep the price: it is then a typed one', () => {
  const a = part('A', 80);
  const o = jobOf([a], { margin: 50 }, { status: 'printing' });
  assert.equal(E.partsLock(o).askPrice, true);
  const r = E.applyParts(o, [a, part('B', 40)], { keepPrice: true });
  assert.equal(r.ok, true);
  assert.equal(o.price, 120, 'kept');
  assert.equal(o.priceSource, 'override');
  assert.equal(o.priceOverride, 120);
  assert.equal(o.computedPrice, 180, 'what the parts now come to');
  // Without it the price follows.
  const p = jobOf([a], { margin: 50 }, { status: 'printing' });
  E.applyParts(p, [a, part('B', 40)], {});
  assert.equal(p.price, 180);
});

// ── applyParts: refusals leave the job untouched ──────────────────────────

test('a change that brings the bill below what was paid is refused, and nothing moves', () => {
  const a = part('A', 80), b = part('B', 40);
  const o = jobOf([a, b], { margin: 50 }, { paidAmount: 150, paymentStatus: 'partial' });
  const before = JSON.stringify(o);
  const r = E.applyParts(o, [a], {});
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'paid_exceeds_price');
  assert.equal(JSON.stringify(o), before, 'untouched: paid is not capped to fit');
  // Exactly paid for what remains is allowed.
  const exact = jobOf([a, b], { margin: 50 }, { paidAmount: 120 });
  assert.equal(E.applyParts(exact, [a], {}).ok, true);
  assert.equal(exact.price, 120);
  assert.equal(exact.paidAmount, 120);
  // A gift card counts as paid.
  const gift = jobOf([a, b], { margin: 50 }, { paidAmount: 100, giftCardDiscount: 50 });
  assert.equal(E.applyParts(gift, [a], {}).reason, 'paid_exceeds_price');
});

test('the refusal reads the bill WITH tax on top, where the shop adds it', () => {
  const a = part('A', 80), b = part('B', 40);
  const settings = { tax: { name: 'VAT', mode: 'exclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15, compound: false }] } };
  // New price 120; with 15% on top the bill is 138. Paid 130 is under it.
  const o = jobOf([a, b], { margin: 50 }, { paidAmount: 130 });
  assert.equal(E.applyParts(o, [a], { settings }).ok, true);
  const p = jobOf([a, b], { margin: 50 }, { paidAmount: 140 });
  assert.equal(E.applyParts(p, [a], { settings }).reason, 'paid_exceeds_price');
});

test('a finished job: a name may change, nothing else', () => {
  const a = part('A', 80), b = part('B', 40);
  const o = jobOf([a, b], { margin: 50 }, { status: 'completed', costBasis: 120, materialDeducted: true });
  const price = o.price;
  const renamed = E.applyParts(o, [Object.assign({}, a, { name: 'Body', partNote: 'sanded' }), b], {});
  assert.equal(renamed.ok, true);
  assert.equal(o.parts[0].name, 'Body');
  assert.equal(o.price, price);
  assert.equal(o.costBasis, 120);
  for (const next of [[a], [a, b, part('C', 10)], [Object.assign({}, a, { qty: 3 }), b],
                      [Object.assign({}, a, { material: 'PETG' }), b], [b, a]]) {
    const before = JSON.stringify(o);
    const r = E.applyParts(o, next, {});
    assert.equal(r.reason, 'name_only');
    assert.equal(JSON.stringify(o), before);
  }
});

test('a part already handed over is fixed, and cannot be removed', () => {
  const a = part('A', 80, { delivered: true }), b = part('B', 40);
  const o = jobOf([a, b], { margin: 50 });
  assert.equal(E.applyParts(o, [b], {}).reason, 'delivered_part');
  assert.equal(E.applyParts(o, [Object.assign({}, a, { qty: 2 }), b], {}).reason, 'delivered_part');
  // The other part may still change, and the delivered one may be relabelled.
  const r = E.applyParts(o, [Object.assign({}, a, { name: 'Delivered body' }), Object.assign({}, b, { baseCost: 60, unitCost: 60, printWeight: 150 })], {});
  assert.equal(r.ok, true);
  assert.equal(o.price, 210);
});

test('locked jobs, an empty list, and no change at all', () => {
  const a = part('A', 80);
  for (const [extra, reason] of [[{ zatcaUuid: 'u' }, 'zatca'], [{ voidedAt: 'x' }, 'voided'],
                                 [{ creditedAt: 'x' }, 'credited'], [{ status: 'cancelled' }, 'cancelled']]) {
    const o = jobOf([a], {}, extra);
    const before = JSON.stringify(o);
    assert.equal(E.applyParts(o, [a, part('B', 10)], {}).reason, reason);
    assert.equal(JSON.stringify(o), before);
  }
  const o = jobOf([a]);
  assert.equal(E.applyParts(o, [], {}).reason, 'no_parts');
  assert.equal(E.applyParts(o, null, {}).reason, 'no_parts');
  const same = E.applyParts(o, [Object.assign({}, a)], {});
  assert.equal(same.ok, true);
  assert.deepEqual(same.changes, {});
  assert.equal(o.editHistory, undefined, 'an editor opened and closed writes nothing');
});

test('a job with no parts, or a zero price, can be given parts', () => {
  // No parts before: there is no margin to read, so the caller says one.
  const empty = { id: 'J', status: 'pending', price: 0, parts: [], paidAmount: 0, discountPct: 0, shippingCost: 0 };
  const r = E.applyParts(empty, [part('A', 80)], { marginPct: 25 });
  assert.equal(r.ok, true);
  assert.equal(empty.price, 100);
  // Without one it is priced at cost, never at nothing and never NaN.
  const atCost = { id: 'J', status: 'pending', price: 0, parts: [], paidAmount: 0 };
  E.applyParts(atCost, [part('A', 80)], {});
  assert.equal(atCost.price, 80);
  // A free job (price 0, costed parts): the factor is unreadable, same rule.
  const free = jobOf([part('A', 80)], { margin: 50 }); free.price = 0; free.priceSource = 'override'; free.priceOverride = 0; free.computedPrice = 120;
  const kept = E.applyParts(free, [part('A', 80), part('B', 40)], {});
  assert.equal(kept.ok, true);
  assert.equal(free.price, 0, 'a typed zero stays zero');
  assert.ok(Number.isFinite(free.computedPrice));
});

// ── applyJobEdit: one edit, all or nothing ────────────────────────────────

test('applyJobEdit: name, parts and details together', () => {
  const a = part('A', 80);
  const o = jobOf([a], { margin: 50 });
  const r = E.applyJobEdit(o, { project: 'Bracket v2', parts: [a, part('B', 40)], notes: 'collects Sunday', shippingCost: 10 }, {});
  assert.deepEqual(r, { ok: true, reason: null, step: null, changed: true });
  assert.equal(o.project, 'Bracket v2');
  assert.equal(o.notes, 'collects Sunday');
  assert.equal(o.price, fresh([a, part('B', 40)], { margin: 50, shippingCost: 10 }));
});

test('applyJobEdit: a refusal anywhere leaves the whole job as it was', () => {
  const a = part('A', 80), b = part('B', 40);
  const o = jobOf([a, b], { margin: 50 }, { paidAmount: 150 });
  const before = JSON.stringify(o);
  const r = E.applyJobEdit(o, { project: 'Renamed', notes: 'x', parts: [a] }, {});
  assert.deepEqual(r, { ok: false, reason: 'paid_exceeds_price', step: 'parts', changed: false });
  assert.equal(JSON.stringify(o), before, 'the name and the note were not written either');
  // A typed total below what was paid is refused too, instead of capping paid.
  const typed = E.applyJobEdit(o, { price: 100 }, {});
  assert.deepEqual(typed, { ok: false, reason: 'paid_exceeds_price', step: 'price', changed: false });
  assert.equal(JSON.stringify(o), before);
  // …and one at or above it is taken.
  assert.equal(E.applyJobEdit(o, { price: 150 }, {}).ok, true);
  assert.equal(o.price, 150);
  assert.equal(o.paidAmount, 150);
});

test('applyJobEdit: nothing named, nothing changed', () => {
  const o = jobOf([part('A', 80)]);
  const before = JSON.stringify(o);
  assert.deepEqual(E.applyJobEdit(o, {}, {}), { ok: true, reason: null, step: null, changed: false });
  assert.deepEqual(E.applyJobEdit(o, { project: o.project }, {}), { ok: true, reason: null, step: null, changed: false });
  assert.equal(JSON.stringify(o), before);
  assert.equal(E.applyJobEdit(null, {}, {}).reason, 'missing');
});
