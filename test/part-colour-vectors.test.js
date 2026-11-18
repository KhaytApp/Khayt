'use strict';
/**
 * test/fixtures/part-colour-vectors.json through lib/order-edit.js
 * applyJobEdit: a part's colour is not money (Dev Hub, Nov 18). A colour-only
 * change never reprices and never asks keep-or-new on a seen price, a finished
 * job may still correct it, and a frozen job stays locked. The job is written
 * back with the colour and nothing else moved. The Mac and the phone run the
 * same file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'calculator-cost', 'order-new']) require('../lib/' + f + '.js');
const E = require('../lib/order-edit.js');
const V = require('./fixtures/part-colour-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

for (const c of V.cases) {
  test(c.why, () => {
    const part = Object.assign(clone(V.part), c.colourBefore ? { colour: c.colourBefore } : {});
    const order = Object.assign(clone(c.order), { parts: [part] });
    const before = clone(order);
    const next = clone(part);
    // Cleared with an empty value: applyParts merges each part over its old
    // copy, so a colour left OUT would come back (the sheet sends '').
    next.colour = c.colour;
    const ctx = Object.assign({ now: 1, id: 'e', priceId: 'e2', settings: {}, clients: [] }, clone(c.ctx));
    const r = E.applyJobEdit(order, { parts: [next] }, ctx);
    assert.equal(r.ok, c.want.ok, r.reason);
    if (!c.want.ok) { assert.equal(r.reason, c.want.reason); assert.deepEqual(order, before, 'a refusal writes nothing'); return; }
    assert.equal(order.price, c.want.price, 'the price did not move');
    assert.equal(order.priceSource || null, c.want.priceSource, 'and it was not turned into a typed price');
    assert.equal(order.parts[0].colour, c.colour, 'the colour is saved, or cleared');
    for (const k of ['baseCost', 'unitCost', 'printWeight', 'printTime', 'qty']) assert.equal(order.parts[0][k], before.parts[0][k], k + ' unchanged');
    for (const k of ['priceBeforeDiscount', 'overheadCost', 'discountPct', 'shippingCost']) assert.equal(order[k], before[k], k + ' unchanged');
  });
}
