/**
 * The change-index's current scope — which shop `stampChanges` and `seedIndex`
 * mean when a caller names none.
 *
 * test/phase3-delta-roundtrip.test.js proved the per-shop index is needed and
 * that an explicit scope works. This file is about the plumbing: three call
 * sites in the app pass no scope at all, and the failure mode when they disagree
 * is silent and expensive.
 *
 * The hazard, stated once: an empty index makes `stampChanges` treat every
 * record as new, so it bumps every rev. That device then wins every conflict on
 * the next merge and discards whatever another device legitimately changed. It
 * looks like a working sync. Every test below is ultimately about not doing that.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');

/** A fresh engine with its own module-level index, the way a separate machine has one. */
function loadEngine() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

const snap = (over = {}) => ({ printLog: [], clients: [], inventory: [], tombstones: [], ...over });
const store = () => snap({
  printLog: [{ id: 'o1', project: 'bracket', price: 100 }, { id: 'o2', project: 'vase', price: 60 }],
  clients: [{ id: 'c1', name: 'سارة' }],
});

/** The revs of every record, so "did anything get re-stamped?" is one comparison. */
const revs = (s) => Object.fromEntries(
  Object.entries(s).filter(([, v]) => Array.isArray(v))
    .flatMap(([k, arr]) => arr.map((r) => [`${k}:${r.id}`, r.rev])),
);

test('with no shop id, everything behaves exactly as it did before scopes', () => {
  const S = loadEngine();
  assert.equal(S.getScope(), S.DEFAULT_SCOPE);
  const s = store();
  S.seedIndex(s);
  const before = revs(s);
  S.stampChanges(s);
  assert.deepEqual(revs(s), before, 'a seeded index stamps nothing on an unchanged store');
});

test('naming the scope before seeding puts the fingerprints under that shop', () => {
  const S = loadEngine();
  S.setScope('shop-riyadh');
  assert.equal(S.getScope(), 'shop-riyadh');
  S.seedIndex(store());
  assert.deepEqual(S._scopes(), ['shop-riyadh']);
  assert.equal(S._indexSize('shop-riyadh'), 3);
});

test('connecting to the cloud is a rename, not a switch: no record is re-stamped', () => {
  // The real sequence when a standalone shop signs up: it has been running
  // unnamed all along, then learns its id. The records on disk did not change,
  // so a save right afterwards must not bump a single rev — if it did, this
  // device would out-rev every other device in the shop on its first sync.
  const S = loadEngine();
  const s = store();
  S.seedIndex(s);                       // unnamed, as at launch
  const before = revs(s);

  const r = S.setScope('shop-new');
  assert.equal(r.seeded, true, 'the fingerprints came with it');
  assert.deepEqual(S._scopes(), ['shop-new'], 'and the unnamed scope is gone, not duplicated');

  S.stampChanges(s);
  assert.deepEqual(revs(s), before, 'nothing was re-stamped by learning a name');
});

test('disconnecting is a rename too', () => {
  const S = loadEngine();
  const s = store();
  S.setScope('shop-a');
  S.seedIndex(s);
  const before = revs(s);

  const r = S.setScope(null);
  assert.equal(S.getScope(), S.DEFAULT_SCOPE);
  assert.equal(r.seeded, true);
  S.stampChanges(s);
  assert.deepEqual(revs(s), before, 'signing out does not re-stamp the store either');
});

test('moving between two real shops is a switch: nothing is carried, and it says so', () => {
  // This is the case the scoping exists for. Shop A's fingerprints must NOT
  // follow, because stampChanges reads "in the index but not in the snapshot" as
  // a delete and would write tombstones for A's records into B's store.
  const S = loadEngine();
  S.setScope('shop-a');
  S.seedIndex(store());

  const r = S.setScope('shop-b');
  assert.equal(r.seeded, false, 'reported unseeded so the caller knows to seed');
  assert.equal(S._indexSize('shop-b'), 0);
  assert.equal(S._indexSize('shop-a'), 3, 'shop A keeps its own memory');
});

