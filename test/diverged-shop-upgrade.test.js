/**
 * What happens to a shop that ALREADY diverged, when it upgrades to the fix.
 *
 * The tombstone-propagation fix (v3.4.2) stops new divergence. It says nothing
 * about the stores that are already in the bad state: one device holding a
 * tombstone, another holding the record that a third device put back. Those
 * shops upgrade and then sync, and what happens next is a data change nobody
 * chose. It deserves to be pinned down rather than discovered.
 *
 * Measured, both cases:
 *
 *   untouched record   removed, no report
 *   worked-on record   removed, reported as delete_over_edit
 *
 * The second reaches the user — settings.js reportSyncConflicts turns it into a
 * toast, traced end to end. The first does not, and that is the decision this
 * file exists to record.
 *
 * WHY THE FIRST IS DELIBERATELY NOT REPORTED
 *
 * The record was deleted by the shop on purpose. Its reappearance was the bug;
 * removing it restores what they asked for. Reporting it would mean flagging a
 * correction as a loss.
 *
 * And there is no honest way to detect it anyway. "A delete arriving for a record
 * this device holds" is also the shape of every ordinary delete made on another
 * machine, so any rule that catches the resurrection case catches routine deletes
 * too — noise on every sync for a shop that simply tidies up old orders. The only
 * discriminators available are heuristics on how OLD the tombstone is, which get
 * it wrong for the shop whose second machine was switched off for a month.
 *
 * The case where the shop has real skin in it — they went on working on the
 * record after it came back — is exactly the case rev can identify, and it is
 * already reported. That is the line, and it is drawn where the evidence is.
 *
 * If a future change makes the silent removal look like a bug worth "fixing",
 * read this first: preventing the removal would keep the two devices disagreeing
 * forever, which is the actual bug.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');
function device() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

const snap = (over = {}) => ({ printLog: [], tombstones: [], ...over });
const ids = (s) => s.printLog.map((r) => r.id).sort();

/** The device that pressed delete: tombstone held, record gone. */
const deleter = () => snap({
  printLog: [{ id: 'o1', project: 'bracket', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' }],
  tombstones: [{ id: 'o2', collection: 'printLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z' }],
});

/** The device the record came back on, in the state the old bug left it: no tombstone. */
const resurrected = (o2) => snap({
  printLog: [{ id: 'o1', project: 'bracket', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' }, o2],
});

function syncFromDeleter(target) {
  const A = device();
  const a = deleter();
  A.setScope('shop');
  A.seedIndex(a);
  const B = device();
  B.setScope('shop');
  B.seedIndex(target);
  return B.applyDeltas(target, A.extractDeltas(a, { rev: 0, ts: '' }), { appendOnly: [] });
}

test('an untouched resurrected record converges away, quietly and correctly', () => {
  const b = resurrected({ id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' });
  assert.deepEqual(ids(b), ['o1', 'o2'], 'the store starts in the diverged state');

  const r = syncFromDeleter(b);

  assert.deepEqual(ids(b), ['o1'], 'the two devices agree again');
  assert.equal(r.removed, 1);
  assert.equal(r.conflicts.length, 0,
    'not reported, on purpose — see the header: this restores what the shop asked for');
  assert.equal(b.tombstones.length, 1, 'and the delete is now remembered here too');
});

test('a resurrected record the shop went on working on IS reported', () => {
  // rev moved past the rev the delete saw, which is the one signal that says the
  // shop did something with this record after it came back.
  const b = resurrected({ id: 'o2', project: 'vase — three weeks of edits', rev: 6, updatedAt: '2026-07-20T00:00:00.000Z' });

  const r = syncFromDeleter(b);

  assert.deepEqual(ids(b), ['o1'], 'the delete still wins — convergence is not negotiable');
  assert.equal(r.conflicts.length, 1);
  assert.equal(r.conflicts[0].kind, 'delete_over_edit');
  assert.equal(r.conflicts[0].id, 'o2');
  assert.equal(r.conflicts[0].localRev, 6, 'the work that was discarded is named');
  assert.equal(r.conflicts[0].tombRev, 1);
  assert.equal(r.conflicts[0].discarded.project, 'vase — three weeks of edits');
});

test('the report the user sees names the record, not an id', () => {
  // The conflict is only worth producing if it survives the summariser that turns
  // it into a toast. Guards the whole path, not just the shape applyDeltas returns.
  const S = device();
  const b = resurrected({ id: 'o2', project: 'vase — three weeks of edits', rev: 6, updatedAt: '2026-07-20T00:00:00.000Z' });
  const r = syncFromDeleter(b);

  const { count, firstName } = S.summarizeDiscardedEdits(r.conflicts);
  assert.equal(count, 1);
  assert.equal(firstName, 'vase — three weeks of edits');

  // And an untouched removal produces nothing to say.
  const b2 = resurrected({ id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' });
  assert.equal(S.summarizeDiscardedEdits(syncFromDeleter(b2).conflicts).count, 0);
});

test('after converging, the shop cannot diverge the same way again', () => {
  // The point of the whole exercise: the upgraded device now holds the tombstone,
  // so a third device still carrying the record can no longer put it back.
  const b = resurrected({ id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' });
  syncFromDeleter(b);

  const C = device();
  const c = resurrected({ id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' });
  C.setScope('shop');
  C.seedIndex(c);

  const B = device();
  B.setScope('shop');
  B.seedIndex(b);
  B.applyDeltas(b, C.extractDeltas(c, { rev: 0, ts: '' }), { appendOnly: [] });

  assert.deepEqual(ids(b), ['o1'], 'the straggler did not resurrect it');
});

test('findResurrected still sees the state on a store that has not synced yet', () => {
  // A device that resurrected a record holds no tombstone, so it is invisible to
  // the detector — which is why the fix, not the detector, is what closes this.
  // The device that DELETED it is the one the detector was built for, and it must
  // keep working: that report is all a shop has before its next sync.
  const D = device();
  const stuck = snap({
    printLog: [{ id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' }],
    tombstones: [{ id: 'o2', collection: 'printLog', rev: 1, deletedAt: '2026-07-02T00:00:00.000Z' }],
  });
  const found = D.findResurrected(stuck);
  assert.equal(found.length, 1);
  assert.equal(found[0].id, 'o2');
  assert.equal(D.summarizeResurrected(found).count, 1);

  // And the no-tombstone device genuinely cannot be seen — stated, not assumed,
  // so the limit is on the record rather than in someone's head.
  const invisible = resurrected({ id: 'o2', project: 'vase', rev: 1, updatedAt: '2026-07-01T00:00:00.000Z' });
  assert.equal(D.findResurrected(invisible).length, 0);
});
