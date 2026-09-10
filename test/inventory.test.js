const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/util.js');
require('../renderer/format.js');

test('computeMaterialForecast flags overcommitted spools', () => {
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 100 }];
  global.printLog = [{
    status: 'printing',
    parts: [{ filamentId: 'S1', printWeight: 120 }],
  }];
  const { computeMaterialForecast } = require('../renderer/inventory.js');
  const forecast = computeMaterialForecast();
  assert.equal(forecast.length, 1);
  assert.equal(forecast[0].material, 'PLA');
  assert.equal(forecast[0].available, -20);
  assert.equal(forecast[0].urgent, true);
});

test('KhaytInventory exports inventory tab entry points', () => {
  const api = require('../renderer/inventory.js');
  assert.equal(typeof api.renderInventory, 'function');
  assert.equal(typeof api.renderCatalog, 'function');
  assert.equal(typeof api.deductFilamentForOrder, 'function');
  assert.equal(typeof api.isLowStock, 'function');
});

test('isLowStock uses reorderPoint, then settings threshold, then 200 fallback', () => {
  const { isLowStock } = require('../renderer/inventory.js');
  // Explicit per-item reorder point wins.
  global.settings = { lowStockThreshold: 50 };
  assert.equal(isLowStock({ weight: 100, reorderPoint: 120 }), true);
  assert.equal(isLowStock({ weight: 130, reorderPoint: 120 }), false);
  // At-threshold counts as low (<=) so banner and badge agree.
  assert.equal(isLowStock({ weight: 120, reorderPoint: 120 }), true);
  // Falls back to settings.lowStockThreshold when no reorderPoint.
  assert.equal(isLowStock({ weight: 40 }), true);
  assert.equal(isLowStock({ weight: 60 }), false);
  // Falls back to 200 default when settings threshold is also absent.
  global.settings = {};
  assert.equal(isLowStock({ weight: 150 }), true);
  assert.equal(isLowStock({ weight: 250 }), false);
  assert.equal(isLowStock(null), false);
});

test('deductFilamentForOrder emits ONE aggregated toast and surfaces low-stock', () => {
  const api = require('../renderer/inventory.js');
  const toasts = [];
  global.settings = { autoDeduct: true, lowStockThreshold: 200 };
  global.inventory = [
    { id: 'S1', material: 'PLA', weight: 1000, reorderPoint: 100 },
    { id: 'S2', material: 'PETG', weight: 150, reorderPoint: 100 }, // will drop below 100
    { id: 'S3', material: 'ABS', weight: 500, reorderPoint: 100 },
  ];
  global.consumables = [];
  global.toast = (msg) => toasts.push(msg);
  global.t = (key, fields) => `${key}:${JSON.stringify(fields || {})}`;
  global.saveAll = () => {};
  global.renderInventory = () => {};
  global.renderConsumables = () => {};

  const order = {
    id: 'O1',
    parts: [
      { filamentId: 'S1', printWeight: 100, qty: 1 },  // 100g
      { filamentId: 'S2', printWeight: 60, qty: 1 },   // 60g → S2 -> 90 (low)
      { filamentId: 'S3', printWeight: 160, qty: 1 },  // 160g
    ],
  };
  api.deductFilamentForOrder(order, { skipRender: true });

  // Exactly one filament toast — not one per spool.
  assert.equal(toasts.length, 1);
  // Aggregated total = 320g across 3 spools, 1 now low (S2).
  assert.match(toasts[0], /inv\.deducted_summary_low/);
  assert.match(toasts[0], /"weight":320/);
  assert.match(toasts[0], /"spools":3/);
  assert.match(toasts[0], /"low":1/);
  assert.equal(order.materialDeducted, true);
});


/* ── WHAT A JOB REALLY USED, OFF THE SHELF ─────────────────────────────────
 *
 * `deductForOrder` has taken an `actualGrams` since #978 — "what the PRINTER
 * says the job used, when anything measured it" — and nothing passed it. That
 * change was about FAILED prints, where the grams go through `deductActual`
 * instead, and it left completions where they were on purpose: "absent — which
 * is every job Khayt has ever deducted for — the estimate stands exactly as
 * before".
 *
 * What has changed since is that a completion can now BE measured, in both
 * apps. So a job that used 260 g against a 160 g quote took 160 g off the
 * shelf, and the shop was short 100 g with nothing to reconcile it.
 *
 * The three cases below are the whole change: more, less, and none — and the
 * last one is the one that matters most, because it says a book full of jobs
 * finished before this existed still deducts exactly what it always did.
 */
function shelfFor(order) {
  const api = require('../renderer/inventory.js');
  global.settings = { autoDeduct: true, lowStockThreshold: 200 };
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 1000, reorderPoint: 100 }];
  global.consumables = [];
  global.toast = () => {};
  global.t = (key, fields) => `${key}:${JSON.stringify(fields || {})}`;
  global.saveAll = () => {};
  global.renderInventory = () => {};
  global.renderConsumables = () => {};
  api.deductFilamentForOrder(order, { skipRender: true });
  return global.inventory[0].weight;
}

const quotedAt160 = () => ({
  id: 'O1',
  parts: [{ filamentId: 'S1', printWeight: 160, qty: 1 }],
});

test('a job that used more than it was quoted takes the real grams off the shelf', () => {
  const order = { ...quotedAt160(), actualWeight: 260 };
  assert.equal(shelfFor(order), 740, 'the shelf lost the estimate, not the measurement');
});

