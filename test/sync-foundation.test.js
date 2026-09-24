/**
 * Phase 0 sync-foundation tests. See docs/KHAYT-3.0-PHASE0-SPEC.md §7.
 * KhaytSync is pure logic (no DOM) — require it directly.
 */
const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const sync = require('../lib/sync.js');

beforeEach(() => sync._resetIndex()); // each test starts with an empty index

function snap(over = {}) {
  return { printLog: [], clients: [], inventory: [], tombstones: [], ...over };
}

test('stamp: a new record gets rev:1 + updatedAt', () => {
  const s = snap({ clients: [{ id: 'c1', name: 'Acme' }] });
  const sum = sync.stampChanges(s);
  assert.equal(s.clients[0].rev, 1);
  assert.equal(typeof s.clients[0].updatedAt, 'string');
  assert.deepEqual(sum.created, [{ collection: 'clients', id: 'c1' }]);
});

test('stamp: an unchanged record across two saves does NOT bump rev (idempotency)', () => {
  const rec = { id: 'c1', name: 'Acme' };
  const s = snap({ clients: [rec] });
  sync.seedIndex(s);              // seed from loaded state (no bump)
  const sum = sync.stampChanges(s);
  assert.equal(rec.rev, undefined, 'seeded-but-unchanged record is never stamped');
  assert.equal(sum.created.length, 0);
  assert.equal(sum.changed.length, 0);
});

test('stamp: a content change bumps rev by exactly 1 and advances updatedAt', () => {
  const rec = { id: 'c1', name: 'Acme', rev: 3, updatedAt: '2020-01-01T00:00:00.000Z' };
  const s = snap({ clients: [rec] });
  sync.seedIndex(s);
  rec.name = 'Acme Corp';        // a real content change
  const sum = sync.stampChanges(s);
  assert.equal(rec.rev, 4, 'rev bumps by exactly 1');
  assert.ok(rec.updatedAt > '2020-01-01T00:00:00.000Z', 'updatedAt advances');
  assert.deepEqual(sum.changed, [{ collection: 'clients', id: 'c1' }]);
});

test('fingerprint excludes rev/updatedAt — changing only those is not a content change', () => {
  const rec = { id: 'c1', name: 'Acme', rev: 1, updatedAt: 'x' };
  const s = snap({ clients: [rec] });
  sync.seedIndex(s);
  rec.rev = 99; rec.updatedAt = 'y'; // touch only reserved fields
  const sum = sync.stampChanges(s);
  assert.equal(sum.changed.length, 0, 'reserved-field churn must not count as a change');
});

test('delete: emits a tombstone and does not resurrect on applyDeltas', () => {
  const s = snap({ clients: [{ id: 'c1', name: 'Acme' }, { id: 'c2', name: 'B' }] });
  sync.seedIndex(s);
  s.clients = s.clients.filter((c) => c.id !== 'c2'); // delete c2
  const sum = sync.stampChanges(s);
  assert.deepEqual(sum.deleted, [{ collection: 'clients', id: 'c2' }]);
  assert.equal(s.tombstones.length, 1);
  assert.equal(s.tombstones[0].id, 'c2');
  // applyDeltas with that tombstone must remove c2 if a stale delta re-adds it
  sync.applyDeltas(s, { deltas: [{ collection: 'clients', record: { id: 'c2', rev: 5 } }], tombstones: [] });
  sync.applyDeltas(s, { deltas: [], tombstones: s.tombstones });
  assert.equal(s.clients.some((c) => c.id === 'c2'), false, 'tombstone wins — no resurrection');
});

