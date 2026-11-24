#!/usr/bin/env node
/**
 * Fold the changelog fragments into CHANGELOG.md, at the release cut.
 *
 * Each pull request writes its entry to `changelog.d/<branch>.md` instead of
 * the top of [Unreleased], so open PRs stop conflicting with every merge
 * (scripts/check-changelog.js, ~/Khayt-proposals/changelog-fragments.md).
 * This puts them back where they would have been:
 *
 *   - directly under `## [Unreleased]` and its blank line, above the entries
 *     already there, as if each had been added at the top in its turn;
 *   - fragments NEWEST FIRST (the commit that added the file, so the order is
 *     the order they landed), each fragment's own lines in its own order;
 *   - every other line of the file byte for byte as it was;
 *   - then the fragment files are deleted (README.md stays).
 *
 * Run it as step 0 of the release checklist (VERSIONING.md), before moving
 * [Unreleased] into `## [X.Y.Z]`:
 *
 *   npm run changelog:fold            folds, deletes, prints what it did
 *   npm run changelog:fold -- --check exits 1 if any fragment is waiting
 *                                     (cut-release.yml, mac/release-local.sh)
 *
 * The core, fold(), is pure and tested against today's file
 * (test/changelog-fold.test.js).
 */
'use strict';

const HEADING = '## [Unreleased]';

/** The fragment's entry lines: trailing blank lines and CRLF dropped, nothing else touched. */
function entryLines(text) {
  const lines = String(text == null ? '' : text).replace(/\r\n/g, '\n').split('\n');
  while (lines.length && !lines[lines.length - 1].trim()) lines.pop();
  while (lines.length && !lines[0].trim()) lines.shift();
  return lines;
}

/**
 * @param {string} changelog  CHANGELOG.md as it is
 * @param {Array<{name: string, text: string}>} fragments  NEWEST FIRST
 * @returns {string} the file with every fragment's lines at the top of [Unreleased]
 */
function fold(changelog, fragments) {
  const src = String(changelog);
  const list = (Array.isArray(fragments) ? fragments : []).map((f) => entryLines(f && f.text)).filter((l) => l.length);
  if (!list.length) return src;
  const lines = src.split('\n');
  const at = lines.indexOf(HEADING);
  if (at === -1) throw new Error(`CHANGELOG.md has no "${HEADING}" line to fold into`);
  // The heading, one blank line, then the entries: today's shape.
  let insert = at + 1;
  if (insert < lines.length && lines[insert].trim() === '') insert += 1;
  const added = [];
  for (const l of list) added.push(...l);
  // A blank line before whatever heading follows: the next version, or a
  // "### Before you update" at the top of [Unreleased] (review of #2706).
  const next = lines[insert];
  if (next === undefined || /^#/.test(next)) added.push('');
  if (insert === at + 1) added.unshift('');
  lines.splice(insert, 0, ...added);
  return lines.join('\n');
}

/**
 * Newest first: the time of the commit that ADDED each file (git), a file git
 * does not know yet first of all, ties by name.
 */
function order(names, addedAt) {
  return names.slice().sort((a, b) => {
    const ta = addedAt(a), tb = addedAt(b);
    const ka = ta == null ? Infinity : ta, kb = tb == null ? Infinity : tb;
    if (ka !== kb) return kb - ka;
    return a < b ? -1 : a > b ? 1 : 0;
  });
}

module.exports = { fold, order, entryLines, HEADING };

if (require.main === module) {
  const fs = require('fs');
  const path = require('path');
  const { execFileSync } = require('child_process');
  const { checkFragment, waitingFragments, FRAGMENT_DIR, CHANGELOG } = require('./check-changelog.js');
  const ROOT = path.join(__dirname, '..');
  const dir = path.join(ROOT, FRAGMENT_DIR);
  // Anything but the README is waiting, the same rule as cut-release.yml and
  // the release PR's check: a stray .txt or folder is refused below, never
  // silently skipped while the tag step refuses it forever (review of #2706).
  const names = waitingFragments(fs.existsSync(dir) ? fs.readdirSync(dir) : []).map((n) => `${FRAGMENT_DIR}/${n}`);

  if (process.argv.includes('--check')) {
    if (names.length) {
      process.stderr.write(`${names.length} changelog fragment(s) not folded into ${CHANGELOG}:\n`
        + names.map((n) => `  ${n}\n`).join('')
        + `Run "npm run changelog:fold", then move [Unreleased] into the version's section.\n`);
      process.exit(1);
    }
    process.stdout.write('no changelog fragments waiting\n');
    process.exit(0);
  }

  const problems = [];
  const texts = {};
  for (const n of names) {
    if (!fs.statSync(path.join(ROOT, n)).isFile()) { problems.push(`${n}: not a file — ${FRAGMENT_DIR}/ holds only <name>.md fragments and README.md`); continue; }
    texts[n] = fs.readFileSync(path.join(ROOT, n), 'utf8');
    problems.push(...checkFragment(n, texts[n]).problems);
  }
  if (problems.length) {
    process.stderr.write(`not folding — fix these fragments first:\n${problems.map((p) => `  ${p}\n`).join('')}`);
    process.exit(1);
  }
  const addedAt = (n) => {
    try {
      const out = execFileSync('git', ['log', '--diff-filter=A', '--format=%ct', '-1', '--', n], { cwd: ROOT, encoding: 'utf8' }).trim();
      return out ? Number(out) : null;
    } catch (_) { return null; }
  };
  const sorted = order(names, addedAt);
  const file = path.join(ROOT, CHANGELOG);
  const before = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(file, fold(before, sorted.map((n) => ({ name: n, text: texts[n] }))));
  for (const n of sorted) fs.unlinkSync(path.join(ROOT, n));
  process.stdout.write(sorted.length
    ? `folded ${sorted.length} fragment(s) into ${CHANGELOG}, newest first:\n${sorted.map((n) => `  ${n}\n`).join('')}`
    : 'no changelog fragments to fold\n');
}
