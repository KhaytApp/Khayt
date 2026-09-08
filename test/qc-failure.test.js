'use strict';
/**
 * A job that failed inspection.
 *
 * Three records, each read by something different: the fields on the ORDER
 * (`qcStatusOf`, `computeQcMetrics`), a DEFECT entry (the analytics screen's
 * defects-by-type table) and a WASTE row (the waste screen, which labels and
 * filters by `failureType`).
 *
 * All three were written in two places and had drifted. Bed Ready's defect
 * carried no `severity` and no `photoRef`, and it never set the inspector — so
 * a failure recorded there answered "how bad was it" with undefined, for ever.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const Q = require('../lib/qc-failure.js');

const NOW = Date.parse('2026-09-04T09:15:00.000Z');
const NOW_ISO = new Date(NOW).toISOString();
const SHELF = [{ material: 'PLA', cost: 80, weight: 1000 }, { material: 'PETG', cost: 0, weight: 0 }];

/* ── The original, copied from renderer/order-flows.js before the move ─────── */
function originalRecord(g, order, { failureType, severity, reason, weight, inspector, photoRef }) {
  const { wasteLog, inventory } = g;
  const nowIso = NOW_ISO;
  const w = Math.max(0, +weight || 0);
  wasteLog.unshift({
    id: 'WASTE-1',
    date: nowIso.split('T')[0],
    material: order.material || '',
    machineId: order.machineId || null,
    weight: w || 0,
    cost: w > 0 ? (() => {
      const inv = inventory.find(i => i.material === order.material);
      return (inv && inv.weight > 0) ? (inv.cost / inv.weight) * w : 0;
    })() : 0,
    reason: reason || 'QC fail',
    orderId: order.id,
    failureType,
  });
  order.qcStatus = 'fail';
  order.qcFailedAt = nowIso;
  order.qcAt = nowIso;
  order.inspector = inspector || order.inspector || null;
  if (!Array.isArray(order.defects)) order.defects = [];
  order.defects.push({ type: failureType, severity: severity || 'major', note: reason || '', photoRef: photoRef || null, at: nowIso });
}

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test('the lifted record and the original agree, field for field', () => {
  const rnd = mulberry32(20260904);
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  for (let i = 0; i < 2000; i++) {
    const order = {
      id: `o${i}`,
      material: pick(['PLA', 'PETG', 'ABS', '', undefined]),
      machineId: rnd() < 0.6 ? 'm1' : undefined,
      inspector: rnd() < 0.3 ? 'OP-OLD' : undefined,
      defects: rnd() < 0.2 ? [{ type: 'old' }] : undefined,
    };
    const failure = {
      failureType: pick(Q.FAILURE_TYPES),
      severity: pick(['major', 'minor', undefined]),
      reason: rnd() < 0.6 ? 'it warped' : '',
      weight: pick([0, 12, 250.5, -5, undefined]),
      inspector: rnd() < 0.4 ? 'OP1' : undefined,
      photoRef: rnd() < 0.2 ? 'photo-1' : undefined,
    };

    const a = { wasteLog: [], inventory: SHELF };
    const orderA = JSON.parse(JSON.stringify(order));
    originalRecord(a, orderA, failure);

    const logB = [];
    const orderB = JSON.parse(JSON.stringify(order));
    Q.record(orderB, failure, {
      now: NOW, inventory: SHELF, wasteLog: logB,
      wasteId: 'WASTE-1', defaultReason: 'QC fail',
    });

    assert.deepEqual(orderB, orderA, `the order diverged: ${JSON.stringify({ order, failure })}`);
    assert.deepEqual(logB, a.wasteLog, `the waste row diverged: ${JSON.stringify(failure)}`);
  }
});

/* ── The rules that are easy to break and hard to notice ───────────────────── */

test('an unclassified failure is major, and its category is one the waste screen knows', () => {
  const order = { id: 'o1', material: 'PLA' };
  Q.record(order, { failureType: 'exploded', severity: 'catastrophic' },
    { now: NOW, inventory: SHELF, wasteLog: [] });
  assert.equal(order.defects[0].type, 'other',
    'a category the waste screen cannot name is worse than "other"');
  assert.equal(order.defects[0].severity, 'major',
    'an unclassified failure that reads as minor is one nobody goes back to look at');
});

test('the failure is on the order, where the metrics look for it', () => {
  const order = { id: 'o1', material: 'PLA' };
  Q.record(order, { failureType: 'warping' }, { now: NOW, inventory: SHELF, wasteLog: [] });
  assert.equal(order.qcStatus, 'fail');
  assert.equal(order.qcFailedAt, NOW_ISO, 'qcStatusOf falls back to this one');
  assert.equal(order.qcAt, NOW_ISO);
});

