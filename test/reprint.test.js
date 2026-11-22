/**
 * `lib/reprint.js` — the linked reprint after a QC failure, as both apps make
 * it. The desktop's `applyReprintMeta` delegates here (test/qc-reprint.test.js
 * holds that); this file holds `create`, the path the Mac takes.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
require('../lib/order-new.js');
const R = require('../lib/reprint.js');
const Q = require('../lib/qc-metrics.js');

const tokens = () => ({ tracking: new Array(16).fill(1), quoteApproval: new Array(16).fill(2) });
const failed = () => ({
  id: 'INV-2026-0007', project: 'Falcon hood', clientId: 'CLI-1', client: 'Nora', status: 'qc',
  productId: 'PRD-HOOD', price: 120, discountPct: 0, shippingCost: 0,
  materialDeducted: true, qcStatus: 'fail',
  parts: [{ id: 'PRT-1', name: 'Shell', qty: 2, printWeight: 40, printTime: 2, filamentId: 'SP-1',
            spoolCost: 100, spoolWeight: 1000, baseCost: 1, partStatus: 'done' }],
});

test('a QC-failed job with QC on is kept as a scrapped record in the QC stage', () => {
  const o = failed();
  R.markScrapped(o, '2026-11-04T10:00:00Z');
  assert.equal(o.scrapped, true);
  assert.equal(o.status, 'qc', 'not sent back to Pending');
  assert.deepEqual(o.statusHistory, [{ status: 'qc', at: '2026-11-04T10:00:00Z', note: 'QC failed' }]);
});

test('a shop-cost reprint is a new job through newOrder, free, linked both ways', () => {
  const log = [failed()];
  const settings = { invNumNext: 8, invNumYear: 2026, defaultMargin: 50 };
  const out = R.create('INV-2026-0007', log, {
    settings, now: new Date('2026-11-04T10:00:00Z'), tokens: tokens(),
    inventory: [], consumables: [], clients: [], reason: 'qc_fail', cost: 'shop', partIdBase: 'PRT-R',
  });
  const job = out.order;
  assert.equal(job.jobNumber, 'INV-2026-0008', 'the shared id rule: the next invoice number');
  assert.match(job.id, /^INV-2026-0008-[a-z0-9]{4}$/, 'collision-free id (#2210)');
  assert.equal(out.settings.invNumNext, 9, 'the counter advanced, for the caller to write back');
  assert.equal(job.status, 'pending');
  assert.equal(job.reprintOf, 'INV-2026-0007');
  assert.equal(job.reprintReason, 'qc_fail');
  assert.equal(job.reprintCost, 'shop');
  assert.equal(job.reprintChain, 'INV-2026-0007');
  assert.equal(job.price, 0);
  assert.equal(job.reprintNoCharge, true);
  assert.equal(job.client, 'Nora');
  assert.deepEqual(job.parts.map((p) => [p.id, p.qty, p.partStatus]), [['PRT-R-P1', 2, 'pending']]);
  assert.ok(job.parts[0].baseCost > 1, 'costed again as a line total, not copied');
  assert.equal(out.printLog[0], job, 'newest first');
  const orig = out.printLog.find((o) => o.id === 'INV-2026-0007');
  assert.deepEqual(orig.reprintedInto, [job.id], 'linked by id, which carries the #2210 tag');
  assert.equal(orig.materialDeducted, true, 'the failed job\'s material is never touched');
  assert.deepEqual(log[0].reprintedInto, undefined, 'the log handed in is not changed');
});

test('a billable reprint keeps its price at the shop\'s margin', () => {
  const out = R.create('INV-2026-0007', [failed()], {
    settings: { defaultMargin: 50 }, now: new Date('2026-11-04T10:00:00Z'), tokens: tokens(),
    reason: 'qc_fail', cost: 'billable',
  });
  assert.ok(out.order.price > 0);
  assert.equal(out.order.reprintCost, 'billable');
  assert.equal(out.order.reprintNoCharge, undefined);
});

test('the QC figures see the reprint: the chain counts once, and not first time', () => {
  const o = failed();
  R.markScrapped(o, 'x');
  const out = R.create(o.id, [o], { settings: {}, now: new Date('2026-11-04T10:00:00Z'), tokens: tokens(), cost: 'shop' });
  const passed = Object.assign({}, out.order, { status: 'completed', qcStatus: 'pass', qcPassedAt: 'y' });
  const m = Q.qcMetrics([passed, out.printLog[1]]);
  assert.equal(m.firstPassYield, 0, 'the chain passed only after a reprint');
});

test('no such job: nothing is made', () => {
  assert.equal(R.create('NOPE', [failed()], { settings: {}, tokens: tokens() }), null);
});
