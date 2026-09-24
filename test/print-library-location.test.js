/**
 * The library has to be allowed to live somewhere other than this laptop.
 *
 * Models are the expensive thing a shop owns, and they were pinned inside the
 * app's own support folder — unreachable from the second workstation, and in the
 * one place a backup regime never looks. On macOS a mounted share and a synced
 * folder (iCloud Drive, Dropbox, Google Drive, OneDrive) are both just paths, so
 * one setting covers "network drive" and "online provider" without the app
 * learning a protocol.
 *
 * The decisions worth pinning are the ones with a wrong answer that looks fine:
 * what counts as inside the library once it can move, and what happens when the
 * folder is not there.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const {
  resolveRoots, insideLibrary, verdict, explain, itemDirName,
} = require('../lib/print-library-location.js');

const DEFAULT = path.resolve('/Users/maker/Library/Application Support/khayt/print-files-vault');
const NAS = path.resolve('/Volumes/shop-nas/khayt-library');
const CLOUD = path.resolve('/Users/maker/Library/Mobile Documents/com~apple~CloudDocs/Khayt');

test('no setting means exactly what it did before', () => {
  const r = resolveRoots({}, DEFAULT);
  assert.equal(r.primary, DEFAULT);
  assert.equal(r.mirror, null);
  assert.equal(r.isCustom, false);
  assert.deepEqual(r.roots, [DEFAULT]);
});

test('a configured folder becomes the place files are written', () => {
  const r = resolveRoots({ root: NAS }, DEFAULT);
  assert.equal(r.primary, NAS);
  assert.equal(r.isCustom, true);
});

test('the built-in folder stays part of the library after a move', () => {
  // Records written before the move still point into it. Dropping it from the
  // known roots would make yesterday's files unreadable rather than relocated —
  // every handler confines paths to the library and would start refusing them.
  const r = resolveRoots({ root: NAS }, DEFAULT);
  assert.ok(r.roots.includes(DEFAULT), 'the old location stopped being part of the library');
  assert.ok(insideLibrary(path.join(DEFAULT, 'PF-abc', 'model-x.3mf'), r.roots),
    'a file from before the move is no longer recognised as ours');
  assert.ok(insideLibrary(path.join(NAS, 'PF-abc', 'model-x.3mf'), r.roots));
});

test('a mirror is a known root too, but never the primary', () => {
  const r = resolveRoots({ root: NAS, mirror: CLOUD }, DEFAULT);
  assert.equal(r.primary, NAS, 'writes must go to the primary, not the backup');
  assert.equal(r.mirror, CLOUD);
  assert.ok(insideLibrary(path.join(CLOUD, 'PF-abc', 'x.stl'), r.roots));
});

test('a mirror pointed at the primary is not a mirror', () => {
  // Copying a file onto itself is not a backup, and would double every write.
  const r = resolveRoots({ root: NAS, mirror: NAS }, DEFAULT);
  assert.equal(r.mirror, null);
});

test('blank and whitespace settings are not paths', () => {
  for (const s of [{}, { root: '' }, { root: '   ' }, { root: null }, null, undefined]) {
    assert.equal(resolveRoots(s, DEFAULT).primary, DEFAULT, JSON.stringify(s));
  }
});

test('nothing outside every root is inside the library', () => {
  const r = resolveRoots({ root: NAS }, DEFAULT);
  assert.equal(insideLibrary('/etc/passwd', r.roots), false);
  assert.equal(insideLibrary(path.join(path.dirname(NAS), 'khayt-library-old', 'x'), r.roots), false,
    'a sibling folder sharing a name prefix is not inside');
  assert.equal(insideLibrary('', r.roots), false);
  assert.equal(insideLibrary(path.join(NAS, 'a'), []), false, 'no roots means nothing is inside');
});

test('a missing folder is refused, and named', () => {
  // The whole point of failing closed: a shop told "unavailable" opens the app's
  // settings, a shop told which folder is missing opens the Finder — which is
  // where a share that did not mount actually lives.
  const v = verdict({ exists: false });
  assert.equal(v.ok, false);
  assert.equal(v.reason, 'missing');
  const msg = explain(v.reason, NAS);
  assert.ok(msg.includes(NAS), 'the message does not say which folder');
  assert.match(msg, /network drive|external disk/, 'it does not hint at why it might be gone');
});

test('a file where a folder should be, and a folder we cannot write to', () => {
  assert.deepEqual(verdict({ exists: true, isDirectory: false }), { ok: false, reason: 'not-a-directory' });
  assert.deepEqual(verdict({ exists: true, isDirectory: true, writable: false }), { ok: false, reason: 'not-writable' });
  assert.deepEqual(verdict({ exists: true, isDirectory: true, writable: true }), { ok: true, reason: 'ok' });
  assert.ok(explain('not-a-directory', NAS).includes(NAS));
  assert.ok(explain('not-writable', NAS).includes(NAS));
  assert.equal(explain('ok', NAS), '', 'a working folder has nothing to explain');
});

test('a record folder is named the same under every root', () => {
  // A mirror has to land beside the primary. If the two sanitised the id
  // differently the backup would be a folder nobody could find again.
  assert.equal(itemDirName('PF-abc123'), 'PF-abc123');
  assert.equal(itemDirName('PF/../../etc'), 'etc');
  assert.equal(itemDirName('a b*c'), 'a_b_c');
  assert.equal(itemDirName(''), 'unsorted');
  assert.equal(itemDirName(null), 'unsorted');
});

test('the root of a disk is never a library folder, however it arrives', () => {
  // Settings arrive in restored backups and over cloud sync. A library "at /"
  // makes insideLibrary() true for every file — which is what printlib-delete
  // confines itself with — and gives a migration the whole disk as its source.
  const path = require('path');
  const PLL = require('../lib/print-library-location');
  const root = path.parse(process.cwd()).root;
  const base = path.join(root, 'app', 'print-library');
  const r = PLL.resolveRoots({ root, mirror: root, history: [root, path.join(root, 'old')] }, base);
  assert.equal(r.primary, base, 'a drive-root primary falls back to the built-in folder');
  assert.equal(r.mirror, null);
  assert.equal(r.isCustom, false);
  assert.ok(!r.roots.includes(root), 'a drive root is in the known roots');
  assert.ok(r.roots.includes(path.join(root, 'old')), 'an ordinary past root is still kept');
  assert.equal(PLL.insideLibrary(path.join(root, 'etc', 'passwd'), r.roots), false,
    'a file outside every real root counts as inside the library');
});