test('backfill: records missing rev get rev:1 + updatedAt; idempotent', () => {
  const s = snap({ inventory: [{ id: 'f1' }, { id: 'f2', rev: 7 }] });
  const n = sync.backfill(s, '2026-01-01T00:00:00.000Z');
  assert.equal(n, 1, 'only the record missing rev is backfilled');
  assert.equal(s.inventory[0].rev, 1);
  assert.equal(s.inventory[0].updatedAt, '2026-01-01T00:00:00.000Z');
  assert.equal(s.inventory[1].rev, 7, 'existing rev preserved');
  assert.equal(sync.backfill(s), 0, 'second backfill is a no-op');
});

test('id backfill: an id-less record gets a stable id, unchanged on next pass', () => {
  const s = snap({ shiftLogs: [{ note: 'opened' }] });
  sync.backfill(s);
  const id = s.shiftLogs[0].id;
  assert.equal(typeof id, 'string');
  assert.ok(id.length > 0);
  sync.seedIndex(s);
  sync.stampChanges(s);
  assert.equal(s.shiftLogs[0].id, id, 'id is stable across passes');
});

test('extractDeltas: returns only records past the cursor; empty when nothing changed', () => {
  const s = snap({ clients: [{ id: 'c1', rev: 2 }, { id: 'c2', rev: 5 }] });
  const out = sync.extractDeltas(s, { rev: 2, ts: '' });
  assert.equal(out.deltas.length, 1);
  assert.equal(out.deltas[0].record.id, 'c2');
  assert.equal(out.cursor.rev, 5);
  const none = sync.extractDeltas(s, { rev: 5, ts: '' });
  assert.equal(none.deltas.length, 0, 'cursor at high-water => no deltas');
});

test('applyDeltas: LWW by rev — higher rev wins, lower is rejected', () => {
  const s = snap({ clients: [{ id: 'c1', name: 'old', rev: 2 }] });
  const r1 = sync.applyDeltas(s, { deltas: [{ collection: 'clients', record: { id: 'c1', name: 'new', rev: 3 } }] });
  assert.equal(s.clients[0].name, 'new');
  assert.equal(r1.applied, 1);
  const r2 = sync.applyDeltas(s, { deltas: [{ collection: 'clients', record: { id: 'c1', name: 'stale', rev: 1 } }] });
  assert.equal(s.clients[0].name, 'new', 'lower-rev incoming is rejected');
  assert.equal(r2.skipped, 1);
});

test('applyDeltas: append-only collections are never overwritten (union)', () => {
  const s = snap({ shiftLogs: [{ id: 's1', note: 'a', rev: 1 }] });
  const r = sync.applyDeltas(
    s,
    { deltas: [
      { collection: 'shiftLogs', record: { id: 's1', note: 'EDIT', rev: 9 } }, // same id -> skipped
      { collection: 'shiftLogs', record: { id: 's2', note: 'b', rev: 1 } },    // new id -> added
    ] },
    { appendOnly: ['shiftLogs'] },
  );
  assert.equal(s.shiftLogs.find((x) => x.id === 's1').note, 'a', 'existing append-only entry untouched');
  assert.equal(s.shiftLogs.length, 2, 'new entry unioned in');
  assert.equal(r.applied, 1);
});

test('LocalBackend: status is "off" and push/pull are no-ops', async () => {
  assert.equal(sync.status(), 'off');
  sync.setBackend(sync.LocalBackend);
  assert.equal(sync.LocalBackend.status(), 'off');
  assert.deepEqual(await sync.LocalBackend.pullDeltas(), { deltas: [], tombstones: [], newCursor: null });
  sync.setBackend(null);
  assert.equal(sync.status(), 'off');
});

test('golden invariant: load (seed) → save with no edits → zero churn', () => {
  // The keystone: a cloud-off user who loads and saves without editing must see
  // no rev bumps and no tombstones — Phase 0 introduces no spurious diffs.
  const s = snap({
    printLog: [{ id: 'o1', status: 'completed', rev: 1, updatedAt: 't' }],
    inventory: [{ id: 'f1', rev: 1, updatedAt: 't' }],
    clients: [{ id: 'c1', rev: 1, updatedAt: 't' }],
  });
  sync.seedIndex(s);
  const sum = sync.stampChanges(s);
  assert.equal(sum.created.length + sum.changed.length + sum.deleted.length, 0);
  assert.equal(s.tombstones.length, 0);
  assert.equal(s.printLog[0].rev, 1, 'rev untouched');
});

