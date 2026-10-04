'use strict';
/**
 * What a finished job takes off the shelf.
 *
 * These rules were lifted out of `renderer/inventory.js` so the Mac app can
 * complete a job without silently failing to deduct the filament it printed
 * with — which is worse than not letting it complete the job at all.
 *
 * A deduction bug does not crash. It reports a shop 400g of PETG it does not
 * have, or charges a re-opened job twice, and shows up as a print that stops
 * half way. So the first test runs the ORIGINAL implementations — copied out
 * of inventory.js before the move — and the extracted module over a few
 * thousand generated orders, comparing every spool, every consumable row, the
 * order's own flags, and the messages and redraws each one asked for.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const D = require('../lib/order-deduction.js');

const TODAY = '2026-09-04';

/* ── The originals, copied from renderer/inventory.js before the move ────────
   Globals become `g`; toast/save/render record themselves instead of
   happening. Nothing else is changed. */
function originalDeduct(g, order, { skipRender = false } = {}) {
  const { settings, inventory, consumables, machines, notices, effects } = g;
  const toast = (code, params) => notices.push({ code, params });
  const saveAll = () => effects.push({ type: 'save' });
  const renderInventory = () => effects.push({ type: 'render_inventory' });
  const renderConsumables = () => effects.push({ type: 'render_consumables' });
  const localDateStr = () => TODAY;
  const isLowStock = (item) => {
    if (!item) return false;
    const threshold = item.reorderPoint ?? settings.lowStockThreshold ?? 200;
    return (+item.weight || 0) <= threshold;
  };
  const orderSpoolsByLocationPreference = (candidates, locId) => {
    const list = Array.isArray(candidates) ? candidates.slice() : [];
    if (!locId) return list;
    const tier = (s) => {
      if (s && s.locationId === locId) return 0;
      if (!s || !s.locationId) return 1;
      return 2;
    };
    return list.map((s, i) => ({ s, i, tier: tier(s) }))
      .sort((a, b) => (a.tier - b.tier) || (a.i - b.i)).map((x) => x.s);
  };
  const partGramsConsumed = (p) => ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1);
  const orderLocationId = (o) => {
    if (!o) return null;
    if (o.locationId) return o.locationId;
    const mid = o.machineId;
    const m = mid ? machines.find(x => x.id === mid)
                  : machines.find(x => x.name && o.machine && x.name === o.machine);
    return m?.locationId || null;
  };

  if (!settings.autoDeduct) return;
  if (order.materialDeducted) return;
  let deductedAny = false;
  let totalDeducted = 0;
  const spoolsTouched = new Set();
  const nowLow = [];
  const today = localDateStr();
  const orderLoc = orderLocationId(order);
  for (const part of (order.parts || [])) {
    if (part.colours && part.colours.length) {
      const perQty = Math.max(1, +part.qty || 1);
      for (const col of part.colours) {
        const primaryC = col.filamentId && inventory.find(i => i.id === col.filamentId);
        if (!primaryC) continue;
        let remaining = Math.max(0, (+col.grams || 0) * perQty);
        if (remaining <= 0) continue;
        const othersC = inventory.filter(s =>
          s.id !== primaryC.id && s.material === primaryC.material && (+s.weight || 0) > 0);
        const fbC = orderLoc ? orderSpoolsByLocationPreference(othersC, orderLoc) : othersC;
        for (const sp of [primaryC, ...fbC]) {
          if (remaining <= 0) break;
          const avail = +sp.weight || 0;
          if (avail <= 0) continue;
          const take = Math.min(avail, remaining);
          sp.weight = Math.max(0, avail - take);
          remaining -= take;
          if (!sp.usageHistory) sp.usageHistory = [];
          sp.usageHistory.unshift({ orderId: order.id, project: order.project || '', weightUsed: take, date: today });
          if (sp.usageHistory.length > 200) sp.usageHistory.length = 200;
          deductedAny = true;
          totalDeducted += take;
          spoolsTouched.add(sp.id);
          if (isLowStock(sp) && !nowLow.some(x => x.id === sp.id)) nowLow.push(sp);
        }
      }
      continue;
    }
    if (!part.filamentId || !part.printWeight) continue;
    const primary = inventory.find(i => i.id === part.filamentId);
    if (!primary) continue;
    const extra = (part.additionalSpools || []).reduce((s, a) => s + (+a.weight || 0), 0);
    let remaining = Math.max(0, partGramsConsumed(part) - extra);
    if (remaining <= 0) continue;
    const others = inventory.filter(s =>
      s.id !== primary.id && s.material === primary.material && (+s.weight || 0) > 0);
    const fallback = orderLoc ? orderSpoolsByLocationPreference(others, orderLoc) : others;
    for (const sp of [primary, ...fallback]) {
      if (remaining <= 0) break;
      const avail = +sp.weight || 0;
      if (avail <= 0) continue;
      const take = Math.min(avail, remaining);
      sp.weight = Math.max(0, avail - take);
      remaining -= take;
      if (!sp.usageHistory) sp.usageHistory = [];
      sp.usageHistory.unshift({ orderId: order.id, project: order.project || '', weightUsed: take, date: today });
      if (sp.usageHistory.length > 200) sp.usageHistory.length = 200;
      deductedAny = true;
      totalDeducted += take;
      spoolsTouched.add(sp.id);
      if (isLowStock(sp) && !nowLow.some(x => x.id === sp.id)) nowLow.push(sp);
    }
  }
  if (deductedAny) {
    const fields = { weight: Math.round(totalDeducted), spools: spoolsTouched.size, low: nowLow.length };
    if (nowLow.length > 0) {
      toast('filament_deducted_low', fields);
    } else {
      toast('filament_deducted', fields);
    }
    saveAll();
    if (!skipRender) renderInventory();
  }
  const printHrs = +order.printTime || 0;
  if (printHrs > 0) {
    consumables.forEach(c => {
      if (c.usagePerHour && c.usagePerHour > 0) {
        const used = c.usagePerHour * printHrs;
        c.stock = Math.max(0, (c.stock || 0) - used);
        if (c.stock <= (c.minStock || 0)) {
          toast('consumable_low', { name: c.name });
        }
      }
    });
    saveAll();
    renderConsumables();
  }
  const comps = Array.isArray(order.components) ? order.components : [];
  if (comps.length) {
    const aq = Math.max(1, +order.assemblyQty || 1);
    let touched = false;
    comps.forEach(comp => {
      if (!comp || !comp.consumableId) return;
      const c = consumables.find(x => x.id === comp.consumableId);
      if (!c) return;
      const draw = Math.max(0, (+comp.qtyPerUnit || 0) * aq);
      if (draw <= 0) return;
      c.stock = Math.max(0, (c.stock || 0) - draw);
      touched = true;
      if (c.stock <= (c.minStock || 0)) {
        toast('consumable_low', { name: c.name });
      }
    });
    if (touched) { saveAll(); renderConsumables(); }
  }
  order.materialDeducted = true;
}

