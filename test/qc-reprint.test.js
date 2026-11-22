const { test } = require('node:test');
const assert = require('node:assert/strict');
const flows = require('../renderer/order-flows.js');

test('QC helpers are exported', () => {
  for (const name of [
    'qcStatusOf', 'inspectorInitials', 'reprintChainRoot', 'applyReprintMeta',
    'computeWithinWarranty', 'computeQcMetrics', 'recordQcFailure',
    'createLinkedReprint', 'openRmaModal',
  ]) {
    assert.equal(typeof flows[name], 'function', name);
  }
});

test('qcStatusOf: explicit wins, else derived from legacy fields / stage', () => {
  assert.equal(flows.qcStatusOf({ qcStatus: 'fail', qcPassedAt: 'x' }), 'fail');
  assert.equal(flows.qcStatusOf({ qcPassedAt: '2026-01-01' }), 'pass');
  assert.equal(flows.qcStatusOf({ qcFailedAt: '2026-01-01' }), 'fail');
  assert.equal(flows.qcStatusOf({ status: 'qc' }), 'pending');
  assert.equal(flows.qcStatusOf({ status: 'printing' }), null);
  assert.equal(flows.qcStatusOf(null), null);
});

test('inspectorInitials: up to two letters, uppercase', () => {
  const ops = [{ id: 'op1', name: 'sara noor' }, { id: 'op2', name: 'Ali' }];
  assert.equal(flows.inspectorInitials('op1', ops), 'SN');
  assert.equal(flows.inspectorInitials('op2', ops), 'A');
  assert.equal(flows.inspectorInitials('nope', ops), '');
});

test('applyReprintMeta (shop): zero-charge, links original, NEVER touches its material', () => {
  const orig = { id: 'O1', materialDeducted: true, costBasis: 5 };
  const reprint = { id: 'O2', price: 100, priceBeforeDiscount: 120, paymentStatus: 'unpaid', paidAmount: 0 };
  flows.applyReprintMeta(reprint, { of: 'O1', reason: 'qc_fail', cost: 'shop', chain: 'O1' }, [orig, reprint]);
  assert.equal(reprint.reprintOf, 'O1');
  assert.equal(reprint.reprintReason, 'qc_fail');
  assert.equal(reprint.reprintChain, 'O1');
  assert.equal(reprint.price, 0);
  assert.equal(reprint.priceBeforeDiscount, null);
  assert.equal(reprint.reprintNoCharge, true);
  assert.equal(reprint.paymentStatus, 'paid');
  assert.deepEqual(orig.reprintedInto, ['O2']);
  // Core correctness rule: the failed job's deduction is untouched.
  assert.equal(orig.materialDeducted, true);
});

test('applyReprintMeta (billable): keeps calculator price, still links back', () => {
  const orig = { id: 'O1' };
  const reprint = { id: 'O2', price: 100, priceBeforeDiscount: 120 };
  flows.applyReprintMeta(reprint, { of: 'O1', reason: 'qc_fail', cost: 'billable', chain: 'O1' }, [orig, reprint]);
  assert.equal(reprint.price, 100);
  assert.ok(!reprint.reprintNoCharge);
  assert.equal(reprint.reprintCost, 'billable');
  assert.deepEqual(orig.reprintedInto, ['O2']);
});

test('applyReprintMeta (rma): links the warranty record to the replacement', () => {
  const orig = { id: 'D1', rma: { resolution: 'reprint', reprintId: null } };
  const rep = { id: 'D2', price: 50 };
  flows.applyReprintMeta(rep, { of: 'D1', reason: 'rma', cost: 'shop', chain: 'D1' }, [orig, rep]);
  assert.equal(orig.rma.reprintId, 'D2');
});

test('applyReprintMeta: dedups reprintedInto on repeat', () => {
  const orig = { id: 'O1', reprintedInto: ['O2'] };
  const rep = { id: 'O2' };
  flows.applyReprintMeta(rep, { of: 'O1', reason: 'manual', cost: 'billable', chain: 'O1' }, [orig, rep]);
  assert.deepEqual(orig.reprintedInto, ['O2']);
});

test('computeWithinWarranty: inside vs outside the window', () => {
  const now = Date.parse('2026-07-19T00:00:00Z');
  const recent = '2026-07-10T00:00:00Z'; // 9 days ago
  const old = '2026-05-01T00:00:00Z';    // ~79 days ago
  assert.equal(flows.computeWithinWarranty(recent, 30, now), true);
  assert.equal(flows.computeWithinWarranty(old, 30, now), false);
  assert.equal(flows.computeWithinWarranty(null, 30, now), false);
});

