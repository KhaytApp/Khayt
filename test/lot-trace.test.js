'use strict';
/**
 * Lot tracing: the lot is stamped on every draw and every receipt, a restock
 * of a different lot becomes its own spool, and `lib/lot-trace.js` joins the
 * book back up — recorded where the draw carries its lot, inferred from the
 * spool's current lot where it does not.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const D = require('../lib/order-deduction.js');
const PO = require('../lib/purchase-orders.js');
const LT = require('../lib/lot-trace.js');

const job = (over = {}) => ({
  id: 'ORD-1', project: 'Lantern',
  parts: [{ filamentId: 'sp-1', printWeight: 100, qty: 1 }],
  ...over,
});
const settings = { autoDeduct: true };

/* ── Stamping at deduction time ─────────────────────────────────────────── */

test('a completion stamps the lot and the PO on every draw and history row', () => {
  const inventory = [{ id: 'sp-1', material: 'PLA', weight: 1000, lot: '  2406-A ', poId: 'PO-9' }];
  const order = job();
  D.deductForOrder(order, { settings, inventory, today: '2026-10-01' }, { skipRender: true });
  assert.deepEqual(order.materialDrawn.spools,
    [{ spoolId: 'sp-1', grams: 100, lot: '2406-A', poId: 'PO-9' }]);
  const h = inventory[0].usageHistory[0];
  assert.equal(h.lot, '2406-A');
  assert.equal(h.poId, 'PO-9');
  assert.equal(h.weightUsed, 100);
});

test('a spool with no lot draws exactly as before — no empty keys', () => {
  const inventory = [{ id: 'sp-1', material: 'PLA', weight: 1000, lot: '   ' }];
  const order = job();
  D.deductForOrder(order, { settings, inventory, today: '2026-10-01' }, { skipRender: true });
  assert.deepEqual(order.materialDrawn.spools, [{ spoolId: 'sp-1', grams: 100 }]);
  assert.deepEqual(inventory[0].usageHistory[0],
    { orderId: 'ORD-1', project: 'Lantern', weightUsed: 100, date: '2026-10-01' });
});

test('a failed print records the lot on drawn[], and re-opening still returns', () => {
  const inventory = [{ id: 'sp-1', material: 'PLA', weight: 1000, lot: 'L1' }];
  const order = job();
  const taken = D.deductActual(order, 40, { settings, inventory, today: '2026-10-01' });
  assert.deepEqual(taken.drawn, [{ spoolId: 'sp-1', grams: 40, lot: 'L1' }]);

  D.deductForOrder(order, { settings, inventory, today: '2026-10-02' }, { skipRender: true });
  assert.equal(inventory[0].weight, 860);
  const back = D.returnForOrder(order, { inventory, consumables: [] });
  assert.equal(back.grams, 100);
  assert.equal(inventory[0].weight, 960, 'the stamp does not stop the history row matching');
});

/* ── Receiving with a lot ──────────────────────────────────────────────── */

const spool = (over = {}) => ({ id: 'sp-1', material: 'PETG', color: '#000', brand: 'Acme',
  cost: 80, weight: 300, lot: 'OLD-1', openedAt: '2026-01-01', usageHistory: [{ orderId: 'x', weightUsed: 5 }],
  dryingLog: [{ date: '2026-02-01', hours: 4 }], adjustments: [{ date: '2026-03-01', grams: -10 }],
  ...over });

test('a different lot onto a spool that still holds filament becomes its own spool', () => {
  const po = { id: 'PO-7', qty: 1000, itemId: 'sp-1' };
  const out = PO.receive({ po, item: spool(), quantity: 1000, today: '2026-10-03',
                           lot: ' new-2 ', newSpoolId: 'sp-NEW' });
  assert.equal(out.ok, true);
  assert.equal(out.item, undefined, 'the old spool is untouched');
  const n = out.newItem;
  assert.equal(n.id, 'sp-NEW');
  assert.equal(n.weight, 1000);
  assert.equal(n.lot, 'new-2');
  assert.equal(n.poId, 'PO-7');
  assert.equal(n.material, 'PETG');
  assert.equal(n.brand, 'Acme');
  assert.equal(n.cost, 80);
  assert.equal(n.openedAt, undefined, 'the roll\'s own dates are not inherited');
  assert.equal(n.dryingLog, undefined, 'a new roll has not been dried');
  assert.equal(n.adjustments, undefined, 'nor weighed and corrected');
  assert.equal(n.usageHistory.length, 1);
  assert.equal(n.usageHistory[0].type, 'received');
  assert.equal(n.usageHistory[0].weightUsed, -1000);
  assert.equal(n.usageHistory[0].lot, 'new-2');
  assert.equal(out.po.itemId, 'sp-1', 'the order still points where it did');
  assert.deepEqual(out.po.receivedInto, ['sp-NEW']);
});

