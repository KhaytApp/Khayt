/**
 * Bed Ready's queue transitions.
 *
 * The bug this replaces was not a crash. `updateStatus` lives in order-flows.js, which is
 * business-only, so bedready-shim.js declared it a no-op to stop a boot-time ReferenceError
 * — and Bed Ready shipped a production queue whose buttons rendered, whose click handler
 * ran, and whose jobs never moved. `function () { return ''; }` is a very quiet failure.
 *
 * So two things are tested here. That the transitions do what a workshop needs — which is
 * ordinary logic — and that the module is loaded in an order where it actually replaces the
 * stub, which is the part that would silently undo all of it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const SRC = fs.readFileSync(path.join(ROOT, 'renderer/bedready-queue.js'), 'utf8');

/* The shared rules the queue is now a HOST for. Loaded into the same scope the
   page loads them into, because "the module is present" is exactly the sort of
   thing that is true in a unit test and false on the page — which is the bug
   this file's own header is about. */
const RULES = ['lib/assembly.js', 'lib/order-status.js', 'lib/order-deduction.js', 'lib/qc-failure.js']
  .map((f) => fs.readFileSync(path.join(ROOT, f), 'utf8'));

/** A renderer-ish global scope with only what Bed Ready actually provides. */
function boot({ orders = [], settings = {} } = {}) {
  const calls = { saved: 0, filament: [], packaging: [], activity: [], toasts: [], repaints: 0 };
  const ctx = {
    printLog: orders,
    settings,
    structuredClone: (o) => JSON.parse(JSON.stringify(o)),
    t: (k) => k,
    toast: (msg, kind, ms, opts) => calls.toasts.push({ msg, kind, opts }),
    saveAll: () => { calls.saved += 1; },
    renderKanban: () => { calls.repaints += 1; },
    renderQueueList: () => {},
    deductFilamentForOrder: (o) => calls.filament.push(o.id),
    deductPackagingConsumables: (o) => calls.packaging.push(o.id),
    logActivity: (kind, msg, id) => calls.activity.push({ kind, msg, id }),
    inventory: [],
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  for (const src of RULES) vm.runInContext(src, ctx);
  vm.runInContext(SRC, ctx);
  return { ctx, calls, order: orders[0] };
}

const job = (over) => Object.assign({ id: 'J1', status: 'pending', parts: [], statusHistory: [] }, over || {});

test('it replaces the shim no-op rather than sitting beside it', () => {
  // The shim gets there first and assigns only when undefined; this must overwrite.
  const ctx = { updateStatus: function () { return ''; }, printLog: [], settings: {} };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  for (const src of RULES) vm.runInContext(src, ctx);
  vm.runInContext(SRC, ctx);
  assert.ok(!/return\s*''/.test(String(ctx.updateStatus)), 'the no-op is still installed');
});

test('a job moves through the queue, and the live timer starts with it', () => {
  const { ctx, order, calls } = boot({ orders: [job()] });
  ctx.updateStatus('J1', 'printing');
  assert.equal(order.status, 'printing');
  assert.ok(order.timerStart, 'kanban draws its timer badge from this, and nothing was setting it');
  assert.ok(order.printingStartedAt);
  assert.equal(calls.saved, 1, 'a move that is not persisted is a move that did not happen');
  assert.ok(calls.repaints > 0, 'and the board has to redraw or the card stays where it was');
});

test('completing deducts the filament the print actually used', () => {
  const { ctx, order, calls } = boot({ orders: [job({ status: 'printing', timerStart: 'x' })] });
  ctx.updateStatus('J1', 'completed');
  assert.equal(order.status, 'completed');
  assert.ok(order.completedAt, 'completedAt is what everything downstream reads');
  assert.ok(!order.timerStart, 'the timer stops when the print does');
  assert.deepEqual(calls.filament, ['J1'], 'finishing a print is the moment the spool is lighter');
  assert.deepEqual(calls.packaging, ['J1']);
});

test('re-opening a finished job clears the completion, not just the column', () => {
  const { ctx, order } = boot({ orders: [job({ status: 'completed', completedAt: '2026-01-01T00:00:00Z' })] });
  ctx.updateStatus('J1', 'pending');
  assert.equal(order.status, 'pending');
  assert.ok(!order.completedAt,
    'a job going round again is not finished; leaving the stamp reports it as done to anything reading completedAt');
});

test('every move is recorded, and the history cannot grow without bound', () => {
  const { ctx, order } = boot({ orders: [job({ statusHistory: new Array(200).fill({ status: 'pending', at: 'x' }) })] });
  ctx.updateStatus('J1', 'printing');
  assert.equal(order.statusHistory.length, 200, 'trimmed, not grown');
  assert.equal(order.statusHistory[199].status, 'printing', 'and the newest move is the one kept');
});

test('a paused shop does not start new prints, but can still finish the ones running', () => {
  const paused = { productionPaused: true };
  const a = boot({ orders: [job()], settings: paused });
  a.ctx.updateStatus('J1', 'printing');
  assert.equal(a.order.status, 'pending', 'a paused shop means it');

  const b = boot({ orders: [job({ status: 'printing' })], settings: paused });
  b.ctx.updateStatus('J1', 'completed');
  assert.equal(b.order.status, 'completed', 'pausing must never strand a job that is already on the bed');
});

test('a hard WIP limit blocks the move; completing is never blocked', () => {
  // A real full column rather than a stubbed predicate: the arithmetic is the
  // shared one now, and stubbing it would test the stub.
  const over = { wipLimits: { printing: 1 }, wipEnforceHardLimit: true };
  const busy = () => job({ id: 'J0', status: 'printing' });
  const a = boot({ orders: [job(), busy()], settings: over });
  a.ctx.updateStatus('J1', 'printing');
  assert.equal(a.order.status, 'pending', 'the limit should have stopped this');

  const b = boot({ orders: [job({ status: 'qc' }), busy()], settings: over });
  b.ctx.updateStatus('J1', 'completed');
  assert.equal(b.order.status, 'completed',
    'the point of a WIP limit is to stop work starting, never to strand what is already done');
});

test('a soft WIP limit warns and lets the move through', () => {
  const { ctx, order, calls } = boot({
    orders: [job(), job({ id: 'J0', status: 'printing' })],
    settings: { wipLimits: { printing: 1 } },
  });
  ctx.updateStatus('J1', 'printing');
  assert.equal(order.status, 'printing');
  assert.ok(calls.toasts.some((x) => x.kind === 'warning'), 'it should say so, though');
});

test('the move can be undone', () => {
  const { ctx, calls, order } = boot({ orders: [job()] });
  ctx.updateStatus('J1', 'printing');
  const undo = calls.toasts.map((x) => x.opts && x.opts.undo).filter(Boolean)[0];
  assert.ok(undo, 'a status change should be undoable');
  undo();
  assert.equal(ctx.printLog[0].status, 'pending', 'undo should put it back');
  assert.ok(!ctx.printLog[0].timerStart, 'including the timer it started');
});

test('nothing happens for an unknown job, or a move to where it already is', () => {
  const { ctx, calls } = boot({ orders: [job({ status: 'printing' })] });
  ctx.updateStatus('NOPE', 'completed');
  ctx.updateStatus('J1', 'printing');
  assert.equal(calls.saved, 0, 'neither is a change, so neither should write');
});

test('bedready.html loads it after the shim it has to override', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer/bedready.html'), 'utf8');
  const shim = html.indexOf('bedready-shim.js');
  const queue = html.indexOf('bedready-queue.js');
  assert.ok(shim !== -1, 'the shim should be loaded');
  assert.ok(queue !== -1, 'bedready-queue.js is not loaded at all — the queue is inert again');
  assert.ok(queue > shim,
    'loaded before the shim, the shim would find updateStatus defined, leave it alone... '
    + 'and this would still work. Loaded after, it overwrites. Either way the ORDER is the '
    + 'contract, so it is pinned rather than left to chance.');
});

