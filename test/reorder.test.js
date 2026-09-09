/**
 * Reorder-suggestion engine (lib/reorder.js) — pure consumption math.
 * Injected partGrams + isLow + now, so it's deterministic with no globals.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/reorder.js');

const DAY = 86400000;
const NOW = 1_000_000_000_000; // fixed clock
const partGrams = (p) => +p.grams || 0;
const at = (daysAgo) => new Date(NOW - daysAgo * DAY).toISOString();

test('consumptionByItem sums completed-order grams within the window into g/day', () => {
  const orders = [
    { status: 'completed', completedAt: at(10), parts: [{ filamentId: 'pla', grams: 300 }] },
    { status: 'delivered', completedAt: at(20), parts: [{ filamentId: 'pla', grams: 300 }] },
    { status: 'completed', completedAt: at(40), parts: [{ filamentId: 'pla', grams: 999 }] }, // outside 30d window
    { status: 'printing', parts: [{ filamentId: 'pla', grams: 500 }] },                        // not completed
  ];
  const rates = R.consumptionByItem(orders, { windowDays: 30, now: NOW, partGrams });
  assert.equal(rates.pla, 600 / 30); // 20 g/day
});

test('reorderSuggestions flags soon-to-deplete + low items with a suggested qty', () => {
  const inventory = [
    { id: 'pla', name: 'PLA Black', weight: 200 },   // 200g, ~20 g/day → ~10 days left → within leadDays
    { id: 'petg', name: 'PETG', weight: 5000 },       // tons left, not low → skip
    { id: 'abs', name: 'ABS', weight: 50 },           // no usage history but low stock → still listed
  ];
  const orders = [
    { status: 'completed', completedAt: at(5), parts: [{ filamentId: 'pla', grams: 200 }] },
    { status: 'completed', completedAt: at(15), parts: [{ filamentId: 'pla', grams: 400 }] },
  ];
  const isLow = (it) => it.id === 'abs'; // ABS is low; others above reorder point
  const sug = R.reorderSuggestions(inventory, orders, { windowDays: 30, now: NOW, partGrams, isLow, leadDays: 14, targetDays: 45 });

  const ids = sug.map((s) => s.id);
  assert.ok(ids.includes('pla'), 'pla projected to deplete soon → suggested');
  assert.ok(ids.includes('abs'), 'abs low-stock → suggested even without usage history');
  assert.ok(!ids.includes('petg'), 'petg healthy → not suggested');

  const pla = sug.find((s) => s.id === 'pla');
  assert.equal(pla.gramsPerDay, 20);
  assert.equal(pla.daysLeft, 10);
  assert.equal(pla.suggestG, Math.ceil(20 * 45 - 200)); // cover 45 days beyond the 200 on hand
});

test('most-urgent (fewest days left) sorts first', () => {
  const inventory = [
    { id: 'a', name: 'A', weight: 100 }, // 100/20 = 5 days
    { id: 'b', name: 'B', weight: 300 }, // 300/20 = 15 days (but leadDays 30 keeps it)
  ];
  const orders = [
    { status: 'completed', completedAt: at(10), parts: [{ filamentId: 'a', grams: 600 }, { filamentId: 'b', grams: 600 }] },
  ];
  const sug = R.reorderSuggestions(inventory, orders, { windowDays: 30, now: NOW, partGrams, isLow: () => false, leadDays: 30 });
  assert.equal(sug[0].id, 'a', 'fewest days-left first');
});

test('reorderText builds a supplier-ready list (qty, restock, empty)', () => {
  const txt = R.reorderText([
    { label: 'PLA Black', suggestG: 600, low: false },
    { label: 'ABS', suggestG: 0, low: true },
    { label: 'PETG', suggestG: 0, low: false },
  ], { header: 'Reorder:' });
  assert.match(txt, /^Reorder:/);
  assert.match(txt, /PLA Black: ~600 g/);
  assert.match(txt, /ABS: restock/);
  assert.match(txt, /- PETG$/m);
  assert.equal(R.reorderText([]), '');
});

test('completionMs falls back to statusHistory when no completedAt', () => {
  const ms = R.completionMs({ statusHistory: [{ status: 'pending', at: at(9) }, { status: 'completed', at: at(3) }] });
  assert.equal(ms, Date.parse(at(3)));
  assert.equal(R.completionMs({ status: 'printing' }), null);
});

test('committedByItem sums grams from open orders only', () => {
  const orders = [
    { status: 'printing', parts: [{ filamentId: 'pla', grams: 200 }] },
    { status: 'pending', parts: [{ filamentId: 'pla', grams: 150 }] },
    { status: 'completed', completedAt: at(2), parts: [{ filamentId: 'pla', grams: 999 }] }, // not open
    { status: 'quote', parts: [{ filamentId: 'pla', grams: 999 }] }, // not open
  ];
  const c = R.committedByItem(orders, { partGrams });
  assert.equal(c.pla, 350);
});

test('open-order demand lowers days-left and raises the suggested qty', () => {
  const inventory = [{ id: 'pla', material: 'PLA', weight: 1000 }];
  // velocity: 600 g over 30d window = 20 g/day → 50 days on 1000g with no commitments
  const baseOrders = [{ status: 'completed', completedAt: at(10), parts: [{ filamentId: 'pla', grams: 600 }] }];
  const noOpen = R.reorderSuggestions(inventory, baseOrders, { now: NOW, partGrams, isLow: () => false, leadDays: 14, targetDays: 45 });
  assert.equal(noOpen.length, 0); // 50d left, healthy

  // add 700g of queued work → available 300g → 15 days left → surfaces
  const withOpen = baseOrders.concat([{ status: 'printing', parts: [{ filamentId: 'pla', grams: 700 }] }]);
  const sug = R.reorderSuggestions(inventory, withOpen, { now: NOW, partGrams, isLow: () => false, leadDays: 20, targetDays: 45 });
  const pla = sug.find((s) => s.id === 'pla');
  assert.ok(pla, 'should surface once committed demand is factored');
  assert.equal(pla.committedG, 700);
  assert.equal(pla.available, 300);
  assert.equal(pla.daysLeft, 15); // 300 / 20
  assert.ok(pla.suggestG > 0);
});

test('committed beyond stock → daysLeft 0 even with no usage history', () => {
  const inventory = [{ id: 'abs', material: 'ABS', weight: 100 }];
  const orders = [{ status: 'pending', parts: [{ filamentId: 'abs', grams: 400 }] }];
  const sug = R.reorderSuggestions(inventory, orders, { now: NOW, partGrams, isLow: () => false });
  const abs = sug.find((s) => s.id === 'abs');
  assert.ok(abs);
  assert.equal(abs.daysLeft, 0);
  assert.equal(abs.suggestG, 300); // shortfall 400 - 100
});

test('itemsNeedingDraftPo skips items with an open PO; keeps fresh low items', () => {
  const sug = [
    { suggestG: 800, item: { id: 'i1' } },   // needs PO
    { suggestG: 500, item: { id: 'i2' } },   // already has an open draft → skip
    { suggestG: 0, item: { id: 'i3' } },     // no quantity → skip
    { suggestG: 300, item: { id: 'i4' } },   // had a received PO (closed) → still needs one
  ];
  const pos = [
    { itemId: 'i2', status: 'draft' },
    { itemId: 'i4', status: 'received' },
    { itemId: 'i1', status: 'cancelled' },   // cancelled doesn't block i1
  ];
  const need = R.itemsNeedingDraftPo(sug, pos).map((s) => s.item.id).sort();
  assert.deepEqual(need, ['i1', 'i4']);
  assert.deepEqual(R.itemsNeedingDraftPo([], pos), []);
});

test('supplierPriceFor picks the cheapest matching price across suppliers', () => {
  const suppliers = [
    { id: 's1', name: 'A', priceList: [{ material: 'PLA', pricePerKg: 40 }, { material: 'PETG', pricePerKg: 55 }] },
    { id: 's2', name: 'B', priceList: [{ material: 'PLA Premium', pricePerKg: 35 }] },
    { id: 's3', name: 'C', priceList: [{ material: 'ABS', pricePerKg: 0 }] }, // 0 ignored
  ];
  const pla = R.supplierPriceFor(suppliers, 'PLA Black');
  assert.equal(pla.supplierId, 's2');     // 35 < 40
  assert.equal(pla.pricePerKg, 35);
  assert.equal(R.supplierPriceFor(suppliers, 'PETG').supplierId, 's1');
  assert.equal(R.supplierPriceFor(suppliers, 'TPU'), null);   // no match
  assert.equal(R.supplierPriceFor([], 'PLA'), null);
});

/* ── runway: how long has this spool got ─────────────────────── */

