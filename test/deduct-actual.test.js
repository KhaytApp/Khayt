/**
 * A print takes its filament off the shelf, whatever the result — and it takes
 * what it ACTUALLY used.
 *
 * Two changes to how a shop's stock is kept, and both are deliberate:
 *
 *  1. A FAILED PRINT DEDUCTS. It used not to: the waste row recorded the grams
 *     and their cost and the inventory was left alone, while the reprint later
 *     deducted only its own. So the filament a failed attempt really burned
 *     through never left the shelf, and a shop's stock read high by the grams
 *     of every failure it had ever had.
 *  2. THE AMOUNT CAN COME FROM THE PRINTER. A print that stopped at 40% did not
 *     use what it was quoted, and the printer is the only thing that knows how
 *     far it got.
 *
 * The claims split — which spool each part draws from, and the shortfall rule
 * that covers what a chosen spool cannot supply — is unchanged, and
 * test/order-deduction.test.js still proves it against the original.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const D = require('../lib/order-deduction.js');
const A = require('../lib/printer-actuals.js');

const shelf = () => [
  { id: 'S1', material: 'PLA', weight: 1000, cost: 90 },
  { id: 'S2', material: 'PLA', weight: 500, cost: 90 },
  { id: 'S3', material: 'PETG', weight: 800, cost: 120 },
];
const job = () => ({
  id: 'J1',
  parts: [
    { filamentId: 'S1', printWeight: 100, supportWeight: 20, qty: 2 },  // 240 g
    { filamentId: 'S3', printWeight: 60, qty: 1 },                      //  60 g
  ],
});

test('the claims are the estimate, part by part, off the assigned spools', () => {
  const claims = D.claimsFor(job(), shelf());
  assert.deepEqual(claims.map((c) => [c.spool.id, c.grams]), [['S1', 240], ['S3', 60]]);
  assert.equal(D.claimedGrams(claims), 300);
});

test('nothing measured means the estimate, which is what Khayt has always deducted', () => {
  const claims = D.claimsFor(job(), shelf());
  for (const nothing of [undefined, null, 0, -5, NaN, 'x']) {
    assert.equal(D.scaleFor(claims, nothing), 1, String(nothing));
  }
  const inv = shelf();
  D.deductForOrder(job(), { settings: { autoDeduct: true }, inventory: inv, today: 'd' });
  assert.equal(inv[0].weight, 760);
  assert.equal(inv[2].weight, 740);
});

test('a measured total scales every part, so each spool is charged its share', () => {
  // 150 g measured against a 300 g estimate: half of each part, off each part's
  // own spool. Deducting one lump from the first spool would charge PLA for
  // PETG and leave the shelf wrong in two places rather than one.
  const inv = shelf();
  D.deductForOrder(job(), { settings: { autoDeduct: true }, inventory: inv, today: 'd', actualGrams: 150 });
  assert.equal(inv[0].weight, 880, '120 g of the PLA');
  assert.equal(inv[2].weight, 770, '30 g of the PETG');
});

test('a print that used MORE than it was quoted deducts more, rather than being capped', () => {
  // A shelf that refuses to believe a measurement is a shelf that drifts.
  const inv = shelf();
  D.deductForOrder(job(), { settings: { autoDeduct: true }, inventory: inv, today: 'd', actualGrams: 600 });
  assert.equal(inv[0].weight, 520, 'twice the estimate off the PLA');
  assert.equal(inv[2].weight, 680);
});

test('a job with no estimate to scale falls back to the estimate path', () => {
  // Scaling by a total when there is nothing to scale is a division by zero,
  // and a shelf cannot be charged infinity.
  const empty = { id: 'J2', parts: [] };
  assert.equal(D.scaleFor(D.claimsFor(empty, shelf()), 500), 1);
  const inv = shelf();
  const out = D.deductForOrder(empty, { settings: { autoDeduct: true }, inventory: inv, today: 'd', actualGrams: 500 });
  assert.deepEqual(out.notices, []);
  assert.equal(inv[0].weight, 1000, 'nothing to draw from, so nothing is drawn');
});

/* ── A failed print ─────────────────────────────────────────────────────── */