test('tombstones are capped so they cannot grow without bound', () => {
  const many = Array.from({ length: 5100 }, (_, i) => ({ id: 'D' + i, collection: 'printLog', deletedAt: i }));
  const s = snap({ tombstones: many });
  sync.stampChanges(s);
  assert.equal(s.tombstones.length, 5000);
  assert.ok(s.tombstones.some(t => t.id === 'D5099'), 'newest tombstone kept');
  assert.ok(!s.tombstones.some(t => t.id === 'D0'), 'oldest tombstone dropped');
});

/* ------------------------------------------------------------------
 * A merge that overwrites a local edit must say so.
 *
 * `rev` is a per-record counter, not a causal clock. A peer that edited the
 * same record TWICE arrives at rev 7 while this device sits at its own rev 6
 * from a single edit — so "higher rev wins" discarded the local edit and
 * reported nothing. The only conflict a shop was ever told about was
 * delete-over-edit.
 *
 * The baseline that makes this detectable is per-DEVICE (what this machine has
 * exchanged with the server), so it lives in the change index, never on the
 * record. Putting it on the record makes two devices holding the identical
 * record disagree byte for byte — org-multishop-sync.test.js catches that, and
 * caught the first attempt at this.
 * ------------------------------------------------------------------ */

/** Two devices in sync at rev 5, this one having pushed. */
function syncedAt5(extra = {}) {
  const s = snap({ clients: [{ id: 'c1', name: 'Acme', phone: '0500000000', rev: 5, ...extra }] });
  sync.seedIndex(s);
  sync.markSynced(s);
  return s;
}

test('overwrite: a local edit lost to a higher-rev peer is reported', () => {
  const s = syncedAt5();
  s.clients[0].phone = '0555555555';           // the shop fixes the phone number
  sync.stampChanges(s);                        // → rev 6, never pushed
  const r = sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme Ltd', phone: '0500000000', rev: 7 } }] });

  assert.equal(s.clients[0].phone, '0500000000', 'the higher rev still wins — outcome unchanged');
  assert.equal(r.conflicts.length, 1, 'the discarded edit went unreported');
  const c = r.conflicts[0];
  assert.equal(c.kind, 'remote_over_local_edit');
  assert.equal(c.localRev, 6);
  assert.equal(c.incomingRev, 7);
  assert.equal(c.syncedRev, 5);
  assert.equal(c.discarded.phone, '0555555555', 'the lost copy is handed back');
});

test('overwrite: no local edit means no conflict', () => {
  const s = syncedAt5();
  const r = sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme Ltd', phone: '0500000000', rev: 7 } }] });
  assert.equal(r.applied, 1);
  assert.equal(r.conflicts.length, 0, 'an ordinary update must not be called a conflict');
});

test('overwrite: an unknown baseline says nothing', () => {
  // A store that has not pushed or merged since launch has no baseline. Treating
  // unknown as 0 would report a conflict for the whole store on the first merge.
  const s = snap({ clients: [{ id: 'c1', name: 'Acme', rev: 5 }] });
  sync.seedIndex(s);                           // note: no markSynced
  s.clients[0].name = 'Acme Co';
  sync.stampChanges(s);
  const r = sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme Ltd', rev: 7 } }] });
  assert.equal(r.conflicts.length, 0, 'a false conflict teaches the shop to ignore the message');
});

test('overwrite: identical content is not a conflict', () => {
  const s = syncedAt5();
  s.clients[0].phone = '0555555555';
  sync.stampChanges(s);
  const r = sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme', phone: '0555555555', rev: 7 } }] });
  assert.equal(r.conflicts.length, 0, 'the peer arrived at the same answer — nothing was lost');
});

