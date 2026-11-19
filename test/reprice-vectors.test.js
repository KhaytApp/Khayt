'use strict';
/**
 * test/fixtures/reprice-vectors.json through lib/order-edit.js applyJobEdit
 * { reprice }: a job priced again from its parts is priced EXACTLY as
 * lib/order-new.js newOrder prices it (each case's job is made by newOrder,
 * then disturbed, then repriced), under a typed price's locks. The Mac and
 * the phone run the same file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'calculator-cost', 'order-new', 'order-edit']) require('../lib/' + f + '.js');
const N = globalThis.KhaytOrderNew;
const E = globalThis.KhaytOrderEdit;
const V = require('./fixtures/reprice-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

function make(c, settings) {
  const input = Object.assign({ parts: [clone(V.part)], project: 'R', margin: settings.defaultMargin }, clone(c.cart), { asQuote: !!c.asQuote });
  return N.newOrder(input, { settings, orders: [], clients: [{ id: 'CU', currency: 'USD' }], consumables: clone(c.makeConsumables || []), now: new Date('2026-11-19T08:00:00Z'),
    tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
}

for (const c of V.cases) {
  test(c.why, () => {
    const settings = clone(V.settings);
    const order = make(c, settings);
    if (c.want.price !== undefined && !c.req.marginPct) assert.equal(order.price, c.want.price, 'newOrder priced it at the figure the case expects');
    const madeAt = order.price;
    for (const k of c.unset || []) delete order[k];
    // Disturbed: a price typed over it, and whatever the case sets.
    Object.assign(order, { price: c.typed, priceSource: 'override', priceOverride: c.typed, computedPrice: c.typed }, clone(c.set || {}));
    if (c.laterRates) settings.exchangeRates = clone(c.laterRates);
    const before = clone(order);
    const r = E.applyJobEdit(order, { reprice: clone(c.req) }, Object.assign({ now: Date.parse('2026-11-19T09:00:00Z'), id: 'e', priceId: 'p', settings, clients: [] }, clone(c.ctx || {})));
    assert.equal(r.ok, c.want.ok, r.reason);
    if (!c.want.ok) { assert.equal(r.reason, c.want.reason); assert.equal(r.step, 'reprice'); assert.deepEqual(clone(order), before, 'a refusal writes nothing'); return; }
    assert.equal(order.price, c.want.priceFromNewOrder ? madeAt : c.want.price, 'the price newOrder gives');
    if (c.want.priceFromNewOrder) assert.ok(order.componentsCost > 0 && madeAt > 104, 'the components are in it');
    if (c.want.usedMarkup !== undefined) assert.equal(r.marginPct, c.want.usedMarkup, 'the markup the reprice used');
    if (c.want.typedGone) { assert.notEqual(order.priceSource, 'override'); assert.equal('priceOverride' in order, false); }
    if (c.want.logged) assert.ok(order.editHistory.some((h) => h.fields && h.fields.price && h.fields.price.to === c.want.price), 'the price change is logged');
    if (c.want.lineAmounts) assert.deepEqual(order.extraLines.map((l) => l.amount), c.want.lineAmounts);
  });
}
