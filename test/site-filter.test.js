'use strict';

/**
 * lib/site-filter.js against the desktop's originals, verbatim below.
 *
 * Where every site an item names still exists, the shared rule answers exactly
 * as the renderer did. Where one does not — the one fix — the item is no
 * longer hidden from every site.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const SF = require('../lib/site-filter.js');

// ── The originals (renderer/ops-locations.js, renderer/inventory.js) ──────
function makeOriginals(machines, activeLocation) {
  function orderLocationId(order) {
    if (!order) return null;
    if (order.locationId) return order.locationId;
    const mid = order.machineId;
    const m = mid
      ? machines.find(x => x.id === mid)
      : machines.find(x => x.name && order.machine && x.name === order.machine);
    return m?.locationId || null;
  }
  function orderMatchesActiveLocation(order) {
    if (!activeLocation) return true;
    const loc = orderLocationId(order);
    if (!loc) return true;
    return loc === activeLocation;
  }
  function machineMatchesActiveLocation(machine) {
    if (!activeLocation) return true;
    if (!machine?.locationId) return true;
    return machine.locationId === activeLocation;
  }
  function spoolMatchesLocation(item, activeLoc) {
    if (!activeLoc) return true;
    if (!item || !item.locationId) return true;
    return item.locationId === activeLoc;
  }
  function perLocationLowStockCounts(items, isLow) {
    const out = {};
    (Array.isArray(items) ? items : []).forEach((it) => {
      if (!isLow(it)) return;
      const key = it && it.locationId ? it.locationId : '_unassigned';
      out[key] = (out[key] || 0) + 1;
    });
    return out;
  }
  return { orderMatchesActiveLocation, machineMatchesActiveLocation, spoolMatchesLocation, perLocationLowStockCounts };
}

// A deterministic generator: two sites, machines on either or none, jobs by
// own site, by machine id, by machine NAME, or nowhere; spools likewise.
function rng(seed) { let s = seed; return () => (s = (s * 1103515245 + 12345) % 2147483648) / 2147483648; }
function book(seed) {
  const r = rng(seed);
  const pick = (xs) => xs[Math.floor(r() * xs.length)];
  const locations = [{ id: 'LOC-a', name: 'Main' }, { id: 'LOC-b', name: 'Site 2' }];
  const sites = ['LOC-a', 'LOC-b', '', undefined];
  const machines = [1, 2, 3, 4].map((i) => ({ id: 'M' + i, name: 'Printer ' + i, locationId: pick(sites) }));
  const orders = Array.from({ length: 30 }, (_, i) => {
    const how = pick(['own', 'byId', 'byName', 'none']);
    const o = { id: 'O' + i, status: 'pending' };
    if (how === 'own') o.locationId = pick(['LOC-a', 'LOC-b']);
    if (how === 'byId') o.machineId = pick(machines).id;
    if (how === 'byName') o.machine = pick(machines).name;
    return o;
  });
  const inventory = Array.from({ length: 12 }, (_, i) => ({ id: 'S' + i, locationId: pick(sites), grams: Math.floor(r() * 900) }));
  return { locations, machines, orders, inventory };
}

test('every answer is the desktop\'s where every site still exists', () => {
  for (let seed = 1; seed <= 40; seed++) {
    const b = book(seed);
    for (const active of [null, '', 'LOC-a', 'LOC-b']) {
      const O = makeOriginals(b.machines, active);
      for (const o of b.orders) {
        assert.equal(SF.orderMatches(o, active, { machines: b.machines, locations: b.locations }),
          O.orderMatchesActiveLocation(o), `seed ${seed} ${active} ${o.id}`);
      }
      for (const m of b.machines) {
        assert.equal(SF.machineMatches(m, active, b.locations), O.machineMatchesActiveLocation(m));
      }
      for (const s of b.inventory) {
        assert.equal(SF.spoolMatches(s, active, b.locations), O.spoolMatchesLocation(s, active));
      }
    }
    const low = (s) => s.grams < 300;
    assert.deepEqual(SF.perLocationLowStockCounts(b.inventory, low, b.locations),
      makeOriginals(b.machines, null).perLocationLowStockCounts(b.inventory, low));
  }
});

test('without the shop\'s sites, ids are trusted as they stand — the old answer exactly', () => {
  assert.equal(SF.spoolMatches({ locationId: 'LOC-gone' }, 'LOC-a'), false);
  assert.equal(SF.spoolMatches({ locationId: 'LOC-a' }, 'LOC-a'), true);
  assert.deepEqual(SF.filterInventory([{ locationId: 'X' }, {}], 'Y'), [{}]);
});

test('a site that no longer exists hides nothing from every site', () => {
  const locations = [{ id: 'LOC-a', name: 'Main' }];
  const machines = [{ id: 'M1', locationId: 'LOC-gone' }, { id: 'M2', locationId: 'LOC-a' }];
  const ctx = { machines, locations };
  // The renderer: a job on a machine at a deleted site matched NO site.
  const O = makeOriginals(machines, 'LOC-a');
  assert.equal(O.orderMatchesActiveLocation({ id: 'J', machineId: 'M1' }), false);
  // Now it is unplaced, and shown under the filter like any unplaced job.
  assert.equal(SF.orderMatches({ id: 'J', machineId: 'M1' }, 'LOC-a', ctx), true);
  assert.equal(SF.machineMatches(machines[0], 'LOC-a', locations), true);
  assert.equal(SF.spoolMatches({ locationId: 'LOC-gone' }, 'LOC-a', locations), true);
  // A job's own stale site falls back to its machine's (lib/location-pl.js).
  assert.equal(SF.orderMatches({ id: 'K', locationId: 'LOC-gone', machineId: 'M2' }, 'LOC-a', ctx), true);
  assert.deepEqual(SF.perLocationLowStockCounts([{ locationId: 'LOC-gone' }], () => true, locations), { _unassigned: 1 });
});

test('a filter naming a deleted site shows everything', () => {
  const locations = [{ id: 'LOC-a', name: 'Main' }];
  assert.equal(SF.activeSite('LOC-gone', locations), null);
  assert.equal(SF.orderMatches({ id: 'J', locationId: 'LOC-a' }, 'LOC-gone', { locations }), true);
  const out = SF.scope({ locations, orders: [{ id: 'J', locationId: 'LOC-a' }] }, 'LOC-gone');
  assert.equal(out.active, null);
  assert.deepEqual(out.orderIds, ['J']);
});

test('scope: what one filter shows, as ids, and out of how many', () => {
  const b = book(7);
  const out = SF.scope(b, 'LOC-b');
  assert.equal(out.active, 'LOC-b');
  assert.equal(out.name, 'Site 2');
  assert.deepEqual(out.total, { orders: 30, machines: 4, spools: 12 });
  const O = makeOriginals(b.machines, 'LOC-b');
  assert.deepEqual(out.orderIds, b.orders.filter(O.orderMatchesActiveLocation).map((o) => o.id));
  assert.deepEqual(out.machineIds, b.machines.filter(O.machineMatchesActiveLocation).map((m) => m.id));
  assert.deepEqual(out.spoolIds, b.inventory.filter((s) => O.spoolMatchesLocation(s, 'LOC-b')).map((s) => s.id));
  assert.ok(out.orderIds.length < 30 && out.orderIds.length > 0, 'the generator reaches both sides');
  const all = SF.scope(b, null);
  assert.equal(all.orderIds.length, 30);
  assert.equal(all.name, '');
});
