'use strict';
/**
 * Changelog fragments (changelog.d/) and the fold at the release cut.
 * ~/Khayt-proposals/changelog-fragments.md.
 *
 * The fold must give exactly the file the old way gave: each PR's lines at the
 * top of [Unreleased], newest on top, nothing else moved. Checked on the real
 * CHANGELOG.md as it stands, and through the guards that read that file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { fold, order, entryLines } = require('../scripts/changelog-fold.js');
const { verdict, checkFragment, isFragmentPath, placement } = require('../scripts/check-changelog.js');

const ROOT = path.join(__dirname, '..');
const REAL = fs.readFileSync(path.join(ROOT, 'CHANGELOG.md'), 'utf8');

const A = '- **Bed Ready: a download asks the switch first.** One sentence.';
const B = '- **Printer success: 199 of 200 is 99%.** Another.';
const B2 = '- **Printer success: a second line from the same PR.**';

test('fold: the lines land at the top of [Unreleased], newest first, exactly as if typed there', () => {
  const out = fold(REAL, [{ name: 'changelog.d/b.md', text: `${B}\n${B2}\n` }, { name: 'changelog.d/a.md', text: `${A}\n` }]);
  // The old way: each PR inserted its line right under the heading's blank line.
  const lines = REAL.split('\n');
  const at = lines.indexOf('## [Unreleased]');
  assert.equal(lines[at + 1], '', 'today: a blank line under the heading');
  const byHand = [...lines.slice(0, at + 2), B, B2, A, ...lines.slice(at + 2)].join('\n');
  assert.equal(out, byHand);
  // Nothing else moved: everything from the first released section on is byte for byte the same.
  const firstRelease = REAL.search(/\n## \[\d/);
  assert.ok(firstRelease > 0);
  assert.equal(out.slice(out.search(/\n## \[\d/)), REAL.slice(firstRelease));
});

test('fold: the result passes the guards that read CHANGELOG.md', () => {
  const out = fold(REAL, [{ name: 'changelog.d/a.md', text: `${A}\n` }]);
  // check-changelog.js placement: every added bullet is in [Unreleased].
  const diff = ['@@ -5,2 +5,3 @@', ' ## [Unreleased]', ' ', `+${A}`].join('\n');
  assert.deepEqual(placement(diff, out), { ok: true, misplaced: [] });
  // check-release-claims.js rule 5: no heading repeated in [Unreleased] (a fragment cannot add one).
  const unrel = out.slice(out.indexOf('## [Unreleased]'));
  const body = unrel.slice(0, unrel.indexOf('\n## [', 1));
  const heads = [...body.matchAll(/^### (.+)$/gm)].map((m) => m[1]);
  assert.equal(new Set(heads).size, heads.length);
  // One [Unreleased], still first.
  assert.equal(out.match(/^## \[Unreleased\]$/gm).length, 1);
  assert.ok(out.indexOf('## [Unreleased]') < out.search(/\n## \[\d/));
});

test('fold: no fragments is no change; blank and CRLF fragments add nothing stray', () => {
  assert.equal(fold(REAL, []), REAL);
  assert.equal(fold(REAL, [{ name: 'changelog.d/x.md', text: '\n\n' }]), REAL);
  assert.equal(fold(REAL, [{ name: 'changelog.d/a.md', text: `\r\n${A}\r\n\r\n` }]), fold(REAL, [{ name: 'changelog.d/a.md', text: `${A}\n` }]));
  assert.deepEqual(entryLines(`${A}\n  continued\n\n`), [A, '  continued']);
});

test('fold: an empty [Unreleased] keeps its blank lines on both sides', () => {
  const small = '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- old\n';
  assert.equal(fold(small, [{ name: 'changelog.d/a.md', text: A }]),
    `# Changelog\n\n## [Unreleased]\n\n${A}\n\n## [1.0.0] - 2026-01-01\n\n- old\n`);
  const tight = '## [Unreleased]\n## [1.0.0]\n- old\n';
  assert.equal(fold(tight, [{ name: 'changelog.d/a.md', text: A }]), `## [Unreleased]\n\n${A}\n\n## [1.0.0]\n- old\n`);
  assert.throws(() => fold('## [1.0.0]\n- old\n', [{ name: 'changelog.d/a.md', text: A }]), /no "## \[Unreleased\]"/);
});

test('order: newest added first, a file git does not know yet first of all, ties by name', () => {
  const t = { 'changelog.d/old.md': 100, 'changelog.d/new.md': 300, 'changelog.d/mid.md': 200, 'changelog.d/b.md': 200 };
  assert.deepEqual(order(['changelog.d/old.md', 'changelog.d/mid.md', 'changelog.d/local.md', 'changelog.d/new.md', 'changelog.d/b.md'], (n) => t[n] ?? null),
    ['changelog.d/local.md', 'changelog.d/new.md', 'changelog.d/b.md', 'changelog.d/mid.md', 'changelog.d/old.md']);
});

test('the check: a fragment counts as the entry; a deleted one (the fold) or the README does not', () => {
  assert.equal(verdict(['lib/x.js', 'changelog.d/my-branch.md'], 'fix').ok, true);
  assert.match(verdict(['lib/x.js', 'changelog.d/my-branch.md'], 'fix').reason, /fragment/);
  assert.equal(verdict(['lib/x.js', 'changelog.d/my-branch.md'], 'fix', []).ok, false, 'listed in files only because it was deleted');
  assert.equal(verdict(['lib/x.js', 'changelog.d/README.md'], 'fix').ok, false);
  assert.equal(isFragmentPath('changelog.d/README.md'), false);
  assert.equal(isFragmentPath('docs/changelog.d/x.md'), false);
  // The old ways still work.
  assert.equal(verdict(['lib/x.js', 'CHANGELOG.md'], 'fix').ok, true);
  assert.equal(verdict(['lib/x.js'], 'refactor [no changelog]').ok, true);
});

test('the check: what a fragment may hold', () => {
  const ok = (name, text) => checkFragment(name, text).ok;
  assert.equal(ok('changelog.d/claude-bedready-fix.md', `${A}\n`), true);
  assert.equal(ok('changelog.d/a.md', `${A}\n  a continuation\n\n${B}\n`), true);
  assert.equal(ok('changelog.d/a.md', ''), false, 'empty');
  assert.equal(ok('changelog.d/a.md', '\n- \n'), false, 'a bare dash is no entry');
  assert.equal(ok('changelog.d/a.md', `### Before you update\n${A}\n`), false, 'no headings');
  assert.equal(ok('changelog.d/a.md', `## [Unreleased]\n${A}\n`), false);
  assert.equal(ok('changelog.d/a.md', `Some prose.\n${A}\n`), false, 'prose that is not an entry');
  assert.equal(ok('changelog.d/a.md', `  indented before any bullet\n${A}\n`), false);
  assert.equal(ok('changelog.d/a.md', `* star bullet\n`), false);
  for (const bad of ['changelog.d/claude/x.md', 'changelog.d/.hidden.md', 'changelog.d/x.txt', 'changelog.d/a b.md']) {
    assert.equal(ok(bad, `${A}\n`), false, bad);
  }
  assert.ok(checkFragment('changelog.d/a.md', '### Before you update\n').problems.some((p) => /CHANGELOG\.md itself/.test(p)), 'says where that goes');
});

test('the repo: changelog.d holds a README and only well-formed fragments', () => {
  const dir = path.join(ROOT, 'changelog.d');
  assert.ok(fs.existsSync(path.join(dir, 'README.md')));
  for (const n of fs.readdirSync(dir)) {
    const f = `changelog.d/${n}`;
    if (!isFragmentPath(f)) continue;
    assert.deepEqual(checkFragment(f, fs.readFileSync(path.join(dir, n), 'utf8')).problems, [], f);
  }
});