test('Khayt does not load it — its own updateStatus is the real one', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer/index.html'), 'utf8');
  assert.ok(!html.includes('bedready-queue.js'),
    'this would replace order-flows.js updateStatus and silently drop invoicing, loyalty and webhooks');
});

/* ── The rules Bed Ready used to be missing ────────────────────────────────── */

test('a job resuming from hold gets back the days it waited', () => {
  // This was written down in this module as impossible: the function that did
  // it lived in order-flows.js, which Bed Ready does not ship. It is shared
  // now, so a Bed Ready job held for nine days comes back nine days later
  // rather than nine days late.
  const heldAt = new Date(Date.now() - 9 * 86400000 + 3600000).toISOString();
  const { ctx, order, calls } = boot({
    orders: [job({ status: 'on_hold', dueDate: '2099-01-20', heldAt, holdReason: 'no filament' })],
  });
  ctx.updateStatus('J1', 'printing');
  assert.equal(order.dueDate, '2099-01-29');
  assert.equal(order.heldAt, undefined, 'the hold is over');
  assert.equal(order.holdReason, undefined);
  assert.ok(calls.toasts.some((x) => x.kind === 'info'), 'and the maker is told the date moved');
});

test('putting a job on hold records when, so the days can be counted', () => {
  const { ctx, order } = boot({ orders: [job({ status: 'printing', timerStart: 'x' })] });
  ctx.updateStatus('J1', 'on_hold', { holdReason: 'nozzle clog' });
  assert.equal(order.status, 'on_hold');
  assert.ok(order.heldAt, 'without this the due date can never be given back');
  assert.equal(order.holdReason, 'nozzle clog');
  assert.ok(!order.timerStart, 'and nothing is being printed while it waits');
});

test('a completion fixes what the job cost', () => {
  const { ctx, order } = boot({
    orders: [job({ status: 'qc', parts: [{ baseCost: 12.5 }, { baseCost: 4 }] })],
  });
  ctx.updateStatus('J1', 'completed');
  assert.equal(order.costBasis, 16.5, "or the margin is recomputed at next year's filament prices");
});