test('a failed print draws from the same spools a completion would have', () => {
  const inv = shelf();
  const out = D.deductActual(job(), 150, { settings: {}, inventory: inv, today: 'd' });
  assert.equal(out.deducted, 150);
  assert.deepEqual(out.spools, ['S1', 'S3']);
  assert.equal(inv[0].weight, 880);
  assert.equal(inv[2].weight, 770);
  assert.equal(inv[0].usageHistory[0].orderId, 'J1', 'and the spool remembers which job');
});

test('a failed print does not mark the job deducted, so the reprint still pays', () => {
  const order = job();
  const inv = shelf();
  D.deductActual(order, 100, { settings: {}, inventory: inv, today: 'd' });
  assert.equal(order.materialDeducted, undefined,
    'the job is not done — the reprint must deduct its own');
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory: inv, today: 'd' });
  assert.equal(inv[0].weight, 1000 - 80 - 240, 'the failed attempt AND the reprint');
});

test('the shortfall rule still holds: a spool that ran out is covered by its siblings', () => {
  const inv = shelf();
  inv[0].weight = 50;                    // S1 nearly empty
  const out = D.deductActual(job(), 300, { settings: {}, inventory: inv, today: 'd' });
  assert.equal(out.deducted, 300);
  assert.equal(inv[0].weight, 0, 'the assigned spool is emptied first');
  assert.equal(inv[1].weight, 500 - 190, 'and the rest comes off the other PLA');
  assert.equal(inv[2].weight, 740);
});

test('a failed print takes nothing when there is nothing to take', () => {
  for (const grams of [0, -1, null, undefined, 'x']) {
    const inv = shelf();
    assert.deepEqual(D.deductActual(job(), grams, { settings: {}, inventory: inv, today: 'd' }),
      { deducted: 0, spools: [], drawn: [], nowLow: [] }, String(grams));
    assert.equal(inv[0].weight, 1000);
  }
  const inv = shelf();
  assert.equal(D.deductActual({ id: 'J3', parts: [] }, 100, { settings: {}, inventory: inv, today: 'd' }).deducted, 0);
});

test('a spool that goes low is reported, so the shop can order more', () => {
  const inv = shelf();
  inv[0].weight = 300;                   // 240 g comes off it, leaving 60
  const out = D.deductActual(job(), 300, { settings: { lowStockThreshold: 200 }, inventory: inv, today: 'd' });
  assert.equal(inv[0].weight, 60);
  assert.ok(out.nowLow.some((s) => s.id === 'S1'), 'the PLA is under its threshold');
  assert.ok(!out.nowLow.some((s) => s.id === 'S3'), 'and the PETG, which is not, is not reported');
});

/* ── What the printer says a failed print got through ───────────────────── */

test('the measured grams are used, and only when something measured them', () => {
  const now = Date.now();
  const estimate = { printTime: 8, weightG: 300 };
  const measured = A.measuredSoFar({
    estimate,
    completion: { at: now - 1000, actuals: { filamentGrams: 96, durationS: 3600, source: 'moonraker' } },
    now,
  });
  assert.deepEqual(measured, { grams: 96, source: 'moonraker' });

  // NOT the estimate. `prefillActuals` falls back to it, which is right for a
  // completion and exactly wrong for a failure: offering the whole-job figure
  // as the default invites a shop to confirm a number that is certainly too
  // big, and the grams come off the shelf now.
  assert.equal(A.prefillActuals({ estimate, completion: null, now }).weightG, 300);
  assert.equal(A.measuredSoFar({ estimate, completion: null, now }), null);

  // A printer that reports time but not filament — OctoPrint, PrusaLink and
  // Bambu, for reasons lib/printer-actuals.js explains at length — measures
  // nothing here.
  assert.equal(A.measuredSoFar({
    estimate,
    completion: { at: now - 1000, actuals: { filamentGrams: null, durationS: 3600, source: 'octoprint' } },
    now,
  }), null);

  // And a reading too old to be about this job is not a reading.
  assert.equal(A.measuredSoFar({
    estimate,
    completion: { at: now - 1000 * 60 * 60 * 24 * 30, actuals: { filamentGrams: 96, source: 'moonraker' } },
    now,
  }), null);
});

