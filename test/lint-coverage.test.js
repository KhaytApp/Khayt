const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { discover, EXCLUDE_DIRS } = require('../scripts/lint-syntax.js');

const ROOT = path.join(__dirname, '..');

/**
 * The linter's own discovery walk decides what gets syntax-checked. These tests
 * exist because the thing it replaced — a hand-maintained list of 153 file paths
 * in package.json — had silently drifted: 68 real modules were never checked,
 * and the chain broke twice when files were added or removed.
 *
 * A glob fixes the drift, but introduces a new failure mode: an over-broad
 * EXCLUDE, a typo'd root, or a walk bug could shrink the net without anyone
 * noticing. So this re-derives the file list independently and asserts the
 * linter reaches everything.
 */

/** Independent walk — deliberately NOT sharing the linter's implementation. */
function walkSources(dir, acc = []) {
  for (const entry of fs.readdirSync(path.join(ROOT, dir))) {
    const rel = path.join(dir, entry);
    const st = fs.statSync(path.join(ROOT, rel));
    if (st.isDirectory()) {
      if (EXCLUDE_DIRS.has(entry)) continue;
      walkSources(rel, acc);
    } else if (/\.(js|mjs|cjs)$/.test(entry)) {
      acc.push(rel);
    }
  }
  return acc;
}

test('every source file under lib/, renderer/ and scripts/ is syntax-checked', () => {
  const covered = new Set(discover());
  for (const dir of ['lib', 'renderer', 'scripts']) {
    const missing = walkSources(dir).filter((f) => !covered.has(f));
    assert.deepEqual(missing, [], `${dir}: ${missing.length} file(s) escape the linter`);
  }
});

test('the entrypoints are syntax-checked', () => {
  const covered = new Set(discover());
  for (const f of ['main.js', 'preload.js', 'electron-builder.bedready.js']) {
    assert.ok(covered.has(f), `${f} must be linted — it is an app entrypoint`);
  }
});

test('discovery is a superset of the hand-maintained chain it replaced', () => {
  // A sample of what the old package.json chain named explicitly. If discovery
  // ever stops reaching these, the replacement regressed on its own promise.
  const covered = new Set(discover());
  const previouslyListed = [
    'main.js', 'preload.js', 'lib/gcode-parse.js', 'lib/store-io.js', 'lib/cloud-client.js',
    'lib/attention.js', 'lib/queue-groups.js', 'renderer/app-state.js', 'renderer/dashboard.js',
    'lib/sync.js', 'renderer/cloud-sync.js', 'renderer/queue-list.js', 'renderer/icons.js',
    'renderer/themes/registry-core.js', 'renderer/themes/workbench/screens.js',
    'scripts/e2e-smoke.mjs', 'scripts/e2e-theme-shells.mjs',
  ];
  for (const f of previouslyListed) {
    assert.ok(covered.has(f), `${f} was linted before and must still be`);
  }
});

test('the modules the old chain silently missed are now covered', () => {
  // These existed for releases without ever being syntax-checked.
  const covered = new Set(discover());
  for (const f of ['lib/bambu.js', 'lib/kpi.js', 'lib/forecast.js', 'lib/mdns.js', 'lib/reorder.js']) {
    assert.ok(covered.has(f), `${f} must now be linted`);
  }
});

test('exclusions stay minimal — every hole in the net is deliberate', () => {
  // Widening this set is how a glob quietly becomes as leaky as the old list.
  assert.deepEqual([...EXCLUDE_DIRS].sort(), ['.git', 'dist', 'node_modules', 'out', 'release']);
});

test('discovery finds no duplicates and every path resolves', () => {
  const files = discover();
  assert.equal(new Set(files).size, files.length, 'duplicate entries in discovery');
  for (const f of files) {
    assert.ok(fs.existsSync(path.join(ROOT, f)), `discovered path does not exist: ${f}`);
  }
});
