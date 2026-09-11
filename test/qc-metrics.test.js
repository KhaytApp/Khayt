'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { qcMetrics, qcStatusOf } = require('../lib/qc-metrics.js');

test('QC standing comes from whichever field recorded it', () => {
  assert.equal(qcStatusOf({ qcStatus: 'fail', qcPassedAt: 'x' }), 'fail', 'the explicit field wins');
  assert.equal(qcStatusOf({ qcPassedAt: '2026-09-01' }), 'pass');
  assert.equal(qcStatusOf({ qcFailedAt: '2026-09-01' }), 'fail');
  // Sitting AT the QC stage is neither a pass nor a fail.
  assert.equal(qcStatusOf({ status: 'qc' }), 'pending');
  assert.equal(qcStatusOf({ status: 'printing' }), null);
  assert.equal(qcStatusOf(null), null);
});

test('only inspected work is in the rate; pending and un-inspected are not', () => {
  const m = qcMetrics([
    { id: 'a', qcStatus: 'pass' },
    { id: 'b', qcStatus: 'fail' },
    { id: 'c', status: 'qc' },
    { id: 'd', status: 'printing' },
  ]);
  assert.equal(m.qcd, 2);
  assert.equal(m.passed, 1);
  assert.equal(m.failed, 1);
  assert.equal(m.passRate, 0.5);
});

/**
 * THE CORRECTION.
 *
 * `passRate: 0` renders as "0% pass", i.e. everything failed — about a shop
 * that has simply never inspected anything.
 */
test('a shop that has never inspected anything has no rate, not a rate of nought', () => {
  const m = qcMetrics([{ id: 'a', status: 'printing' }]);
  assert.equal(m.passRate, null);
  assert.equal(m.firstPassYield, null);
  assert.equal(m.qcd, 0, 'and it says how much there is behind that');
});

/**
 * Pass rate is the easy figure and the less useful one: a shop that reprints
 * until it passes has a pass rate near 100% and a quality problem.
 */
test('a reprint chain is one job for first-pass yield', () => {
  const m = qcMetrics([
    { id: 'a', qcStatus: 'fail' },
    { id: 'b', qcStatus: 'pass', reprintOf: 'a', reprintChain: 'a' },
    { id: 'c', qcStatus: 'pass' },
  ]);
  assert.equal(m.passRate, 2 / 3, 'two of three inspections passed');
  assert.equal(m.roots, 2, 'but there were only two jobs');
  assert.equal(m.firstPassYield, 0.5, 'and only one was right first time');
});

test('reprinting until it passes does not make the yield look good', () => {
  const m = qcMetrics([
    { id: 'a', qcStatus: 'fail' },
    { id: 'b', qcStatus: 'fail', reprintOf: 'a', reprintChain: 'a' },
    { id: 'c', qcStatus: 'pass', reprintOf: 'b', reprintChain: 'a' },
  ]);
  assert.equal(m.roots, 1);
  assert.equal(m.firstPass, 0);
  assert.equal(m.firstPassYield, 0, 'nothing was right first time, and that is a real zero');
});

/// A shop can go and do something about "layer shift" and nothing about a
/// percentage.
test('defects are counted by kind, and the commonest is named', () => {
  const m = qcMetrics([
    { id: 'a', qcStatus: 'fail', defects: [{ type: 'layer_shift' }, { type: 'warping' }] },
    { id: 'b', qcStatus: 'fail', defects: [{ type: 'layer_shift' }] },
    { id: 'c', qcStatus: 'fail', defects: [{}] },
  ]);
  assert.equal(m.defectsByType.layer_shift, 2);
  assert.equal(m.defectsByType.warping, 1);
  assert.equal(m.defectsByType.other, 1, 'a defect with no kind is not dropped');
  assert.equal(m.worstDefect.type, 'layer_shift');
  assert.equal(m.worstDefect.count, 2);
});

/// What the shop ate putting it right, not what the customer was charged,
/// which was nothing.
test('warranty work is counted, and costed at what the reprint cost', () => {
  const m = qcMetrics([
    { id: 'a', rma: { openedAt: '2026-09-01' } },
    { id: 'b', reprintReason: 'rma', costBasis: 120.456 },
    { id: 'c', reprintReason: 'quality', costBasis: 900 },
  ]);
  assert.equal(m.rmaCount, 1);
  assert.equal(m.rmaCost, 120.46);
});

test('nothing at all is an answer, not a throw', () => {
  const m = qcMetrics(undefined);
  assert.equal(m.qcd, 0);
  assert.equal(m.passRate, null);
  assert.equal(m.worstDefect, null);
  assert.deepEqual(m.defectsByType, {});
});
