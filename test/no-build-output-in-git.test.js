'use strict';
/**
 * Build output must not be committed.
 *
 * PR #922 added 1,492 SwiftPM artifacts — 93 MB — to the repository, because
 * `.gitignore` said `build/` and SwiftPM writes `.build/`. The dot is the whole
 * bug: `build/` matches neither `.build/` nor `DerivedData/`, and `git add -A`
 * does not ask twice. Every clone carries that weight now.
 *
 * This is cheap to check and expensive to miss, so it is checked.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const tracked = () => execFileSync('git', ['ls-files'], { cwd: ROOT, encoding: 'utf8', maxBuffer: 64e6 })
  .split('\n').filter(Boolean);

test('no build output is tracked', () => {
  const junk = /(^|\/)(\.build|DerivedData|node_modules|dist|out)\//;
  const found = tracked().filter((f) => junk.test(f));
  assert.deepEqual(found.slice(0, 10), [],
    `${found.length} build artifact(s) are tracked. Add the directory to .gitignore `
    + 'and `git rm -r --cached` it — do not commit generated files.');
});

test('.gitignore covers the dotted variants', () => {
  const ig = require('fs').readFileSync(path.join(ROOT, '.gitignore'), 'utf8')
    .split('\n').map((l) => l.trim());
  for (const rule of ['.build/', 'DerivedData/']) {
    assert.ok(ig.includes(rule),
      `.gitignore is missing "${rule}". "build/" does not match ".build/" — that is how #922 happened.`);
  }
});

test('nothing tracked is larger than a source file has any business being', () => {
  // A binary sneaking in one file at a time is the same failure, slower.
  const out = execFileSync('git', ['ls-files', '-s'], { cwd: ROOT, encoding: 'utf8', maxBuffer: 64e6 });
  const shas = out.split('\n').filter(Boolean).map((l) => l.split(/\s+/)[1]);
  const sizes = execFileSync('git', ['cat-file', '--batch-check=%(objectsize) %(rest)'],
    { cwd: ROOT, input: shas.join('\n'), encoding: 'utf8', maxBuffer: 64e6 });
  const big = sizes.split('\n').filter(Boolean)
    .map((l, i) => [Number(l.split(' ')[0]), i]).filter(([n]) => n > 3_000_000);
  assert.equal(big.length, 0, `${big.length} tracked blob(s) exceed 3 MB`);
});