/* ── Waste logged against a job ─────────────────────────────────────────── */

test('waste logged against a job comes off that job\'s spools, not the first of a material', () => {
  const W = require('../lib/waste-entry.js');
  // Two PLA spools; the job prints from the SECOND. Taking the grams off the
  // first — which is what a material lookup does — charges the wrong roll and
  // leaves both wrong.
  const inv = [
    { id: 'S1', material: 'PLA', weight: 1000, cost: 90 },
    { id: 'S2', material: 'PLA', weight: 800, cost: 90 },
  ];
  const order = { id: 'J1', parts: [{ filamentId: 'S2', printWeight: 300, qty: 1 }] };
  const out = W.forOrder(order, { material: 'PLA', weight: 120, failureType: 'warping' },
                         { id: 'W1', today: 'd', inventory: inv, settings: {} });
  assert.equal(out.deducted, 120);
  assert.equal(inv[0].weight, 1000, 'the spool this job was not printing from is untouched');
  assert.equal(inv[1].weight, 680);
  assert.deepEqual(out.entry.drawn, [{ spoolId: 'S2', grams: 120 }]);
  assert.equal(out.entry.orderId, 'J1');
  assert.ok(out.entry.cost > 0, 'and it is costed');
});

test('deleting a job\'s waste puts back exactly what it took, spool by spool', () => {
  const W = require('../lib/waste-entry.js');
  // The assigned spool runs out and the rest spills onto its sibling. A row
  // that remembered only "which spool" would put the whole lot back on one.
  const inv = [
    { id: 'S1', material: 'PLA', weight: 50, cost: 90 },
    { id: 'S2', material: 'PLA', weight: 500, cost: 90 },
  ];
  const order = { id: 'J1', parts: [{ filamentId: 'S1', printWeight: 200, qty: 1 }] };
  const out = W.forOrder(order, { material: 'PLA', weight: 200 },
                         { id: 'W1', today: 'd', inventory: inv, settings: {} });
  assert.deepEqual(out.entry.drawn, [{ spoolId: 'S1', grams: 50 }, { spoolId: 'S2', grams: 150 }]);
  assert.deepEqual(inv.map((s) => s.weight), [0, 350]);

  const log = [out.entry];
  W.removeEntry(log, 'W1', { inventory: inv });
  assert.deepEqual(inv.map((s) => s.weight), [50, 500], 'both spools, the right amounts');
  assert.equal(log.length, 0);
});

test('an older waste row, written before `drawn`, still restores the way it always did', () => {
  const W = require('../lib/waste-entry.js');
  const inv = [{ id: 'S1', material: 'PLA', weight: 800 }];
  const log = [{ id: 'W-old', spoolId: 'S1', weight: 120, material: 'PLA' }];
  W.removeEntry(log, 'W-old', { inventory: inv });
  assert.equal(inv[0].weight, 920);
});

test('a spool deleted since the waste was logged is skipped, not recreated', () => {
  const D = require('../lib/order-deduction.js');
  const inv = [{ id: 'S2', material: 'PLA', weight: 500 }];
  // The filament went with the spool; inventing it back would be a lie about
  // stock the shop no longer has.
  assert.equal(D.restoreDrawn([{ spoolId: 'S1', grams: 50 }, { spoolId: 'S2', grams: 150 }],
                              { inventory: inv }), 150);
  assert.equal(inv[0].weight, 650);
});

test('a job\'s waste with no material is refused, and takes nothing', () => {
  const W = require('../lib/waste-entry.js');
  const inv = [{ id: 'S1', material: 'PLA', weight: 800 }];
  const out = W.forOrder({ id: 'J1', parts: [{ filamentId: 'S1', printWeight: 200, qty: 1 }] },
                         { material: '   ', weight: 100 },
                         { id: 'W1', today: 'd', inventory: inv, settings: {} });
  assert.deepEqual(out, { refused: 'material' });
  assert.equal(inv[0].weight, 800);
});

