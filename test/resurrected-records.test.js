/**
 * Finding the records the old sync bug brought back.
 *
 * v3.3.0 and every 3.4 beta shipped a merge that re-added records the store had
 * already deleted (see test/cloud-sync.test.js). The fix stops new cases and can
 * do nothing about the ones already saved to disk, so the app has to be able to
 * say "these came back" rather than leaving a shop to notice on its own.
 *
 * The whole approach rests on one claim, so it is worth testing rather than
 * asserting: a store holding BOTH a tombstone for an id AND a live record with
 * that id cannot arise legitimately. Ids are never derived from external data
 * (`ensureId` and `uniqueLanId` are timestamp+random), there is no undo-delete,
 * and no restore path merges records back in. The tests below cover the normal
 * lifecycles that might plausibly produce a false positive.
 */
const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const sync = require('../lib/sync.js');

beforeEach(() => sync._resetIndex());

const snap = (over = {}) => ({ printLog: [], clients: [], inventory: [], tombstones: [], ...over });

test('a record present despite its own tombstone is reported', () => {
  const s = snap({
    clients: [{ id: 'c1', nameEn: 'Acme Co', rev: 4 }],
    tombstones: [{ id: 'c1', collection: 'clients', rev: 2, deletedAt: '2026-07-12T09:00:00.000Z' }],
  });

  const found = sync.findResurrected(s);
  assert.equal(found.length, 1);
  assert.equal(found[0].collection, 'clients');
  assert.equal(found[0].id, 'c1');
  assert.equal(found[0].deletedAt, '2026-07-12T09:00:00.000Z', 'the shop is told WHEN they deleted it');
  assert.equal(found[0].record.nameEn, 'Acme Co', 'and which record it is');
});

test('an ordinary delete — tombstone, no record — is not reported', () => {
  // The overwhelmingly common case. If this ever flags, every deleting user gets
  // a false alarm and the warning becomes noise.
  const s = snap({
    clients: [{ id: 'c2', nameEn: 'Still here' }],
    tombstones: [{ id: 'c1', collection: 'clients', rev: 2, deletedAt: '2026-07-12T09:00:00.000Z' }],
  });
  assert.deepEqual(sync.findResurrected(s), []);
});

test('a normal delete lifecycle through the real engine reports nothing', () => {
  // Not a hand-built fixture: create, save, delete, save — the actual path a
  // shop takes. It must come out clean.
  const s = snap({ clients: [{ id: 'c1', nameEn: 'Acme' }] });
  sync.stampChanges(s);
  s.clients = [];
  sync.stampChanges(s);

  assert.equal(s.tombstones.length, 1, 'the delete was recorded');
  assert.deepEqual(sync.findResurrected(s), [], 'and it is not mistaken for a resurrection');
});

test('a tombstone for one collection does not flag a same-id record in another', () => {
  // Ids are unique per store in practice, but the check keys on (collection, id)
  // and a collection-blind version would invent findings.
  const s = snap({
    clients: [{ id: 'x1', nameEn: 'A client' }],
    tombstones: [{ id: 'x1', collection: 'printLog', rev: 1, deletedAt: '2026-07-12T09:00:00.000Z' }],
  });
  assert.deepEqual(sync.findResurrected(s), []);
});

test('the real resurrection path produces exactly this signature', () => {
  // Rather than trusting the fixture, reproduce the bug's outcome: a store that
  // deleted c1, and a peer delta re-adding it. Pre-fix this is what landed on
  // disk, so it is what a real shop's store looks like today.
  const s = snap({
    clients: [],
    tombstones: [{ id: 'c1', collection: 'clients', rev: 2, deletedAt: '2026-07-12T09:00:00.000Z' }],
  });
  // Force the pre-fix behaviour by hand: the unseen-record branch pushing it back.
  s.clients.push({ id: 'c1', nameEn: 'Came back', rev: 2 });

  const found = sync.findResurrected(s);
  assert.equal(found.length, 1);
  assert.equal(found[0].record.nameEn, 'Came back');
});

test('detection is report-only — it never mutates the store', () => {
  // Re-deleting automatically would be a second silent data change on top of the
  // first, and the shop may have worked on the record since it returned.
  const s = snap({
    clients: [{ id: 'c1', nameEn: 'Acme', rev: 4 }],
    tombstones: [{ id: 'c1', collection: 'clients', rev: 2, deletedAt: '2026-07-12T09:00:00.000Z' }],
  });
  const before = JSON.stringify(s);
  sync.findResurrected(s);
  assert.equal(JSON.stringify(s), before, 'the store is untouched');
});

test('malformed stores do not throw — this runs at load, before validation', () => {
  assert.deepEqual(sync.findResurrected(null), []);
  assert.deepEqual(sync.findResurrected(undefined), []);
  assert.deepEqual(sync.findResurrected({}), []);
  assert.deepEqual(sync.findResurrected({ tombstones: 'nonsense' }), []);
  assert.deepEqual(sync.findResurrected({ tombstones: [null, {}, { id: 'a' }] }), []);
  assert.deepEqual(sync.findResurrected({ tombstones: [{ id: 'a', collection: 'nope' }] }), []);
});

test('the summary names the first record and counts the rest', () => {
  const found = sync.findResurrected(snap({
    clients: [{ id: 'c1', nameEn: 'Acme Co' }],
    printLog: [{ id: 'o1', project: 'Bracket v2' }],
    tombstones: [
      { id: 'c1', collection: 'clients', rev: 1, deletedAt: '2026-07-12T09:00:00.000Z' },
      { id: 'o1', collection: 'printLog', rev: 1, deletedAt: '2026-07-13T09:00:00.000Z' },
    ],
  }));
  const { count, firstName } = sync.summarizeResurrected(found);
  assert.equal(count, 2);
  assert.equal(firstName, 'Acme Co', 'clients use nameEn, which the generic name/title lookup would miss');
});

test('nothing found means nothing to announce', () => {
  assert.deepEqual(sync.summarizeResurrected([]), { count: 0, firstName: '' });
  assert.deepEqual(sync.summarizeResurrected(null), { count: 0, firstName: '' });
});