const RNOW = Date.parse('2026-09-09T12:00:00Z');
const done = (daysAgo, spoolId, grams) => ({
  status: 'completed',
  completedAt: new Date(RNOW - daysAgo * DAY).toISOString(),
  parts: [{ spoolId, grams }],
});

test('runway: a spool being used has a rate and a date', () => {
  const inv = [{ id: 'S1', weight: 800 }];
  const orders = [done(5, 'S1', 400), done(10, 'S1', 200)];
  const r = R.runwayByItem(inv, orders, { now: RNOW }).S1;
  assert.equal(r.gramsPerDay, 20);              // 600 g over the 30-day window
  assert.equal(r.daysLeft, 40);                 // 800 g at 20 g/day
  assert.equal(new Date(r.emptyAt).toISOString().slice(0, 10), '2026-10-19');
});

test('runway: a spool nobody has printed with says null, not forever', () => {
  const r = R.runwayByItem([{ id: 'S9', weight: 1000 }], [], { now: RNOW }).S9;
  assert.equal(r.daysLeft, null, 'an unknown future was written as an infinite one');
  assert.equal(r.emptyAt, null);
  assert.equal(r.gramsPerDay, 0);
});

test('runway: work already queued comes off the top', () => {
  // 800 g on the shelf, 300 g promised to open jobs → 500 g actually available.
  const inv = [{ id: 'S1', weight: 800 }];
  const orders = [
    done(5, 'S1', 400),                                   // sets the rate: 400/30
    { status: 'queued', parts: [{ spoolId: 'S1', grams: 300 }] },
  ];
  const r = R.runwayByItem(inv, orders, { now: RNOW }).S1;
  assert.equal(r.committedG, 300);
  assert.equal(r.available, 500);
  assert.ok(r.daysLeft < 800 / r.gramsPerDay, 'the queue was ignored');
});

