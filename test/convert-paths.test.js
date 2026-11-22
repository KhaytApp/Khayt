/**
 * The converter's read gate and its write gate are not the same gate.
 *
 * They used to be. `hub:mf-convert` takes an `outPath` from the renderer and checked it
 * with the READ allow-list, which returns true for userData, Documents, Downloads,
 * Desktop and temp. So a renderer could name any path under any of those — any filename,
 * any extension — and have the main process write there with no save dialog shown,
 * including into userData next to the store the app reads at boot. Confirmed by driving
 * the IPC directly: 30 MB landed at a renderer-chosen `.txt` path inside userData.
 *
 * The same conflation ran the other way too. The STL and 3MF exporters put the path the
 * user had just typed into our own save dialog through that list, so saving a converted
 * model to an external drive, or to any folder outside those five, was refused with
 * "Output path is outside an allowed folder" — the user's own choice, denied.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { under, readAllowed, writeAllowed } = require('../lib/convert-paths');

const HOME = path.resolve('/home/maker');
const DOCS = path.join(HOME, 'Documents');
const USERDATA = path.join(HOME, '.config', 'Khayt');
const TEMP = path.resolve('/tmp');
const OUTDIR = path.join(HOME, 'converted');       // picked in the output-folder dialog
const APP_DIRS = [USERDATA, DOCS, TEMP];

test('under() matches a directory and its contents, and nothing that merely shares a prefix', () => {
  assert.equal(under(DOCS, DOCS), true);
  assert.equal(under(path.join(DOCS, 'a', 'b.3mf'), DOCS), true);
  // The bug a bare startsWith() gives you: /home/maker/Documents-old is not inside Documents.
  assert.equal(under(DOCS + '-old', DOCS), false);
  assert.equal(under(path.join(HOME, 'Desktop', 'x.3mf'), DOCS), false);
});

test('under() resolves traversal rather than trusting the string', () => {
  assert.equal(under(path.join(DOCS, '..', '..', 'etc', 'passwd'), DOCS), false);
  assert.equal(under(path.join(DOCS, 'sub', '..', 'kept.3mf'), DOCS), true);
});

test('reading stays broad — that is what makes the converter usable', () => {
  const ctx = { approvedSources: [path.join(HOME, 'dev', 'model.3mf')], approvedDirs: [OUTDIR], appDirs: APP_DIRS };
  assert.equal(readAllowed(path.join(DOCS, 'poster.3mf'), ctx), true);
  assert.equal(readAllowed(path.join(TEMP, 'scratch.3mf'), ctx), true);
  // A file the user picked through our own open dialog, wherever it lives.
  assert.equal(readAllowed(path.join(HOME, 'dev', 'model.3mf'), ctx), true);
  // ...but only that exact file, not its whole folder.
  assert.equal(readAllowed(path.join(HOME, 'dev', 'other.3mf'), ctx), false);
  assert.equal(readAllowed(path.join(HOME, '.ssh', 'id_rsa'), ctx), false);
});

test('writing does NOT inherit the read list — this is the hole that was open', () => {
  const ctx = { approvedDirs: [OUTDIR] };
  for (const p of [
    path.join(USERDATA, 'khayt-store.json'),   // the app's own store
    path.join(USERDATA, 'anything.txt'),
    path.join(DOCS, 'invoice.pdf'),
    path.join(TEMP, 'payload.sh'),
    path.join(HOME, 'Downloads', 'setup.exe'),
  ]) {
    assert.equal(writeAllowed(p, ctx), false, `${p} must not be writable without the user choosing it`);
  }
});

test('writing is allowed under a folder the user picked for output', () => {
  const ctx = { approvedDirs: [OUTDIR] };
  assert.equal(writeAllowed(path.join(OUTDIR, 'model-u1.3mf'), ctx), true);
  assert.equal(writeAllowed(path.join(OUTDIR, 'nested', 'model-u1.3mf'), ctx), true);
  // Escaping the approved folder by traversal is still escaping it.
  assert.equal(writeAllowed(path.join(OUTDIR, '..', '.bashrc'), ctx), false);
});

test('with no output folder approved, nothing is writable without asking', () => {
  assert.equal(writeAllowed(path.join(OUTDIR, 'model.3mf'), { approvedDirs: [] }), false);
  assert.equal(writeAllowed(path.join(DOCS, 'model.3mf'), {}), false);
});

test('empty and junk paths are refused by both gates', () => {
  const ctx = { approvedDirs: [OUTDIR], appDirs: APP_DIRS };
  for (const p of ['', null, undefined]) {
    assert.equal(readAllowed(p, ctx), false);
    assert.equal(writeAllowed(p, ctx), false);
  }
});

test('everything is under the root of a disk', () => {
  // `/` already ends in the separator, so `'/' + sep` was `//` and nothing was
  // under it — print-library-migrate's sources() then failed to see that a
  // root of `/` contains the library, and would walk the disk as a source.
  const { under } = require('../lib/convert-paths');
  const path = require('path');
  const root = path.parse(process.cwd()).root;          // `/` here, `C:\` on Windows
  assert.equal(under(path.join(root, 'lib'), root), true);
  assert.equal(under(root, root), true);
  // The separator rule that the fix must not loosen:
  assert.equal(under('/home/user-data', '/home/user'), false);
  assert.equal(under('/home/user/x', '/home/user/'), true, 'a trailing separator on dir is the same dir');
});