test('the same lot, any case, tops the spool up and stamps the receipt', () => {
  const out = PO.receive({ po: { id: 'PO-7' }, item: spool(), quantity: 500,
                           today: 'T', lot: 'old-1' });
  assert.equal(out.newItem, undefined);
  assert.equal(out.item.weight, 800);
  assert.equal(out.item.lot, 'old-1');
  assert.equal(out.item.poId, 'PO-7');
  assert.equal(out.item.usageHistory[0].lot, 'old-1');
  assert.equal(out.item.usageHistory[0].poId, 'PO-7');
});

test('an empty spool refilled with a new lot is the same spool, relabelled', () => {
  const out = PO.receive({ po: { id: 'PO-7' }, item: spool({ weight: 0 }), quantity: 1000,
                           today: 'T', lot: 'NEW-3' });
  assert.equal(out.newItem, undefined);
  assert.equal(out.item.weight, 1000);
  assert.equal(out.item.lot, 'NEW-3');
});

test('no lot given: exactly the old behaviour, plus the PO id', () => {
  const out = PO.receive({ po: { id: 'PO-7' }, item: spool(), quantity: 100, today: 'T' });
  assert.equal(out.newItem, undefined);
  assert.equal(out.item.weight, 400);
  assert.equal(out.item.lot, 'OLD-1');
  assert.equal(out.item.poId, 'PO-7');
  assert.equal(out.po.receivedInto, undefined);
});

/* ── Tracing ───────────────────────────────────────────────────────────── */

function book() {
  return {
    printLog: [
      { id: 'J1', project: 'Recorded', client: 'Noura', completedAt: '2026-10-05T10:00:00Z',
        materialDrawn: { spools: [{ spoolId: 'sp-a', grams: 120, lot: 'LOT-A' },
                                  { spoolId: 'sp-b', grams: 30, lot: 'LOT-B' }] } },
      { id: 'J2', project: 'Old job', date: '2026-09-01' },
      { id: 'J3', project: 'Failed', date: '2026-10-06' },
    ],
    wasteLog: [{ id: 'W1', orderId: 'J3', date: '2026-10-06', weight: 50,
                 drawn: [{ spoolId: 'sp-a', grams: 50, lot: 'lot-a' }] }],
    inventory: [
      { id: 'sp-a', material: 'PLA', lot: 'LOT-A', usageHistory: [
        { orderId: 'J3', weightUsed: 50, date: '2026-10-06', lot: 'lot-a' },
        { orderId: 'J1', weightUsed: 120, date: '2026-10-05', lot: 'LOT-A' },
        { orderId: 'J2', weightUsed: 80, date: '2026-09-01', project: 'Old job' },
        { type: 'received', orderId: 'PO-1', weightUsed: -1000, date: '2026-08-01' },
      ] },
      { id: 'sp-b', material: 'PLA', lot: 'LOT-B', usageHistory: [
        { orderId: 'J1', weightUsed: 30, date: '2026-10-05', lot: 'LOT-B' },
      ] },
    ],
  };
}

test('jobsForLot finds recorded, failed and inferred jobs, once each', () => {
  const jobs = LT.jobsForLot(book(), '  lot-a ');
  assert.deepEqual(jobs.map(j => j.orderId), ['J3', 'J1', 'J2']);
  const j1 = jobs.find(j => j.orderId === 'J1');
  assert.equal(j1.grams, 120, 'only the grams from THIS lot');
  assert.equal(j1.inferred, false);
  assert.equal(j1.client, 'Noura');
  const j3 = jobs.find(j => j.orderId === 'J3');
  assert.equal(j3.failed, true);
  assert.equal(j3.grams, 50, 'the waste row and its history line are one draw');
  const j2 = jobs.find(j => j.orderId === 'J2');
  assert.equal(j2.inferred, true, 'an old history row takes the spool\'s current lot');
  assert.equal(j2.grams, 80);
});

test('a blank lot matches nothing', () => {
  assert.deepEqual(LT.jobsForLot(book(), '  '), []);
});

test('jobsForSpool lists every job off one spool', () => {
  assert.deepEqual(LT.jobsForSpool(book(), 'sp-b').map(j => j.orderId), ['J1']);
  assert.deepEqual(LT.jobsForSpool(book(), 'sp-a').map(j => j.orderId), ['J3', 'J1', 'J2']);
});

