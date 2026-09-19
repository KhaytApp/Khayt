#!/usr/bin/env node
/**
 * A change a user can notice should say so in CHANGELOG.md.
 *
 * Nine PRs landed between v3.6.0-beta.8 and the commit that added this, and
 * `[Unreleased]` was empty for every one of them — two of them mine. The notes
 * for beta.8 were therefore reconstructed from PR bodies at cut time, by someone
 * who had not made the changes. That is slower and less accurate than the author
 * writing one line while the reasoning is still in their head, and the cost lands
 * on whoever cuts the release rather than whoever skipped it.
 *
 * The rule is deliberately narrow. It asks only about code that ships and can
 * change what a shop sees; tests, scripts, CI and docs are exempt outright, and
 * anything genuinely invisible can say so.
 */
'use strict';

/** Files whose change can alter what a user experiences. */
const WATCHED = [
  (f) => f === 'main.js',
  (f) => f === 'preload.js',
  (f) => f.startsWith('lib/'),
  (f) => f.startsWith('renderer/'),
  // ── THE MAC APP SHIPS TOO, AND THIS DID NOT KNOW ────────────────────────
  //
  // This list was written when Khayt was one product. The native Mac app is a
  // second one now — its own version, its own release lane, its own downloads
  // — and none of it was watched, so every user-visible Mac change since has
  // passed this check without a line. The 4.0.0-alpha.3 notes were written by
  // hand at cut time, which is precisely the reconstruction-after-the-fact
  // this file exists to end; it simply had not been told the Mac app exists.
  //
  // `Sources/` and not `mac/`: the tests, the build script and the package
  // manifest are exempt for the same reason `test/` is.
  (f) => f.startsWith('mac/KhaytCore/Sources/'),
];

/**
 * Say this in a commit message when a watched file changed but nothing a shop
 * could notice did — a refactor, a comment, a rename, an internal-only guard.
 */
const OVERRIDE = '[no changelog]';

const CHANGELOG = 'CHANGELOG.md';

const isWatched = (file) => WATCHED.some((m) => m(String(file || '').trim()));

/**
 * @param {string[]} files     paths changed, relative to the repo root
 * @param {string}   messages  the PR's commit messages, joined
 * @returns {{ok: boolean, reason: string, watched: string[]}}
 */
function verdict(files, messages = '') {
  const list = (Array.isArray(files) ? files : []).map((f) => String(f || '').trim()).filter(Boolean);
  const watched = list.filter(isWatched);

  if (!watched.length) {
    return { ok: true, reason: 'no shipped code changed', watched };
  }
  if (list.includes(CHANGELOG)) {
    return { ok: true, reason: `${CHANGELOG} was updated`, watched };
  }
  // Case-insensitive: the marker is for humans, and "[No Changelog]" is the
  // same intent typed differently.
  if (String(messages || '').toLowerCase().includes(OVERRIDE)) {
    return { ok: true, reason: `${OVERRIDE} was given`, watched };
  }
  return { ok: false, reason: `shipped code changed and ${CHANGELOG} did not`, watched };
}

/* ────────────────────────────────────────────────────────────────────────────
 * WHERE the entry landed, not just that there was one.
 *
 * Twice in one night an entry was written into a section that had already
 * shipped, and neither time did anything fail:
 *
 *   - a rebase resolved a conflict by keeping both sides, which put a second
 *     `## [3.8.0]` heading above 117 entries and quietly took them out of
 *     `[Unreleased]` (#1400);
 *   - a branch cut before that repair inserted its own entry at an anchor that
 *     had since moved, so the entry landed *inside* `[3.8.0]`, six hundred
 *     lines below where its author put it (#1399).
 *
 * An entry in a released section is not lost — it is worse than lost. It reads
 * as published, so nobody looks for it, and the release it belongs to goes out
 * without it. The check above cannot see this: it asks only whether the file
 * was touched.
 *
 * The rule: a bullet ADDED by a pull request belongs under `[Unreleased]`, or
 * under a section that same pull request added — which is what a release cut
 * is, and the only time writing into a version section is right.
 * ──────────────────────────────────────────────────────────────────────────── */

/** `## [x] - date` → x, for one line. */
function headingOf(line) {
  const m = /^## \[([^\]]+)\]/.exec(String(line || ''));
  return m ? m[1] : null;
}

/**
 * Added bullets and the section each landed in.
 *
 * @param {string} diff   `git diff <base>...HEAD -- CHANGELOG.md`, unified.
 * @param {string} after  the file as the PR leaves it.
 * @returns {{ok: boolean, misplaced: Array<{section: string, text: string}>}}
 */