test('grams the spool switch already took are not charged again', () => {
  /* Switching spools mid-print deducts there and then — the filament left that
   * roll when it was loaded — and records the amount on the part. The weight a
   * shop types for a failed print is the WHOLE print, so the switch's grams
   * have to come off that figure before it is drawn.
   *
   * Without this, a job that switched 50 g and then failed at 120 g takes 120
   * more off the shelf: 170 charged for 120 used. */
  const inv = [
    { id: 'S1', material: 'PLA', weight: 1000 },
    { id: 'S2', material: 'PLA', weight: 950 },   // 50 g already gone, at the switch
  ];
  const order = {
    id: 'J1',
    parts: [{ filamentId: 'S1', printWeight: 200, qty: 1, additionalSpools: [{ spoolId: 'S2', weight: 50 }] }],
  };
  const out = D.deductActual(order, 120, { settings: {}, inventory: inv, today: 'd' });
  assert.equal(out.deducted, 70, '120 used, 50 of it already off the shelf');
  assert.deepEqual(inv.map((s) => s.weight), [930, 950]);
  assert.equal(1000 + 1000 - inv[0].weight - inv[1].weight, 120,
    'and 120 grams have left the shelf in total, which is what the print used');
});

test('a failure that used less than the switch already took draws nothing more', () => {
  const inv = [
    { id: 'S1', material: 'PLA', weight: 1000 },
    { id: 'S2', material: 'PLA', weight: 950 },
  ];
  const order = {
    id: 'J1',
    parts: [{ filamentId: 'S1', printWeight: 200, qty: 1, additionalSpools: [{ spoolId: 'S2', weight: 50 }] }],
  };
  const out = D.deductActual(order, 30, { settings: {}, inventory: inv, today: 'd' });
  assert.equal(out.deducted, 0, 'the shelf is not credited back — the filament is still gone');
  assert.deepEqual(inv.map((s) => s.weight), [1000, 950]);
});

/* ── Scaling against the WHOLE job (Oct 2026) ───────────────────────────── */

test('a measured total is the whole job: a part with no spool keeps its share', () => {
  // Two 100 g parts, only one on a spool, 200 g measured. The measurement is
  // what the WHOLE print used; charging it all to the spooled part took 200 g
  // off a spool that gave 100.
  const inv = shelf();
  const order = { id: 'J3', parts: [
    { filamentId: 'S1', printWeight: 100, qty: 1 },
    { printWeight: 100, qty: 1 },
  ] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory: inv, today: 'd', actualGrams: 200 });
  assert.equal(inv[0].weight, 900, 'the spool gave its own part\'s 100 g, not the job\'s 200');
});

test('grams a spool switch already took are part of the measured total', () => {
  // The switch took 50 g off another roll mid-print; the printer measured
  // 200 g for the whole print. 150 more is owed, not 200 — 250 in all.
  const inv = shelf();
  const order = { id: 'J4', parts: [
    { filamentId: 'S1', printWeight: 200, qty: 1, additionalSpools: [{ spoolId: 'S2', weight: 50 }] },
  ] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory: inv, today: 'd', actualGrams: 200 });
  assert.equal(inv[0].weight, 850, '150 more, so the print cost 200 in all');
});

test('support is in the estimate the measurement is compared against', () => {
  // 100 g + 30 g support, measured 130: the estimate exactly, all of it.
  const inv = shelf();
  const order = { id: 'J5', parts: [{ filamentId: 'S1', printWeight: 100, supportWeight: 30, qty: 1 }] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory: inv, today: 'd', actualGrams: 130 });
  assert.equal(inv[0].weight, 870);
});

test('a failed print with a spool-less part charges the spool only its share', () => {
  const inv = shelf();
  const order = { id: 'J6', parts: [
    { filamentId: 'S1', printWeight: 100, qty: 1 },
    { printWeight: 100, qty: 1 },
  ] };
  const out = D.deductActual(order, 100, { settings: {}, inventory: inv, today: 'd' });
  assert.equal(out.deducted, 50, 'half the print got through: half of the spooled part');
  assert.equal(inv[0].weight, 950);
});
