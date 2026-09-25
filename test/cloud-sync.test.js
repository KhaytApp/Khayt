/**
 * Stage C auto-sync controller (renderer/cloud-sync.js). Drives the controller
 * with injected fake push/pull/snapshot deps (no IPC, no DOM) so the conflict
 * merge, single-flight, and status transitions are deterministic.
 */
const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/sync.js');          // defines globalThis.KhaytSync (merge engine)
require('../lib/cloud-inbox.js');   // defines globalThis.KhaytCloudInbox (the merge rule)
const sync = require('../renderer/cloud-sync.js'); // defines globalThis.KhaytCloudSync

const clone = (o) => JSON.parse(JSON.stringify(o));

beforeEach(() => sync.stop()); // reset module-level state between tests

function makeDeps(overrides = {}) {
  let state = overrides.initialState || { clients: [{ id: 'c1', name: 'Local', rev: 2, updatedAt: 'a' }], tombstones: [] };
  const calls = { push: 0, pull: 0, saved: 0 };
  const deps = {
    debounceMs: 5,
    appendOnly: overrides.appendOnly || [],
    buildSnapshot: () => clone(state),
    applySnapshot: (s) => { state = clone(s); },
    save: () => { calls.saved++; },
    pull: overrides.pull || (async () => { calls.pull++; return { ok: true, store: null, rev: 0 }; }),
    push: overrides.push || (async () => { calls.push++; return { ok: true, rev: 1 }; }),
  };
  return { deps, calls, getState: () => state };
}

test('happy path: push succeeds → status synced', async () => {
  const { deps } = makeDeps();
  sync.configure(deps);
  const r = await sync.syncNow();
  assert.equal(r.ok, true);
  assert.equal(r.rev, 1);
  assert.equal(sync.status(), 'synced');
});

test('conflict resolves via pull → LWW merge → re-push (server-newer wins, new record added, local-newer kept)', async () => {
  let pushCalls = 0;
  const serverStore = {
    clients: [
      { id: 'c1', name: 'Server', rev: 3, updatedAt: 'b' }, // higher rev than local c1 (rev2) → wins
      { id: 'c2', name: 'NewFromServer', rev: 1, updatedAt: 'b' }, // not local → added
      { id: 'c3', name: 'ServerOld', rev: 1, updatedAt: 'b' }, // lower rev than local c3 → local kept
    ],
    tombstones: [],
  };
  const { deps, calls, getState } = makeDeps({
    initialState: {
      clients: [
        { id: 'c1', name: 'Local', rev: 2, updatedAt: 'a' },
        { id: 'c3', name: 'LocalNew', rev: 5, updatedAt: 'z' },
      ],
      tombstones: [],
    },
    pull: async () => { calls.pull++; return { ok: true, store: clone(serverStore), rev: 9 }; },
    push: async () => { pushCalls++; return pushCalls === 1 ? { conflict: true, rev: 9 } : { ok: true, rev: 10 }; },
  });
  sync.configure(deps);
  const r = await sync.syncNow();

  assert.equal(r.ok, true, 'final push succeeds after merge');
  assert.equal(pushCalls, 2, 'pushed once, hit conflict, pushed again');
  assert.equal(calls.pull, 1, 'pulled once to resolve');
  const st = getState();
  assert.equal(st.clients.find((c) => c.id === 'c1').name, 'Server', 'server rev3 overwrote local rev2');
  assert.ok(st.clients.find((c) => c.id === 'c2'), 'server-only record added');
  assert.equal(st.clients.find((c) => c.id === 'c3').name, 'LocalNew', 'local rev5 kept over server rev1');
});

test('append-only collections are never overwritten on merge', async () => {
  let pushCalls = 0;
  const serverStore = { loyaltyLedger: [{ id: 'L1', pts: 999, rev: 9, updatedAt: 'b' }], tombstones: [] };
  const { deps, getState } = makeDeps({
    appendOnly: ['loyaltyLedger'],
    initialState: { loyaltyLedger: [{ id: 'L1', pts: 10, rev: 1, updatedAt: 'a' }], tombstones: [] },
    pull: async () => ({ ok: true, store: clone(serverStore), rev: 9 }),
    push: async () => { pushCalls++; return pushCalls === 1 ? { conflict: true, rev: 9 } : { ok: true, rev: 10 }; },
  });
  sync.configure(deps);
  await sync.syncNow();
  assert.equal(getState().loyaltyLedger.find((r) => r.id === 'L1').pts, 10, 'existing ledger row not overwritten');
});