function placement(diff, after) {
  const lines = String(after || '').split('\n');

  // Which section each line of the new file belongs to.
  const sectionAt = [];
  let current = null;
  for (const line of lines) {
    const name = headingOf(line);
    if (name) current = name;
    sectionAt.push(current);
  }

  // Walk the diff's hunks, tracking the line number in the NEW file.
  const addedBullets = [];   // {lineNo, text}
  const addedSections = new Set();
  let lineNo = 0;
  for (const raw of String(diff || '').split('\n')) {
    const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
    if (hunk) { lineNo = Number(hunk[1]) - 1; continue; }
    if (raw.startsWith('+++') || raw.startsWith('---')) continue;
    if (raw.startsWith('+')) {
      lineNo += 1;
      const text = raw.slice(1);
      const name = headingOf(text);
      if (name) { addedSections.add(name); continue; }
      if (text.startsWith('- ')) addedBullets.push({ lineNo, text });
      continue;
    }
    if (raw.startsWith('-')) continue;       // gone from the new file
    if (raw.startsWith(' ')) { lineNo += 1; continue; }
  }

  const misplaced = [];
  for (const { lineNo: n, text } of addedBullets) {
    const section = sectionAt[n - 1];
    // Above the first heading, or in a file with none: not this rule's business.
    if (!section) continue;
    if (section === 'Unreleased') continue;
    // A release cut writes the section and its entries together.
    if (addedSections.has(section)) continue;
    misplaced.push({ section, text: text.slice(0, 90) });
  }
  return { ok: misplaced.length === 0, misplaced };
}

module.exports = { verdict, isWatched, WATCHED, OVERRIDE, CHANGELOG, placement };

if (require.main === module) {
  const { execFileSync } = require('child_process');
  const base = process.env.BASE_REF || process.argv[2] || 'main';
  const sh = (args) => execFileSync('git', args, { encoding: 'utf8' });

  let files = [];
  let messages = '';
  try {
    files = sh(['diff', '--name-only', `${base}...HEAD`]).split('\n');
    messages = sh(['log', '--format=%B', `${base}..HEAD`]);
  } catch (e) {
    // A missing base ref is a CI wiring fault, not a contributor's fault —
    // failing the PR for it would teach people to ignore this check.
    process.stdout.write(`changelog check skipped — could not diff against "${base}": ${(e && e.message) || e}\n`);
    process.exit(0);
  }

  const r = verdict(files, messages);

  // WHERE it landed, whenever the file was touched at all — including by a PR
  // that changed no shipped code, since a misplaced entry is misplaced either
  // way.
  if (files.includes(CHANGELOG)) {
    let where = { ok: true, misplaced: [] };
    try {
      const diff = sh(['diff', '--unified=3', `${base}...HEAD`, '--', CHANGELOG]);
      where = placement(diff, require('fs').readFileSync(CHANGELOG, 'utf8'));
    } catch (e) {
      process.stdout.write(`changelog placement not checked — ${(e && e.message) || e}\n`);
    }
    if (!where.ok) {
      process.stderr.write(
        `\nchangelog check failed — ${where.misplaced.length} entr` +
        `${where.misplaced.length === 1 ? 'y was' : 'ies were'} added to a section that has ` +
        `already shipped:\n\n` +
        where.misplaced.map((m) => `  [${m.section}]  ${m.text}\n`).join('') +
        `\nAn entry there reads as published, so nobody goes looking for it, and the\n` +
        `release it belongs to goes out without it. Move it under "## [Unreleased]".\n` +
        `\nIf this IS a release cut, the section it writes into must be added by the\n` +
        `same pull request.\n`
      );
      process.exit(1);
    }
  }

  if (r.ok) {
    process.stdout.write(`changelog check ok — ${r.reason}\n`);
    process.exit(0);
  }

  process.stderr.write(
    `\nchangelog check failed — ${r.reason}.\n\n` +
    `These shipped files changed:\n` +
    r.watched.slice(0, 20).map((f) => `  ${f}\n`).join('') +
    (r.watched.length > 20 ? `  …and ${r.watched.length - 20} more\n` : '') +
    `\nAdd a line under "## [Unreleased]" in ${CHANGELOG} saying what a shop would\n` +
    `notice. If a shop would notice nothing, put ${OVERRIDE} in the commit message.\n`
  );
  process.exit(1);
}
