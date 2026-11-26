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

/* ── FRAGMENTS: one file per pull request (changelog.d/) ─────────────────────
 *
 * Every PR used to add its line at the top of [Unreleased], so every merge put
 * every other open PR in conflict on the same spot. With main strict and CI
 * at 8–12 minutes, one busy day cost each PR a refresh and a full CI cycle per
 * merge ahead of it (Nov 24). A PR now writes `changelog.d/<branch>.md`, a
 * file nobody else touches, and the cut folds them in (scripts/changelog-fold.js).
 * ~/Khayt-proposals/changelog-fragments.md. */
const FRAGMENT_DIR = 'changelog.d';
const FRAGMENT_NAME = /^changelog\.d\/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.md$/;
const isFragmentPath = (file) => {
  const f = String(file || '').trim();
  return f.startsWith(FRAGMENT_DIR + '/') && f !== FRAGMENT_DIR + '/README.md';
};

/**
 * What a fragment may hold: exactly what would have gone under [Unreleased].
 * Bullets (`- `), continuation lines indented two spaces, blank lines. No
 * heading of any level: [Unreleased] has none, check-release-claims.js
 * refuses a repeated `###` there, and "### Before you update" is parsed by the
 * updater's gate, so it is written in CHANGELOG.md itself.
 *
 * @returns {{ok: boolean, problems: string[]}}
 */
