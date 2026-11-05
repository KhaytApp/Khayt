'use strict';
/**
 * A customer-reported defect on a delivered job — `lib/reprint.js openRma` —
 * the record the desktop's RMA sheet wrote inline, now written by both apps.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
require('../lib/order-new.js');
const R = require('../lib/reprint.js');

const NOW = '2026-11-05T09:00:00.000Z';

test('the warranty window is thirty days unless the shop says otherwise', () => {
  const now = Date.parse(NOW);
  assert.equal(R.withinWarranty('2026-10-20T09:00:00.000Z', undefined, now), true);
  assert.equal(R.withinWarranty('2026-09-20T09:00:00.000Z', undefined, now), false);
  assert.equal(R.withinWarranty('2026-10-20T09:00:00.000Z', 7, now), false);
  assert.equal(R.withinWarranty(null, 30, now), false);
  assert.equal(R.withinWarranty('nonsense', 30, now), false);
});

test('an RMA is recorded as the desktop recorded it', () => {
  const o = { id: 'J1' };
  const out = R.openRma(o, { reason: ' split ', resolution: 'refund', withinWarranty: true, reportedBy: 'OP1', now: NOW });
  assert.deepEqual(o.rma, { reportedAt: NOW, reportedBy: 'OP1', reason: 'split', withinWarranty: true,
                            resolution: 'refund', reprintId: null });
  assert.equal(out.reprintCost, null);
});

test('a reprint resolution says who pays: the shop within warranty', () => {
  assert.equal(R.openRma({}, { resolution: 'reprint', withinWarranty: true, now: NOW }).reprintCost, 'shop');
  assert.equal(R.openRma({}, { resolution: 'reprint', withinWarranty: false, now: NOW }).reprintCost, 'billable');
  const odd = {};
  R.openRma(odd, { resolution: 'whatever', now: NOW });
  assert.equal(odd.rma.resolution, 'reprint');
  assert.equal(odd.rma.reason, null);
});

test('the RMA reprint links back into the record', () => {
  const log = [{ id: 'J1', project: 'Lamp', parts: [], price: 100, rma: null }];
  R.openRma(log[0], { resolution: 'reprint', withinWarranty: true, now: NOW });
  const made = R.create('J1', log, { settings: {}, now: Date.parse(NOW), reason: 'rma', cost: 'shop',
                                     tokens: { tracking: [1, 2, 3], quoteApproval: [4, 5, 6] } });
  const original = made.printLog.find((o) => o.id === 'J1');
  assert.equal(original.rma.reprintId, made.order.id);
  assert.equal(made.order.reprintReason, 'rma');
  assert.equal(made.order.price, 0);
});
