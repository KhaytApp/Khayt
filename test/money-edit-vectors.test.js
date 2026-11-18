'use strict';
/**
 * test/fixtures/money-edit-vectors.json through lib/order-edit.js applyJobEdit
 * (beta.40 money review, Nov 17). Each job was made by newOrder, and each
 * expected price is what a FRESH newOrder of the edited job costs, so a pass
 * means an edit prices a job exactly as taking it new would:
 *   HIGH  a 100% discount kept no markup, so lifting it priced parts at cost;
 *   HIGH  a percentage extra line (a fee, a card surcharge) kept its old amount;
 *   MED   the overhead line ignored a new quantity or print time;
 *   LOW   2.5 of a part counted as 3 here and 2.5 in newOrder;
 *   LOW   a negative agreed price turned the part into a costed one.
 * And `unexplainedShare`, which the Mac's sheet asks before passing the shop's
 * markup for an all-agreed job (Mac #2537). The Mac runs the same file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'calculator-cost', 'order-new']) require('../lib/' + f + '.js');
const E = require('../lib/order-edit.js');
const V = require('./fixtures/money-edit-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

for (const c of V.cases) {
  test(c.why, () => {
    const order = clone(c.order);
    if (c.want.unexplainedShareBefore !== undefined) {
      assert.ok(Math.abs(E.unexplainedShare(order) - c.want.unexplainedShareBefore) < 0.005, 'unexplainedShare');
    }
    const ctx = Object.assign({ now: 1, id: 'e', priceId: 'e2', ids: ['N1', 'N2'], settings: clone(V.settings), clients: [], priceSeenOk: true }, clone(c.ctx));
    const r = E.applyJobEdit(order, clone(c.next), ctx);
    assert.equal(r.ok, c.want.ok, r.reason);
    if (!c.want.ok) { assert.equal(r.reason, c.want.reason); return; }
    assert.ok(Math.abs(order.price - c.want.price) < 0.005, `${order.price} != ${c.want.price}`);
    if (c.want.extraLines) assert.deepEqual(order.extraLines.map((l) => +(+l.amount).toFixed(2)), c.want.extraLines.map((v) => +(+v).toFixed(2)));
    if (c.want.overheadCost !== undefined) assert.equal(order.overheadCost, c.want.overheadCost);
    if (c.want.priceBeforeDiscount !== undefined) assert.equal(order.priceBeforeDiscount, c.want.priceBeforeDiscount);
  });
}

test('unexplainedShare is pricedFrom\'s base: 0 on an all-agreed discounted job', () => {
  const N = globalThis.KhaytOrderNew;
  const o = N.newOrder({ parts: [{ id: 'B', name: 'b', qty: 1, agreedPrice: 100 }], discountPct: 10 },
    { settings: { currency: 'SAR' }, orders: [], now: new Date(1800000000000), tokens: { id: new Uint8Array([1, 2, 3, 4]) } });
  assert.equal(E.unexplainedShare(o), 0);
});

test('the order editor (applyDetails): a new discount resolves a percentage line at the new price, not the draft\'s old amount', () => {
  const N = globalThis.KhaytOrderNew;
  const lines = [{ label: 'Fee', pct: 10, fee: true }];
  const o = N.newOrder({ parts: [{ id: 'A', name: 'a', qty: 1, printWeight: 50, baseCost: 100 }], margin: 0, extraLines: lines },
    { settings: { currency: 'SAR' }, orders: [], now: new Date(1800000000000), tokens: { id: new Uint8Array([1, 2, 3, 4]) } });
  assert.equal(o.price, 111.11);
  // The editor sends the lines as it holds them: the fee at its OLD amount.
  E.applyDetails(o, { discountPct: 50, extraLines: clone(o.extraLines) }, { now: 1, id: 'e', settings: { currency: 'SAR' } });
  assert.equal(o.price, 55.56);
  assert.equal(+o.extraLines[0].amount.toFixed(2), 5.56);
});
