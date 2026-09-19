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

/* ────────────────────────────────────────────────────────────────────────────
 * THE FILE ITSELF, not just the rule that asks for an entry.
 *
 * A rebase whose CHANGELOG conflict was resolved by keeping both sides put a
 * SECOND `## [3.8.0]` heading — with the released section's whole summary —
 * between `[Unreleased]` and the 117 entries below it. Nothing failed. The
 * entries were still in the file, still in order, still readable; they had
 * simply stopped belonging to `[Unreleased]`, so the Mac's next cut would have
 * found its notes empty and written a release with none.
 *
 * `check-changelog.js` could not see it: it asks whether a PR touched the file,
 * not what the file says. These read the file.
 * ──────────────────────────────────────────────────────────────────────────── */

const { readFileSync } = require('node:fs');
const { join } = require('node:path');

/** Every `## [version]` heading, in the order they appear. */
function headings() {
  const text = readFileSync(join(__dirname, '..', 'CHANGELOG.md'), 'utf8');
  return text.split('\n')
    .map((line) => /^## \[([^\]]+)\]/.exec(line))
    .filter(Boolean)
    .map((m) => m[1]);
}

test('no version has two sections in the changelog', () => {
  const seen = new Map();
  for (const version of headings()) seen.set(version, (seen.get(version) || 0) + 1);
  const twice = [...seen].filter(([, n]) => n > 1).map(([v, n]) => `${v} × ${n}`);
  assert.deepEqual(twice, [], `a version is written twice — the entries under the \
first copy belong to whatever section precedes it, and the next cut will not \
find them:\n  ${twice.join('\n  ')}`);
});

test('[Unreleased] is the first section, and there is exactly one', () => {
  // Two release lines share it — Electron's and the Mac's — so an entry that
  // falls out of it falls out of BOTH their notes.
  const all = headings();
  assert.equal(all.filter((v) => v === 'Unreleased').length, 1, 'expected one [Unreleased]');
  assert.equal(all[0], 'Unreleased', '[Unreleased] must be the first section');
});

test('every released section has entries under it', () => {
  // An empty section is a cut that wrote its notes from an empty [Unreleased]
  // — which is exactly what the duplicate heading above would have produced.
  //
  // Two sections carry prose and no entries ON PURPOSE, and both say why in
  // their own text: a release candidate that is `beta.19` under another name
  // and changes no behaviour, and the last 2.0.x patch, whose notes live in
  // GitHub Releases. Named here rather than pattern-matched, so a third one
  // has to be argued for.
  const PROSE_ONLY = new Set(['3.6.0-rc.1', '2.0.16']);
  const text = readFileSync(join(__dirname, '..', 'CHANGELOG.md'), 'utf8');
  const parts = text.split(/^## \[/m).slice(1);
  const empty = parts
    .map((part) => ({ name: part.slice(0, part.indexOf(']')), body: part }))
    .filter(({ name, body }) => name !== 'Unreleased' && !PROSE_ONLY.has(name)
                                && !/^- /m.test(body))
    .map(({ name }) => name);
  assert.deepEqual(empty, [], `released sections with no entries: ${empty.join(', ')}`);
});

/* ────────────────────────────────────────────────────────────────────────────
 * WHERE an entry landed.
 *
 * #1399 put its line six hundred lines below where its author wrote it — inside
 * a section that had already shipped — because the anchor it matched had moved
 * under it. #1400's rebase did the same thing to 117 lines at once. Both files
 * read perfectly afterwards, and every check passed.
 * ──────────────────────────────────────────────────────────────────────────── */

const { placement } = require('../scripts/check-changelog.js');

/** The file as a PR leaves it. */
const AFTER = [
  '# Changelog',                       // 1
  '',                                  // 2
  '## [Unreleased]',                   // 3
  '',                                  // 4
  '### Changed',                       // 5
  '',                                  // 6
  '- **A new thing.** Said here.',     // 7
  '',                                  // 8
  '## [3.8.0] - 2026-09-18',           // 9
  '',                                  // 10
  '- **A shipped thing.** Said then.', // 11
  '',                                  // 12
  '- **A smuggled thing.** Said late.',// 13
].join('\n');

test('an entry added under [Unreleased] is where it belongs', () => {
  const diff = ['@@ -6,0 +7 @@', '+- **A new thing.** Said here.'].join('\n');
  assert.deepEqual(placement(diff, AFTER), { ok: true, misplaced: [] });
});

test('an entry added inside a shipped section is refused', () => {
  const diff = ['@@ -12,0 +13 @@', '+- **A smuggled thing.** Said late.'].join('\n');
  const r = placement(diff, AFTER);
  assert.equal(r.ok, false);
  assert.equal(r.misplaced.length, 1);
  assert.equal(r.misplaced[0].section, '3.8.0');
});

test('a release cut writes its own section and is allowed', () => {
  // The one time writing into a version section is right: the PR adds the
  // heading and the entries together.
  const cut = [
    '# Changelog', '', '## [Unreleased]', '', '## [4.0.0-alpha.26] - 2026-09-19', '',
    '- **A cut thing.** Shipped now.', '', '## [3.8.0] - 2026-09-18',
  ].join('\n');
  const diff = [
    '@@ -3,0 +4,4 @@',
    '+',
    '+## [4.0.0-alpha.26] - 2026-09-19',
    '+',
    '+- **A cut thing.** Shipped now.',
  ].join('\n');
  assert.deepEqual(placement(diff, cut), { ok: true, misplaced: [] });
});

test('context and removed lines keep the line count honest', () => {
  // The bullet below is the 13th line of the new file only if a removed line
  // is NOT counted and the context lines are. Get that wrong and the check
  // blames the wrong section — or clears a real one.
  const diff = [
    '@@ -9,5 +9,5 @@',
    ' ## [3.8.0] - 2026-09-18',
    ' ',
    ' - **A shipped thing.** Said then.',
    '-- **A removed thing.** Gone.',
    ' ',
    '+- **A smuggled thing.** Said late.',
  ].join('\n');
  const r = placement(diff, AFTER);
  assert.equal(r.ok, false, 'the smuggled entry was not found');
  assert.equal(r.misplaced[0].section, '3.8.0');
});

test('a changelog with no headings at all is not this rule\'s business', () => {
  const diff = ['@@ -1,0 +1 @@', '+- **A thing.**'].join('\n');
  assert.equal(placement(diff, '- **A thing.**').ok, true);
});

test('an empty diff passes, and garbage does not throw', () => {
  assert.equal(placement('', AFTER).ok, true);
  assert.equal(placement(null, null).ok, true);
  assert.equal(placement('not a diff at all', AFTER).ok, true);
});
