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
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { fold, order, entryLines } = require('../scripts/changelog-fold.js');
const { verdict, checkFragment, isFragmentPath, placement, releaseSignals, waitingFragments } = require('../scripts/check-changelog.js');

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

test('fold: the real diff of the folded file passes placement(), and [Unreleased] is still the one first section', () => {
  const out = fold(REAL, [{ name: 'changelog.d/a.md', text: `${A}\n${B}\n` }]);
  // git's own diff of before → after, as check-changelog.js reads a PR.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'cl-fold-'));
  try {
    fs.writeFileSync(path.join(tmp, 'before.md'), REAL);
    fs.writeFileSync(path.join(tmp, 'after.md'), out);
    const r = spawnSync('git', ['diff', '--no-index', '--unified=3', 'before.md', 'after.md'], { cwd: tmp, encoding: 'utf8' });
    assert.equal(r.status, 1, 'the files differ');
    const added = r.stdout.split('\n').filter((l) => l.startsWith('+') && !l.startsWith('+++'));
    assert.deepEqual(added, [`+${A}`, `+${B}`], 'only the fragment lines are added');
    assert.deepEqual(placement(r.stdout, out), { ok: true, misplaced: [] });
    // The same lines added at the top of a RELEASED section would be refused: the check can fail.
    const wrong = out.replace(`${A}\n${B}\n`, '').replace(/(\n## \[\d[^\n]*\n\n(?:### [^\n]*\n\n)?)/, `$1${A}\n`);
    fs.writeFileSync(path.join(tmp, 'wrong.md'), wrong);
    const w = spawnSync('git', ['diff', '--no-index', '--unified=3', 'before.md', 'wrong.md'], { cwd: tmp, encoding: 'utf8' });
    assert.equal(placement(w.stdout, wrong).ok, false);
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  assert.equal(out.match(/^## \[Unreleased\]$/gm).length, 1);
  assert.ok(out.indexOf('## [Unreleased]') < out.search(/\n## \[\d/));
});

test('fold: a heading at the top of [Unreleased] ("### Before you update") keeps its blank line', () => {
  const s = '## [Unreleased]\n\n### Before you update\n\n- gate item\n\n## [1.0.0]\n- old\n';
  assert.equal(fold(s, [{ name: 'changelog.d/a.md', text: A }]),
    `## [Unreleased]\n\n${A}\n\n### Before you update\n\n- gate item\n\n## [1.0.0]\n- old\n`);
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

test('releaseSignals: a version section added, or a version changed, is a release; [Unreleased] is not', () => {
  const v = (before, after) => ({ versionBefore: (f) => before[f] ?? null, versionAfter: (f) => after[f] ?? null });
  assert.deepEqual(releaseSignals({ changelogDiff: '+++ b/CHANGELOG.md\n+## [Unreleased]\n+- x', ...v({}, {}) }), []);
  assert.equal(releaseSignals({ changelogDiff: '+## [4.12.0] - 2026-11-25\n+- x', ...v({}, {}) }).length, 1);
  assert.equal(releaseSignals({ changelogDiff: '-## [4.12.0] - 2026-11-25', ...v({}, {}) }).length, 0, 'removed is not added');
  assert.match(releaseSignals({ changelogDiff: '', ...v({ 'package.json': '4.11.0' }, { 'package.json': '4.12.0' }) })[0], /4\.11\.0 to 4\.12\.0/);
  assert.match(releaseSignals({ changelogDiff: '', ...v({ 'mac/version.json': '4.0.0-beta.50' }, { 'mac/version.json': '4.0.0-beta.51' }) })[0], /mac\/version\.json/);
  assert.deepEqual(releaseSignals({ changelogDiff: '', ...v({ 'package.json': '4.11.0' }, { 'package.json': '4.11.0' }) }), []);
});

test('waitingFragments: anything in changelog.d/ but the README waits, the same rule everywhere', () => {
  assert.deepEqual(waitingFragments(['README.md', 'b.md', 'a.md', '.gitkeep', 'x.txt', 'sub']), ['.gitkeep', 'a.md', 'b.md', 'sub', 'x.txt']);
  assert.deepEqual(waitingFragments(['README.md']), []);
  assert.deepEqual(waitingFragments(undefined), []);
});

test('the message when nothing was written names the fragment first', () => {
  assert.match(verdict(['lib/x.js'], 'fix').reason, /changelog\.d\/ fragment/);
});

/* ── The command line, in a throwaway repo: what only git can show ───────── */
function sandbox() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cl-cli-'));
  const git = (...a) => {
    const r = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@e.x', '-c', 'commit.gpgsign=false', ...a], { cwd: dir, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git ${a.join(' ')}: ${r.stderr}`);
    return r.stdout;
  };
  const write = (f, s) => { fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true }); fs.writeFileSync(path.join(dir, f), s); };
  fs.mkdirSync(path.join(dir, 'scripts'));
  for (const f of ['check-changelog.js', 'changelog-fold.js']) fs.copyFileSync(path.join(ROOT, 'scripts', f), path.join(dir, 'scripts', f));
  git('init', '-q', '-b', 'main');
  write('CHANGELOG.md', '# Changelog\n\n## [Unreleased]\n\n- old entry\n\n## [1.0.0] - 2026-01-01\n\n- shipped\n');
  write('package.json', '{"version":"1.0.0"}\n');
  write('lib/a.js', '1\n');
  write('changelog.d/README.md', 'readme\n');
  write('changelog.d/someone-else.md', '- **Theirs.**\n');
  git('add', '-A'); git('commit', '-q', '-m', 'base');
  git('checkout', '-q', '-b', 'pr');
  const check = (cwd = dir, env = {}) => spawnSync(process.execPath, [path.join(dir, 'scripts/check-changelog.js')], { cwd, encoding: 'utf8', env: { ...process.env, BASE_REF: 'main', CHANGELOG_CHECK_SCOPE: '', ...env } });
  return { dir, git, write, check, done: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

test('CLI: a fragment the PR added passes; editing or renaming someone else\'s does not count', () => {
  const s = sandbox();
  try {
    s.write('lib/a.js', '2\n'); s.git('commit', '-qam', 'code');
    assert.equal(s.check().status, 1, 'code and no entry');
    s.write('changelog.d/someone-else.md', '- **Theirs, rewritten by me.**\n'); s.git('commit', '-qam', 'edit theirs');
    assert.equal(s.check().status, 1, 'an edit to an existing fragment is not this PR\'s entry');
    s.git('mv', 'changelog.d/someone-else.md', 'changelog.d/mine.md'); s.git('commit', '-qm', 'rename theirs');
    const renamed = s.check();
    assert.equal(renamed.status, 1, 'nor is a rename (or rewrite-and-rename) of one');
    assert.match(renamed.stderr, /removes an entry another pull request wrote[\s\S]*changelog\.d\/someone-else\.md/);
    s.git('mv', 'changelog.d/mine.md', 'changelog.d/someone-else.md'); s.git('checkout', '-q', 'main', '--', 'changelog.d/someone-else.md');
    s.write('changelog.d/pr.md', '- **Mine.** Added by this PR.\n'); s.git('add', '-A'); s.git('commit', '-qm', 'entry');
    const r = s.check();
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /fragment was written \(changelog\.d\/pr\.md\)/);
    assert.equal(s.check(path.join(s.dir, 'lib')).status, 0, 'run from lib/');
  } finally { s.done(); }
});

test('CLI: a malformed fragment is refused, a non-ASCII name included', () => {
  const s = sandbox();
  try {
    s.write('lib/a.js', '2\n'); s.write('changelog.d/café.md', '- **Accented name.**\n'); s.git('add', '-A'); s.git('commit', '-qm', 'x');
    const r = s.check();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /changelog\.d\/café\.md: a fragment is changelog\.d\/<name>\.md/);
    s.git('rm', '-q', 'changelog.d/café.md'); s.write('changelog.d/pr.md', '### Before you update\n- x\n'); s.git('add', '-A'); s.git('commit', '-qm', 'y');
    assert.match(s.check().stderr, /no headings in a fragment/);
  } finally { s.done(); }
});

test('CLI: a release PR is refused while a fragment waits, and passes once folded', () => {
  const s = sandbox();
  try {
    s.write('package.json', '{"version":"1.1.0"}\n');
    s.write('CHANGELOG.md', '# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-11-25\n\n- old entry\n\n## [1.0.0] - 2026-01-01\n\n- shipped\n');
    s.git('commit', '-qam', 'release 1.1.0');
    const r = s.check();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /this is a release \(.*package\.json goes from 1\.0\.0 to 1\.1\.0/);
    assert.match(r.stderr, /changelog\.d\/someone-else\.md/);
    s.git('rm', '-q', 'changelog.d/someone-else.md');
    s.write('CHANGELOG.md', '# Changelog\n\n## [Unreleased]\n\n## [1.1.0] - 2026-11-25\n\n- **Theirs.**\n- old entry\n\n## [1.0.0] - 2026-01-01\n\n- shipped\n');
    s.git('commit', '-qam', 'fold');
    const ok = s.check();
    assert.equal(ok.status, 0, ok.stderr);
  } finally { s.done(); }
});

test('CLI, merge queue (CHANGELOG_CHECK_SCOPE=release): only the release rule, which a PR ahead in the queue can break', () => {
  const s = sandbox();
  const queue = { CHANGELOG_CHECK_SCOPE: 'release' };
  try {
    // A PR whose own run passed on "[no changelog]": the queue's commits do not carry that message.
    s.write('lib/a.js', '2\n'); s.git('commit', '-qam', 'internal refactor');
    assert.equal(s.check(s.dir).status, 1, 'its own run would ask for an entry');
    const q = s.check(s.dir, queue);
    assert.equal(q.status, 0, q.stderr);
    assert.match(q.stdout, /merge queue: not a release/);
    // The release PR, with a fragment that landed ahead of it in the queue still waiting: refused.
    s.write('package.json', '{"version":"1.1.0"}\n'); s.git('commit', '-qam', 'release');
    const r = s.check(s.dir, queue);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /this is a release[\s\S]*changelog\.d\/someone-else\.md/);
  } finally { s.done(); }
});

test('ci.yml: the "Changelog entry" job runs in the merge queue too, on the release rule only', () => {
  const ci = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');
  const job = ci.slice(ci.indexOf('\n  changelog:\n'), ci.indexOf('\n  dco:\n'));
  assert.ok(job.length > 0, 'the changelog job is where it was');
  assert.match(job, /if: github\.event_name == 'pull_request' \|\| github\.event_name == 'merge_group'/);
  assert.match(job, /BASE_REF: \$\{\{ github\.event_name == 'merge_group' && github\.event\.merge_group\.base_sha \|\| format\('origin\/\{0\}', github\.base_ref\) \}\}/);
  assert.match(job, /CHANGELOG_CHECK_SCOPE: \$\{\{ github\.event_name == 'merge_group' && 'release' \|\| 'all' \}\}/);
  assert.match(job, /fetch-depth: 0/, 'the base must be in the clone');
});

test('CLI: the fold\'s --check and the fold itself treat a stray file the same way', () => {
  const s = sandbox();
  try {
    s.git('rm', '-q', 'changelog.d/someone-else.md'); s.write('changelog.d/notes.txt', 'x\n'); s.git('add', '-A'); s.git('commit', '-qm', 'x');
    const fold = (...a) => spawnSync(process.execPath, [path.join(s.dir, 'scripts/changelog-fold.js'), ...a], { cwd: s.dir, encoding: 'utf8' });
    assert.equal(fold('--check').status, 1, '--check sees it');
    const r = fold();
    assert.equal(r.status, 1, 'the fold refuses it rather than skipping it');
    assert.match(r.stderr, /notes\.txt/);
  } finally { s.done(); }
});
