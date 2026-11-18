'use strict';
/**
 * test/fixtures/business-flag-vectors.json through lib/order-edit.js
 * applyJobEdit: the not-business flag moves only before a tax invoice is
 * issued, and never on a frozen job (Dev Hub, Nov 18). The Mac and the phone
 * run the same file.
 *
 * And the parity that lets order-edit.js carry its own `invoiceIssued`: for
 * every status and flag below it equals lib/accounting-rows.js `isInvoice`
 * (the VAT tax point) for the job as if it were business.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const E = require('../lib/order-edit.js');
const A = require('../lib/accounting-rows.js');
const V = require('./fixtures/business-flag-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

for (const c of V.cases) {
  test(c.why, () => {
    const order = clone(c.order);
    const before = JSON.stringify(order);
    const r = E.applyJobEdit(order, clone(c.next), { now: 1, id: 'e', priceId: 'e2', settings: {}, clients: [] });
    assert.equal(r.ok, c.want.ok, r.reason);
    if (!c.want.ok) {
      assert.equal(r.reason, c.want.reason);
      assert.equal(r.step, c.want.step);
      assert.equal(JSON.stringify(order), before, 'a refusal writes nothing');
      return;
    }
    assert.equal(order.nonBusiness === true, c.want.nonBusiness);
    if (!c.want.nonBusiness) assert.ok(!('nonBusiness' in order), 'cleared, not false');
    if (c.want.internalNotes) assert.equal(order.internalNotes, c.want.internalNotes);
  });
}

test('invoiceIssued equals accounting-rows isInvoice for the job as if it were business', () => {
  const statuses = ['quote', 'pending', 'printing', 'post', 'qc', 'completed', 'on_hold', 'cancelled', 'split'];
  const flags = [{}, { hasQuote: true }, { hasQuote: true, quoteAcceptedAt: 'x' }, { hasQuote: true, clientApprovedAt: 'x' },
    { voidedAt: 'x' }, { creditedAt: 'x' }, { splitInto: ['a'] }, { splitInto: [] }, { nonBusiness: true }];
  let n = 0;
  for (const status of statuses) for (const f of flags) {
    const o = Object.assign({ id: 'P', status, price: 10 }, f);
    const asBusiness = Object.assign({}, o); delete asBusiness.nonBusiness;
    assert.equal(E.invoiceIssued(o), A.isInvoice(asBusiness), JSON.stringify(o));
    n++;
  }
  assert.equal(n, statuses.length * flags.length);
});
