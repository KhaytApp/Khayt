'use strict';
/**
 * Two ways a restore or an import destroyed everything, quietly.
 *
 * Both live in `replaceStoreFromSnapshot`, which is reached from Settings →
 * Import, from Restore backup, and from a restore point.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

function loadValidator() {
  const ctx = vm.createContext({ globalThis: {}, console });
  ctx.globalThis = ctx;
  vm.runInContext(read('lib/store-validate.js'), ctx);
  return ctx.globalThis.KhaytStoreValidate;
}

test('a file that is not a Khayt export is refused, not salvaged into nothing', () => {
  /* `normalizeStoreSnapshot` SALVAGES: it keeps what it recognises and skips the
   * rest, which is right for a slightly damaged store on load. Handed a file
   * that is not ours it recognises NOTHING and returns a TRUTHY EMPTY OBJECT —
   * and the only refusal was `if (!normalized)`.
   *
   * So picking the wrong .json in Settings → Import zeroed all 31 collections,
   * applied nothing, and toasted "Imported successfully". Every order, client,
   * invoice, spool and print file, gone, under a green tick. */
  const V = loadValidator();
  assert.equal(typeof V.looksLikeStore, 'function', 'the "is this even ours" check is gone');

  for (const notOurs of [{}, { name: 'foo' }, { dependencies: { x: '1' } }, { profiles: [1, 2] },
    null, undefined, [1, 2], 'a string', 42]) {
    assert.equal(V.looksLikeStore(notOurs), false,
      `${JSON.stringify(notOurs)} would have wiped the database`);
    // …and the salvaging normaliser still says "fine" to the object cases,
    // which is exactly why the extra check has to exist.
    if (notOurs && typeof notOurs === 'object' && !Array.isArray(notOurs)) {
      assert.ok(V.normalizeStoreSnapshot(notOurs).normalized,
        'normalizeStoreSnapshot stopped salvaging — re-check what refuses an import now');
    }
  }
});

test('a genuine export is still accepted, including a brand-new shop', () => {
  // buildExportPayload writes every collection (empty arrays), settings, version
  // and exportedAt — so "recognises at least one" cannot refuse a real file.
  const V = loadValidator();
  assert.equal(V.looksLikeStore({ settings: {} }), true, 'a new shop with no records was refused');
  assert.equal(V.looksLikeStore({ printLog: [] }), true, 'an empty collection was not recognised');
  assert.equal(V.looksLikeStore({ clients: [{ id: 'c1' }] }), true);
});

test('replaceStoreFromSnapshot checks it BEFORE it zeroes anything', () => {
  const src = read('renderer/app-state.js');
  const at = src.indexOf('function replaceStoreFromSnapshot(store)');
  assert.ok(at > -1, 'replaceStoreFromSnapshot is gone');
  const body = src.slice(at, src.indexOf('\nfunction ', at + 10));
  const guard = body.indexOf('looksLikeStore(store)');
  const firstWipe = body.indexOf('printLog = [];');
  assert.ok(guard > -1, 'the import path no longer checks that the file is ours');
  assert.ok(firstWipe > -1, 'the wipe moved — re-check the ordering below');
  assert.ok(guard < firstWipe,
    'the check runs AFTER the collections are zeroed, which is the same as not running');
});

test('a restore reseeds the change index, or it deletes the difference everywhere', () => {
  /* `_doSave` runs stampChanges on every save, and that treats "in the index,
   * absent from the snapshot" as a DELETE — it writes a tombstone. The index is
   * seeded at load, on a shop switch and after a cloud merge. A restore reseeded
   * nothing.
   *
   * So restoring a three-week-old backup wrote a tombstone for every record
   * created since, those synced out, applyDeltas deleted them unconditionally,
   * and the tombstone carried the very rev the peer held — so not even the
   * delete-over-edit conflict fired. Three weeks gone from the other machine,
   * silently, on both sides. */
  const src = read('renderer/app-state.js');
  const at = src.indexOf('function replaceStoreFromSnapshot(store)');
  const body = src.slice(at, src.indexOf('\nfunction ', at + 10));
  assert.match(body, /KhaytSync\.seedIndex\(/,
    'a restore does not reseed the change index — the next save tombstones everything newer');
  assert.ok(body.indexOf('applyStoreFromSnapshot(store)') < body.indexOf('KhaytSync.seedIndex('),
    'the index is reseeded before the snapshot is applied, so it seeds the OLD state');
});

test('stampChanges really does tombstone what a stale index cannot see', () => {
  // The mechanism behind the test above, exercised rather than asserted about —
  // if this ever stops being true, the reseed is no longer load-bearing and the
  // guard above is measuring nothing.
  const ctx = vm.createContext({ globalThis: {}, console, Date });
  ctx.globalThis = ctx;
  vm.runInContext(read('lib/sync.js'), ctx);
  const S = ctx.globalThis.KhaytSync;
  const before = { clients: [{ id: 'c1' }, { id: 'c2' }], tombstones: [] };
  S.seedIndex(before);
  const restored = { clients: [{ id: 'c1' }], tombstones: [] };
  S.stampChanges(restored);
  assert.equal(restored.tombstones.length, 1,
    'stampChanges no longer tombstones a record missing from the snapshot');
  assert.equal(restored.tombstones[0].id, 'c2');
});