test('server tombstone removes a local record on merge', async () => {
  let pushCalls = 0;
  const serverStore = { clients: [], tombstones: [{ id: 'c1', collection: 'clients', deletedAt: 'b' }] };
  const { deps, getState } = makeDeps({
    pull: async () => ({ ok: true, store: clone(serverStore), rev: 9 }),
    push: async () => { pushCalls++; return pushCalls === 1 ? { conflict: true, rev: 9 } : { ok: true, rev: 10 }; },
  });
  sync.configure(deps);
  await sync.syncNow();
  assert.equal(getState().clients.find((c) => c.id === 'c1'), undefined, 'tombstoned record removed locally');
});

test('locked push → status locked, no throw', async () => {
  const { deps } = makeDeps({ push: async () => ({ ok: false, error: 'locked' }) });
  sync.configure(deps);
  const r = await sync.syncNow();
  assert.equal(r.error, 'locked');
  assert.equal(sync.status(), 'locked');
});

test('single-flight: a second syncNow while one is in flight is rejected, then coalesced', async () => {
  let resolvePush;
  const { deps, calls } = makeDeps({ push: () => new Promise((res) => { resolvePush = res; }) });
  sync.configure(deps);
  const p1 = sync.syncNow();                 // starts, awaits push
  const p2 = await sync.syncNow();           // in-flight → rejected
  assert.equal(p2.error, 'in-flight');
  resolvePush({ ok: true, rev: 1 });
  const r1 = await p1;
  assert.equal(r1.ok, true);
});

test('pullMerge with empty server → ok+empty, no apply', async () => {
  const { deps, calls } = makeDeps({ pull: async () => ({ ok: true, store: null, rev: 0 }) });
  sync.configure(deps);
  const r = await sync.pullMerge();
  assert.equal(r.ok, true);
  assert.equal(r.empty, true);
  assert.equal(calls.saved, 0, 'nothing saved when server is empty');
});

test('stop() turns it off; scheduleSync after stop is a no-op', async () => {
  const { deps, calls } = makeDeps();
  sync.configure(deps);
  sync.stop();
  assert.equal(sync.status(), 'off');
  sync.scheduleSync();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(calls.push, 0, 'no push after stop');
});

test('onStatus listener receives transitions', async () => {
  const { deps } = makeDeps();
  const seen = [];
  const off = sync.onStatus((s) => seen.push(s));
  sync.configure(deps);
  await sync.syncNow();
  off();
  assert.ok(seen.includes('syncing'));
  assert.ok(seen.includes('synced'));
});

test('offline failure → status offline + auto-retry that succeeds when back online', async () => {
  let attempts = 0;
  const { deps, calls } = makeDeps({
    push: async () => { attempts++; if (attempts === 1) throw new Error('network down'); return { ok: true, rev: 7 }; },
  });
  deps.retryBaseMs = 10; // fast backoff for the test
  sync.configure(deps);
  const r = await sync.syncNow();
  assert.equal(r.ok, false, 'first push fails offline');
  assert.equal(sync.status(), 'offline');
  // the controller scheduled an automatic retry; wait for it
  await new Promise((res) => setTimeout(res, 40));
  assert.equal(attempts, 2, 'auto-retried after backoff');
  assert.equal(sync.status(), 'synced', 'retry succeeded once connectivity returned');
});

test('flush() retries immediately and resets backoff', async () => {
  let attempts = 0;
  const { deps } = makeDeps({
    push: async () => { attempts++; if (attempts === 1) throw new Error('offline'); return { ok: true, rev: 3 }; },
  });
  deps.retryBaseMs = 60_000; // long, so only an explicit flush would retry in time
  sync.configure(deps);
  await sync.syncNow();
  assert.equal(sync.status(), 'offline');
  const r = await sync.flush(); // e.g. the window 'online' event
  assert.equal(r.ok, true);
  assert.equal(attempts, 2);
  assert.equal(sync.status(), 'synced');
});

test('a fresh edit supersedes the pending retry (no double-push)', async () => {
  let attempts = 0;
  const { deps } = makeDeps({
    push: async () => { attempts++; if (attempts === 1) throw new Error('offline'); return { ok: true, rev: 1 }; },
  });
  deps.retryBaseMs = 10; deps.debounceMs = 5;
  sync.configure(deps);
  await sync.syncNow();          // attempt 1 fails → retry scheduled (~10ms)
  sync.scheduleSync();           // a new edit arrives → supersedes the retry (~5ms)
  await new Promise((res) => setTimeout(res, 40));
  assert.equal(attempts, 2, 'exactly one more push, not two');
  assert.equal(sync.status(), 'synced');
});

