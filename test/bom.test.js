const { test } = require('node:test');
const assert = require('node:assert/strict');
const cost = require('../lib/calculator-cost.js');

const CONS = [
  { id: 'c1', name: 'Magnet 6mm', cost: 0.5, stock: 100, minStock: 20, unit: 'pcs' },
  { id: 'c2', name: 'M3 insert', cost: 0.2, stock: 40, minStock: 10, unit: 'pcs' },
];

test('computeComponentsCost sums consumable.cost × qtyPerUnit', () => {
  const comps = [
    { id: 'x', consumableId: 'c1', qtyPerUnit: 4 }, // 4 × 0.5 = 2.0
    { id: 'y', consumableId: 'c2', qtyPerUnit: 6 }, // 6 × 0.2 = 1.2
  ];
  assert.equal(cost.computeComponentsCost(comps, CONS), 3.2);
});

test('computeComponentsCost ignores missing/deleted consumables and bad rows', () => {
  const comps = [
    { id: 'x', consumableId: 'gone', qtyPerUnit: 5 }, // deleted → 0
    { id: 'y', consumableId: 'c1', qtyPerUnit: 0 },   // 0 qty → 0
    { consumableId: 'c2', qtyPerUnit: 2 },            // 2 × 0.2 = 0.4
    null,
    { id: 'z' },                                       // no consumableId → skip
  ];
  assert.equal(cost.computeComponentsCost(comps, CONS), 0.4);
});

test('computeComponentsCost: empty / non-array → 0', () => {
  assert.equal(cost.computeComponentsCost([], CONS), 0);
  assert.equal(cost.computeComponentsCost(undefined, CONS), 0);
  assert.equal(cost.computeComponentsCost(null, CONS), 0);
});

// Mirror the deduction rule used in inventory.js deductFilamentForOrder so the
// qtyPerUnit × assemblyQty math + clamp-at-zero is locked down.
function deductComponents(order, cons) {
  const comps = Array.isArray(order.components) ? order.components : [];
  const aq = Math.max(1, +order.assemblyQty || 1);
  const low = [];
  for (const comp of comps) {
    if (!comp || !comp.consumableId) continue;
    const c = cons.find(x => x.id === comp.consumableId);
    if (!c) continue;
    const draw = Math.max(0, (+comp.qtyPerUnit || 0) * aq);
    if (draw <= 0) continue;
    c.stock = Math.max(0, (c.stock || 0) - draw);
    if (c.stock <= (c.minStock || 0)) low.push(c.id);
  }
  return low;
}

test('deduction draws qtyPerUnit × assemblyQty and clamps at zero', () => {
  const cons = JSON.parse(JSON.stringify(CONS));
  const order = { components: [{ consumableId: 'c1', qtyPerUnit: 4 }, { consumableId: 'c2', qtyPerUnit: 6 }], assemblyQty: 3 };
  const low = deductComponents(order, cons);
  assert.equal(cons.find(c => c.id === 'c1').stock, 100 - 12, '4×3 magnets');
  assert.equal(cons.find(c => c.id === 'c2').stock, 40 - 18, '6×3 inserts');
  assert.ok(!low.length, 'still above min stock');
});

test('deduction clamps at 0 and flags low stock, never negative', () => {
  const cons = [{ id: 'c1', name: 'Magnet', cost: 0.5, stock: 5, minStock: 10 }];
  const order = { components: [{ consumableId: 'c1', qtyPerUnit: 4 }], assemblyQty: 3 }; // wants 12, has 5
  const low = deductComponents(order, cons);
  assert.equal(cons[0].stock, 0, 'clamped, not negative');
  assert.deepEqual(low, ['c1'], 'low-stock flagged');
});

test('assemblyQty defaults to 1 when absent/invalid', () => {
  const cons = JSON.parse(JSON.stringify(CONS));
  deductComponents({ components: [{ consumableId: 'c1', qtyPerUnit: 2 }] }, cons);
  assert.equal(cons.find(c => c.id === 'c1').stock, 100 - 2, 'assemblyQty→1');
});
