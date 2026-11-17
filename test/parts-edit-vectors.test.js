'use strict';
/**
 * test/fixtures/parts-edit-vectors.json through lib/order-edit.js applyJobEdit:
 * what a job's price becomes when its parts change, with no markup passed.
 * The Mac (JobEditBridgeTests) and the iPhone run the same file through their
 * own engines.
 *
 * Written for the beta.40 pre-release review: #2523 kept "a price not built
 * from its parts", and took a job priced wholly from AGREED prices for one.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const E = require('../lib/order-edit.js');
const V = require('./fixtures/parts-edit-vectors.json');

for (const c of V.cases) {
  test(c.why, () => {
    const order = JSON.parse(JSON.stringify(c.order));
    const r = E.applyJobEdit(order, { parts: JSON.parse(JSON.stringify(c.parts)) }, JSON.parse(JSON.stringify(V.ctx)));
    assert.equal(r.ok, true, r.reason);
    assert.equal(order.price, c.want.price);
    if (c.want.priceSource === 'none') assert.notEqual(order.priceSource, 'override');
    else if (c.want.priceSource) assert.equal(order.priceSource, c.want.priceSource);
    if (c.want.computedPrice !== undefined) assert.equal(order.computedPrice, c.want.computedPrice);
    assert.equal(order.parts.length, c.parts.length);
  });
}

test('the file covers the agreed-only, mixed, unbuilt and cost-plus jobs', () => {
  assert.ok(V.cases.length >= 13);
  assert.equal(V.cases.filter((c) => /an uncosted part/.test(c.why)).length, 3);
  assert.equal(V.cases.filter((c) => /^agreed only/.test(c.why)).length, 5);
});