function originalPackaging(g, order) {
  const { consumables, notices, effects } = g;
  const toast = (code, params) => notices.push({ code, params });
  const saveAll = () => effects.push({ type: 'save' });
  const renderConsumables = () => effects.push({ type: 'render_consumables' });

  if (order.packagingDeducted) return;
  const packagingItems = consumables.filter(c => c.isPackaging && c.stock > 0);
  if (packagingItems.length === 0) return;
  packagingItems.forEach(c => {
    c.stock = Math.max(0, (c.stock || 0) - 1);
    if (c.stock <= (c.minStock || 0)) {
      toast('packaging_low', { name: c.name });
    }
  });
  saveAll();
  renderConsumables();
  toast('packaging_deducted', {});
  order.packagingDeducted = true;
}

/* ── Generated shops ───────────────────────────────────────────────────────── */
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const MATERIALS = ['PLA', 'PETG', 'ABS', 'Resin'];
const LOCATIONS = [null, 'loc-a', 'loc-b'];

function makeShop(rnd) {
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const inventory = Array.from({ length: 8 }, (_, i) => {
    const spool = {
      id: `f${i}`, material: pick(MATERIALS),
      // Empty and nearly-empty spools on purpose: the shortfall path and the
      // "chosen spool already ran out" path are where this code is subtlest.
      weight: [0, 0, 12, 180, 200, 400, 950][Math.floor(rnd() * 7)],
    };
    if (rnd() < 0.6) spool.locationId = pick(LOCATIONS);
    if (rnd() < 0.3) spool.reorderPoint = Math.floor(rnd() * 300);
    if (rnd() < 0.2) {
      spool.usageHistory = Array.from({ length: 198 + Math.floor(rnd() * 5) },
        (_, k) => ({ orderId: `old${k}`, project: 'old', weightUsed: 1, date: '2026-01-01' }));
    }
    return spool;
  });
  const consumables = Array.from({ length: 5 }, (_, i) => ({
    id: `c${i}`, name: `item ${i}`,
    stock: Math.round(rnd() * 40) / 2, minStock: Math.floor(rnd() * 5),
    usagePerHour: rnd() < 0.5 ? Math.round(rnd() * 100) / 100 : 0,
    isPackaging: rnd() < 0.4,
  }));
  const machines = [
    { id: 'm1', name: 'Alpha', locationId: 'loc-a' },
    { id: 'm2', name: 'Beta', locationId: 'loc-b' },
    { id: 'm3', name: 'Gamma' },
  ];
  return { inventory, consumables, machines };
}