test('the wasted filament is costed from the spool it came off', () => {
  // 80 riyals per kilo, 250g wasted.
  const order = { id: 'o1', material: 'PLA' };
  const log = [];
  Q.record(order, { failureType: 'warping', weight: 250 },
    { now: NOW, inventory: SHELF, wasteLog: log });
  assert.equal(log[0].cost, 20);

  // A material that is not on the shelf, and one whose spool is empty: an
  // invented cost is worse than an honest zero.
  const petg = { id: 'o2', material: 'PETG' };
  const log2 = [];
  Q.record(petg, { failureType: 'warping', weight: 250 },
    { now: NOW, inventory: SHELF, wasteLog: log2 });
  assert.equal(log2[0].cost, 0);

  const nylon = { id: 'o3', material: 'Nylon' };
  const log3 = [];
  Q.record(nylon, { failureType: 'warping', weight: 250 },
    { now: NOW, inventory: SHELF, wasteLog: log3 });
  assert.equal(log3[0].cost, 0);
});

test('no weight recorded is no waste, not a guess', () => {
  const log = [];
  Q.record({ id: 'o1', material: 'PLA' }, { failureType: 'warping' },
    { now: NOW, inventory: SHELF, wasteLog: log });
  assert.equal(log[0].weight, 0);
  assert.equal(log[0].cost, 0);

  const log2 = [];
  Q.record({ id: 'o2', material: 'PLA' }, { failureType: 'warping', weight: -40 },
    { now: NOW, inventory: SHELF, wasteLog: log2 });
  assert.equal(log2[0].weight, 0, 'a negative weight is not a negative cost');
});

test('the inspector who found it, or the one already on the job', () => {
  const known = { id: 'o1', material: 'PLA', inspector: 'OP-OLD' };
  Q.record(known, { failureType: 'warping' }, { now: NOW, inventory: SHELF, wasteLog: [] });
  assert.equal(known.inspector, 'OP-OLD', 'a shop with no roster does not blank the field');

  const named = { id: 'o2', material: 'PLA', inspector: 'OP-OLD' };
  Q.record(named, { failureType: 'warping', inspector: 'OP-NEW' },
    { now: NOW, inventory: SHELF, wasteLog: [] });
  assert.equal(named.inspector, 'OP-NEW');

  const nobody = { id: 'o3', material: 'PLA' };
  Q.record(nobody, { failureType: 'warping' }, { now: NOW, inventory: SHELF, wasteLog: [] });
  assert.equal(nobody.inspector, null);
});

test('a second failure on the same job is a second defect', () => {
  const order = { id: 'o1', material: 'PLA' };
  Q.record(order, { failureType: 'warping' }, { now: NOW, inventory: SHELF, wasteLog: [] });
  Q.record(order, { failureType: 'stringing' }, { now: NOW, inventory: SHELF, wasteLog: [] });
  assert.equal(order.defects.length, 2, 'the defects-by-type table counts every one');
  assert.deepEqual(order.defects.map(d => d.type), ['warping', 'stringing']);
});

test('the waste row goes on the front, the way the waste screen reads it', () => {
  const log = [{ id: 'older' }];
  Q.record({ id: 'o1', material: 'PLA' }, { failureType: 'warping' },
    { now: NOW, inventory: SHELF, wasteLog: log, wasteId: 'newest' });
  assert.equal(log[0].id, 'newest');
  assert.equal(log.length, 2);
});

test('a caller with no waste log still gets the row back', () => {
  // The Mac app has no `wasteLog` array in memory — it writes the collection
  // itself, inside the same swap as everything else.
  const out = Q.record({ id: 'o1', material: 'PLA' }, { failureType: 'warping', weight: 100 },
    { now: NOW, inventory: SHELF });
  assert.equal(out.waste.orderId, 'o1');
  assert.equal(out.waste.weight, 100);
  assert.deepEqual(out.effects.map(e => e.type), ['save', 'render_waste', 'render_inventory']);
});

test('a QC failure and a waste entry cost the same plastic the same', () => {
  // Two screens, one roll. They each had their own copy of "price divided by
  // weight", so they shared the defect — the plastic growing dearer as the roll
  // emptied — and fixing one would have left them disagreeing about the same
  // 180 g. `qc-failure` delegates to `waste-entry` now; this is what stops it
  // growing a second opinion again.
  require('../lib/spool-edit.js');
  const WasteEntry = require('../lib/waste-entry.js');
  const roll = [{ id: 'sp', material: 'PA-CF', cost: 240, weight: 120, spoolWeight: 500 }];
  for (const grams of [1, 42, 180, 500]) {
    for (const reclaims of [false, true]) {
      assert.equal(Q.wasteCost('PA-CF', grams, roll, reclaims),
                   WasteEntry.costOf('PA-CF', grams, roll, reclaims),
                   `${grams} g, reclaims=${reclaims}`);
    }
  }
  // And the shared answer is the roll's real price per gram, not what is left.
  assert.equal(Math.round(Q.wasteCost('PA-CF', 180, roll, false) * 100) / 100, 86.40);
});
