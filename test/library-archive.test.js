'use strict';
// A model the Mac archived (archivedAt: by the shop, or because its vault
// file was trashed elsewhere — #2071) stays in the book but out of the
// library. The desktop showed it as a live model; these hold the Mac's rule.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const A = require('../lib/library-archive.js');

const recs = [
  { id: 'a', name: 'live' },
  { id: 'b', name: 'shop archived', archivedAt: '2026-10-26T08:00:00Z' },
  { id: 'c', name: 'vault trashed', archivedAt: '2026-10-26T09:00:00Z', vaultArchived: true, vaultTrashedAt: '2026-10-26T08:00:00Z' },
  { id: 'd', name: 'blank stamp', archivedAt: '  ' },
  { id: 'e', name: 'trash only, not archived', vaultTrashedAt: '2026-10-26T08:00:00Z' },
  null,
];

test('archived means a non-empty archivedAt, as on the Mac', () => {
  assert.deepEqual(recs.filter(Boolean).filter(A.isArchived).map((r) => r.id), ['b', 'c']);
  assert.equal(A.isArchived({ archivedAt: 1730000000 }), false, 'only a string counts, as Swift reads it');
  assert.equal(A.isArchived(null), false);
});

test('the library is the live models; Archived is only the archived ones', () => {
  assert.deepEqual(A.pool(recs, false).map((r) => r.id), ['a', 'd', 'e']);
  assert.deepEqual(A.pool(recs, true).map((r) => r.id), ['b', 'c']);
  assert.equal(A.archivedCount(recs), 2);
  assert.deepEqual(A.pool(undefined, false), []);
});

test('wired: the grid, its chips and the part picker read the rule; both pages load it', () => {
  const root = path.join(__dirname, '..');
  const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
  const pf = read('renderer/printfiles.js');
  for (const fn of ['filtered', 'rowsExcept', 'normalizeFilters']) {
    assert.match(pf, new RegExp(`function ${fn}\\([^)]*\\) \\{[\\s\\S]{0,260}const list = pool\\(\\);`), `${fn} reads pool()`);
  }
  assert.match(pf, /shared\.tagCounts\(pool\(\)\)/, 'tag chips count the live library');
  assert.match(pf, /\? pool\(\)\.filter\(\(r\) => r\.userPhoto\)/, 'the gallery too');
  assert.match(pf, /const total = pool\(\)\.length;/);
  assert.match(pf, /case 'pf-archived':/);
  assert.match(read('renderer/inventory.js'), /part\.printFileId === f\.id \|\| !\(typeof KhaytLibraryArchive !== 'undefined' && KhaytLibraryArchive\.isArchived\(f\)\)/);
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = read(page);
    const at = html.indexOf('<script src="../lib/library-archive.js"></script>');
    assert.ok(at > 0 && at < html.indexOf('<script src="printfiles.js"></script>'), `${page} loads the rule before the library`);
  }
});