test('a job that used less takes less', () => {
  // The case a shop notices: a print that stopped short, or one that simply
  // used less than the slicer thought. Deducting the quote takes filament off
  // a shelf that still has it.
  const order = { ...quotedAt160(), actualWeight: 80 };
  assert.equal(shelfFor(order), 920, 'the shelf lost more than the job used');
});

test('a job with no actuals deducts the estimate, exactly as before', () => {
  // Every job finished before this existed. The change must not rewrite what a
  // shop has already done, only what it does with a figure it now has.
  assert.equal(shelfFor(quotedAt160()), 840);
});

test('a zero actual is not a measurement of nothing', () => {
  // `actualWeight: 0` is what a record carries when somebody cleared the box,
  // not a print that used no filament — and `deductForOrder`'s own guard reads
  // "not finite or <= 0 means scale by 1". Pinned here because a shelf that
  // stopped deducting entirely would look like nothing was wrong for weeks.
  const order = { ...quotedAt160(), actualWeight: 0 };
  assert.equal(shelfFor(order), 840, 'a zero actual stopped the deduction');
});

test('deductFilamentForOrder uses non-low summary when nothing drops below', () => {
  const api = require('../renderer/inventory.js');
  const toasts = [];
  global.settings = { autoDeduct: true, lowStockThreshold: 200 };
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 1000, reorderPoint: 100 }];
  global.consumables = [];
  global.toast = (msg) => toasts.push(msg);
  global.t = (key, fields) => `${key}:${JSON.stringify(fields || {})}`;
  global.saveAll = () => {};
  global.renderInventory = () => {};
  global.renderConsumables = () => {};

  api.deductFilamentForOrder({ id: 'O2', parts: [{ filamentId: 'S1', printWeight: 50, qty: 1 }] }, { skipRender: true });
  assert.equal(toasts.length, 1);
  assert.match(toasts[0], /inv\.deducted_summary:/);
  assert.match(toasts[0], /"low":0/);
});

function invStubs() {
  global.settings = { autoDeduct: true, lowStockThreshold: 200 };
  global.consumables = [];
  global.toast = () => {};
  global.t = (key, fields) => `${key}:${JSON.stringify(fields || {})}`;
  global.saveAll = () => {};
  global.renderInventory = () => {};
  global.renderConsumables = () => {};
  global.machines = [];
}

test('H1: reservation + over-commit key on filamentId (most parts have no spoolId)', () => {
  const api = require('../renderer/inventory.js');
  invStubs();
  global.inventory = [{ id: 'S1', material: 'PLA', weight: 100 }];
  global.printLog = [
    { id: 'O1', status: 'printing', parts: [{ filamentId: 'S1', printWeight: 80, qty: 1 }] },
  ];
  // Reserved must reflect the filamentId-keyed part (was 0 when keyed on spoolId).
  assert.equal(api.getSpoolReservedGrams('S1'), 80);
  // A second 80g job on the 100g spool over-commits and must warn.
  const warns = api.checkSpoolOvercommit([{ filamentId: 'S1', printWeight: 80, qty: 1 }], 'O2');
  assert.equal(warns.length, 1);
  assert.equal(warns[0].needed, 80);
});

test('H2: additionalSpools are not deducted twice at completion', () => {
  const api = require('../renderer/inventory.js');
  invStubs();
  // Helper spool S2 already drew 100g via the spool-switch flow; primary S1 owes
  // the remaining 200g of the 300g part — not the full 300g.
  global.inventory = [
    { id: 'S1', material: 'PLA', weight: 1000 },
    { id: 'S2', material: 'PLA', weight: 1000 },
  ];
  global.printLog = [];
  const order = { id: 'O1', parts: [{ filamentId: 'S1', printWeight: 300, qty: 1, additionalSpools: [{ spoolId: 'S2', weight: 100 }] }] };
  api.deductFilamentForOrder(order, { skipRender: true });
  assert.equal(global.inventory.find(s => s.id === 'S1').weight, 800); // 1000 - 200, not - 300
});

test('H3: a shortfall is drawn from another same-material spool, not lost', () => {
  const api = require('../renderer/inventory.js');
  invStubs();
  // Chosen spool S1 has only 50g; the 80g part draws 50 from S1 and 30 from S2.
  global.inventory = [
    { id: 'S1', material: 'PLA', weight: 50 },
    { id: 'S2', material: 'PLA', weight: 1000 },
  ];
  global.printLog = [];
  api.deductFilamentForOrder({ id: 'O1', parts: [{ filamentId: 'S1', printWeight: 80, qty: 1 }] }, { skipRender: true });
  assert.equal(global.inventory.find(s => s.id === 'S1').weight, 0);
  assert.equal(global.inventory.find(s => s.id === 'S2').weight, 970);
});

test('M8: estimateDaysRemaining never returns NaN for a non-numeric weight', () => {
  const { estimateDaysRemaining } = require('../renderer/inventory.js');
  const recent = new Date(Date.now() - 5 * 86400000).toISOString().slice(0, 10);
  // Normal case → a finite estimate.
  const ok = estimateDaysRemaining({ weight: 500, usageHistory: [{ weightUsed: 100, date: recent }] });
  assert.ok(Number.isFinite(ok) && ok > 0, `expected a positive number, got ${ok}`);
  // CSV/legacy row with a non-numeric weight → null, not NaN.
  const bad = estimateDaysRemaining({ weight: 'n/a', usageHistory: [{ weightUsed: 100, date: recent }] });
  assert.equal(bad, null);
  // No usage history → null.
  assert.equal(estimateDaysRemaining({ weight: 500, usageHistory: [] }), null);
});