test('lotsForJob: recorded draws first; history as the inferred fallback', () => {
  const b = book();
  const rows = LT.lotsForJob(b.printLog[0], b.inventory);
  assert.deepEqual(rows.map(r => [r.spoolId, r.lot, r.grams, r.inferred]),
    [['sp-a', 'LOT-A', 120, false], ['sp-b', 'LOT-B', 30, false]]);
  assert.equal(rows[0].material, 'PLA');

  const old = LT.lotsForJob(b.printLog[1], b.inventory);
  assert.deepEqual(old.map(r => [r.spoolId, r.lot, r.grams, r.inferred]),
    [['sp-a', 'LOT-A', 80, true]]);

  const failed = LT.lotsForJob(b.printLog[2], b.inventory, b.wasteLog);
  assert.deepEqual(failed.map(r => [r.source, r.grams]), [['failed', 50]]);
  assert.deepEqual(LT.lotsForJob({ id: 'none' }, b.inventory), []);
});

test('a draw from a deleted spool with no lot of its own has no lot', () => {
  const rows = LT.lotsForJob({ id: 'J', materialDrawn: { spools: [{ spoolId: 'gone', grams: 9 }] } }, []);
  assert.equal(rows[0].lot, '');
  assert.equal(rows[0].spoolGone, true);
});

test('csvForJobs quotes what needs quoting', () => {
  const csv = LT.csvForJobs(LT.jobsForLot(book(), 'LOT-B'));
  const lines = csv.trim().split('\n');
  assert.equal(lines[0], 'Job,Project,Client,Date,Grams,Lots,Status');
  assert.equal(lines[1], 'J1,Recorded,Noura,2026-10-05,30,LOT-B,completed');
  assert.match(LT.csvForJobs([{ orderId: 'a', project: 'x, "y"', lots: [], grams: 1 }]), /"x, ""y"""/);
});

test('csvForJobs opens a formula-looking cell as text, not a formula', () => {
  const csv = LT.csvForJobs([
    { orderId: 'a', project: '+cmd', client: '=1+1', lots: ['@SUM(A1)', '-x'], grams: 2 },
    { orderId: 'b', project: 'ok', client: '=HYPERLINK("http://x","y")', lots: [], grams: 1 },
  ]);
  const [, a, b] = csv.trim().split('\n');
  assert.equal(a, "a,'+cmd,'=1+1,,2,'@SUM(A1) / -x,completed");
  assert.equal(b, `b,ok,"'=HYPERLINK(""http://x"",""y"")",,1,,completed`);
  // A plain figure is still a figure.
  assert.match(LT.csvForJobs([{ orderId: 'c', lots: [], grams: 3.5 }]), /^c,,,,3.5,,completed$/m);
});

test('the whole round trip: receive a lot, print from it, trace it back', () => {
  const po = { id: 'PO-1', qty: 1000 };
  const got = PO.receive({ po, item: { id: 'sp-1', material: 'PLA', weight: 0 },
                           quantity: 1000, today: '2026-10-01', lot: 'R-77' });
  const inventory = [got.item];
  const order = job({ id: 'ORD-9', completedAt: '2026-10-02' });
  D.deductForOrder(order, { settings, inventory, today: '2026-10-02' }, { skipRender: true });
  const jobs = LT.jobsForLot({ printLog: [order], inventory }, 'r-77');
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].orderId, 'ORD-9');
  assert.equal(jobs[0].inferred, false);
  assert.equal(jobs[0].draws[0].poId, 'PO-1');
});

/* ── Review fixes ──────────────────────────────────────────────────────── */

test('a failure that drew twice off one spool is counted once, not twice', () => {
  // Two parts on one spool: `deductActual` writes a history row per take
  // (30 g, 20 g) but ONE drawn row per spool (50 g). The history must be
  // covered by the total, not matched gram for gram.
  const inventory = [{ id: 'S1', material: 'PLA', weight: 1000, lot: 'A' }];
  const order = job({ id: 'ORD-F', parts: [
    { filamentId: 'S1', printWeight: 30, qty: 1 },
    { filamentId: 'S1', printWeight: 20, qty: 1 },
  ] });
  const taken = D.deductActual(order, 50, { settings, inventory, today: '2026-10-01' });
  assert.deepEqual(taken.drawn, [{ spoolId: 'S1', grams: 50, lot: 'A' }],
    "deductActual's output shape is unchanged");
  assert.equal(inventory[0].usageHistory.length, 2);
  const wasteLog = [{ id: 'W1', orderId: 'ORD-F', date: '2026-10-01', weight: 50,
                      drawn: taken.drawn }];
  const jobs = LT.jobsForLot({ printLog: [order], wasteLog, inventory }, 'A');
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].grams, 50);
  assert.equal(jobs[0].draws.length, 1);
});