function makeOrder(rnd, i, inventory) {
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const maybe = (p) => rnd() < p;
  const order = {
    id: `o${i}`, project: `Job ${i}`,
    parts: Array.from({ length: 1 + Math.floor(rnd() * 3) }, () => {
      const part = { qty: 1 + Math.floor(rnd() * 3) };
      if (maybe(0.3)) {
        part.colours = Array.from({ length: 1 + Math.floor(rnd() * 3) }, () => ({
          filamentId: maybe(0.85) ? pick(inventory).id : 'missing',
          grams: Math.round(rnd() * 400) / 2,
        }));
      } else {
        part.filamentId = maybe(0.85) ? pick(inventory).id : 'missing';
        part.printWeight = maybe(0.9) ? Math.round(rnd() * 500) / 2 : 0;
        part.supportWeight = maybe(0.4) ? Math.round(rnd() * 60) / 2 : 0;
        if (maybe(0.2)) {
          part.additionalSpools = [{ weight: Math.round(rnd() * 200) / 2 }];
        }
      }
      return part;
    }),
  };
  if (maybe(0.6)) order.printTime = Math.round(rnd() * 4000) / 100;
  if (maybe(0.4)) order.machineId = pick(['m1', 'm2', 'm3', 'gone']);
  else if (maybe(0.3)) order.machine = pick(['Alpha', 'Beta', 'Nowhere']);
  if (maybe(0.2)) order.locationId = pick(['loc-a', 'loc-b']);
  if (maybe(0.25)) {
    order.components = [
      { id: 'k1', consumableId: pick(['c0', 'c1', 'c2', 'gone']), qtyPerUnit: 1 + Math.floor(rnd() * 3) },
      { id: 'k2', consumableId: maybe(0.5) ? 'c3' : null, qtyPerUnit: maybe(0.3) ? 0 : 2 },
    ];
    if (maybe(0.5)) order.assemblyQty = 1 + Math.floor(rnd() * 4);
  }
  if (maybe(0.1)) order.materialDeducted = true;
  if (maybe(0.1)) order.packagingDeducted = true;
  return order;
}

