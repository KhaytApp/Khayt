'use strict';
/**
 * What the shop threw away, by month and by why.
 *
 * Lifted from an inline chart whose failure-type names did not match the
 * waste log's own vocabulary — the test for that is first.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/waste-trend.js');

const NOW = new Date(2026, 8, 16, 10, 0, 0).getTime();
const entry = (date, failureType, weight) => ({ id: 'W', date, failureType, weight, material: 'PLA' });

test('the named types come from the DATA, so a failed first layer is not "other"', () => {
  // The original named `adhesion`; the log says `bed_adhesion`. Every one landed in "other".
  const log = [
    entry('2026-09-01', 'bed_adhesion', 300),
    entry('2026-09-02', 'bed_adhesion', 200),
    entry('2026-08-10', 'warping', 120),
    entry('2026-07-05', 'stringing', 40),
    entry('2026-07-06', 'nozzle_jam', 30),
    entry('2026-06-01', 'power_failure', 10),
  ];
  const r = W.wasteTrend(log, { now: NOW });
  assert.deepEqual(r.types, ['bed_adhesion', 'warping', 'stringing', 'other'], 'heaviest three, then the rest');
  assert.equal(r.byType.bed_adhesion, 500);
  assert.equal(r.byType.other, 40, 'nozzle jam and power failure fell outside the three');
  assert.equal(r.total, 700);
  assert.equal(r.entries, 6);
});

test('six months ending with this one, and a month with nothing thrown away is ZERO', () => {
  // Unlike hours printed, zero waste is a real and good answer.
  const r = W.wasteTrend([entry('2026-09-01', 'warping', 50)], { now: NOW });
  assert.deepEqual(r.months.map((m) => m.key), ['2026-04', '2026-05', '2026-06', '2026-07', '2026-08', '2026-09']);
  assert.equal(r.months[0].total, 0);
  assert.equal(r.months[0].entries, 0);
  assert.deepEqual(r.months[0].byType, {});
  assert.equal(r.months[5].total, 50);
  assert.deepEqual(r.months[5].byType, { warping: 50 });
});

test('"other" appears only when something falls in it, and an unnamed type is other', () => {
  const two = W.wasteTrend([entry('2026-09-01', 'warping', 50), entry('2026-09-02', 'stringing', 20)], { now: NOW });
  assert.deepEqual(two.types, ['warping', 'stringing'], 'nothing left over, no "other" column');
  const blank = W.wasteTrend([entry('2026-09-01', '', 50), entry('2026-09-02', undefined, 20)], { now: NOW });
  assert.deepEqual(blank.types, ['other']);
  assert.equal(blank.byType.other, 70);
  // A log that says "other" itself stays other, however heavy.
  const said = W.wasteTrend([entry('2026-09-01', 'other', 900), entry('2026-09-02', 'warping', 1)], { now: NOW });
  assert.deepEqual(said.types, ['warping', 'other']);
});

test('entries outside the window, and junk, are left out without a NaN', () => {
  const r = W.wasteTrend([
    entry('2025-01-01', 'warping', 999), entry('2027-01-01', 'warping', 999),
    entry('', 'warping', 5), entry('garbage', 'warping', 5), null, {},
    entry('2026-09-01', 'warping', 'x'), entry('2026-09-01', 'warping', -20),
  ], { now: NOW });
  assert.equal(r.total, 0);
  assert.equal(r.entries, 2, 'the two in-window entries with no usable weight still count as entries');
  for (const m of r.months) assert.ok(Number.isFinite(m.total));
});

test('the number of named types is the caller\'s, and ties break by name so the columns are stable', () => {
  const log = [entry('2026-09-01', 'warping', 10), entry('2026-09-01', 'stringing', 10), entry('2026-09-01', 'nozzle_jam', 10)];
  assert.deepEqual(W.wasteTrend(log, { now: NOW, named: 1 }).types, ['nozzle_jam', 'other']);
  assert.deepEqual(W.wasteTrend(log, { now: NOW, named: 0 }).types, ['other']);
  assert.deepEqual(W.wasteTrend(log, { now: NOW }).types, ['nozzle_jam', 'stringing', 'warping']);
});
