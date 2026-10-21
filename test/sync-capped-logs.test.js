/**
 * A log trimming its own oldest rows is not a delete.
 *
 * The team activity log keeps 2,000 entries (renderer/app-helpers.js
 * logActivity). Once it was full, every save that logged an action dropped
 * one row, and `stampChanges` tombstoned it as if the shop had deleted it.
 * Tombstones are capped at 5,000 and pruned oldest-first, so a few thousand
 * logged actions pushed out every REAL delete marker — and a device syncing
 * from an older copy then brought deleted customers and jobs back.
 *
 * The Mac mirrors this in `StoreWriter.recordDeletions`
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

/** A full activity log and one customer, stamped and indexed. */
function fullBook(S) {
  const snapshot = {
    auditLog: Array.from({ length: CAP }, (_, i) => entry(i)),
    clients: [{ id: 'c1', name: 'Sara' }],
    tombstones: [],
  };
  S.backfill(snapshot);
  S.seedIndex(snapshot);
  return snapshot;
}

test('the cap is the one logActivity trims at', () => {
  const S = device();
  assert.equal(S.CAPPED_LOGS.get('auditLog'), CAP);
});

test('the 2001st audit entry trims the oldest and leaves no tombstone', () => {
  const S = device();
  const snapshot = fullBook(S);
  // logActivity's own shape: push, then keep the newest 2,000.
  snapshot.auditLog.push(entry(CAP));
  snapshot.auditLog = snapshot.auditLog.slice(-CAP);
  const out = S.stampChanges(snapshot);
  assert.equal(snapshot.auditLog.length, CAP);
  assert.deepEqual(snapshot.tombstones, [], 'a trimmed log row was tombstoned');
  assert.deepEqual(out.deleted, [], 'a trimmed log row was reported as a delete');
});

test('a real delete beside a full log is still tombstoned', () => {
  const S = device();
  const snapshot = fullBook(S);
  snapshot.clients = [];
  snapshot.auditLog.push(entry(CAP));
  snapshot.auditLog = snapshot.auditLog.slice(-CAP);
  S.stampChanges(snapshot);
  assert.deepEqual(snapshot.tombstones.map((t) => t.collection + ':' + t.id), ['clients:c1']);
});

test('a log emptied below its cap is a delete, and is tombstoned', () => {
  const S = device();
  const snapshot = fullBook(S);
  snapshot.auditLog = [];
  S.stampChanges(snapshot);
  assert.equal(snapshot.tombstones.length, CAP);
  assert.ok(snapshot.tombstones.every((t) => t.collection === 'auditLog'));
});
