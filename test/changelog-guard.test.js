const { test } = require('node:test');
const assert = require('node:assert/strict');
const { verdict, isWatched, OVERRIDE } = require('../scripts/check-changelog.js');

/**
 * Nine PRs landed between v3.6.0-beta.8 and this guard with `[Unreleased]`
 * empty for every one — so beta.8's notes were written at cut time by someone
 * who had not made the changes. These pin down what the guard asks for and,
 * just as importantly, what it must NOT nag about: a check that fires on test
 * and CI edits gets muted, and then it protects nothing.
 */

test('shipped code without a changelog entry is refused', () => {
  const r = verdict(['lib/stl-estimate.js'], 'fix the estimator');
  assert.equal(r.ok, false);
  assert.deepEqual(r.watched, ['lib/stl-estimate.js']);
});

test('shipped code WITH a changelog entry passes', () => {
  assert.equal(verdict(['lib/stl-estimate.js', 'CHANGELOG.md'], 'fix').ok, true);
});

test('every shipped root is watched', () => {
  for (const f of ['main.js', 'preload.js', 'lib/a.js', 'lib/deep/b.js', 'renderer/app.js', 'renderer/bedready/c.js']) {
    assert.equal(isWatched(f), true, `${f} should be watched`);
  }
});

test('tests, scripts, CI and docs never demand an entry on their own', () => {
  // The whole reason this rule is narrow. A guard that fires on a test tweak
  // gets ignored, and an ignored guard is worse than none.
  const quiet = [
    'test/foo.test.js', 'scripts/e2e-smoke.mjs', '.github/workflows/ci.yml',
    'docs/RELEASE-HOLD.md', 'README.md', 'package-lock.json', 'assets/icon.png',
  ];
  for (const f of quiet) assert.equal(isWatched(f), false, `${f} should not be watched`);
  const r = verdict(quiet, 'housekeeping');
  assert.equal(r.ok, true);
  assert.match(r.reason, /no shipped code/);
});

test('an invisible change can say so', () => {
  const r = verdict(['lib/stl-estimate.js'], `rename a variable\n\n${OVERRIDE}`);
  assert.equal(r.ok, true);
  assert.match(r.reason, /no changelog/);
});

test('the override is case-insensitive, because it is typed by humans', () => {
  assert.equal(verdict(['main.js'], 'tidy up\n\n[No Changelog]').ok, true);
  assert.equal(verdict(['main.js'], 'tidy up\n\n[NO CHANGELOG]').ok, true);
});

test('the override must be deliberate, not a coincidence of wording', () => {
  // "no changelog entry needed" without the brackets is prose, not a marker.
  assert.equal(verdict(['main.js'], 'no changelog needed for this one').ok, false);
});

test('a mixed PR is judged on the shipped files only', () => {
  const r = verdict(['test/a.test.js', 'renderer/app.js', 'scripts/x.mjs'], 'work');
  assert.equal(r.ok, false);
  assert.deepEqual(r.watched, ['renderer/app.js'], 'only the shipped file should be named');
});

test('a release commit passes on its own merits', () => {
  // `npm run version:*` touches package.json and the lockfile; the cut also
  // edits CHANGELOG.md, which is exactly what this asks for.
  assert.equal(verdict(['package.json', 'package-lock.json', 'CHANGELOG.md'], 'chore: release').ok, true);
});

test('an empty or malformed file list is not an accusation', () => {
  assert.equal(verdict([], '').ok, true);
  assert.equal(verdict(null, null).ok, true);
  assert.equal(verdict(['', '   '], '').ok, true);
});

test('paths are matched at the root, not anywhere in the string', () => {
  // A vendored copy under test fixtures must not be mistaken for shipped code.
  assert.equal(isWatched('test/fixtures/lib/thing.js'), false);
  assert.equal(isWatched('docs/renderer/notes.md'), false);
  assert.equal(isWatched('scripts/main.js'), false);
});

/// The Mac app is a second shipping product and this list did not know.
///
/// Written when Khayt was one product, so `mac/` was watched by nothing: every
/// user-visible Mac change passed without a changelog line, and the
/// 4.0.0-alpha.3 notes were written by hand at cut time — the exact
/// reconstruction-after-the-fact the guard exists to end.
test('the Mac app counts as shipped code', () => {
  assert.equal(isWatched('mac/KhaytCore/Sources/KhaytApp/Catalogue.swift'), true);
  assert.equal(isWatched('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift'), true);

  const v = verdict(['mac/KhaytCore/Sources/KhaytApp/Catalogue.swift'], 'a new screen');
  assert.equal(v.ok, false, 'a Mac change with no changelog line passed');
});

/// Exempt for the same reason `test/` is: they ship nothing a shop sees.
test('the Mac tests, build script and manifest are not shipped code', () => {
  for (const file of [
    'mac/KhaytCore/Tests/KhaytAppTests/SearchReachTests.swift',
    'mac/make-app.sh',
    'mac/KhaytCore/Package.swift',
    'mac/version.json',
  ]) {
    assert.equal(isWatched(file), false, `${file} should not demand a changelog line`);
  }
});
