/**
 * The build guard has to survive a writer it does not control.
 *
 * scripts/build-bedready.mjs swaps package.json to Bed Ready's version for the duration of
 * a build and restores the exact bytes on the way out. electron-builder, meanwhile, runs
 * @electron/rebuild and an npm "collector" with `projectDir=./ appDir=./` — the same
 * directory — and spawnSync waits for its own child, not for that child's children. So a
 * straggler npm can still be writing package.json after the restore has verified its own
 * write and reported success.
 *
 * That happened: a pack left package.json carrying Bed Ready's version with the whole
 * `scripts` block gone, logged "source restored byte-identical (finally)", and exited 0.
 * The checkout stayed broken until the next `npm run` failed with "npm error npm run".
 *
 * This pins the settle-and-repair behaviour that makes such a write survivable, against a
 * temp directory rather than the real package.json.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { createSourceGuard } = require('../lib/source-guard.js');

/** The real guard, with the sleep replaced so the test runs instantly. */
function makeGuard(files) {
  const repairs = [];
  const g = createSourceGuard(files, { log: (m) => repairs.push(m), error: () => {}, sleep: () => {} });
  return { ...g, repairs };
}

function tmpPkg(contents) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-guard-'));
  const file = path.join(dir, 'package.json');
  fs.writeFileSync(file, contents);
  return file;
}

const ORIGINAL = JSON.stringify({ name: 'khayt', version: '3.6.0-beta.8', scripts: { lint: 'x', test: 'y' } }, null, 2) + '\n';
/** What the corrupted file actually looked like: version swapped, scripts gone. */
const CORRUPT = JSON.stringify({ name: 'khayt', version: '1.0.0-beta.1' }, null, 2) + '\n';

test('a single restore is not enough when something writes afterwards', () => {
  const file = tmpPkg(ORIGINAL);
  const g = makeGuard([file]);
  g.restore('finally');
  // The straggler lands AFTER the restore verified its own write.
  fs.writeFileSync(file, CORRUPT);
  assert.equal(g.drifted().length, 1, 'the file is now corrupt and a one-shot restore would never know');
});

test('settle-and-repair puts back a write that lands after the restore', () => {
  const file = tmpPkg(ORIGINAL);
  const g = makeGuard([file]);
  g.restore('finally');
  const stable = g.settleAndVerify({
    rounds: 4,
    onCheck: (i) => { if (i === 0) fs.writeFileSync(file, CORRUPT); },
  });
  assert.equal(stable, true, 'the guard must repair the straggler write');
  assert.equal(fs.readFileSync(file, 'utf8'), ORIGINAL, 'byte-identical to what the build started with');
  assert.ok(g.repairs.some((m) => /post-build drift/.test(m)), 'and it must say it had to repair');
});

test('a writer that will not stop is reported as a failure, not passed over', () => {
  const file = tmpPkg(ORIGINAL);
  const g = makeGuard([file]);
  g.restore('finally');
  // Rewrites on every single round — the guard can never win.
  const stable = g.settleAndVerify({ rounds: 3, onCheck: () => fs.writeFileSync(file, CORRUPT) });
  assert.equal(stable, false, 'an unwinnable race must fail the build rather than exit 0 quietly');
});

test('a clean build reports stable without touching anything twice', () => {
  const file = tmpPkg(ORIGINAL);
  const g = makeGuard([file]);
  g.restore('finally');
  const stable = g.settleAndVerify({ rounds: 3 });
  assert.equal(stable, true);
  assert.equal(g.repairs.filter((m) => /restored byte-identical/.test(m)).length, 1,
    'no repeat restores when nothing drifted');
});