test('overwrite: the baseline survives a save and a reseed', () => {
  // pullMerge reseeds after every merge and stampChanges runs on every save.
  // Either dropping the baseline silently disables the whole report.
  const s = syncedAt5();
  sync.seedIndex(s);                           // as pullMerge does
  s.clients[0].phone = '0555555555';
  sync.stampChanges(s);                        // as every save does
  const r = sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme Ltd', phone: '0500000000', rev: 7 } }] });
  assert.equal(r.conflicts.length, 1, 'the baseline was thrown away by a reseed or a save');
});

test('overwrite: accepting a record from the server sets the baseline', () => {
  // Otherwise the very next local edit would look unpushed and report falsely.
  const s = syncedAt5();
  sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme Ltd', phone: '0500000000', rev: 7 } }] });
  assert.equal(sync.syncedRevOf('clients', 'c1'), 7);
  s.clients[0].phone = '0566666666';
  sync.stampChanges(s);
  const r = sync.applyDeltas(s, { deltas: [{ collection: 'clients',
    record: { id: 'c1', name: 'Acme Ltd', phone: '0500000000', rev: 9 } }] });
  assert.equal(r.conflicts.length, 1);
  assert.equal(r.conflicts[0].syncedRev, 7, 'the baseline did not move with the merge');
});

test('summarizeOverwrittenEdits names the first record and counts the rest', () => {
  const none = sync.summarizeOverwrittenEdits([{ kind: 'delete_over_edit', discarded: { name: 'X' } }]);
  assert.equal(none.count, 0, 'the delete case has its own message');
  const some = sync.summarizeOverwrittenEdits([
    { kind: 'remote_over_local_edit', id: 'c1', discarded: { name: 'Acme' } },
    { kind: 'remote_over_local_edit', id: 'c2', discarded: { name: 'Beta' } },
  ]);
  assert.deepEqual(some, { count: 2, firstName: 'Acme' });
});

// Security scan, Sep 2026: a delta names its own collection, and the name
// comes from a phone or a peer.
test('a delta cannot turn the settings object (or any non-list) into a collection', () => {
  const S = require('../lib/sync.js');
  const snap = { settings: { shopName: 'Athar', cloud: { token: '__enc__x' } }, clients: [] };
  const r = S.applyDeltas(snap, { deltas: [
    { collection: 'settings', record: { id: 'x', rev: 99 } },
    { collection: '__proto__', record: { id: 'y', rev: 1 } },
    { collection: 'tombstones', record: { id: 'z', rev: 1 } },
    { collection: 'clients', record: { id: 'c1', rev: 1 } },
    { collection: '_auditLog', record: { id: 'a1', rev: 1 } },
  ] });
  assert.equal(snap.settings.shopName, 'Athar', 'the settings object survived');
  assert.equal(snap.clients.length, 1, 'an ordinary collection still takes records');
  assert.equal(snap._auditLog.length, 1, 'a real underscore ledger still takes records');
  assert.equal(r.applied, 2);
  assert.equal(r.skipped, 3);
});

test('a masked secret coming back from a phone never overwrites the real one', () => {
  const S = require('../lib/sync.js');
  const snap = { machines: [{ id: 'm1', rev: 1, name: 'U1', printerApi: { host: 'u1.local', apiKey: '__enc__REAL' } }] };
  S.applyDeltas(snap, { deltas: [{ collection: 'machines',
    record: { id: 'm1', rev: 2, name: 'U1 renamed', printerApi: { host: 'u1.local', apiKey: '__KHAYT_MASKED__' } } }] });
  assert.equal(snap.machines[0].name, 'U1 renamed', 'the edit itself is taken');
  assert.equal(snap.machines[0].printerApi.apiKey, '__enc__REAL', 'the key is not replaced by the mask');
});