const SETTINGS_VARIANTS = [
  { autoDeduct: true },
  { autoDeduct: true, lowStockThreshold: 500 },
  { autoDeduct: true, lowStockThreshold: 0 },
  { autoDeduct: false },
];

test('the lifted deductions and the originals agree, shelf for shelf', () => {
  const rnd = mulberry32(20260904);
  let compared = 0;
  for (let seed = 0; seed < 120; seed++) {
    const shop = makeShop(rnd);
    const order = makeOrder(rnd, seed, shop.inventory);
    for (const settings of SETTINGS_VARIANTS) {
      for (const skipRender of [false, true]) {
        const a = {
          settings, ...JSON.parse(JSON.stringify(shop)),
          notices: [], effects: [],
        };
        const b = {
          settings, ...JSON.parse(JSON.stringify(shop)),
          notices: [], effects: [],
        };
        const orderA = JSON.parse(JSON.stringify(order));
        const orderB = JSON.parse(JSON.stringify(order));

        originalDeduct(a, orderA, { skipRender });
        originalPackaging(a, orderA);

        const d1 = D.deductForOrder(orderB, {
          settings: b.settings, inventory: b.inventory,
          consumables: b.consumables, machines: b.machines, today: TODAY,
        }, { skipRender });
        const d2 = D.deductPackaging(orderB, { consumables: b.consumables });
        b.notices = [...d1.notices, ...d2.notices];
        b.effects = [...d1.effects, ...d2.effects];

        const label = `${order.id} / ${JSON.stringify(settings)} / skipRender=${skipRender}`;
        // ONE FIELD IS NEW: `materialDrawn`, the record of what came off, so
        // re-opening the job can give it back (`returnForOrder`). Everything
        // else is the original's — and the record must add up to what the
        // shelf actually lost.
        const drawnRecord = orderB.materialDrawn;
        delete orderB.materialDrawn;
        assert.deepEqual(orderB, orderA, `the order diverged: ${label}`);
        if (drawnRecord) {
          const lost = shop.inventory.reduce((s, sp) => s + (+sp.weight || 0), 0)
            - b.inventory.reduce((s, sp) => s + (+sp.weight || 0), 0);
          const recorded = drawnRecord.spools.reduce((s, d) => s + d.grams, 0);
          assert.ok(Math.abs(lost - recorded) < 1e-9, `the record says ${recorded} g, the shelf lost ${lost} g: ${label}`);
        }
        assert.deepEqual(b.inventory, a.inventory, `the spools diverged: ${label}`);
        assert.deepEqual(b.consumables, a.consumables, `the consumables diverged: ${label}`);
        assert.deepEqual(b.notices, a.notices, `the messages diverged: ${label}`);
        assert.deepEqual(b.effects, a.effects, `the effects diverged: ${label}`);
        compared++;
      }
    }
  }
  assert.ok(compared >= 960, `expected ~a thousand shops, compared ${compared}`);
});

/* ── The rules that are easy to break and hard to notice ───────────────────── */

const SPOOLS = () => [
  { id: 'f1', material: 'PLA', weight: 100 },
  { id: 'f2', material: 'PLA', weight: 500 },
  { id: 'f3', material: 'PETG', weight: 500 },
];

test('a job draws from the spool it was given, then from its siblings', () => {
  const inventory = SPOOLS();
  const order = { id: 'o1', parts: [{ filamentId: 'f1', printWeight: 250, qty: 1 }] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[0].weight, 0, 'the chosen spool empties first');
  assert.equal(inventory[1].weight, 350, 'the shortfall comes off a same-material spool');
  assert.equal(inventory[2].weight, 500, 'and never off a different material');
});

test('an empty chosen spool is a spool that ran out, not an error', () => {
  const inventory = SPOOLS();
  inventory[0].weight = 0;
  const order = { id: 'o1', parts: [{ filamentId: 'f1', printWeight: 120, qty: 1 }] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[1].weight, 380, 'the job still consumed the filament');
});

