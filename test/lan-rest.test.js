'use strict';
/**
 * lib/lan-rest.js — the REST routes' rules, which both LAN servers run: the
 * desktop's lib/lan-server.js and the native Mac's LanServer.swift (in
 * JavaScriptCore). The HTTP side of the desktop is covered by the
 * lan-*-endpoint tests; this pins the rules themselves.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/lan-rest.js');

const NOW = Date.UTC(2026, 10, 6, 9, 30, 0);
const ctx = { nowMs: NOW, rand: 'ab12' };
const book = () => ({
  settings: { invPrefix: 'INV', quotePrefix: 'QUO', quoteValidityDays: 7, lang: 'en' },
  printLog: [
    { id: 'o1', project: 'Bracket', client: 'Sara', status: 'pending', price: 10, machineId: 'm1', machine: 'MK4', jobNumber: 'INV-2026-0001', secretField: 'x' },
    { id: 'o2', project: 'Vase', status: 'printing', machine: 'MK4', machineId: 'm1' },
    { id: 'q1', project: 'Quote', status: 'quote', quoteExpiresAt: '2099-01-01' },
    { id: 'q2', project: 'Old', status: 'quote', quoteExpiresAt: '2000-01-01' },
  ],
  machines: [{ id: 'm1', name: 'MK4', type: 'fdm', status: 'idle', printerApi: { type: 'octoprint', apiKey: '__enc__k' } }],
  clients: [{ id: 'c1', nameEn: 'Sara', phone: '1', email: 'e', notes: 'private', nameDe: 'x' }],
  inventory: [{ id: 's1', material: 'PLA', weight: 800, cost: 75, supplier: 'Acme', costPerGram: 0.075 }],
  waitingList: [
    { id: 'w1', project: 'Ask', clientName: 'Ali', status: 'active' },
    { id: 'w2', project: 'Gone', status: 'declined' },
  ],
});

test('the reads project, never dump', () => {
  const b = book();
  const orders = R.ordersList(b, {});
  assert.equal(orders.length, 4);
  assert.equal('secretField' in orders[0], false);
  assert.equal(orders[0].jobNumber, 'INV-2026-0001');
  assert.deepEqual(R.ordersList(b, { status: 'quote' }).map((o) => o.id), ['q1', 'q2']);
  assert.equal(R.ordersList(b, { limit: '1' }).length, 1);
  assert.equal(R.ordersList(b, { limit: '9999' }).length, 4, 'capped at 200, not refused');

  const machines = R.machinesList(b);
  assert.deepEqual(machines, [{ id: 'm1', name: 'MK4', type: 'fdm', status: 'idle', hasPrinterApi: true }]);
  assert.equal(JSON.stringify(machines).includes('__enc__'), false, 'a printer key never leaves');

  const spools = R.inventoryList(b);
  assert.equal('supplier' in spools[0], false);
  assert.equal('costPerGram' in spools[0], false);
  assert.equal(spools[0].weight, 800);

  assert.deepEqual(R.waitingList(b).map((w) => w.id), ['w1'], 'a declined entry is history');
  const clients = R.clientsList(b);
  assert.deepEqual(Object.keys(clients[0]).sort(), ['email', 'id', 'name', 'nameAr', 'nameEn', 'phone']);
  assert.equal(clients[0].name, 'Sara');
});

test('POST /api/orders: the record, the prefix and the refusals', () => {
  const b = book();
  assert.deepEqual(R.orderCreate(b, {}, ctx), { status: 400, body: { error: 'project is required' } });
  assert.equal(R.orderCreate(b, { project: 'X', machineId: 'nope' }, ctx).status, 404);
  const out = R.orderCreate(b, { project: ' Gear ', price: '12.345', clientId: 'c1', machineId: 'm1' }, ctx);
  assert.equal(out.status, 201);
  const made = out.store.printLog[0];
  // lib/order-new.js newOrder: numbered from the shop's counter, invoice number with it.
  assert.equal(made.id, 'INV-2026-0002-ab12', 'past INV-2026-0001, which the book already holds; the host\'s tag');
  assert.equal(made.jobNumber, 'INV-2026-0002');
  assert.equal(made.invoiceNum, 'INV-2026-0002');
  assert.equal(out.store.settings.invNumNext, 3, 'the counter it took from is advanced in the same write');
  assert.equal(b.settings.invNumNext, undefined, 'on a copy');
  assert.deepEqual(made.statusHistory.map((x) => x.status), ['pending']);
  assert.equal(made.paymentStatus, 'unpaid');
  assert.equal(made.project, 'Gear');
  assert.equal(made.price, 12.35);
  assert.equal(made.client, 'Sara', 'the client is named from the book');
  assert.equal(made.machine, 'MK4');
  assert.equal(made.queuePos, 2);
  assert.equal(out.emit.channel, 'lan-order-created');
  assert.equal(b.printLog.length, 4, 'the book handed in is not changed');

  const quote = R.orderCreate(b, { project: 'Q', status: 'quote' }, ctx).store.printLog[0];
  assert.match(quote.id, /^QUO-/);
  assert.equal(quote.status, 'quote');
  assert.ok(quote.quoteExpiresAt > quote.date);

  // Nonsense off the wire is refused into something harmless.
  const odd = R.orderCreate(b, { project: 'P', price: 'abc', clientId: { $ne: 1 }, dueDate: 12 }, ctx).store.printLog[0];
  assert.equal(odd.price, 0);
  assert.equal(odd.clientId, null);
  assert.equal(odd.dueDate, null);
});

test('PATCH /api/orders/:id changes status and machine only', () => {
  const b = book();
  assert.equal(R.orderPatch(b, 'o1', {}).status, 400);
  assert.equal(R.orderPatch(b, 'o1', { status: 'cancelled' }).status, 400, 'not a status this route sets');
  assert.equal(R.orderPatch(b, 'nope', { status: 'qc' }).status, 404);
  const out = R.orderPatch(b, 'o1', { status: 'qc', machineId: null, price: 0 });
  assert.equal(out.store.printLog[0].status, 'qc');
  assert.equal(out.store.printLog[0].machine, null);
  assert.equal(out.store.printLog[0].price, 10, 'nothing else on the job moves');
});

test('POST /api/orders/:id/approve: 404, 409, and an expired quote is 410', () => {
  const b = book();
  const at = { nowIso: new Date(NOW).toISOString() };
  assert.equal(R.orderApprove(b, 'nope', at).status, 404);
  assert.equal(R.orderApprove(b, 'o1', at).status, 409);
  assert.equal(R.orderApprove(b, 'q2', at).status, 410);
  const ok = R.orderApprove(b, 'q1', at);
  assert.equal(ok.status, 200);
  assert.equal(ok.body.order.status, 'pending');
  assert.equal(b.printLog[2].status, 'quote', 'the book handed in is not changed');
});

test('inventory: booked in by the shelf rule, reweighed, deleted', () => {
  const b = book();
  assert.equal(R.inventoryCreate(b, null, ctx).status, 400);
  assert.equal(R.inventoryCreate(b, { cost: 1 }, ctx).status, 400, 'a spool needs a material');
  const made = R.inventoryCreate(b, { material: 'PETG', weightTotal: 1000, weightRemaining: 600, barcode: 'nope', id: 'evil' }, ctx);
  assert.equal(made.status, 201);
  const s = made.store.inventory[1];
  assert.equal(s.id, `spool-${NOW}-ab12`, 'the id is the server\'s, not the caller\'s');
  assert.equal(s.weight, 600);
  assert.equal(s.spoolWeight, 1000);
  assert.equal('barcode' in s, false, 'a barcode that is not a GTIN is dropped');

  assert.equal(R.inventoryPatch(b, 's1', {}, ctx).status, 400);
  assert.equal(R.inventoryPatch(b, '../x', { remaining: 1 }, ctx).status, 400);
  assert.equal(R.inventoryPatch(b, 'nope', { remaining: 1 }, ctx).status, 404);
  const re = R.inventoryPatch(b, 's1', { remaining: 99999 }, ctx).store.inventory[0];
  assert.equal(re.weight, 50000, 'clamped');
  assert.equal(re.remaining, 50000);

  assert.equal(R.inventoryDelete(b, 'nope').status, 404);
  const gone = R.inventoryDelete(b, 's1');
  assert.equal(gone.store.inventory.length, 0);
  assert.equal(gone.body.spool.id, 's1');
});

test('PATCH /api/waiting-list/:id: declined moves to history with declinedAt', () => {
  const b = book();
  assert.equal(R.waitingListPatch(b, 'w1', { status: 'done' }, ctx).status, 400);
  assert.equal(R.waitingListPatch(b, 'nope', { status: 'active' }, ctx).status, 404);
  const reminded = R.waitingListPatch(b, 'w1', { status: 'reminded' }, ctx).store;
  assert.equal(reminded.waitingList[0].status, 'reminded');
  const declined = R.waitingListPatch(b, 'w1', { status: 'declined' }, ctx).store;
  assert.deepEqual(declined.waitingList.map((w) => w.id), ['w2']);
  assert.equal(declined.waitingListHistory[0].id, 'w1');
  assert.equal(declined.waitingListHistory[0].status, 'declined');
  assert.equal(declined.waitingListHistory[0].declinedAt, new Date(NOW).toISOString());
});

test('POST /api/waste: logged, and deducted only when asked', () => {
  const b = book();
  assert.equal(R.wasteCreate(b, [], ctx).status, 400);
  assert.equal(R.wasteCreate(b, { weight: 5 }, ctx).status, 400, 'material is required');
  const plain = R.wasteCreate(b, { material: 'PLA', weight: 30 }, ctx);
  assert.equal(plain.body.deducted, null);
  assert.equal(plain.store.inventory, b.inventory, 'the shelf is not touched');
  const off = R.wasteCreate(b, { material: 'PLA', weight: 30, deduct: true, cost: -4 }, ctx);
  assert.deepEqual(off.body.deducted, { id: 's1', weight: 770 });
  assert.equal(off.body.entry.cost, 0);
});

test('the printer webhook moves the job through the status rule', () => {
  const b = book();
  assert.equal(R.normalizePrinterEvent({ topic: 'PrintDone' }), 'print_done');
  assert.equal(R.normalizePrinterEvent({ state: 'printing' }), 'print_started');
  const done = R.printerEvent(b, 'm1', { topic: 'PrintDone' }, ctx);
  assert.deepEqual(done.body.advanced, { id: 'o2', from: 'printing', to: 'post', project: 'Vase' });
  assert.equal(done.store.printLog[1].status, 'post');
  const nothing = R.printerEvent(b, 'm9', { topic: 'PrintDone' }, ctx);
  assert.deepEqual(nothing, { status: 200, body: { ok: true, event: 'print_done', advanced: null } });
});

test('a body with prototype keys is cleaned before it is read', () => {
  const evil = JSON.parse('{"project":"P","__proto__":{"polluted":true}}');
  const out = R.orderCreate(book(), evil, ctx);
  assert.equal(out.status, 201);
  assert.equal(({}).polluted, undefined);
});

// ── EVERY DECISION IS PURE (review of #2252) ──────────────────────────────
//
// A server asks each write rule twice, the first time on the book it holds.
// A rule that changed anything it was handed — a nested array pushed onto
// through a shallow copy — changed the live book, and pushed twice.
test('no write rule changes the book it is handed, nested arrays included', () => {
  const b = book();
  b.printLog[1].statusHistory = [{ status: 'printing', at: '2026-11-01T08:00:00.000Z' }];
  b.printLog[0].statusHistory = [{ status: 'pending', at: '2026-11-01T07:00:00.000Z' }];
  b.inventory[0].priceHistory = [{ cost: 70, at: '2026-01-01' }];
  b.waitingList[0].reminderDate = '2026-11-01';
  const before = JSON.stringify(b);
  const at = { ...ctx, nowIso: new Date(NOW).toISOString() };
  R.orderCreate(b, { project: 'P', clientId: 'c1', machineId: 'm1' }, ctx);
  R.orderPatch(b, 'o1', { status: 'qc', machineId: 'm1' });
  R.orderApprove(b, 'q1', at);
  R.inventoryCreate(b, { material: 'PLA', colourVariant: 'Matte' }, ctx);
  R.inventoryPatch(b, 's1', { remaining: 10 }, ctx);
  R.inventoryDelete(b, 's1');
  R.waitingListPatch(b, 'w1', { status: 'reminded', reminderDate: '2026-12-01' }, ctx);
  R.waitingListPatch(b, 'w1', { status: 'declined' }, ctx);
  R.wasteCreate(b, { material: 'PLA', weight: 5, deduct: true }, ctx);
  R.printerEvent(b, 'm1', { topic: 'PrintDone' }, ctx);
  assert.equal(JSON.stringify(b), before);
});

test('asked twice, as a server asks, the printer webhook adds one history entry', () => {
  const b = book();
  b.printLog[1].statusHistory = [{ status: 'printing', at: '2026-11-01T08:00:00.000Z' }];
  R.printerEvent(b, 'm1', { topic: 'PrintDone' }, ctx);        // the probe
  const out = R.printerEvent(b, 'm1', { topic: 'PrintDone' }, ctx); // inside the write
  assert.deepEqual(out.store.printLog[1].statusHistory.map((h) => h.status), ['printing', 'post']);
});

test('PATCH /api/orders/:id: null unassigns, anything else that is not an id is refused', () => {
  const b = book();
  assert.equal(R.orderPatch(b, 'o1', { machineId: null }).store.printLog[0].machine, null);
  for (const bad of [true, {}, [], Infinity]) {
    assert.equal(R.orderPatch(b, 'o1', { machineId: bad }).status, 400, String(bad));
  }
});

test('PATCH /api/waiting-list/:id takes the reminder day the desktop editor writes', () => {
  const b = book();
  const set = R.waitingListPatch(b, 'w1', { status: 'reminded', reminderDate: '2026-12-01' }, ctx).store;
  assert.equal(set.waitingList[0].status, 'reminded');
  assert.equal(set.waitingList[0].reminderDate, '2026-12-01');
  const kept = R.waitingListPatch({ ...b, waitingList: [{ id: 'w1', reminderDate: '2026-11-20' }] }, 'w1', { status: 'reminded' }, ctx).store;
  assert.equal(kept.waitingList[0].reminderDate, '2026-11-20', 'absent leaves it alone');
  assert.equal(R.waitingListPatch(b, 'w1', { status: 'active', reminderDate: '' }, ctx).store.waitingList[0].reminderDate, '');
  for (const bad of ['2026-02-30', '12/01/2026', '2026-12-01T00:00:00Z', 20261201]) {
    assert.equal(R.waitingListPatch(b, 'w1', { status: 'reminded', reminderDate: bad }, ctx).status, 400, String(bad));
  }
});

test('PATCH /api/orders/:id moves a job through the shared status rule, as the board does', () => {
  const b = book();
  b.printLog[1].statusHistory = [{ status: 'printing', at: '2026-11-01T08:00:00.000Z' }];
  const out = R.orderPatch(b, 'o2', { status: 'completed' }, ctx);
  assert.equal(out.status, 200);
  const done = out.store.printLog[1];
  assert.equal(done.status, 'completed');
  assert.ok(done.completedAt, 'completedAt is stamped, as a move on the board stamps it');
  assert.deepEqual(done.statusHistory.map((h) => h.status), ['printing', 'completed'], 'one history entry, not two');
  const types = out.emit.payload.effects.map((e) => e.type);
  assert.ok(types.includes('deduct_filament'), 'the host is asked to take the filament off the shelf');
  assert.ok(!types.some((t) => t.startsWith('toast') || t === 'save'), 'nothing that only a person at the desk sees');
  assert.equal(out.emit.payload.changed.status, 'completed');
  assert.ok('completedAt' in out.emit.payload.changed);
  assert.ok(!('project' in out.emit.payload.changed), 'only what the move changed travels');
  assert.equal(b.printLog[1].status, 'printing', 'the book it was handed is unchanged');
});

test('PATCH /api/orders/:id: a move the rule refuses is a 409 with its code, and nothing is written', () => {
  const b = book();
  b.settings.productionPaused = true;
  const out = R.orderPatch(b, 'o1', { status: 'printing' }, ctx);
  assert.equal(out.status, 409);
  assert.equal(out.body.code, 'production_paused');
  assert.equal(out.store, undefined);
});

test('PATCH /api/orders/:id: moving out of completed clears completedAt, and the window is told to remove it', () => {
  const b = book();
  b.printLog[1].status = 'completed';
  b.printLog[1].completedAt = '2026-11-02T10:00:00.000Z';
  const out = R.orderPatch(b, 'o2', { status: 'qc' }, ctx);
  assert.equal(out.store.printLog[1].completedAt, undefined);
  assert.ok(out.emit.payload.removed.includes('completedAt'));
});

test('PATCH /api/orders/:id: a machine-only change, or the status it already has, asks for no effects', () => {
  const b = book();
  const m = R.orderPatch(b, 'o1', { machineId: null }, ctx);
  assert.deepEqual(m.emit.payload.effects, []);
  assert.deepEqual(Object.keys(m.emit.payload.changed).sort(), ['machine', 'machineId']);
  const same = R.orderPatch(b, 'o1', { status: 'pending' }, ctx);
  assert.deepEqual(same.emit.payload.effects, []);
  assert.deepEqual(same.emit.payload.changed, {});
});
