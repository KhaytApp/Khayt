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
