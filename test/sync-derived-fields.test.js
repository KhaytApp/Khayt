'use strict';
/**
 * lib/sync.js and the fields a READER derives from a library model's file
 * (beta.40 data review, Nov 17). The Mac's colour sweep writes them unstamped,
 * so at the same rev two devices could hold different colours, and the
 * equal-rev tie-break took either copy and logged a "replaced" loss: about
 * half of a re-read reverted on every cloud pull and was read again next
 * launch. Now they are not part of the fingerprint (a re-read is never
 * stamped, never a conflict) and at equal rev the higher reader's copy wins.
 * Vectors shared with the Mac: test/fixtures/sync-derived-vectors.json.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/sync.js');
const { cases } = require('./fixtures/sync-derived-vectors.json');

const rec = (fields) => Object.assign({ id: 'PF-1', rev: 4, updatedAt: '2026-11-17T09:00:00Z' }, fields);

test('equal rev: the vectors', () => {
  let n = 0;
  for (const c of cases) {
    S.setScope('derived-vec-' + (n++));
    const local = { printFiles: [rec(c.local)] };
    S.seedIndex(local);
    const r = S.applyDeltas(local, { deltas: [{ collection: 'printFiles', record: rec(c.incoming) }], tombstones: [] });
    const kept = local.printFiles[0];
    assert.deepEqual(kept, rec(c.keep === 'incoming' ? c.incoming : c.local), c.why);
    assert.equal(r.conflicts.length > 0, c.conflict, 'conflict: ' + c.why);
  }
});

test('a re-read alone is not stamped, and is not a local edit lost to a higher rev', () => {
  S.setScope('derived-stamp');
  const book = { printFiles: [rec({ name: 'B', coloursReader: 3, colors: [{ hex: '#111111' }] })] };
  S.seedIndex(book);
  Object.assign(book.printFiles[0], { coloursReader: 4, colors: [{ hex: '#222222' }], swapCount: 2, swapsKnown: false, coloursUnreadBudget: 1, coloursUnreadFile: '1:2' });
  const s = S.stampChanges(book);
  assert.deepEqual(s.changed, []);
  assert.equal(book.printFiles[0].rev, 4);
  // A real edit still stamps.
  book.printFiles[0].name = 'Renamed';
  assert.deepEqual(S.stampChanges(book).changed.map((c) => c.id), ['PF-1']);
});

test('other collections keep every field in the fingerprint', () => {
  assert.notEqual(S.fingerprint({ id: 'J', colors: [1] }, 'printLog'), S.fingerprint({ id: 'J', colors: [2] }, 'printLog'));
  assert.equal(S.fingerprint({ id: 'P', colors: [1] }, 'printFiles'), S.fingerprint({ id: 'P', colors: [2] }, 'printFiles'));
});