test('computeQcMetrics: first-pass yield collapses a reprint chain to one root', () => {
  // O1 failed → O2 (reprint of O1) failed → O3 (reprint of O2) passed; O4 passed first try.
  const orders = [
    { id: 'O1', qcStatus: 'fail' },
    { id: 'O2', qcStatus: 'fail', reprintOf: 'O1', reprintChain: 'O1' },
    { id: 'O3', qcStatus: 'pass', reprintOf: 'O2', reprintChain: 'O1' },
    { id: 'O4', qcStatus: 'pass' },
  ];
  const m = flows.computeQcMetrics(orders);
  assert.equal(m.qcd, 4);
  assert.equal(m.passed, 2);
  assert.equal(m.failed, 2);
  assert.equal(m.roots, 2);       // {O1 chain, O4}
  assert.equal(m.firstPass, 1);   // only O4 passed as an original
  assert.equal(m.firstPassYield, 0.5);
});

test('computeQcMetrics: defect categories + RMA count/cost', () => {
  const orders = [
    { id: 'O1', qcStatus: 'fail', defects: [{ type: 'warping' }, { type: 'stringing' }] },
    { id: 'O2', qcStatus: 'fail', defects: [{ type: 'warping' }] },
    { id: 'D1', status: 'delivered', rma: { resolution: 'reprint' } },
    { id: 'D2', reprintReason: 'rma', costBasis: 12.5 },
  ];
  const m = flows.computeQcMetrics(orders);
  assert.equal(m.defectsByType.warping, 2);
  assert.equal(m.defectsByType.stringing, 1);
  assert.equal(m.rmaCount, 1);
  assert.equal(m.rmaCost, 12.5);
});

test('recordQcFailure: writes waste row + defect + qcStatus, AND takes the filament off the shelf', () => {
  global.wasteLog = [];
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 1000, cost: 100 }]; // 0.1/g
  global.settings = {};
  global.machines = [];
  global.localDateStr = () => '2026-09-06';
  global.uid = (p) => p + '-1';
  global.num = (v, d) => { const n = Number(v); return Number.isFinite(n) ? n : d; };
  global.t = (k) => k;
  const order = { id: 'O9', material: 'PLA', machineId: 'M1',
                  parts: [{ filamentId: 'S1', printWeight: 200, qty: 1 }] };
  flows.recordQcFailure(order, { failureType: 'warping', severity: 'major', reason: 'edge lift', weight: 50, inspector: 'op1' });
  assert.equal(global.wasteLog.length, 1);
  assert.equal(global.wasteLog[0].failureType, 'warping');
  assert.equal(global.wasteLog[0].weight, 50);
  assert.equal(Math.round(global.wasteLog[0].cost), 5); // 50g * 0.1
  assert.equal(order.qcStatus, 'fail');
  assert.equal(order.inspector, 'op1');
  assert.equal(order.defects.length, 1);
  assert.equal(order.defects[0].type, 'warping');
  assert.equal(order.defects[0].severity, 'major');
  assert.ok(order.qcFailedAt && order.qcAt);

  /* THE SHELF. It used to be left alone — the waste row recorded the grams and
   * their cost, and the inventory was untouched — so the filament a failed
   * attempt really burned through never left the shelf, and a shop's stock read
   * high by the grams of every failure it had ever had. */
  assert.equal(global.inventory[0].weight, 950, 'the 50g it got through came off the spool');
  assert.equal(global.wasteLog[0].spoolId, 'S1', 'and the row remembers which spool, so it can be put back');
  assert.equal(global.inventory[0].usageHistory[0].orderId, 'O9',
    'and the spool remembers which job burned it');
});

test('a failed print with no parts to draw from takes nothing, and says nothing came off', () => {
  // A job whose parts carry no filament — Bed Ready logs these from printer
  // history — has no spool to charge. The waste is still recorded.
  global.wasteLog = [];
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 1000, cost: 100 }];
  global.settings = {};
  global.machines = [];
  global.localDateStr = () => '2026-09-06';
  global.uid = (p) => p + '-1';
  global.t = (k) => k;
  const order = { id: 'O10', material: 'PLA', parts: [] };
  const out = flows.recordQcFailure(order, { failureType: 'other', weight: 50 });
  assert.equal(global.inventory[0].weight, 1000);
  assert.equal(out.deducted, 0);
  assert.equal(global.wasteLog[0].weight, 50, 'the waste is still recorded and still costed');
});