test('runway: oversold with no rate is nought days, not unknown', () => {
  const inv = [{ id: 'S1', weight: 100 }];
  const orders = [{ status: 'queued', parts: [{ spoolId: 'S1', grams: 400 }] }];
  const r = R.runwayByItem(inv, orders, { now: RNOW }).S1;
  assert.equal(r.available, 0);
  assert.equal(r.daysLeft, 0, 'a spool already promised away read as "cannot say"');
});

test('runway: the shelf and the reorder list cannot disagree', () => {
  // The reason `runway` was extracted. Same spool, both callers, one number.
  const inv = [{ id: 'S1', weight: 120 }];
  const orders = [done(3, 'S1', 300)];               // 10 g/day → 12 days left
  const shelf = R.runwayByItem(inv, orders, { now: RNOW }).S1;
  const list = R.reorderSuggestions(inv, orders, { now: RNOW, leadDays: 14 });
  assert.equal(list.length, 1, 'the reorder list did not raise a spool with 12 days left');
  assert.equal(list[0].daysLeft, Math.round(shelf.daysLeft));
  assert.equal(list[0].gramsPerDay, Math.round(shelf.gramsPerDay * 10) / 10);
});

test('runway: an unused spool is still absent from the reorder list', () => {
  // null days-left must not sort as 0 and shout for a reorder.
  const list = R.reorderSuggestions([{ id: 'S9', weight: 1000 }], [], { now: RNOW, leadDays: 14 });
  assert.deepEqual(list, []);
});