test('history beyond what the record accounts for is still found', () => {
  const inventory = [{ id: 'S1', material: 'PLA', lot: 'A', usageHistory: [
    { orderId: 'J', weightUsed: 20, date: '2026-10-02' },
    { orderId: 'J', weightUsed: 30, date: '2026-10-01' },
  ] }];
  const printLog = [{ id: 'J', materialDrawn: { spools: [{ spoolId: 'S1', grams: 30, lot: 'A' }] } }];
  const jobs = LT.jobsForLot({ printLog, inventory }, 'A');
  assert.equal(jobs[0].grams, 50, 'the 20 g the record does not cover is still counted');
});

test('a second part delivery of the same new lot tops up the spool the first one made', () => {
  const po = { id: 'PO-7', qty: 1000, itemId: 'sp-1' };
  const first = PO.receive({ po, item: spool(), quantity: 500, today: '2026-10-03',
                             lot: 'B', newSpoolId: 'sp-B' });
  assert.deepEqual(first.po.receivedInto, ['sp-B']);
  const second = PO.receive({ po: first.po, item: spool(), quantity: 500, today: '2026-10-04',
                              lot: ' b ', newSpoolId: 'sp-B2',
                              receivedSpools: [first.newItem] });
  assert.equal(second.newItem, undefined, 'no second lot-B spool');
  assert.equal(second.item.id, 'sp-B', 'the grams go onto the lot-B spool');
  assert.equal(second.item.weight, 1000);
  assert.equal(second.item.usageHistory.length, 2);
  assert.deepEqual(second.po.receivedInto, ['sp-B']);
  assert.equal(second.complete, true);
});

test('a spool the order received into with a DIFFERENT lot is not topped up', () => {
  const po = { id: 'PO-7', qty: 1000, itemId: 'sp-1', receivedInto: ['sp-B'] };
  const out = PO.receive({ po, item: spool(), quantity: 500, today: 'T', lot: 'C',
                           newSpoolId: 'sp-C',
                           receivedSpools: [{ id: 'sp-B', material: 'PETG', weight: 500, lot: 'B' }] });
  assert.equal(out.newItem.id, 'sp-C');
  assert.deepEqual(out.po.receivedInto, ['sp-B', 'sp-C']);
});

test('refilling an empty spool with a new lot does not pull earlier jobs into it', () => {
  const got = PO.receive({ po: { id: 'PO-C' }, quantity: 1000, today: '2026-10-10', lot: 'C',
    item: { id: 'S1', material: 'PLA', weight: 0, usageHistory: [
      { orderId: 'OLD', weightUsed: 200, date: '2025-03-01' },
    ] } });
  const inventory = [got.item];
  const printLog = [{ id: 'OLD', project: '2025 job', date: '2025-03-01' }];
  assert.deepEqual(LT.jobsForLot({ printLog, inventory }, 'C'), [],
    'a 2025 draw is not presumed to be from a lot that arrived in October 2026');
  const order = job({ id: 'NEW', parts: [{ filamentId: 'S1', printWeight: 10, qty: 1 }] });
  D.deductForOrder(order, { settings, inventory, today: '2026-10-11' }, { skipRender: true });
  printLog.push(order);
  assert.deepEqual(LT.jobsForLot({ printLog, inventory }, 'C').map(j => j.orderId), ['NEW']);
});

test('before a refill, a draw takes the lot of the receipt then in force', () => {
  const inventory = [{ id: 'S1', material: 'PLA', weight: 1000, lot: 'C', usageHistory: [
    { type: 'received', orderId: 'PO-C', weightUsed: -1000, date: '2026-10-10', lot: 'C', poId: 'PO-C' },
    { orderId: 'OLD', weightUsed: 200, date: '2026-05-01' },
    { type: 'received', orderId: 'PO-A', weightUsed: -1000, date: '2026-04-01', lot: 'A', poId: 'PO-A' },
  ] }];
  const draws = LT.allDraws({ printLog: [{ id: 'OLD' }], inventory });
  assert.equal(draws.length, 1);
  assert.equal(draws[0].lot, 'A');
  assert.equal(draws[0].poId, 'PO-A');
  assert.equal(draws[0].inferred, true);
});
