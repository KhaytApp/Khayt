'use strict';

/**
 * Undoing a status move puts back the stock it changed (lib/stock-undo.js),
 * which is what makes reopening a finished job safe to give filament back on.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const SU = require('../lib/stock-undo.js');
const D = require('../lib/order-deduction.js');
const OS = require('../lib/order-status.js');

test('restore puts back exactly what the move changed, and leaves later edits alone', () => {
  const inventory = [{ id: 'S1', weight: 1000 }, { id: 'S2', weight: 500 }];
  const consumables = [{ id: 'C1', qty: 10 }];
  const s = SU.capture({ inventory, consumables });
  inventory[0].weight = 800;            // the move
  consumables[0].qty = 9;
  assert.equal(s.seal(), 2);
  inventory[1].weight = 450;            // something else, after the move
  const r = s.restore();
  assert.deepEqual(r, { restored: 2, skipped: 0 });
  assert.equal(inventory[0].weight, 1000);
  assert.equal(consumables[0].qty, 10);
  assert.equal(inventory[1].weight, 450, 'not part of the move, not touched');
});

test('a save stamping rev/updatedAt is not an edit, and the restore keeps the current rev', () => {
  const inventory = [{ id: 'S1', weight: 1000, rev: 3, updatedAt: 'a' }];
  const s = SU.capture({ inventory });
  inventory[0].weight = 800; s.seal();
  inventory[0].rev = 4; inventory[0].updatedAt = 'b';   // saveAll after the move
  assert.deepEqual(s.restore(), { restored: 1, skipped: 0 });
  assert.equal(inventory[0].weight, 1000);
  assert.equal(inventory[0].rev, 4, 'travels as a newer edit, not an older copy');
  assert.equal(inventory[0].updatedAt, 'b');
});

test('a record edited again after the move is skipped, not clobbered', () => {
  const inventory = [{ id: 'S1', weight: 1000 }];
  const s = SU.capture({ inventory });
  inventory[0].weight = 800; s.seal();
  inventory[0].weight = 2000;           // topped up while the toast showed
  assert.deepEqual(s.restore(), { restored: 0, skipped: 1 });
  assert.equal(inventory[0].weight, 2000);
});

test('finish, reopen, undo, finish: the shelf ends where one print leaves it', () => {
  const inventory = [{ id: 'S1', weight: 1000, material: 'PLA' }];
  const consumables = [];
  const order = { id: 'O1', status: 'printing', date: '2026-10-01', project: 'p',
    parts: [{ filamentId: 'S1', printWeight: 200, qty: 1 }] };

  // Finish: the completion takes the filament (the renderer's deduct effect).
  OS.apply(order, 'completed', { now: Date.parse('2026-10-02T10:00:00Z'), inventory });
  D.deductForOrder(order, { inventory, consumables, settings: { autoDeduct: true }, today: '2026-10-02' }, { skipRender: true });
  const afterFinish = inventory[0].weight;
  assert.ok(afterFinish < 1000, 'the print took filament');

  // Reopen, with the give-back on and the stock captured for Undo.
  const snap = structuredClone(order);
  const stock = SU.capture({ inventory, consumables });
  const out = OS.apply(order, 'qc', { now: Date.now(), inventory, consumables, returnMaterial: true });
  stock.seal();
  assert.equal(inventory[0].weight, 1000, 'reopening gave it back');
  assert.ok(out.notices.some((n) => n.code === 'filament_returned'));

  // Undo the reopen: spool AND order back together.
  stock.restore();
  Object.assign(order, snap);
  assert.equal(inventory[0].weight, afterFinish, 'the grams are taken again');

  // Finishing again (as Undo left it) must not take a second print's worth.
  D.deductForOrder(order, { inventory, consumables, settings: { autoDeduct: true }, today: '2026-10-02' }, { skipRender: true });
  assert.equal(inventory[0].weight, afterFinish, 'no double deduction');
});

test('every undoable move that gives material back also restores the stock', () => {
  const flows = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'order-flows.js'), 'utf8');
  const br = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'bedready-queue.js'), 'utf8');
  assert.equal((flows.match(/returnMaterial: true/g) || []).length, 2, 'updateStatus and holdOrder');
  assert.equal((flows.match(/_stock\.restore\(\);/g) || []).length, 2);
  assert.equal((flows.match(/_stock\.seal\(\);/g) || []).length, 2);
  assert.match(br, /returnMaterial: !!stock/);
  assert.match(br, /if \(stock\) stock\.restore\(\);/);
  for (const page of ['index.html', 'bedready.html']) {
    const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', page), 'utf8');
    assert.ok(html.indexOf('lib/stock-undo.js') > 0, page);
  }
});