test('support and quantity are part of what a job costs the shelf', () => {
  const inventory = SPOOLS();
  const order = { id: 'o1', parts: [{ filamentId: 'f2', printWeight: 100, supportWeight: 20, qty: 3 }] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[1].weight, 500 - 360);
});

test('grams already taken by a spool switch are not owed twice', () => {
  const inventory = SPOOLS();
  const order = {
    id: 'o1',
    parts: [{ filamentId: 'f2', printWeight: 300, qty: 1, additionalSpools: [{ weight: 200 }] }],
  };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[1].weight, 400, 'only the 100g still owed');
});

test('a completed job is never charged twice, however often it is re-completed', () => {
  const inventory = SPOOLS();
  const order = { id: 'o1', parts: [{ filamentId: 'f2', printWeight: 100, qty: 1 }] };
  const ctx = { settings: { autoDeduct: true }, inventory, today: TODAY };
  D.deductForOrder(order, ctx);
  D.deductForOrder(order, ctx);
  D.deductForOrder(order, ctx);
  assert.equal(inventory[1].weight, 400);
  assert.equal(order.materialDeducted, true);
});

test('a job with nothing to deduct is still flagged, so a re-run cannot find some', () => {
  const order = { id: 'o1', parts: [] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory: SPOOLS(), today: TODAY });
  assert.equal(order.materialDeducted, true);
});

test('a shop that switched auto-deduct off keeps its shelf and its flag', () => {
  const inventory = SPOOLS();
  const order = { id: 'o1', parts: [{ filamentId: 'f2', printWeight: 100, qty: 1 }] };
  const out = D.deductForOrder(order, { settings: { autoDeduct: false }, inventory, today: TODAY });
  assert.equal(inventory[1].weight, 500);
  assert.equal(order.materialDeducted, undefined, 'so it deducts properly if they switch it back on');
  assert.deepEqual(out.notices, []);
  assert.deepEqual(out.effects, []);
});

test('local stock empties before another branch is touched', () => {
  const inventory = [
    { id: 'f1', material: 'PLA', weight: 50, locationId: 'riyadh' },
    { id: 'far', material: 'PLA', weight: 500, locationId: 'jeddah' },
    { id: 'shared', material: 'PLA', weight: 500 },
    { id: 'here', material: 'PLA', weight: 500, locationId: 'riyadh' },
  ];
  const order = {
    id: 'o1', locationId: 'riyadh',
    parts: [{ filamentId: 'f1', printWeight: 300, qty: 1 }],
  };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[0].weight, 0, 'the chosen spool first, wherever it is');
  assert.equal(inventory[3].weight, 250, 'then this branch');
  assert.equal(inventory[2].weight, 500, 'the shared spool is untouched');
  assert.equal(inventory[1].weight, 500, 'and the other branch certainly is');
});

test("a job's branch comes from its machine when it has none of its own", () => {
  const machines = [{ id: 'm1', name: 'Alpha', locationId: 'riyadh' }];
  assert.equal(D.orderLocationId({ machineId: 'm1' }, machines), 'riyadh');
  assert.equal(D.orderLocationId({ machine: 'Alpha' }, machines), 'riyadh', 'matched by name too');
  assert.equal(D.orderLocationId({ locationId: 'jeddah', machineId: 'm1' }, machines), 'jeddah',
    "the job's own branch wins");
  assert.equal(D.orderLocationId({ machineId: 'gone' }, machines), null);
});

test('a multicolour part draws each colour from its own spool', () => {
  const inventory = [
    { id: 'red', material: 'PLA', weight: 500 },
    { id: 'blue', material: 'PLA', weight: 500 },
  ];
  const order = {
    id: 'o1',
    parts: [{ qty: 2, colours: [{ filamentId: 'red', grams: 30 }, { filamentId: 'blue', grams: 10 }] }],
  };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[0].weight, 440, 'times the quantity');
  assert.equal(inventory[1].weight, 480);
});

