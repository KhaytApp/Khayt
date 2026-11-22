const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../renderer/util.js');
require('../renderer/format.js');
require('../renderer/ops-locations.js'); // provides global orderLocationId
const api = require('../renderer/inventory.js');

/* ============================================================
   spoolMatchesLocation — migration-safe scoping
   ============================================================ */
test('spoolMatchesLocation: no active filter shows everything', () => {
  const { spoolMatchesLocation } = api;
  assert.equal(spoolMatchesLocation({ locationId: 'L1' }, null), true);
  assert.equal(spoolMatchesLocation({ locationId: 'L1' }, ''), true);
  assert.equal(spoolMatchesLocation({}, null), true);
});

test('spoolMatchesLocation: legacy/unassigned stock visible under any location', () => {
  const { spoolMatchesLocation } = api;
  // No locationId field at all (pre-migration spool).
  assert.equal(spoolMatchesLocation({ id: 'S1' }, 'L1'), true);
  // Explicit empty/undefined locationId.
  assert.equal(spoolMatchesLocation({ id: 'S2', locationId: undefined }, 'L1'), true);
  assert.equal(spoolMatchesLocation({ id: 'S3', locationId: '' }, 'L1'), true);
  // Null item never throws.
  assert.equal(spoolMatchesLocation(null, 'L1'), true);
});

test('spoolMatchesLocation: assigned stock scopes to its branch', () => {
  const { spoolMatchesLocation } = api;
  assert.equal(spoolMatchesLocation({ locationId: 'L1' }, 'L1'), true);
  assert.equal(spoolMatchesLocation({ locationId: 'L2' }, 'L1'), false);
});

/* ============================================================
   filterInventoryByLocation
   ============================================================ */
test('filterInventoryByLocation: keeps branch + unassigned, drops other branches', () => {
  const { filterInventoryByLocation } = api;
  const inv = [
    { id: 'A', locationId: 'L1' },
    { id: 'B', locationId: 'L2' },
    { id: 'C' },                    // legacy, unassigned
    { id: 'D', locationId: '' },    // explicit unassigned
  ];
  const scoped = filterInventoryByLocation(inv, 'L1');
  assert.deepEqual(scoped.map(s => s.id), ['A', 'C', 'D']);
  // No active filter returns a copy of all.
  const all = filterInventoryByLocation(inv, null);
  assert.equal(all.length, 4);
  assert.notEqual(all, inv); // copy, not the same reference
  // Non-array input is safe.
  assert.deepEqual(filterInventoryByLocation(undefined, 'L1'), []);
});

/* ============================================================
   perLocationLowStockCounts
   ============================================================ */
test('perLocationLowStockCounts: groups low items by branch and _unassigned', () => {
  const { perLocationLowStockCounts } = api;
  const inv = [
    { id: 'A', locationId: 'L1', weight: 50 },   // low
    { id: 'B', locationId: 'L1', weight: 50 },   // low
    { id: 'C', locationId: 'L2', weight: 50 },   // low
    { id: 'D', locationId: 'L1', weight: 5000 }, // healthy
    { id: 'E', weight: 50 },                      // low, unassigned
  ];
  const low = (it) => (+it.weight || 0) <= 200;
  const counts = perLocationLowStockCounts(inv, low);
  assert.equal(counts.L1, 2);
  assert.equal(counts.L2, 1);
  assert.equal(counts._unassigned, 1);
  assert.equal(counts.L3, undefined);
});

/* ============================================================
   orderSpoolsByLocationPreference — deduction ordering
   ============================================================ */
test('orderSpoolsByLocationPreference: branch first, then unassigned, then others', () => {
  const { orderSpoolsByLocationPreference } = api;
  const spools = [
    { id: 'other', locationId: 'L2' },
    { id: 'shared' },                  // unassigned
    { id: 'local', locationId: 'L1' },
  ];
  const ordered = orderSpoolsByLocationPreference(spools, 'L1');
  assert.deepEqual(ordered.map(s => s.id), ['local', 'shared', 'other']);
  // No location id => original order preserved (copy).
  const same = orderSpoolsByLocationPreference(spools, null);
  assert.deepEqual(same.map(s => s.id), ['other', 'shared', 'local']);
});

