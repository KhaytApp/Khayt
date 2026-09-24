/**
 * Bringing the library's existing files to wherever the library now lives.
 *
 * Changing the location only ever changed where the NEXT file went, and
 * hub:printlib-list reads the primary root and nothing else — so the moment the
 * setting changed, every record went from "has three files" to "empty". Nothing
 * was deleted, but from the shop's side of the screen that is indistinguishable.
 *
 * The half of this worth testing hardest is not the planning. It is the seven
 * lines that delete something. A duplicate is recoverable; a deletion is not, and
 * the file being deleted is a customer's model. So moveOne() takes its
 * filesystem as an argument, and the tests below hand it broken ones: a copy
 * that truncates, a copy that lies, a destination that refuses writes. Each asks
 * the same question — is the original still there?
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const {
  sources, decide, collisionName, summarize, enoughSpace, rememberRoot, moveOne,
  MOVE, SAME, COLLISION,
} = require('../lib/print-library-migrate.js');
const { resolveRoots, insideLibrary } = require('../lib/print-library-location.js');

const DEFAULT = path.resolve('/Users/maker/Library/Application Support/khayt/print-files-vault');
const NAS = path.resolve('/Volumes/shop-nas/khayt-library');
const NAS2 = path.resolve('/Volumes/other-nas/library');
const CLOUD = path.resolve('/Users/maker/Dropbox/Khayt');

// ---------------------------------------------------------------- where from

test('the backup folder is never a source', () => {
  // Moving files OUT of a backup is the one operation guaranteed to leave the
  // shop worse off, and it would look exactly like a successful migration.
  const r = resolveRoots({ root: NAS, mirror: CLOUD }, DEFAULT);
  const from = sources(r.roots, r.primary, r.mirror);
  assert.ok(!from.includes(CLOUD), 'the migration would empty the backup');
  assert.deepEqual(from, [DEFAULT]);
});

test('the destination is never a source', () => {
  const r = resolveRoots({ root: NAS }, DEFAULT);
  assert.ok(!sources(r.roots, r.primary, r.mirror).includes(NAS),
    'planning a move onto itself ends in a file deleted after being copied over itself');
});

test('a root nested in the primary, or containing it, is left alone', () => {
  const inside = path.join(NAS, 'models');
  assert.deepEqual(sources([NAS, inside], NAS, null), [], 'a folder already inside the library was rescanned');
  assert.deepEqual(sources([NAS, path.dirname(NAS)], NAS, null), [],
    'the parent of the destination would be walked as if it were a source');
});

test('nothing to move when the library never left home', () => {
  const r = resolveRoots({}, DEFAULT);
  assert.deepEqual(sources(r.roots, r.primary, r.mirror), []);
});

// ------------------------------------------------------- roots are remembered

test('a second move does not orphan the first folder', () => {
  // Without history NAS drops out of the known roots on the second move,
  // insideLibrary() starts refusing paths inside it, and files that are merely
  // in the wrong place become unreadable.
  const after1 = rememberRoot({ root: DEFAULT }, NAS, DEFAULT);
  const after2 = rememberRoot({ ...after1, root: NAS }, NAS2, DEFAULT);
  assert.deepEqual(after2.history, [NAS]);

  const r = resolveRoots(after2, DEFAULT);
  assert.equal(r.primary, NAS2);
  assert.ok(insideLibrary(path.join(NAS, 'PF-a', 'x.stl'), r.roots),
    'a file at the first custom location is no longer recognised as ours');
  assert.deepEqual(sources(r.roots, r.primary, r.mirror).sort(), [DEFAULT, NAS].sort(),
    'the first custom folder would never be offered for the move');
});

test('the built-in folder is not worth recording, and neither is a repeat', () => {
  assert.deepEqual(rememberRoot({ root: '' }, NAS, DEFAULT).history, [], 'the default is always a root already');
  assert.deepEqual(rememberRoot({ root: DEFAULT }, NAS, DEFAULT).history, []);
  const once = rememberRoot({ root: NAS, history: [NAS2] }, NAS2, DEFAULT);
  assert.deepEqual(once.history, [NAS], 'the folder we moved BACK to is a current root, not a past one');
  assert.equal(once.root, NAS2);
});

test('going back to this Mac still remembers where the library was', () => {
  const back = rememberRoot({ root: NAS }, '', DEFAULT);
  assert.equal(back.root, '');
  assert.deepEqual(back.history, [NAS], 'clearing the setting stranded the files with no way back');
});

// ---------------------------------------------------------------- what to do

test('a file the destination does not have is simply moved', () => {
  assert.equal(decide({ destExists: false, srcHash: 'a' }), MOVE);
});

test('same name and same bytes is already migrated', () => {
  assert.equal(decide({ destExists: true, srcHash: 'a', destHash: 'a' }), SAME);
});

test('same name, different bytes, keeps both', () => {
  // Overwriting picks a winner on the shop's behalf and destroys the loser.
  assert.equal(decide({ destExists: true, srcHash: 'a', destHash: 'b' }), COLLISION);
});

test('an unreadable hash is never treated as a match', () => {
  // The dangerous default: if a null hash compared equal to a null hash, an
  // unreadable file would be classed as a duplicate and DELETED.
  assert.equal(decide({ destExists: true, srcHash: null, destHash: null }), COLLISION);
  assert.equal(decide({ destExists: true, srcHash: 'a', destHash: null }), COLLISION);
});

test('a renamed file still opens in a slicer', () => {
  // "model.stl (2)" is a name macOS associates with nothing.
  assert.equal(collisionName('model.stl', []), 'model.stl');
  assert.equal(collisionName('model.stl', ['model.stl']), 'model (moved).stl');
  assert.equal(collisionName('model.stl', ['model.stl', 'model (moved).stl']), 'model (moved 3).stl');
  assert.equal(collisionName('README', ['README']), 'README (moved)');
  assert.match(collisionName('a.stl', ['a.stl']), /\.stl$/);
});

// -------------------------------------------------------------- room to land

test('a move that will not fit is refused before the first copy', () => {
  // Discovered at file 400 of 500, this leaves half a library in two places.
  const tight = enoughSpace(1000, 1200);
  assert.equal(tight.ok, false, 'headroom is not being kept');
  assert.ok(tight.shortBy > 0);
  assert.equal(enoughSpace(1000, 1000 + 256 * 1024 * 1024).ok, true);
});

test('a free-space figure we could not read is not a refusal', () => {
  // statfs is not everywhere. Blocking on a number we could not read is worse
  // than letting individual copies fail and be reported.
  for (const v of [null, undefined, NaN]) {
    const r = enoughSpace(1000, v);
    assert.equal(r.ok, true, String(v));
    assert.equal(r.unknown, true);
  }
});

test('the summary names each folder separately', () => {
  const s = summarize([
    { root: NAS, size: 10 }, { root: NAS, size: 20 }, { root: DEFAULT, size: 5 },
  ]);
  assert.equal(s.files, 3);
  assert.equal(s.bytes, 35);
  assert.deepEqual(s.roots.find((r) => r.root === NAS), { root: NAS, files: 2, bytes: 30 });
  assert.deepEqual(summarize([]), { files: 0, bytes: 0, roots: [] });
});

// ------------------------------------------------- the part that deletes things

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');

function realIO(over = {}) {
  return {
    hash: async (p) => sha(await fs.promises.readFile(p)),
    exists: async (p) => fs.existsSync(p),
    readdir: async (d) => { try { return await fs.promises.readdir(d); } catch (_) { return []; } },
    mkdir: (d) => fs.promises.mkdir(d, { recursive: true }),
    copy: (a, b) => fs.promises.copyFile(a, b),
    unlink: (p) => fs.promises.unlink(p),
    ...over,
  };
}

function tmp() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-mig-'));
  const from = path.join(d, 'old');
  const to = path.join(d, 'new');
  fs.mkdirSync(from, { recursive: true });
  fs.mkdirSync(to, { recursive: true });
  return { d, from, to };
}

test('a good move leaves the bytes at the destination and nothing behind', async () => {
  const { from, to } = tmp();
  const body = crypto.randomBytes(4096);
  fs.writeFileSync(path.join(from, 'a.stl'), body);
  const r = await moveOne(realIO(), path.join(from, 'a.stl'), to, 'a.stl');
  assert.equal(r.action, MOVE);
  assert.ok(fs.readFileSync(path.join(to, 'a.stl')).equals(body));
  assert.equal(fs.existsSync(path.join(from, 'a.stl')), false, 'the original was left behind — the next run moves it again');
});

test('A COPY THAT TRUNCATES DOES NOT COST THE ORIGINAL', async () => {
  // What a share does when it drops mid-transfer, and it is indistinguishable
  // from success at the call site: copyFile returns, no error is thrown.
  const { from, to } = tmp();
  const body = crypto.randomBytes(8192);
  const src = path.join(from, 'model.stl');
  fs.writeFileSync(src, body);
  const io = realIO({
    copy: async (a, b) => { fs.writeFileSync(b, fs.readFileSync(a).subarray(0, 100)); },
  });
  await assert.rejects(() => moveOne(io, src, to, 'model.stl'), /did not match/);
  assert.ok(fs.readFileSync(src).equals(body), 'the customer’s model was deleted after a bad copy');
  assert.equal(fs.existsSync(path.join(to, 'model.stl')), false,
    'the truncated copy was left at the destination, where the next run reads it as a collision and keeps it forever');
});

test('a copy that throws does not cost the original either', async () => {
  const { from, to } = tmp();
  const src = path.join(from, 'model.stl');
  fs.writeFileSync(src, 'real bytes');
  const io = realIO({ copy: async () => { throw new Error('ENOSPC'); } });
  await assert.rejects(() => moveOne(io, src, to, 'model.stl'), /ENOSPC/);
  assert.equal(fs.readFileSync(src, 'utf8'), 'real bytes');
});

test('a file already at the destination is removed from the old place, not re-copied', async () => {
  const { from, to } = tmp();
  const body = crypto.randomBytes(512);
  fs.writeFileSync(path.join(from, 'a.stl'), body);
  fs.writeFileSync(path.join(to, 'a.stl'), body);
  let copied = false;
  const r = await moveOne(realIO({ copy: async () => { copied = true; } }), path.join(from, 'a.stl'), to, 'a.stl');
  assert.equal(r.action, SAME);
  assert.equal(copied, false, 'a file already proven present was copied over itself');
  assert.equal(fs.existsSync(path.join(from, 'a.stl')), false);
  assert.ok(fs.readFileSync(path.join(to, 'a.stl')).equals(body), 'the destination copy was disturbed');
});

test('a different file with the same name is never overwritten', async () => {
  const { from, to } = tmp();
  fs.writeFileSync(path.join(from, 'model.stl'), 'the one from the old folder');
  fs.writeFileSync(path.join(to, 'model.stl'), 'the one already here');
  const r = await moveOne(realIO(), path.join(from, 'model.stl'), to, 'model.stl');
  assert.equal(r.action, COLLISION);
  assert.equal(fs.readFileSync(path.join(to, 'model.stl'), 'utf8'), 'the one already here',
    'the file that was already there was destroyed');
  assert.equal(fs.readFileSync(path.join(to, r.name), 'utf8'), 'the one from the old folder');
  assert.equal(fs.existsSync(path.join(from, 'model.stl')), false);
});

test('running twice over the same folder is not destructive', async () => {
  // The realistic sequence: a move that half-failed, and the shop presses again.
  const { from, to } = tmp();
  const body = crypto.randomBytes(1024);
  fs.writeFileSync(path.join(from, 'a.stl'), body);
  await moveOne(realIO(), path.join(from, 'a.stl'), to, 'a.stl');
  fs.writeFileSync(path.join(from, 'a.stl'), body);          // as if it had been left behind
  const second = await moveOne(realIO(), path.join(from, 'a.stl'), to, 'a.stl');
  assert.equal(second.action, SAME, 'the second pass made a suffixed duplicate of a file it already had');
  assert.deepEqual(fs.readdirSync(to), ['a.stl']);
});

test('the destination folder is created, including for a nested path', async () => {
  const { from, to } = tmp();
  fs.mkdirSync(path.join(from, 'PF-abc'), { recursive: true });
  fs.writeFileSync(path.join(from, 'PF-abc', 'thumb.png'), 'png bytes');
  const dest = path.join(to, 'PF-abc');
  await moveOne(realIO(), path.join(from, 'PF-abc', 'thumb.png'), dest, 'thumb.png');
  assert.equal(fs.readFileSync(path.join(dest, 'thumb.png'), 'utf8'), 'png bytes');
});

test('a root that contains the library is never a source, even the root of a disk', () => {
  const path = require('path');
  const PLM = require('../lib/print-library-migrate');
  const root = path.parse(process.cwd()).root;
  const primary = path.join(root, 'Users', 'shop', 'Library');
  assert.deepEqual(PLM.sources([root, primary], primary, null), [],
    'the whole disk would be walked as a folder to move files out of');
});
