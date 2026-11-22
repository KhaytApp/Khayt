/**
 * A delete has to travel as a FACT, not just as an effect.
 *
 * `applyDeltas` used to carry out an incoming delete and move on: the record was
 * removed, and nothing recorded that a delete had happened. The receiving device
 * therefore had no tombstone, so when a third device that had not yet seen the
 * delete pushed the record, the unseen-record branch accepted it — there was
 * nothing to refuse it with. Meanwhile the device that pressed delete does hold
 * the tombstone and stays deleted. Two devices disagree, permanently, and neither
 * has any way to notice.
 *
 * The earlier resurrection fix (test/resurrected-records.test.js) made the
 * DELETING device immune by consulting its own tombstones. That defence is worth
 * nothing on a device that was never given one.
 *
 * Found by building the three-device case while writing the org integration
 * tests, and confirmed by running it — two devices ending up with different
 * record sets — before any of this was changed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');

/** A fresh engine per simulated device — separate machines have separate indexes. */
function device() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

const snap = (over = {}) => ({ printLog: [], clients: [], tombstones: [], ...over });
const ids = (s, coll = 'printLog') => s[coll].map((r) => r.id).sort();
const all = (s) => ({ deltas: [], tombstones: [], ...s });

/** Two orders, already stamped, known to every device. */
const seeded = () => snap({
  printLog: [
    { id: 'o1', project: 'bracket', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' },
    { id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' },
  ],
});

test('three devices: a delete relayed through one does not come back from another', () => {
  const [A, B, C] = [device(), device(), device()];
  const [a, b, c] = [seeded(), seeded(), seeded()];
  for (const [e, s] of [[A, a], [B, b], [C, c]]) { e.setScope('shop-x'); e.seedIndex(s); }

  // A deletes o2.
  a.printLog = a.printLog.filter((r) => r.id !== 'o2');
  A.stampChanges(a);
  assert.deepEqual(ids(a), ['o1']);
  assert.equal(a.tombstones.length, 1);

  // A → B. B must not merely lose the record; it must learn the record is gone.
  B.applyDeltas(b, A.extractDeltas(a, { rev: 0, ts: '' }), { appendOnly: [] });
  assert.deepEqual(ids(b), ['o1'], 'B applied the delete');
  assert.equal(b.tombstones.length, 1, 'and kept the tombstone that justified it');
  assert.equal(b.tombstones[0].id, 'o2');

  // C never saw the delete and still holds o2. This is the moment it used to
  // come back.
  B.applyDeltas(b, C.extractDeltas(c, { rev: 0, ts: '' }), { appendOnly: [] });
  assert.deepEqual(ids(b), ['o1'], 'C did not resurrect it on B');

  // B → A closes the loop: both agree, and would have disagreed before.
  A.applyDeltas(a, B.extractDeltas(b, { rev: 0, ts: '' }), { appendOnly: [] });
  assert.deepEqual(ids(a), ids(b), 'A and B converged');

  // And C, once it finally syncs, converges too rather than staying the odd one.
  C.applyDeltas(c, B.extractDeltas(b, { rev: 0, ts: '' }), { appendOnly: [] });
  assert.deepEqual(ids(c), ['o1']);
  assert.equal(c.tombstones.length, 1);
});

test('a tombstone for a record this device never had is still recorded', () => {
  // The device that is behind is the one that most needs to know. Dropping the
  // tombstone (the old `if (i === -1) continue`) is how it stayed behind: it
  // would accept the record from any peer that still had it.
  const D = device();
  const d = snap();
  D.setScope('shop-y');
  D.seedIndex(d);

  D.applyDeltas(d, all({
    tombstones: [{ id: 'gone', collection: 'printLog', rev: 3, deletedAt: '2026-07-02T00:00:00.000Z' }],
  }), {});
  assert.equal(d.tombstones.length, 1, 'recorded despite having nothing to remove');

  // Now a peer offers the record. It must be refused.
  const r = D.applyDeltas(d, all({
    deltas: [{ collection: 'printLog', record: { id: 'gone', project: 'ghost', rev: 3 } }],
  }), {});
  assert.deepEqual(ids(d), [], 'the record was refused, not adopted');
  assert.equal(r.skipped, 1);
});

test('propagating a tombstone preserves the rev it deleted', () => {
  // The rev is what lets a delete report that it discarded a newer edit. A copy
  // that dropped it would make every propagated delete look like it deleted rev 0
  // and silence the delete_over_edit report on every device but the first.
  const D = device();
  const d = snap({ printLog: [{ id: 'o1', project: 'edited here', rev: 9, updatedAt: '2026-07-05T00:00:00.000Z' }] });
  D.setScope('shop-z');
  D.seedIndex(d);

  const r = D.applyDeltas(d, all({
    tombstones: [{ id: 'o1', collection: 'printLog', rev: 4, deletedAt: '2026-07-03T00:00:00.000Z' }],
  }), {});

  assert.deepEqual(ids(d), [], 'the delete still wins');
  assert.equal(d.tombstones[0].rev, 4, 'the deleted rev survived the copy');
  assert.equal(d.tombstones[0].deletedAt, '2026-07-03T00:00:00.000Z');
  assert.equal(r.conflicts.length, 1, 'and the discarded newer edit was reported');
  assert.equal(r.conflicts[0].kind, 'delete_over_edit');
  assert.equal(r.conflicts[0].localRev, 9);
});

test('applying the same payload twice does not duplicate tombstones', () => {
  const D = device();
  const d = seeded();
  D.setScope('shop-x');
  D.seedIndex(d);

  const payload = all({ tombstones: [{ id: 'o2', collection: 'printLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z' }] });
  D.applyDeltas(d, payload, {});
  D.applyDeltas(d, payload, {});
  D.applyDeltas(d, payload, {});
  assert.equal(d.tombstones.length, 1, 'idempotent');
  assert.deepEqual(ids(d), ['o1']);
});

test('one payload carrying the same tombstone twice records it once', () => {
  // Repeated CALLS are deduped by rebuilding the local set each time, so they do
  // not exercise the within-payload case at all — a mutation test caught that the
  // guard for it was untested. Our own extractDeltas will not produce a duplicate,
  // but the payload arrives from a server that may have merged two devices' lists.
  const D = device();
  const d = seeded();
  D.setScope('shop-x');
  D.seedIndex(d);

  const t = { id: 'o2', collection: 'printLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z' };
  D.applyDeltas(d, all({ tombstones: [t, { ...t }, { ...t }] }), {});
  assert.equal(d.tombstones.length, 1, 'recorded once, not three times');
  assert.deepEqual(ids(d), ['o1']);
});

test('a higher-rev delete of the same id raises the recorded rev', () => {
  // Two devices can delete the same id after seeing different revs. Keeping the
  // higher one keeps delete_over_edit accurate instead of under-reporting.
  const D = device();
  const d = snap();
  D.setScope('shop-x');
  D.seedIndex(d);

  D.applyDeltas(d, all({ tombstones: [{ id: 'o1', collection: 'printLog', rev: 2, deletedAt: '2026-07-02T00:00:00.000Z' }] }), {});
  D.applyDeltas(d, all({ tombstones: [{ id: 'o1', collection: 'printLog', rev: 7, deletedAt: '2026-07-04T00:00:00.000Z' }] }), {});
  assert.equal(d.tombstones.length, 1);
  assert.equal(d.tombstones[0].rev, 7);

  // A lower one afterwards must not walk it back down.
  D.applyDeltas(d, all({ tombstones: [{ id: 'o1', collection: 'printLog', rev: 3, deletedAt: '2026-07-05T00:00:00.000Z' }] }), {});
  assert.equal(d.tombstones[0].rev, 7);
});

test('propagated tombstones stay bounded', () => {
  // Every device now carries the union of the org's deletes rather than only its
  // own, so the 5000 cap has to hold on this path too. Relying on the next save
  // to trim would make the bound a property of the caller.
  const D = device();
  const d = snap();
  D.setScope('shop-x');
  D.seedIndex(d);

  const many = Array.from({ length: 5200 }, (_, i) => ({
    id: `o${i}`, collection: 'printLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z',
  }));
  D.applyDeltas(d, all({ tombstones: many }), {});
  assert.equal(d.tombstones.length, 5000, 'capped');
  assert.equal(d.tombstones[d.tombstones.length - 1].id, 'o5199', 'the most recent are kept');
});

test('a delete still loses to nothing — live records are untouched', () => {
  // The fix must not turn into over-deletion: only ids that were actually
  // tombstoned may go.
  const D = device();
  const d = seeded();
  D.setScope('shop-x');
  D.seedIndex(d);

  D.applyDeltas(d, all({ tombstones: [{ id: 'o2', collection: 'printLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z' }] }), {});
  assert.deepEqual(ids(d), ['o1'], 'o1 survived');
  assert.equal(d.printLog[0].project, 'bracket', 'and was not rewritten');
  assert.deepEqual(d.clients, [], 'other collections untouched');
});

test('append-only means no EDITS, not no deletes', () => {
  // A non-obvious interaction, measured rather than assumed. `appendOnly` stops a
  // peer's stale copy of a log entry overwriting this one's, so the delta loop
  // refuses updates to those collections. A tombstone is not an update: the app
  // lets a shop delete a waste-log line or a time entry, and that delete has to
  // reach the other devices or they disagree forever.
  //
  // So deletes DO apply to append-only collections, and new entries still arrive.
  // Both halves are asserted, because a future reading of "append-only" as
  // "immutable" would break convergence in one direction and silently.
  const AO = ['auditLog', 'wasteLog'];
  const D = device();
  const d = {
    auditLog: [{ id: 'a1', what: 'price changed', rev: 1 }],
    wasteLog: [{ id: 'w1', grams: 40, rev: 1 }],
    tombstones: [],
  };
  D.setScope('s');
  D.seedIndex(d);

  // An edit is refused...
  let r = D.applyDeltas(d, all({
    deltas: [{ collection: 'auditLog', record: { id: 'a1', what: 'TAMPERED', rev: 9 } }],
  }), { appendOnly: AO });
  assert.equal(d.auditLog[0].what, 'price changed', 'an append-only entry is not rewritten');
  assert.equal(r.skipped, 1);

  // ...a new entry is accepted...
  D.applyDeltas(d, all({
    deltas: [{ collection: 'auditLog', record: { id: 'a2', what: 'stock adjusted', rev: 1 } }],
  }), { appendOnly: AO });
  assert.deepEqual(ids(d, 'auditLog'), ['a1', 'a2'], 'new log entries still propagate');

  // ...and a delete applies, and is remembered like any other.
  r = D.applyDeltas(d, all({
    tombstones: [{ id: 'w1', collection: 'wasteLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z' }],
  }), { appendOnly: AO });
  assert.deepEqual(ids(d, 'wasteLog'), [], 'a deleted waste-log line goes');
  assert.equal(r.removed, 1);
  assert.equal(d.tombstones.length, 1, 'and the delete is remembered, so it cannot come back');
});