test('onConflicts fires when a synced delete discards a local edit', async () => {
  // Local has c1 edited to rev 5. The server's snapshot deleted c1 (tombstone at
  // rev 2). Delete wins — but the host must be told the local edit was dropped.
  let pushCalls = 0;
  const seen = [];
  const serverStore = { clients: [], tombstones: [{ collection: 'clients', id: 'c1', rev: 2 }] };
  const { deps } = makeDeps({
    initialState: { clients: [{ id: 'c1', name: 'Edited Locally', rev: 5, updatedAt: 'z' }], tombstones: [] },
    pull: async () => ({ ok: true, store: clone(serverStore), rev: 9 }),
    push: async () => { pushCalls++; return pushCalls === 1 ? { conflict: true, rev: 9 } : { ok: true, rev: 10 }; },
  });
  deps.onConflicts = (c) => seen.push(...c);
  sync.configure(deps);
  await sync.syncNow();

  const discarded = seen.filter((c) => c.kind === 'delete_over_edit');
  assert.equal(discarded.length, 1, 'the discarded edit was surfaced to the host');
  assert.equal(discarded[0].id, 'c1');
  assert.equal(discarded[0].discarded.name, 'Edited Locally', 'the lost record is handed over');
});

test('onConflicts is not called when a merge discards nothing', async () => {
  let called = false;
  const { deps } = makeDeps({
    pull: async () => ({ ok: true, store: { clients: [{ id: 'c2', name: 'Server', rev: 1 }], tombstones: [] }, rev: 9 }),
    push: async () => ({ ok: true, rev: 1 }),
  });
  deps.onConflicts = () => { called = true; };
  sync.configure(deps);
  await sync.syncNow();
  assert.equal(called, false);
});

/**
 * A delete made here must survive a pull that predates it.
 *
 * pullMerge() runs on unlock, on launch, and inside 409 conflict resolution. If
 * the shop deleted a record and the server has not learned about it yet, the
 * server's copy arrives as an ordinary unseen-record delta — and the merge used
 * to push it straight back into local state, where the following save persisted
 * it. From the shop's side: "I deleted that client and it came back."
 *
 * The engine already refused to let a stale delta undo a delete, but only for
 * tombstones travelling IN the payload, never the ones the target already held.
 * Two devices make it easy to hit: A deletes, B pushes first, A's push 409s, A
 * pulls, and A's own delete is undone.
 */
test('a locally deleted record is not resurrected by a pull that has not seen the delete', async () => {
  const serverStore = {
    clients: [
      { id: 'c1', name: 'Deleted Client', rev: 2, updatedAt: 'a' }, // server has not seen the delete
      { id: 'c2', name: 'Kept', rev: 1, updatedAt: 'a' },
    ],
    tombstones: [],
  };
  const { deps, getState } = makeDeps({
    initialState: {
      clients: [{ id: 'c2', name: 'Kept', rev: 1, updatedAt: 'a' }],
      tombstones: [{ id: 'c1', collection: 'clients', rev: 2, deletedAt: '2026-07-28T08:00:00.000Z' }],
    },
    pull: async () => ({ ok: true, store: clone(serverStore), rev: 9 }),
    push: async () => ({ ok: true, rev: 10 }),
  });
  sync.configure(deps);
  await sync.pullMerge();

  const st = getState();
  assert.equal(st.clients.some((c) => c.id === 'c1'), false, 'the deleted client must stay deleted');
  assert.equal(st.clients.length, 1, 'and nothing else is disturbed');
});

test('a delete does not swallow a genuinely newer edit in silence', async () => {
  // Same shape, but the peer edited the record AFTER the delete saw it. The
  // delete still wins — reversing that would resurrect deleted records — but the
  // shop is told an edit was thrown away rather than it vanishing.
  const seen = [];
  const serverStore = {
    clients: [{ id: 'c1', name: 'Edited On The Other Device', rev: 7, updatedAt: 'z' }],
    tombstones: [],
  };
  const { deps, getState } = makeDeps({
    initialState: {
      clients: [],
      tombstones: [{ id: 'c1', collection: 'clients', rev: 2, deletedAt: '2026-07-28T08:00:00.000Z' }],
    },
    pull: async () => ({ ok: true, store: clone(serverStore), rev: 9 }),
    push: async () => ({ ok: true, rev: 10 }),
  });
  deps.onConflicts = (c) => seen.push(...c);
  sync.configure(deps);
  await sync.pullMerge();

  assert.equal(getState().clients.length, 0, 'delete still wins');
  const discarded = seen.filter((c) => c.kind === 'delete_over_edit');
  assert.equal(discarded.length, 1, 'and the discarded edit is surfaced, not dropped silently');
  assert.equal(discarded[0].discarded.name, 'Edited On The Other Device');
});