test('a spool remembers its last two hundred draws and no more', () => {
  const inventory = [{
    id: 'f1', material: 'PLA', weight: 500,
    usageHistory: Array.from({ length: 200 }, (_, k) => ({ orderId: `old${k}` })),
  }];
  const order = { id: 'new', parts: [{ filamentId: 'f1', printWeight: 10, qty: 1 }] };
  D.deductForOrder(order, { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.equal(inventory[0].usageHistory.length, D.USAGE_CAP);
  assert.equal(inventory[0].usageHistory[0].orderId, 'new', 'the newest draw is first');
  assert.equal(inventory[0].usageHistory[0].date, TODAY);
  assert.equal(inventory[0].usageHistory[199].orderId, 'old198', 'the oldest falls off');
});

test('the low-stock warning is one summary, and it names how many', () => {
  const inventory = [{ id: 'f1', material: 'PLA', weight: 300 }, { id: 'f2', material: 'PLA', weight: 900 }];
  const quiet = D.deductForOrder({ id: 'a', parts: [{ filamentId: 'f2', printWeight: 10, qty: 1 }] },
    { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.deepEqual(quiet.notices.map(n => n.code), ['filament_deducted']);

  const loud = D.deductForOrder({ id: 'b', parts: [{ filamentId: 'f1', printWeight: 150, qty: 1 }] },
    { settings: { autoDeduct: true }, inventory, today: TODAY });
  assert.deepEqual(loud.notices.map(n => n.code), ['filament_deducted_low']);
  assert.equal(loud.notices[0].params.low, 1);
  assert.equal(loud.notices[0].params.spools, 1);
  assert.equal(loud.notices[0].params.weight, 150);
});

test('a spool is low by its own reorder point before the shop-wide threshold', () => {
  assert.equal(D.isLowStock({ weight: 300, reorderPoint: 500 }, { lowStockThreshold: 100 }), true);
  assert.equal(D.isLowStock({ weight: 300 }, { lowStockThreshold: 100 }), false);
  assert.equal(D.isLowStock({ weight: 150 }, {}), true, 'and 200g when nothing is set');
  assert.equal(D.isLowStock({ weight: 300 }, {}), false);
  assert.equal(D.isLowStock({ weight: 0, reorderPoint: 0 }, {}), true, 'an empty spool is low at zero');
});

test('hourly consumables are spent by the hours the job actually ran', () => {
  const consumables = [
    { id: 'c1', name: 'IPA', stock: 10, minStock: 2, usagePerHour: 0.5 },
    { id: 'c2', name: 'Glue', stock: 10, minStock: 2, usagePerHour: 0 },
  ];
  const out = D.deductForOrder({ id: 'o1', printTime: 4, parts: [] },
    { settings: { autoDeduct: true }, consumables, today: TODAY });
  assert.equal(consumables[0].stock, 8);
  assert.equal(consumables[1].stock, 10, 'an item with no hourly rate is not touched');
  assert.deepEqual(out.notices, []);
  assert.deepEqual(out.effects, [{ type: 'save' }, { type: 'render_consumables' }]);
});

test('a consumable that runs low says so, by name', () => {
  const consumables = [{ id: 'c1', name: 'IPA', stock: 3, minStock: 2, usagePerHour: 1 }];
  const out = D.deductForOrder({ id: 'o1', printTime: 2, parts: [] },
    { settings: { autoDeduct: true }, consumables, today: TODAY });
  assert.deepEqual(out.notices, [{ code: 'consumable_low', params: { name: 'IPA' } }]);
  assert.equal(consumables[0].stock, 1);
});

test('an assembly draws its bought-in components, times how many were built', () => {
  const consumables = [
    { id: 'bolt', name: 'M3 bolt', stock: 100, minStock: 10 },
    { id: 'nut', name: 'M3 nut', stock: 100, minStock: 10 },
  ];
  const order = {
    id: 'o1', parts: [], assemblyQty: 5,
    components: [
      { consumableId: 'bolt', qtyPerUnit: 4 },
      { consumableId: 'nut', qtyPerUnit: 0 },
      { consumableId: 'gone', qtyPerUnit: 9 },
      { qtyPerUnit: 9 },
    ],
  };
  D.deductForOrder(order, { settings: { autoDeduct: true }, consumables, today: TODAY });
  assert.equal(consumables[0].stock, 80);
  assert.equal(consumables[1].stock, 100, 'nothing per unit means nothing drawn');
});

test('stock stops at zero rather than going negative', () => {
  const consumables = [{ id: 'c1', name: 'IPA', stock: 1, minStock: 0, usagePerHour: 5 }];
  const inventory = [{ id: 'f1', material: 'PLA', weight: 10 }];
  D.deductForOrder({ id: 'o1', printTime: 10, parts: [{ filamentId: 'f1', printWeight: 999, qty: 1 }] },
    { settings: { autoDeduct: true }, inventory, consumables, today: TODAY });
  assert.equal(consumables[0].stock, 0);
  assert.equal(inventory[0].weight, 0);
});

test('packaging costs one of each, once', () => {
  const consumables = [
    { id: 'box', name: 'Box', stock: 5, minStock: 1, isPackaging: true },
    { id: 'tape', name: 'Tape', stock: 2, minStock: 1, isPackaging: true },
    { id: 'ipa', name: 'IPA', stock: 5, minStock: 1 },
  ];
  const order = { id: 'o1' };
  const out = D.deductPackaging(order, { consumables });
  assert.equal(consumables[0].stock, 4);
  assert.equal(consumables[1].stock, 1);
  assert.equal(consumables[2].stock, 5, 'a non-packaging item ships nothing');
  assert.deepEqual(out.notices.map(n => n.code), ['packaging_low', 'packaging_deducted']);
  assert.equal(order.packagingDeducted, true);

  D.deductPackaging(order, { consumables });
  assert.equal(consumables[0].stock, 4, 'and never again');
});

test('a shop with no packaging in stock is left unflagged, so it deducts once it has some', () => {
  const order = { id: 'o1' };
  D.deductPackaging(order, { consumables: [{ id: 'box', name: 'Box', stock: 0, isPackaging: true }] });
  assert.equal(order.packagingDeducted, undefined);

  const stocked = [{ id: 'box', name: 'Box', stock: 3, minStock: 1, isPackaging: true }];
  D.deductPackaging(order, { consumables: stocked });
  assert.equal(stocked[0].stock, 2);
  assert.equal(order.packagingDeducted, true);
});

test('a part draws its own consumables, per printed piece, and gives them back on re-open', () => {
  const consumables = [
    { id: 'mag', name: 'Magnet 6x3', stock: 50, minStock: 5 },
    { id: 'ins', name: 'M3 insert', stock: 10, minStock: 0 },
  ];
  const order = {
    id: 'o1',
    parts: [
      { name: 'Lid', qty: 3, consumables: [{ consumableId: 'mag', qty: 4 }, { consumableId: 'gone', qty: 2 }] },
      { name: 'Base', consumables: [{ consumableId: 'ins', qty: 2 }, { consumableId: 'mag', qty: 0 }] },
    ],
  };
  D.deductForOrder(order, { settings: { autoDeduct: true }, consumables, today: TODAY });
  assert.equal(consumables[0].stock, 38, '4 magnets × 3 lids');
  assert.equal(consumables[1].stock, 8, '2 inserts × 1 base');
  D.returnForOrder(order, { consumables });
  assert.equal(consumables[0].stock, 50);
  assert.equal(consumables[1].stock, 10);
});
