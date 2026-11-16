'use strict';
/**
 * The desktop's share of lib/part-ids.js: at load, parts with no id get the
 * one they are owed, before the sync backfill and seedIndex, and the jobs that
 * changed are stamped on the next save ONLY when this app owns the book
 * (hub:store-owned). A book another app holds keeps the ids in memory and is
 * never written for them. Synthetic jobs only.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const P = require('../lib/part-ids.js');
const Sync = require('../lib/sync.js');
const vectors = require('./fixtures/part-ids-vectors.json');

function book() {
  return {
    printLog: [
      { id: 'INV-2026-0001', rev: 3, updatedAt: '2026-11-01T00:00:00.000Z', parts: [{ name: 'Bracket', qty: 2 }] },
      { id: 'INV-2026-0002', rev: 1, updatedAt: '2026-11-01T00:00:00.000Z', parts: [{ id: 'PRT-kept', name: 'Hook' }] },
      { id: 'INV-2026-0003', rev: 2, updatedAt: '2026-11-01T00:00:00.000Z', parts: [{ name: 'حامل', qty: 1 }, { name: 'حامل', qty: 1 }] },
    ],
    clients: [{ id: 'CLI-1', rev: 1, updatedAt: '2026-11-01T00:00:00.000Z', name: 'A' }],
    tombstones: [],
  };
}

/** What loadAll does, in its order. */
function load(snap, owned, scope) {
  const jobs = [...new Set(P.assignPartIds(snap.printLog).map((g) => g.orderId))];
  Sync.backfill(snap);
  Sync.setScope(scope);
  Sync.seedIndex(snap);
  if (jobs.length && owned) Sync.markChanged('printLog', jobs);
  return jobs;
}

test('owned: the jobs given ids are stamped on the next save, nothing else is', () => {
  const snap = book();
  const jobs = load(snap, true, 'part-ids-owned');
  assert.deepEqual(jobs, ['INV-2026-0001', 'INV-2026-0003']);
  const s = Sync.stampChanges(snap);
  assert.deepEqual(s.changed.map((c) => c.id).sort(), ['INV-2026-0001', 'INV-2026-0003']);
  assert.deepEqual(s.created, []);
  assert.deepEqual(s.deleted, []);
  assert.equal(snap.printLog[0].rev, 4);
  assert.equal(snap.printLog[1].rev, 1);
  assert.equal(snap.printLog[2].rev, 3);
  assert.equal(snap.printLog[1].parts[0].id, 'PRT-kept');
  // Two identical parts of one job: two ids.
  assert.notEqual(snap.printLog[2].parts[0].id, snap.printLog[2].parts[1].id);
  // Stamped once: the save after changes nothing.
  assert.deepEqual(Sync.stampChanges(snap).changed, []);
});

test('not owned: the ids are in memory, and no save stamps them', () => {
  const snap = book();
  load(snap, false, 'part-ids-not-owned');
  assert.match(snap.printLog[0].parts[0].id, /^PRT-[0-9a-z]{11}$/);
  const s = Sync.stampChanges(snap);
  assert.deepEqual(s.changed, []);
  assert.equal(snap.printLog[0].rev, 3);
});

test('a second load gives nothing and marks nothing', () => {
  const snap = book();
  load(snap, true, 'part-ids-twice');
  Sync.stampChanges(snap);
  assert.deepEqual(load(snap, true, 'part-ids-twice'), []);
  assert.deepEqual(Sync.stampChanges(snap).changed, []);
});

test('two machines loading the same book give the same ids', () => {
  const a = book(); const b = book();
  load(a, true, 'part-ids-a'); load(b, false, 'part-ids-b');
  assert.deepEqual(a.printLog.map((o) => o.parts.map((p) => p.id)), b.printLog.map((o) => o.parts.map((p) => p.id)));
});

test('the load gives every vector its pinned id', () => {
  for (const c of vectors.cases) {
    const parts = [];
    parts[c.index] = { ...c.part };
    for (let i = 0; i < c.index; i++) parts[i] = { id: 'PRT-pre' + i };
    const snap = { printLog: [{ id: c.orderId, parts }] };
    load(snap, true, 'part-ids-vec');
    assert.equal(snap.printLog[0].parts[c.index].id, c.id, c.why);
  }
});

test('markChanged touches only records the index holds', () => {
  const snap = book();
  Sync.setScope('part-ids-mark');
  Sync.seedIndex(snap);
  assert.equal(Sync.markChanged('printLog', ['INV-2026-0001', 'NOPE']), 1);
  assert.equal(Sync.markChanged('printLog', ['INV-2026-0001']), 0);
});

test('loadAll: ids before the backfill, stamped only when the book is ours', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-state.js'), 'utf8');
  const body = src.slice(src.indexOf('async function loadAll('));
  const assign = body.indexOf('KhaytPartIds.assignPartIds(printLog)');
  const backfill = body.indexOf('KhaytSync.backfill(');
  const seed = body.indexOf('KhaytSync.seedIndex(');
  const owned = body.indexOf('window.hubAPI.storeOwned()');
  const mark = body.indexOf("KhaytSync.markChanged('printLog'");
  for (const [k, v] of Object.entries({ assign, backfill, seed, owned, mark })) assert.ok(v > 0, k);
  assert.ok(assign < backfill && backfill < seed && seed < owned && owned < mark);
  assert.match(body.slice(owned, mark), /if \(owned &&/);
  const preload = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  assert.match(preload, /storeOwned:\s*\(\)\s*=>\s*ipcRenderer\.invoke\('hub:store-owned'\)/);
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /ipcMain\.handle\('hub:store-owned'[^\n]*_storeLockVerdict !== 'held'/);
});
