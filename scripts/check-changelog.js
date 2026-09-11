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

module.exports = { verdict, isWatched, WATCHED, OVERRIDE, CHANGELOG };

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
