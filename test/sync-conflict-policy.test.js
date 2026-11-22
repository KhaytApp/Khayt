const { test } = require('node:test');
const assert = require('node:assert/strict');
const { applyDeltas, summarizeDiscardedEdits } = require('../lib/sync.js');

/**
 * The delta sync engine is not wired to a backend yet — the live cloud is
 * whole-snapshot backup/restore with an optimistic rev guard.
 *
 * Concurrent edits used to leave two devices holding different records with no
 * signal to anyone. One edit is still lost — `rev` is a counter, not a causal
 * clock — but the devices now agree on WHICH, so they converge instead of
 * silently drifting apart.
 */

/* ── concurrent edits ────────────────────────────────────────────────────── */

const base = (p, t) => ({ id: 'o1', rev: 4, project: p, updatedAt: t });

test('two devices editing from the same base CONVERGE', () => {
  // rev is a per-record counter, not a causal clock, so one edit is lost either
  // way. What must not happen is each device keeping its own and both believing
  // they are correct — that is silent, permanent divergence.
  const A = base('A edit', '2026-07-22T10:00:00Z');
  const B = base('B edit', '2026-07-22T10:00:05Z');
  const devA = { orders: [{ ...A }] };
  const devB = { orders: [{ ...B }] };
  applyDeltas(devA, { deltas: [{ collection: 'orders', record: { ...B } }] });
  applyDeltas(devB, { deltas: [{ collection: 'orders', record: { ...A } }] });
  assert.equal(devA.orders[0].project, devB.orders[0].project, 'devices diverged');
});

test('the winner does not depend on who pulled first', () => {
  const A = base('A edit', '2026-07-22T10:00:00Z');
  const B = base('B edit', '2026-07-22T10:00:05Z');
  const one = { orders: [{ ...A }] };
  const two = { orders: [{ ...B }] };
  applyDeltas(one, { deltas: [{ collection: 'orders', record: { ...B } }] });
  applyDeltas(two, { deltas: [{ collection: 'orders', record: { ...A } }] });
  assert.equal(one.orders[0].project, 'B edit', 'later updatedAt should win');
  assert.equal(two.orders[0].project, 'B edit');
});

test('identical timestamps still converge, without a coin flip', () => {
  const A = base('A edit', '2026-07-22T10:00:00Z');
  const B = base('B edit', '2026-07-22T10:00:00Z');
  const devA = { orders: [{ ...A }] };
  const devB = { orders: [{ ...B }] };
  applyDeltas(devA, { deltas: [{ collection: 'orders', record: { ...B } }] });
  applyDeltas(devB, { deltas: [{ collection: 'orders', record: { ...A } }] });
  assert.equal(devA.orders[0].project, devB.orders[0].project);
});

test('a conflict is reported, not swallowed', () => {
  const snap = { orders: [base('A edit', '2026-07-22T10:00:00Z')] };
  const r = applyDeltas(snap, {
    deltas: [{ collection: 'orders', record: base('B edit', '2026-07-22T10:00:05Z') }],
  });
  assert.equal(r.conflicts.length, 1, 'nothing can surface a conflict that is never recorded');
  assert.equal(r.conflicts[0].id, 'o1');
  assert.equal(r.conflicts[0].tookIncoming, true);
});

test('a re-sent identical record is not a conflict', () => {
  const rec = base('same', '2026-07-22T10:00:00Z');
  const snap = { orders: [{ ...rec }] };
  const r = applyDeltas(snap, { deltas: [{ collection: 'orders', record: { ...rec } }] });
  assert.equal(r.conflicts.length, 0, 'a duplicate delivery must not look like a conflict');
  assert.equal(r.skipped, 1);
});

test('a lower rev never overwrites a higher one', () => {
  const snap = { orders: [{ id: 'o1', rev: 9, project: 'newer' }] };
  const r = applyDeltas(snap, { deltas: [{ collection: 'orders', record: { id: 'o1', rev: 4, project: 'older' } }] });
  assert.equal(snap.orders[0].project, 'newer');
  assert.equal(r.conflicts.length, 0, 'a clear ordering is not a conflict');
});

