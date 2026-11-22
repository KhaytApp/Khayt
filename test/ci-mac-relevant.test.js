'use strict';
// ci.yml skips "Mac app tests" on a PR that touches nothing matching the
// MAC-RELEVANT pattern. If a Mac test starts reading a repo file the pattern
// does not cover, a PR changing that file would skip the tests that read it.
// This walks mac/ for every repo path a Swift file or script names and requires
// the pattern to match each one.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const ci = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');

function pattern() {
  const m = ci.match(/^\s*pattern='([^']+)'/m);
  assert.ok(m, 'ci.yml has no mac-relevant pattern= line');
  return new RegExp(m[1]);
}

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === '.build' || e.name === 'node_modules') continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (/\.(swift|sh)$/.test(e.name)) out.push(p);
  }
  return out;
}

test('every repo file the Mac tests read is Mac-relevant in ci.yml', () => {
  const re = pattern();
  const topLevel = /"((?:lib|renderer|test|docs|scripts|ios)\/[^"\s\\$]+|main\.js|preload\.js|package\.json)"/g;
  const seen = new Set();
  for (const f of walk(path.join(root, 'mac'), [])) {
    const src = fs.readFileSync(f, 'utf8');
    for (const line of src.split('\n')) {
      if (!/appending\(path:|contentsOf|cp |cat |< /.test(line)) continue;
      for (const m of line.matchAll(topLevel)) seen.add(m[1]);
    }
  }
  // The interpolated forms ("lib/\(module).js", "renderer/locales/\(l).js") are
  // cut at the backslash by the regex above, leaving their directory.
  assert.ok(seen.size > 5, 'found too few paths; did the scan break? ' + [...seen]);
  const missed = [...seen].filter(p => !re.test(p) && !re.test(p + '/x') && !re.test(p + 'x'));
  assert.deepStrictEqual(missed, [], 'add these to the mac-relevant pattern in ci.yml:\n' + missed.join('\n'));
});

test('the pattern runs on what it must and skips docs-only changes', () => {
  const re = pattern();
  for (const p of ['mac/KhaytCore/Package.swift', 'lib/order-status.js', 'main.js',
    'renderer/order-flows.js', 'renderer/locales/ar.js', 'test/fixtures/a.3mf',
    '.github/workflows/ci.yml']) assert.ok(re.test(p), p);
  for (const p of ['CHANGELOG.md', 'docs/RELEASE-HOLD.md', 'package.json',
    'renderer/invoicing.js', 'test/open-jobs-predicate.test.js', 'ios/KhaytCompanion/App.swift'])
    assert.ok(!re.test(p), p);
});

test('the Mac job is skipped by its own if:, never by a workflow path filter', () => {
  assert.doesNotMatch(ci.split('\njobs:')[0], /paths:/, 'a workflow path filter would leave the required check unreported');
  assert.match(ci, /\n  mac:\n    name: Mac app tests\n    needs: mac-relevant\n    if: needs\.mac-relevant\.outputs\.run == 'true'/);
  assert.match(ci, /if \[ "\$EVENT" != "pull_request" \]; then echo "run=true"/, 'a push to main must always run it');
});
