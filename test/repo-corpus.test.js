const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { ROOT, trackedFiles, trackedPaths } = require('./helpers/repo-files.js');

/**
 * Tests that search "the whole repo" have to agree with CI about what the repo
 * is. On this machine the checkout also holds `.claude/worktrees/` (2,151 files
 * at the time of writing), an untracked `Khayt/` (1,907) and `khayt-cloud/` —
 * every one of them an older copy of this same source. A directory walk searched
 * 4,886 files of which 774 were actually in the repository.
 *
 * For a reachability test that is not extra coverage, it is the OPPOSITE of
 * coverage: the deleted call site still exists in the stale copy, so nothing can
 * ever be found unreachable. Green locally, red in CI, which is the version of
 * this that costs a whole session.
 */

test('the corpus is exactly what git tracks', () => {
  const direct = execFileSync('git', ['ls-files', '-z'], { cwd: ROOT, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 })
    .split('\0').filter(Boolean);
  assert.deepEqual(trackedFiles(), direct);
});

test('nothing outside the repository can get into the corpus', () => {
  // The property that matters, stated so it holds on a clean CI checkout too:
  // every path is repo-relative, none escapes upward, and none is in a place
  // git could not have listed.
  for (const rel of trackedFiles()) {
    assert.ok(!path.isAbsolute(rel), `${rel} should be repo-relative`);
    assert.ok(!rel.startsWith('..'), `${rel} escapes the repository`);
    assert.ok(!rel.split('/').includes('node_modules'), `${rel} is a dependency`);
  }
});

test('the stray checkouts on this machine are excluded — when there are any', (t) => {
  // Vacuous on a clean checkout, which is exactly why it is written to skip
  // rather than to pass: a green assertion that tested nothing would be the
  // same false comfort as the walk it replaces.
  const strays = ['.claude', 'Khayt', 'khayt-cloud', 'khayt-website']
    .filter((d) => fs.existsSync(path.join(ROOT, d)));
  if (!strays.length) {
    t.skip('no nested checkouts present — nothing for this to exclude');
    return;
  }
  const tops = new Set(trackedFiles().map((r) => r.split('/')[0]));
  for (const d of strays) {
    assert.ok(!tops.has(d), `${d}/ is not part of this repository and must not be searched`);
  }
});

test('trackedPaths filters and returns absolute paths that exist', () => {
  const js = trackedPaths((rel) => rel.startsWith('lib/') && rel.endsWith('.js'));
  assert.ok(js.length > 50, `expected lib/ to hold many modules, saw ${js.length}`);
  for (const p of js.slice(0, 20)) {
    assert.ok(path.isAbsolute(p));
    assert.ok(fs.existsSync(p), `${p} listed but missing`);
  }
});

test('git is required, not merely preferred', () => {
  // A quiet fallback to a directory walk would restore the exact bug this
  // helper removes, on the one machine where nobody would think to look.
  const src = fs.readFileSync(path.join(ROOT, 'test/helpers/repo-files.js'), 'utf8');
  assert.match(src, /throw new Error\(/);
  assert.doesNotMatch(src, /catch[\s\S]{0,200}readdirSync/);
});
