'use strict';
/**
 * U1 idea 4: per-head actuals, one record per print. test/fixtures/head-
 * actuals-vectors.json through lib/printer-actuals.js perHeadActuals (the
 * Mac and the phone run the same file), and recordHeadActuals' rule that a
 * print is written once: a re-poll, the other app, or a second call changes
 * nothing, and it never adds to actualWeight.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../lib/printer-actuals.js');
const V = require('./fixtures/head-actuals-vectors.json');

for (const c of V.cases) test(c.why, () => assert.deepEqual(A.perHeadActuals(c.job), c.want));

test('the heads add up to the measured total, in mm and (to the rounding) in grams', () => {
  for (const c of V.cases.filter((x) => x.want)) {
    const mm = c.want.heads.reduce((a, h) => a + h.mm, 0);
    assert.ok(Math.abs(mm - c.want.totalMm) < 0.2, c.why);
    assert.ok(Math.abs(c.want.heads.reduce((a, h) => a + h.grams, 0) - c.want.totalG) < 0.011, c.why);
  }
});

test('a print is recorded once: a re-poll and the other app change nothing', () => {
  const r = A.perHeadActuals(V.cases[0].job);
  const order = { id: 'J1', actualWeight: 6.67 };
  const first = A.recordHeadActuals(order, r);
  assert.equal(first.changed, true);
  assert.equal(first.order.actualsByHead.key, 'moonraker-history:00004F');
  assert.equal(first.order.actualWeight, 6.67, 'a breakdown of the same print, never added to actualWeight');
  const again = A.recordHeadActuals(first.order, A.perHeadActuals(V.cases[0].job));
  assert.equal(again.changed, false, 're-poll');
  assert.equal(again.order, first.order);
  // The other app wrote it first (same key, its own copy of the figures).
  const theirs = { ...order, actualsByHead: { ...first.order.actualsByHead } };
  assert.equal(A.recordHeadActuals(theirs, r).changed, false);
});

test('a different print on the same order (a reprint) replaces the record; nothing measured changes nothing', () => {
  const first = A.recordHeadActuals({ id: 'J1' }, A.perHeadActuals(V.cases[0].job)).order;
  const re = A.recordHeadActuals(first, A.perHeadActuals(V.cases[1].job));
  assert.equal(re.changed, true);
  assert.equal(re.order.actualsByHead.jobId, '000101');
  assert.deepEqual(A.recordHeadActuals(first, null), { order: first, changed: false });
});

test('junk in: no record, nothing thrown', () => {
  for (const j of [null, 'x', 7, {}, { job_id: {}, filament_used: 5 }, { job_id: 'A', filament_used: 'lots' },
    { job_id: 'A', filament_used: 100, metadata: { filament_weight: 'x', filament_used_mm: null } },
    { job_id: 'A', filament_used: 100, metadata: { filament_weight: [-5, NaN], filament_used_mm: [-1] } }]) {
    assert.equal(A.perHeadActuals(j), null, JSON.stringify(j));
  }
  // More than 16 entries: only the first 16 heads are read.
  const many = A.perHeadActuals({ job_id: 'B', filament_used: 100, metadata: { filament_weight: Array(40).fill(1), filament_used_mm: Array(40).fill(10) } });
  assert.equal(many.heads.length, 16);
});