test('orderSpoolsByLocationPreference: stable within a tier', () => {
  const { orderSpoolsByLocationPreference } = api;
  const spools = [
    { id: 'a', locationId: 'L1' },
    { id: 'b', locationId: 'L1' },
    { id: 'c' },
    { id: 'd' },
  ];
  const ordered = orderSpoolsByLocationPreference(spools, 'L1');
  assert.deepEqual(ordered.map(s => s.id), ['a', 'b', 'c', 'd']);
});

/* ============================================================
   deductFilamentForOrder — location-preferred fallback when chosen spool empty
   ============================================================ */
test('deductFilamentForOrder: redirects to local spool when chosen spool is empty', () => {
  global.settings = { autoDeduct: true, lowStockThreshold: 200 };
  // Order is at L1 via an assigned machine.
  global.machines = [{ id: 'M1', name: 'Printer', locationId: 'L1' }];
  global.consumables = [];
  global.toast = () => {};
  global.t = (key, fields) => `${key}:${JSON.stringify(fields || {})}`;
  global.saveAll = () => {};
  global.renderInventory = () => {};
  global.renderConsumables = () => {};
  // Chosen spool S0 is empty; same material exists at L1 (S1) and L2 (S2).
  global.inventory = [
    { id: 'S0', material: 'PLA', weight: 0, locationId: 'L2' },
    { id: 'S1', material: 'PLA', weight: 1000, locationId: 'L1' },
    { id: 'S2', material: 'PLA', weight: 1000, locationId: 'L2' },
  ];
  const order = {
    id: 'O1', machineId: 'M1', project: 'Job',
    parts: [{ filamentId: 'S0', printWeight: 300, qty: 1 }],
  };
  api.deductFilamentForOrder(order, { skipRender: true });
  // S0 stays at 0, S1 (local) is drawn down, S2 untouched.
  assert.equal(global.inventory.find(s => s.id === 'S0').weight, 0);
  assert.equal(global.inventory.find(s => s.id === 'S1').weight, 700);
  assert.equal(global.inventory.find(s => s.id === 'S2').weight, 1000);
});

test('deductFilamentForOrder: honors explicit spool when it has stock (no redirect)', () => {
  global.settings = { autoDeduct: true, lowStockThreshold: 200 };
  global.machines = [{ id: 'M1', name: 'Printer', locationId: 'L1' }];
  global.consumables = [];
  global.toast = () => {};
  global.t = (key, fields) => `${key}:${JSON.stringify(fields || {})}`;
  global.saveAll = () => {};
  global.renderInventory = () => {};
  global.renderConsumables = () => {};
  global.inventory = [
    { id: 'S1', material: 'PLA', weight: 1000, locationId: 'L1' },
    { id: 'S2', material: 'PLA', weight: 1000, locationId: 'L2' },
  ];
  const order = {
    id: 'O2', machineId: 'M1', project: 'Job',
    parts: [{ filamentId: 'S2', printWeight: 200, qty: 1 }],
  };
  api.deductFilamentForOrder(order, { skipRender: true });
  // Explicit S2 used despite being at another branch (user's choice respected).
  assert.equal(global.inventory.find(s => s.id === 'S2').weight, 800);
  assert.equal(global.inventory.find(s => s.id === 'S1').weight, 1000);
});

/* ============================================================
   exports
   ============================================================ */
test('KhaytInventory exports per-location helpers + flows', () => {
  assert.equal(typeof api.spoolMatchesLocation, 'function');
  assert.equal(typeof api.filterInventoryByLocation, 'function');
  assert.equal(typeof api.perLocationLowStockCounts, 'function');
  assert.equal(typeof api.orderSpoolsByLocationPreference, 'function');
  assert.equal(typeof api.openStockTransferModal, 'function');
  assert.equal(typeof api.printSpoolLabel, 'function');
});
