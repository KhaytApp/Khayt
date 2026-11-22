/**
 * A full activity log must not spend the real deletes' tombstones.
 *
 * The team activity log keeps 2,000 entries (renderer/app-helpers.js
 * logActivity). Once it is full every logged action trims one row, and the
 * trimmed row is tombstoned like any row that disappears — that tombstone is
 * what stops a merge sending the old row back to the END of the log, where
 * the next trim (by position) kept it and dropped the newest entries.
 *
 * But counted in the one 5,000-cap list, a few thousand logged actions pushed
 * out every REAL delete marker, and a device syncing from an older copy
 * brought deleted customers and jobs back. So each capped log's tombstones
 * have an allowance of their own (`capTombstones`).
 *
 * The Mac mirrors this in `StoreWriter.capTombstones`
 * (`DeletesSurviveSyncTests`).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');

function device() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

const CAP = 2000;
const entry = (i) => ({ id: 'AL' + i, at: '2026-10-01T00:00:00.000Z', action: 'edit', detail: String(i) });
const tombKeys = (s) => s.tombstones.map((t) => t.collection + ':' + t.id);

/** A full activity log and one job, stamped and indexed. */
function fullBook(S) {
  const snapshot = {
    auditLog: Array.from({ length: CAP }, (_, i) => entry(i)),
    printLog: [{ id: 'J1', project: 'bracket' }],
    tombstones: [],
  };
  S.backfill(snapshot);
  S.seedIndex(snapshot);
  return snapshot;
}

/** logActivity's own shape: push, then keep the newest 2,000. */
function logActions(snapshot, from, count) {
  for (let i = from; i < from + count; i++) snapshot.auditLog.push(entry(i));
  if (snapshot.auditLog.length > CAP) snapshot.auditLog = snapshot.auditLog.slice(-CAP);
}

test('the cap is the one logActivity trims at', () => {
  assert.equal(device().CAPPED_LOGS.get('auditLog'), CAP);
});

test('the 2001st entry tombstones the trimmed row, so no merge can send it back', () => {
  const S = device();
  const snapshot = fullBook(S);
  logActions(snapshot, CAP, 1);
  S.stampChanges(snapshot);
  assert.deepEqual(tombKeys(snapshot), ['auditLog:AL0']);
});

test('a real delete survives six thousand log trims after it', () => {
  const S = device();
  const snapshot = fullBook(S);
  logActions(snapshot, CAP, 1);
  S.stampChanges(snapshot);
  snapshot.printLog = [];
  S.stampChanges(snapshot);
  // 6,000 more logged actions, saved a hundred at a time.
  let next = CAP + 1;
  for (let save = 0; save < 60; save++) {
    logActions(snapshot, next, 100);
    next += 100;
    S.stampChanges(snapshot);
  }
  const keys = tombKeys(snapshot);
  assert.ok(keys.includes('printLog:J1'), 'the job lost its tombstone to the activity log');
  // The log's own markers stay bounded, newest kept.
  const logTombs = keys.filter((k) => k.startsWith('auditLog:'));
  assert.equal(logTombs.length, 5000);
  assert.equal(logTombs[logTombs.length - 1], 'auditLog:AL' + (next - CAP - 1));
  assert.equal(snapshot.tombstones.length, 5001);
});

test('a real delete keeps the 5,000 it always had among the other collections', () => {
  const S = device();
  const tomb = [];
  for (let i = 0; i < 5000; i++) tomb.push({ id: 'C' + i, collection: 'clients', rev: 1 });
  for (let i = 0; i < 3000; i++) tomb.push({ id: 'AL' + i, collection: 'auditLog', rev: 1 });
  tomb.push({ id: 'C5000', collection: 'clients', rev: 1 });
  const snapshot = { clients: [], tombstones: tomb };
  S.seedIndex(snapshot);
  S.stampChanges(snapshot);
  const clients = snapshot.tombstones.filter((t) => t.collection === 'clients');
  assert.equal(clients.length, 5000);
  assert.equal(clients[0].id, 'C1', 'the oldest real delete goes first');
  assert.equal(clients[clients.length - 1].id, 'C5000');
  assert.equal(snapshot.tombstones.filter((t) => t.collection === 'auditLog').length, 3000);
});

test('a merge from a server still holding trimmed rows keeps the newest entries', () => {
  const S = device();
  // The server's copy is older: AL0..AL1999.
  const server = { auditLog: Array.from({ length: CAP }, (_, i) => entry(i)), tombstones: [] };
  S.backfill(server);
  const payload = S.extractDeltas(server, null);

  // This device has logged ten more since: AL10..AL2009.
  const local = fullBook(S);
  logActions(local, CAP, 10);
  S.stampChanges(local);
  assert.equal(local.auditLog[0].id, 'AL10');

  S.applyDeltas(local, payload);
  const ids = local.auditLog.map((e) => e.id);
  assert.ok(!ids.includes('AL0') && !ids.includes('AL9'), 'a trimmed row came back');
  assert.equal(local.auditLog.length, CAP);

  // And one more action trims the oldest — not this device's newest.
  logActions(local, CAP + 10, 1);
  S.stampChanges(local);
  assert.equal(local.auditLog[0].id, 'AL11');
  assert.equal(local.auditLog[local.auditLog.length - 1].id, 'AL2010');
});