test('a stale re-add of an already-deleted record is silent — it discards nothing', async () => {
  // The peer is echoing back a record at or below the rev the delete saw. Nothing
  // was lost, so announcing it would train the shop to ignore the warning.
  const seen = [];
  const { deps } = makeDeps({
    initialState: {
      clients: [],
      tombstones: [{ id: 'c1', collection: 'clients', rev: 5, deletedAt: '2026-07-28T08:00:00.000Z' }],
    },
    pull: async () => ({ ok: true, store: { clients: [{ id: 'c1', name: 'Stale', rev: 5, updatedAt: 'a' }], tombstones: [] }, rev: 9 }),
    push: async () => ({ ok: true, rev: 10 }),
  });
  deps.onConflicts = (c) => seen.push(...c);
  sync.configure(deps);
  await sync.pullMerge();

  assert.equal(seen.length, 0, 'no conflict announced for a stale echo');
});

test('a failure tells the listener WHY, not just that it failed', async () => {
  // The badge in settings paints from this callback. It used to take only the
  // status string, so a shop that had outgrown its plan saw a red "Sync error"
  // with no cause and no next step — while the server had already said, in words
  // the owner could act on, that the store was over the plan's size limit.
  //
  // Pinned here rather than on the badge because this is the contract the badge
  // consumes: if the reason stops arriving, no amount of DOM code can show it.
  const reason = 'push failed: Store exceeds your plan’s size limit (HTTP 413)';
  const { deps } = makeDeps({ push: async () => ({ ok: false, error: reason }) });
  const seen = [];
  const off = sync.onStatus((s, detail) => seen.push({ s, why: detail && detail.error }));
  sync.configure(deps);
  await sync.syncNow();
  off();
  // A push that keeps failing keeps rescheduling itself, and this is the last
  // test in the file — without this the retry loop outlives the suite.
  sync.stop();

  const failed = seen.find((e) => e.s === 'error');
  assert.ok(failed, 'the sync reported an error state');
  assert.match(String(failed.why), /exceeds your plan/,
    'the reason has to reach the listener, or the UI has nothing to show');
  assert.match(String(sync.error()), /exceeds your plan/,
    'and it is retained, for a listener that subscribes after the failure');
});

test('a refusal no retry can fix (412) stops the backoff; the next edit still tries', async () => {
  // docs/api-contract.md: 412 is "stop syncing and tell the user to update. Do not retry."
  let attempts = 0;
  const { deps } = makeDeps({
    push: async () => {
      attempts++;
      if (attempts === 1) return { ok: false, status: 412, error: 'push failed: This shop has unsynced changes this build cannot read. Update Khayt to sync again. (HTTP 412)' };
      return { ok: true, rev: 4 };
    },
  });
  deps.retryBaseMs = 10;
  sync.configure(deps);
  const seen = [];
  const off = sync.onStatus((s, d) => seen.push([s, d && d.refused]));
  await sync.syncNow();
  assert.equal(sync.status(), 'error');
  assert.match(sync.error(), /Update Khayt/, 'the server\'s own sentence is what the shop sees');
  assert.ok(seen.some(([s, refused]) => s === 'error' && refused === true), 'the badge is told this is a refusal');
  await new Promise((res) => setTimeout(res, 60));
  assert.equal(attempts, 1, 'retried on the backoff');
  sync.scheduleSync();          // the shop updated and edited something
  await new Promise((res) => setTimeout(res, 40));
  assert.equal(attempts, 2);
  assert.equal(sync.status(), 'synced');
  off();
});

for (const status of [401, 403, 413]) {
  test(`HTTP ${status} is a refusal too, and is not retried`, async () => {
    let attempts = 0;
    const { deps } = makeDeps({ push: async () => { attempts++; return { ok: false, status, error: `push failed (HTTP ${status})` }; } });
    deps.retryBaseMs = 10;
    sync.configure(deps);
    await sync.syncNow();
    await new Promise((res) => setTimeout(res, 60));
    assert.equal(attempts, 1);
  });
}

test('a server error that time may fix (503) is still retried', async () => {
  let attempts = 0;
  const { deps } = makeDeps({
    push: async () => { attempts++; return attempts === 1 ? { ok: false, status: 503, error: 'push failed (HTTP 503)' } : { ok: true, rev: 2 }; },
  });
  deps.retryBaseMs = 10;
  sync.configure(deps);
  await sync.syncNow();
  await new Promise((res) => setTimeout(res, 60));
  assert.equal(attempts, 2);
  assert.equal(sync.status(), 'synced');
});

test('main passes the HTTP status through both cloud IPC handlers', () => {
  const fs = require('node:fs'); const path = require('node:path');
  const mainJs = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  for (const h of ['hub:cloud-push', 'hub:cloud-pull']) {
    const at = mainJs.indexOf(`ipcMain.handle('${h}'`);
    assert.match(mainJs.slice(at, at + 400), /status: \(e && e\.status\) \|\| null/, `${h} drops the status`);
  }
});