test('an unseeded scope re-stamps the whole store — which is why seeded is reported', () => {
  // The consequence, made concrete rather than asserted in the abstract. This is
  // what happens if a caller ignores `seeded:false`.
  const S = loadEngine();
  const s = store();
  S.setScope('shop-a');
  S.seedIndex(s);
  const before = revs(s);

  S.setScope('shop-b');                 // deliberately not seeded
  S.stampChanges(s);
  const after = revs(s);
  assert.notDeepEqual(after, before);
  for (const k of Object.keys(before)) {
    assert.equal(after[k], (before[k] || 0) + 1, `${k} was re-stamped`);
  }

  // And the fix the app actually applies (seed after an unseeded switch) holds it.
  const S2 = loadEngine();
  const s2 = store();
  S2.setScope('shop-a');
  S2.seedIndex(s2);
  const before2 = revs(s2);
  const { seeded } = S2.setScope('shop-b');
  if (!seeded) S2.seedIndex(s2);
  S2.stampChanges(s2);
  assert.deepEqual(revs(s2), before2, 'seeding on the reported miss stamps nothing');
});

test('switching shops writes no tombstones into the other shop', () => {
  // The original Phase 3 bug, re-checked through the no-argument path that the
  // app actually uses rather than through explicit scopes.
  const S = loadEngine();
  const a = store();
  S.setScope('shop-a');
  S.seedIndex(a);
  S.stampChanges(a);

  const b = snap({ printLog: [{ id: 'b1', project: 'jig' }] });
  S.setScope('shop-b');
  S.seedIndex(b);
  S.stampChanges(b);

  assert.deepEqual(b.tombstones, [], 'shop A’s records did not arrive as deletions in B');
  assert.equal(b.printLog.length, 1);
});

test('a genuine edit is still detected after a rename', () => {
  // Carrying fingerprints across a rename must not carry a stale memory that
  // hides real changes — the mirror image of the churn test above.
  const S = loadEngine();
  const s = store();
  S.seedIndex(s);
  S.setScope('shop-new');

  s.printLog[0].price = 175;
  S.stampChanges(s);
  assert.equal(s.printLog[0].rev, 1, 'the edited record was stamped');
  assert.equal(s.printLog[1].rev, undefined, 'the untouched one was not');
});

test('a delete is still tombstoned after a rename', () => {
  const S = loadEngine();
  const s = store();
  S.seedIndex(s);
  S.setScope('shop-new');

  s.printLog = s.printLog.filter((r) => r.id !== 'o2');
  S.stampChanges(s);
  assert.equal(s.tombstones.length, 1);
  assert.equal(s.tombstones[0].id, 'o2');
});

test('setScope is idempotent and reports the resolved scope', () => {
  const S = loadEngine();
  S.seedIndex(store());
  const a = S.setScope('shop-a');
  const b = S.setScope('shop-a');
  assert.deepEqual(a, b);
  assert.equal(b.scope, 'shop-a');
  assert.equal(S._indexSize('shop-a'), 3, 'setting the same scope twice did not clear it');

  for (const falsy of [null, undefined, '', 0, false]) {
    assert.equal(S.setScope(falsy).scope, S.DEFAULT_SCOPE, `${String(falsy)} means "no shop"`);
    S.setScope('shop-a');
  }
});

test('an explicit scope argument still overrides the current one', () => {
  // The explicit-scope API that phase3-delta-roundtrip uses must keep working;
  // the current scope is a default, not a replacement.
  const S = loadEngine();
  S.setScope('shop-a');
  S.seedIndex(store(), 'shop-b');
  assert.equal(S._indexSize('shop-b'), 3);
  assert.equal(S._indexSize('shop-a'), 0);
  assert.equal(S.getScope(), 'shop-a', 'passing a scope does not move the current one');
});

test('_resetIndex() with no argument returns the scope to the default', () => {
  // Otherwise one test's shop leaks into the next test's "clean slate".
  const S = loadEngine();
  S.setScope('shop-a');
  S.seedIndex(store());
  S._resetIndex();
  assert.equal(S.getScope(), S.DEFAULT_SCOPE);
  assert.deepEqual(S._scopes(), []);
});