function checkFragment(file, text) {
  const problems = [];
  const f = String(file || '').trim();
  if (!FRAGMENT_NAME.test(f)) {
    problems.push(`${f}: a fragment is changelog.d/<name>.md — letters, digits, ".", "_", "-", starting with a letter or digit (a branch's "/" becomes "-")`);
  }
  const lines = String(text == null ? '' : text).replace(/\r\n/g, '\n').split('\n');
  if (!lines.some((l) => l.startsWith('- ') && l.trim().length > 2)) {
    problems.push(`${f}: no entry — write at least one line starting "- "`);
  }
  let seenBullet = false;
  lines.forEach((l, i) => {
    const at = `${f}:${i + 1}`;
    if (!l.trim()) return;
    if (/^\s*#/.test(l)) { problems.push(`${at}: no headings in a fragment ("${l.slice(0, 40)}") — a "Before you update" item goes in ${CHANGELOG} itself`); return; }
    if (l.startsWith('- ')) { seenBullet = true; return; }
    if (/^ {2,}\S/.test(l) && seenBullet) return;
    problems.push(`${at}: not an entry line ("${l.slice(0, 40)}") — start with "- ", or indent a continuation by two spaces`);
  });
  return { ok: problems.length === 0, problems };
}

const isWatched = (file) => WATCHED.some((m) => m(String(file || '').trim()));

/**
 * @param {string[]} files      paths changed, relative to the repo root
 * @param {string}   messages   the PR's commit messages, joined
 * @param {string[]} [fragments] fragments the PR ADDED or CHANGED (a deleted
 *                              one is the cut folding it, not an entry).
 *                              Defaults to the fragment paths in `files`.
 * @returns {{ok: boolean, reason: string, watched: string[]}}
 */
function verdict(files, messages = '', fragments) {
  const list = (Array.isArray(files) ? files : []).map((f) => String(f || '').trim()).filter(Boolean);
  const watched = list.filter(isWatched);
  const frags = (Array.isArray(fragments) ? fragments : list).map((f) => String(f || '').trim()).filter(isFragmentPath);

  if (!watched.length) {
    return { ok: true, reason: 'no shipped code changed', watched };
  }
  if (list.includes(CHANGELOG)) {
    return { ok: true, reason: `${CHANGELOG} was updated`, watched };
  }
  if (frags.length) {
    return { ok: true, reason: `a changelog fragment was written (${frags.join(', ')})`, watched };
  }
  // Case-insensitive: the marker is for humans, and "[No Changelog]" is the
  // same intent typed differently.
  if (String(messages || '').toLowerCase().includes(OVERRIDE)) {
    return { ok: true, reason: `${OVERRIDE} was given`, watched };
  }
  return { ok: false, reason: `shipped code changed and there is no changelog entry (no ${FRAGMENT_DIR}/ fragment, no ${CHANGELOG} line)`, watched };
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

/**
 * Is this PR a release? Any of: it ADDS a version section to CHANGELOG.md, or
 * it changes the version in package.json or mac/version.json.
 *
 * @param {{changelogDiff: string, versionBefore: (f)=>string|null, versionAfter: (f)=>string|null}} d
 * @returns {string[]} what makes it one, in words; empty when it is not
 */
function releaseSignals(d) {
  const out = [];
  for (const raw of String((d && d.changelogDiff) || '').split('\n')) {
    if (!raw.startsWith('+') || raw.startsWith('+++')) continue;
    const name = headingOf(raw.slice(1));
    if (name && name !== 'Unreleased') out.push(`it adds "## [${name}]" to ${CHANGELOG}`);
  }
  for (const f of ['package.json', 'mac/version.json']) {
    const a = d && d.versionBefore ? d.versionBefore(f) : null;
    const b = d && d.versionAfter ? d.versionAfter(f) : null;
    if (a && b && a !== b) out.push(`${f} goes from ${a} to ${b}`);
  }
  return out;
}

/** Everything in changelog.d/ but its README: the one rule for "waiting" (the fold's --check and cut-release.yml say the same). */
function waitingFragments(names) {
  return (Array.isArray(names) ? names : []).map(String).filter((n) => n && n !== 'README.md').sort();
}

module.exports = { verdict, isWatched, WATCHED, OVERRIDE, CHANGELOG, placement, checkFragment, isFragmentPath, FRAGMENT_DIR, releaseSignals, waitingFragments };

if (require.main === module) {
  const { execFileSync } = require('child_process');
  const fs = require('fs');
  const path = require('path');
  const base = process.env.BASE_REF || process.argv[2] || 'main';
  // From the repo root whatever the cwd, and paths exactly as written (no
  // octal quoting of a non-ASCII name, which would hide it from the rules).
  const sh = (args) => execFileSync('git', ['-c', 'core.quotePath=false', ...args], { encoding: 'utf8', cwd: TOP });
  const TOP = (() => { try { return execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim(); } catch (_) { return process.cwd(); } })();
  const nul = (s) => String(s || '').split('\0').filter(Boolean);

  let files = [];
  let messages = '';
  let fragments = [];
  let releasing = [];
  let leftover = [];
  let deleted = [];
  try {
    files = nul(sh(['diff', '-z', '--name-only', `${base}...HEAD`]));
    messages = sh(['log', '--format=%B', `${base}..HEAD`]);
    // ADDED only. A fragment that was already on the base is another PR's
    // entry: editing or renaming it is not this PR writing its own (review of #2706).
    // --no-renames: a rename is the old name deleted and a new one added, and
    // the deletion is judged below.
    const inDir = (f) => f.startsWith(FRAGMENT_DIR + '/') && f !== FRAGMENT_DIR + '/README.md';
    fragments = nul(sh(['diff', '-z', '--no-renames', '--name-only', '--diff-filter=A', `${base}...HEAD`, '--', FRAGMENT_DIR])).filter(inDir);
    deleted = nul(sh(['diff', '-z', '--no-renames', '--name-only', '--diff-filter=D', `${base}...HEAD`, '--', FRAGMENT_DIR])).filter(inDir);
    releasing = releaseSignals({
      changelogDiff: files.includes(CHANGELOG) ? sh(['diff', '--unified=0', `${base}...HEAD`, '--', CHANGELOG]) : '',
      versionBefore: (f) => { try { return JSON.parse(sh(['show', `${base}:${f}`])).version || null; } catch (_) { return null; } },
      versionAfter: (f) => { try { return JSON.parse(fs.readFileSync(path.join(TOP, f), 'utf8')).version || null; } catch (_) { return null; } },
    });
    leftover = waitingFragments(fs.existsSync(path.join(TOP, FRAGMENT_DIR)) ? fs.readdirSync(path.join(TOP, FRAGMENT_DIR)) : []);
  } catch (e) {
    // A missing base ref is a CI wiring fault, not a contributor's fault —
    // failing the PR for it would teach people to ignore this check.
    process.stdout.write(`changelog check skipped — could not diff against "${base}": ${(e && e.message) || e}\n`);
    process.exit(0);
  }

  // A RELEASE PR must carry every entry its tag will carry. A fragment that
  // lands while the release PR's CI runs comes in with the rebase, with no
  // conflict; caught only at tag time, it could be filed nowhere but
  // [Unreleased] (the placement rule) and missed its release. The tree that
  // will merge is checked here: the PR's own under `strict`, and since the
  // merge queue (Nov 26) the queue's run as well, which sees every PR ahead of
  // this one (review of #2706; ci.yml runs this on merge_group).
  if (releasing.length && leftover.length) {
    process.stderr.write(
      `\nchangelog check failed — this is a release (${releasing.join('; ')}), and ${FRAGMENT_DIR}/ still ` +
      `holds entries that are not in ${CHANGELOG}:\n\n` + leftover.map((f) => `  ${FRAGMENT_DIR}/${f}\n`).join('') +
      `\nRun "npm run changelog:fold" again and file them in this release's section.\n`
    );
    process.exit(1);
  }

  // In the merge queue only the release rule above can change between the
  // PR's own run and the merge (another PR's fragment landing ahead). The rest
  // was decided on the PR, and the queue's commits do not carry the PR's own
  // messages, so a "[no changelog]" there would read as missing and stall the
  // queue for a PR that was right.
  if (process.env.CHANGELOG_CHECK_SCOPE === 'release') {
    process.stdout.write(`changelog check ok — merge queue: ${releasing.length ? 'a release with no fragments waiting' : 'not a release'}\n`);
    process.exit(0);
  }

  // Only the fold removes a fragment that is already on main, and the fold
  // writes its lines into CHANGELOG.md in the same PR. Anything else that
  // removes one (or renames, or rewrites-and-renames it) drops another PR's
  // entry before any release could carry it.
  if (deleted.length && !files.includes(CHANGELOG)) {
    process.stderr.write(
      `\nchangelog check failed — this removes ${deleted.length === 1 ? 'an entry' : 'entries'} another pull request wrote, ` +
      `and puts ${deleted.length === 1 ? 'it' : 'them'} nowhere:\n\n` + deleted.map((f) => `  ${f}\n`).join('') +
      `\nWrite your own entry in a new file of yours, and leave these as they are. Only the\n` +
      `release cut removes them, by folding them into ${CHANGELOG} (npm run changelog:fold).\n`
    );
    process.exit(1);
  }

  // Every fragment the PR wrote must be one the fold can take as it stands.
  const bad = [];
  for (const f of fragments) {
    let text = '';
    try { text = fs.readFileSync(path.join(TOP, f), 'utf8'); } catch (e) { bad.push(`${f}: unreadable — ${(e && e.message) || e}`); continue; }
    bad.push(...checkFragment(f, text).problems);
  }
  if (bad.length) {
    process.stderr.write(
      `\nchangelog check failed — a fragment the release cut could not fold as written:\n\n` +
      bad.map((p) => `  ${p}\n`).join('') +
      `\nA fragment holds what you would have added under "## [Unreleased]": lines\n` +
      `starting "- ", continuation lines indented two spaces, blank lines. See\n` +
      `${FRAGMENT_DIR}/README.md.\n`
    );
    process.exit(1);
  }

  const r = verdict(files, messages, fragments);

  // WHERE it landed, whenever the file was touched at all — including by a PR
  // that changed no shipped code, since a misplaced entry is misplaced either
  // way.
  if (files.includes(CHANGELOG)) {
    let where = { ok: true, misplaced: [] };
    try {
      const diff = sh(['diff', '--unified=3', `${base}...HEAD`, '--', CHANGELOG]);
      where = placement(diff, fs.readFileSync(path.join(TOP, CHANGELOG), 'utf8'));
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
    `\nWrite what a shop would notice in ${FRAGMENT_DIR}/<your-branch>.md, one line\n` +
    `starting "- " (see ${FRAGMENT_DIR}/README.md). It is folded into ${CHANGELOG}\n` +
    `at the release cut, and unlike a line in ${CHANGELOG} it never conflicts.\n` +
    `If a shop would notice nothing, put ${OVERRIDE} in the commit message.\n`
  );
  process.exit(1);
}
