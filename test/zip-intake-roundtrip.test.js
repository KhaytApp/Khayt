/**
 * Zip import, against real archives on a real disk.
 *
 * test/zip-intake.test.js tests the PLAN. This tests that the plan survives
 * contact with lib/zip-read.js and the filesystem — because the interesting
 * failure is not "does plan() return a basename", it is "does a member called
 * ../../../evil.stl end up outside the destination".
 *
 * The archives are built with lib/zip-write.js, so these are genuine zips read
 * by the genuine reader, not fixtures shaped to agree with the code.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { writeZip } = require('../lib/zip-write.js');
const { listEntries, readEntry } = require('../lib/zip-read.js');
const { plan, summarize } = require('../lib/zip-intake.js');

const buf = (s) => Buffer.from(s, 'utf8');

/** Extract exactly the way main.js's handler does: plan first, plan's name only. */
function extractLikeHandler(zipBuf, destDir, opts) {
  const p = plan(listEntries(zipBuf), opts);
  const written = [];
  for (const t of p.take) {
    const bytes = readEntry(zipBuf, t.entry);
    if (!bytes) continue;
    const dest = path.join(destDir, t.name);     // t.name, never t.from
    fs.writeFileSync(dest, bytes);
    written.push(dest);
  }
  return { plan: p, written };
}

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-ziptest-'));

test('a zip-slip member lands inside the destination, not outside it', () => {
  // The one that matters. A real archive, a real reader, a real write.
  const root = tmp();
  const dest = path.join(root, 'dest');
  const sentinel = path.join(root, 'OUTSIDE.stl');
  fs.mkdirSync(dest);

  const z = writeZip([
    { name: '../OUTSIDE.stl', data: buf('escaped') },
    { name: '../../../../../../tmp/khayt-escape.stl', data: buf('escaped') },
    { name: '..\\..\\windows.stl', data: buf('escaped') },
    { name: 'parts/good.stl', data: buf('solid good') },
  ]);
  assert.ok(z, 'the test archive did not build');

  const { written } = extractLikeHandler(z, dest);

  assert.equal(fs.existsSync(sentinel), false, 'a member escaped one level up');
  assert.equal(fs.existsSync('/tmp/khayt-escape.stl'), false, 'a member escaped to /tmp');
  for (const w of written) {
    assert.equal(path.dirname(path.resolve(w)), path.resolve(dest),
      `${w} was written outside the destination`);
  }
  // And the legitimate file still arrived.
  assert.equal(fs.readFileSync(path.join(dest, 'good.stl'), 'utf8'), 'solid good');
  fs.rmSync(root, { recursive: true, force: true });
});

test('the bytes that come out are the bytes that went in', () => {
  const root = tmp();
  const body = Buffer.from(Array.from({ length: 4096 }, (_, i) => i % 256));
  const z = writeZip([{ name: 'a/model.stl', data: body }]);
  const { written } = extractLikeHandler(z, root);
  assert.equal(written.length, 1);
  assert.ok(fs.readFileSync(written[0]).equals(body), 'the extracted file does not match the original');
  fs.rmSync(root, { recursive: true, force: true });
});

test('two members with the same basename both land, neither overwritten', () => {
  const root = tmp();
  const z = writeZip([
    { name: 'parts/a.stl', data: buf('first') },
    { name: 'spares/a.stl', data: buf('second') },
  ]);
  const { written } = extractLikeHandler(z, root);
  assert.equal(written.length, 2, 'one file overwrote the other');
  const bodies = written.map((w) => fs.readFileSync(w, 'utf8')).sort();
  assert.deepEqual(bodies, ['first', 'second']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('non-print members are left in the archive, and reported', () => {
  const root = tmp();
  const z = writeZip([
    { name: 'README.txt', data: buf('hi') },
    { name: 'cover.png', data: buf('png') },
    { name: 'model.3mf', data: buf('3mf') },
  ]);
  const { plan: p, written } = extractLikeHandler(z, root);
  assert.deepEqual(written.map((w) => path.basename(w)), ['model.3mf']);
  assert.deepEqual(p.skipped.map((s) => s.name).sort(), ['README.txt', 'cover.png']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('an archive of nothing printable is empty rather than a silent success', () => {
  const root = tmp();
  const z = writeZip([{ name: 'notes.txt', data: buf('x') }]);
  const { plan: p, written } = extractLikeHandler(z, root);
  assert.equal(written.length, 0);
  assert.equal(summarize(p).empty, true);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a budget stops the extraction and says which files it cost', () => {
  const root = tmp();
  const z = writeZip([
    { name: 'a.stl', data: buf('x'.repeat(500)) },
    { name: 'b.stl', data: buf('x'.repeat(500)) },
    { name: 'c.stl', data: buf('x'.repeat(500)) },
  ]);
  const { plan: p, written } = extractLikeHandler(z, root, { maxBytes: 900 });
  assert.equal(written.length, 1);
  assert.equal(p.truncated, true, 'files were dropped and nothing said so');
  assert.deepEqual(p.skipped.filter((s) => s.reason === 'over-budget').map((s) => s.name), ['b.stl', 'c.stl']);
  fs.rmSync(root, { recursive: true, force: true });
});

test('a truncated / corrupt archive yields nothing and does not throw', () => {
  const root = tmp();
  const good = writeZip([{ name: 'a.stl', data: buf('solid') }]);
  for (const bad of [good.subarray(0, Math.floor(good.length / 2)), Buffer.alloc(0), buf('not a zip at all')]) {
    const { written } = extractLikeHandler(bad, root);
    assert.equal(written.length, 0);
  }
  fs.rmSync(root, { recursive: true, force: true });
});
