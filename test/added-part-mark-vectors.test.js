'use strict';
/**
 * test/fixtures/added-part-mark-vectors.json through KhaytOrderMoney.addedPartMark,
 * at the switch's shipped setting and flipped. The Mac runs the same file
 * through JavaScriptCore (partsForSave).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const Mo = require('../lib/order-money.js');
const V = require('./fixtures/added-part-mark-vectors.json');

test('the switch ships as the fixture says (Turki, Nov 19: own labour)', () => {
  assert.equal(Mo.HAND_PARTS_SHARE_ONCE, V.switch);
});

for (const c of V.cases) {
  test(c.why, () => {
    assert.equal(Mo.addedPartMark(c.order), c.want);
    const was = Mo.HAND_PARTS_SHARE_ONCE;
    try { Mo.HAND_PARTS_SHARE_ONCE = true; assert.equal(Mo.addedPartMark(c.order), c.flipped, 'flipped'); }
    finally { Mo.HAND_PARTS_SHARE_ONCE = was; }
  });
}