/* ── delete over a newer edit ──────────────────────────────────────────────
   Delete still wins (a resurrected order is worse than a lost edit for a shop),
   but the discarded edit is now REPORTED instead of vanishing silently. */

test('a tombstone discarding a newer edit is reported', () => {
  const snap = { orders: [{ id: 'o1', rev: 9, project: 'edited here', updatedAt: 'z' }] };
  const r = applyDeltas(snap, { tombstones: [{ collection: 'orders', id: 'o1', rev: 2 }] });
  assert.equal(snap.orders.length, 0, 'delete still wins — record removed');
  assert.equal(r.removed, 1);
  const c = r.conflicts.find((x) => x.kind === 'delete_over_edit');
  assert.ok(c, 'the discarded edit must be reported');
  assert.equal(c.id, 'o1');
  assert.equal(c.tombRev, 2);
  assert.equal(c.localRev, 9);
  assert.equal(c.discarded.project, 'edited here', 'the lost record travels with the conflict');
});

test('a tombstone at or above the local rev is a plain delete, not a conflict', () => {
  // Nobody edited past what the delete saw → no edit was discarded, no report.
  const snap = { orders: [{ id: 'o1', rev: 3 }] };
  const r = applyDeltas(snap, { tombstones: [{ collection: 'orders', id: 'o1', rev: 3 }] });
  assert.equal(r.removed, 1);
  assert.equal(r.conflicts.filter((x) => x.kind === 'delete_over_edit').length, 0);
});

test('a legacy tombstone with no rev never fabricates a conflict', () => {
  // Pre-rev tombstones (rev 0). A rev-0 delete can never out-be-edited into a
  // false positive: localRev > 0 would report, but we compare against the tomb's
  // own rev — a genuine edit (rev 1+) over a rev-0 delete IS a real discard.
  const snap = { orders: [{ id: 'o1', rev: 1, project: 'p' }] };
  const r = applyDeltas(snap, { tombstones: [{ collection: 'orders', id: 'o1' }] });
  assert.equal(r.removed, 1);
  // rev 1 edit over an unknown (0) delete point → reported, correctly.
  assert.equal(r.conflicts.filter((x) => x.kind === 'delete_over_edit').length, 1);
});

test('deleting an unedited record (both at rev 0) reports nothing', () => {
  const snap = { orders: [{ id: 'o1', project: 'p' }] };
  const r = applyDeltas(snap, { tombstones: [{ collection: 'orders', id: 'o1' }] });
  assert.equal(r.removed, 1);
  assert.equal(r.conflicts.length, 0);
});

/* ── summarizeDiscardedEdits (pure UI input) ───────────────────────────────── */

test('summarizeDiscardedEdits ignores non-discard conflicts', () => {
  assert.deepEqual(summarizeDiscardedEdits([]), { count: 0, firstName: '' });
  assert.deepEqual(summarizeDiscardedEdits([{ kind: 'concurrent_edit', id: 'x' }]), { count: 0, firstName: '' });
  assert.deepEqual(summarizeDiscardedEdits(null), { count: 0, firstName: '' });
});

test('summarizeDiscardedEdits counts discards and names the first', () => {
  const r = summarizeDiscardedEdits([
    { kind: 'concurrent_edit', id: 'ignore' },
    { kind: 'delete_over_edit', id: 'O1', discarded: { project: 'Gearbox batch' } },
    { kind: 'delete_over_edit', id: 'O2', discarded: { name: 'Al-Faisal' } },
  ]);
  assert.equal(r.count, 2, 'only the two discards count');
  assert.equal(r.firstName, 'Gearbox batch');
});

test('summarizeDiscardedEdits falls back through name fields to the id', () => {
  assert.equal(summarizeDiscardedEdits([{ kind: 'delete_over_edit', id: 'O-9' }]).firstName, 'O-9');
  assert.equal(summarizeDiscardedEdits([{ kind: 'delete_over_edit', id: 'x', discarded: { title: 'T' } }]).firstName, 'T');
});