test('re-opening a finished job does not let it deduct its filament a second time', () => {
  const { ctx, order, calls } = boot({
    orders: [job({
      status: 'completed', completedAt: '2026-01-01T00:00:00Z',
      materialDeducted: true, printingStartedAt: '2026-01-01T00:00:00Z',
      materialDrawn: { spools: [{ spoolId: 'S1', grams: 200 }], consumables: [] },
    })],
  });
  ctx.inventory = [{ id: 'S1', material: 'PLA', weight: 800 }];
  ctx.updateStatus('J1', 'printing');
  // Bed Ready's Undo restores the order alone, so it does not ask for the
  // filament back (`returnMaterial`): the flag stays and finishing again
  // takes nothing more. It used to clear the flag, and the second
  // completion took the same 200 g off the spool again.
  assert.equal(order.materialDeducted, true);
  assert.equal(ctx.inventory[0].weight, 800);
  assert.ok(order.printingStartedAt !== '2026-01-01T00:00:00Z', 'and the new run starts now');

  ctx.updateStatus('J1', 'completed');
  assert.deepEqual(calls.filament, ['J1'], 'the deduction is still asked for; the flag makes it a no-op');
});

test('a job finished before completions were recorded keeps its flag when re-opened', () => {
  const { ctx, order } = boot({
    orders: [job({
      status: 'completed', completedAt: '2026-01-01T00:00:00Z',
      materialDeducted: true, printingStartedAt: '2026-01-01T00:00:00Z',
    })],
  });
  ctx.updateStatus('J1', 'printing');
  assert.equal(order.materialDeducted, true,
    'nothing knows what it took — clearing the flag blind is how it was charged twice');
});

test('a resin job entering post gets somewhere to record the wash and the cure', () => {
  const { ctx, order } = boot({
    orders: [job({ status: 'printing', filamentId: 'R1' })],
  });
  ctx.inventory = [{ id: 'R1', materialType: 'resin' }];
  ctx.updateStatus('J1', 'post');
  assert.equal(order.isResin, true);
  assert.ok(order.resinPost, 'the fields the post-processing panel writes into');
});

test('the effects a workshop does not have are ignored, not mistaken for missing', () => {
  // Every commercial effect — the webhooks, the email, the Telegram message,
  // the portal refresh, the survey token, the loyalty tier — falls through the
  // default case. What must NOT happen is the move failing because of them.
  const { ctx, order, calls } = boot({
    orders: [job({ status: 'qc', clientId: 'C1' })],
    settings: {
      telegram: { botToken: 't', chatId: 'c', notifyOnComplete: true },
      webhooks: { enabled: true },
    },
  });
  ctx.updateStatus('J1', 'completed');
  assert.equal(order.status, 'completed', 'a workshop finishes its job either way');
  assert.equal(calls.saved > 0, true);
});

test('passing QC records the inspection on the job, not just the column', () => {
  // `qcStatusOf` reads these fields and `computeQcMetrics` counts only the
  // orders it can answer for, so a completion that skipped them is not counted
  // as failed — it is not counted at all.
  const { ctx, order } = boot({ orders: [job({ status: 'qc' })] });
  ctx.openFormModal = (cfg) => {
    cfg.onSave({ querySelector: () => ({ value: 'looked fine' }) });
  };
  ctx.qcPassOrder('J1');
  assert.equal(order.status, 'completed');
  assert.equal(order.qcStatus, 'pass');
  assert.ok(order.qcPassedAt, 'the fallback qcStatusOf reads when qcStatus is absent');
  assert.equal(order.qcNotes, 'looked fine');
});

test('a Bed Ready QC failure records how bad it was', () => {
  // It never did: the defect was written here with only a type and a note, so
  // "how bad was it" answered undefined for ever, and the photo reference was
  // dropped on the floor. Both come from lib/qc-failure.js now.
  const { ctx, order } = boot({ orders: [job({ status: 'qc', material: 'PLA' })] });
  ctx.wasteLog = [];
  ctx.inventory = [{ material: 'PLA', cost: 100, weight: 1000 }];
  ctx.uid = (p) => p + '-1';
  ctx.num = (v, d) => (Number.isFinite(+v) ? +v : d);
  ctx.openFormModal = (cfg) => {
    cfg.onSave({
      querySelector: (sel) => ({
        value: sel.includes('Type') ? 'warping' : sel.includes('Weight') ? '40' : 'it lifted',
      }),
    });
  };
  ctx.qcFailOrder('J1');

  assert.equal(order.qcStatus, 'fail');
  assert.ok(order.qcFailedAt, 'or computeQcMetrics does not count it as a failure at all');
  assert.equal(order.defects.length, 1);
  assert.equal(order.defects[0].severity, 'major', 'this was undefined');
  assert.equal(order.defects[0].type, 'warping');
  assert.equal(ctx.wasteLog.length, 1);
  assert.equal(ctx.wasteLog[0].weight, 40);
  assert.equal(ctx.wasteLog[0].cost, 4, '100 riyals per kilo, 40 grams');
  assert.equal(order.status, 'pending', 'and the job goes back to be printed again');
});
