#!/usr/bin/env node
/**
 * List remote branches whose work is already on the default branch.
 *
 * WHY THIS IS NOT A ONE-LINER
 *
 * Every PR here is REBASE-merged, which rewrites each commit under a new SHA.
 * So the obvious tests are worse than useless:
 *
 *   git branch --merged main          → reports nothing merged
 *   git merge-base --is-ancestor …    → false for every merged branch
 *
 * Both once reported 0 of 85 branches as merged, which is pure noise. Two
 * checks do work, and this runs them in order:
 *
 *   1. `git cherry` compares by PATCH-ID, which survives the rebase. Zero '+'
 *      lines means every commit's content is already on the base.
 *
 *   2. Everything else is REPORTED, not judged. A branch that landed squashed
 *      has no matching patch-id and looks identical, by the numbers, to a live
 *      feature branch that is merely old: both are far behind, both would
 *      delete more than they add. Guessing between them risks deleting real
 *      work, so this prints the evidence — commits ahead, lines added and
 *      removed — and leaves the call to a person.
 *
 * Only proof gets a branch onto the delete list. `--include-behind` will add
 * the ones that look squashed-and-abandoned, for when you have checked them.
 *
 * Branch names come from `git ls-remote`, never from refs/remotes/*: a stale
 * local ref — or one invented by an odd fetch refspec — otherwise shows up as a
 * branch that does not exist, and lands in a delete list. That happened.
 *
 * Usage:
 *   npm run branches:stale                  # report only
 *   npm run branches:stale -- --command     # also print the delete command
 *   npm run branches:stale -- --json        # machine-readable
 *   npm run branches:stale -- --remote origin
 *
 * Deleting is left to you on purpose: it is the one step that cannot be undone
 * from here. Deleting a branch does NOT affect its pull request or any tag —
 * GitHub keeps both permanently.
 */
import { execSync } from 'child_process';

const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : fallback;
};

const asJson = flag('json');
const showCommand = flag('command');
// Squashed-and-abandoned branches look exactly like live-but-old ones by the
// numbers. They join the delete list only when you say you have checked them.
const includeBehind = flag('include-behind');

function fail(msg) {
  console.error(`list-stale-branches: ${msg}`);
  process.exit(1);
}

function git(cmd, { quiet = false } = {}) {
  try {
    return execSync(`git ${cmd}`, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', quiet ? 'ignore' : 'pipe'],
    }).trim();
  } catch (e) {
    if (quiet) return '';
    throw e;
  }
}

function pickRemote() {
  const remotes = git('remote').split('\n').filter(Boolean);
  if (!remotes.length) fail('this repository has no remotes');
  const explicit = opt('remote', null);
  if (explicit) {
    if (!remotes.includes(explicit)) fail(`no remote named "${explicit}" (have: ${remotes.join(', ')})`);
    return explicit;
  }
  // Releases publish from upstream in this repo, so prefer it when present.
  return remotes.includes('upstream') ? 'upstream' : remotes[0];
}

const remote = pickRemote();

/** The branch everything is measured against — the remote's own HEAD. */
function defaultBranch() {
  const head = git(`symbolic-ref --quiet refs/remotes/${remote}/HEAD`, { quiet: true });
  if (head) return head.replace(`refs/remotes/${remote}/`, '');
  for (const guess of ['main', 'master']) {
    if (git(`ls-remote --heads ${remote} ${guess}`, { quiet: true })) return guess;
  }
  return fail(`could not determine the default branch on ${remote}`);
}

const base = defaultBranch();

if (!asJson) console.error(`Fetching ${remote}…`);
git(`fetch ${remote} --prune --quiet`, { quiet: true });

// Authoritative list, straight from the remote.
const remoteBranches = git(`ls-remote --heads ${remote}`)
  .split('\n').filter(Boolean)
  .map((l) => l.split('refs/heads/')[1])
  .filter((b) => b && b !== base)
  .sort();

/** A branch with an open PR is never a candidate, whatever its content says. */
function openPrBranches() {
  const url = git(`remote get-url ${remote}`, { quiet: true });
  const repo = (url.match(/[:/]([^/]+\/[^/]+?)(?:\.git)?$/) || [])[1];
  if (!repo) return null;
  try {
    const out = execSync(
      `gh pr list --repo ${repo} --state open --limit 200 --json headRefName --jq '.[].headRefName'`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
    ).trim();
    return new Set(out ? out.split('\n') : []);
  } catch {
    return null;   // gh missing, unauthenticated, or offline
  }
}

const openPrs = openPrBranches();

const absorbed = [];   // every commit's content already on base
const behind = [];     // patch-ids differ, but the branch is plainly older than base
const unmerged = [];   // real work not on base
const skipped = [];

for (const b of remoteBranches) {
  const ref = `${remote}/${b}`;
  if (openPrs?.has(b)) { skipped.push({ branch: b, why: 'has an open pull request' }); continue; }
  if (!git(`rev-parse --verify --quiet ${ref}`, { quiet: true })) {
    skipped.push({ branch: b, why: 'no local tracking ref after fetch' });
    continue;
  }

  const ahead = git(`cherry ${remote}/${base} ${ref}`, { quiet: true })
    .split('\n').filter((l) => l.startsWith('+')).length;
  if (ahead === 0) { absorbed.push({ branch: b }); continue; }

  const stat = git(`diff --shortstat ${remote}/${base}..${ref}`, { quiet: true });
  const insertions = +(stat.match(/(\d+) insertion/) || [, 0])[1];
  const deletions = +(stat.match(/(\d+) deletion/) || [, 0])[1];
  (deletions > insertions ? behind : unmerged).push({ branch: b, ahead, insertions, deletions });
}

const deletable = [...absorbed, ...(includeBehind ? behind : [])].map((r) => r.branch).sort();

if (asJson) {
  console.log(JSON.stringify({ remote, base, absorbed, behind, unmerged, skipped, deletable, includeBehind }, null, 2));
  process.exit(0);
}

const pad = (s, n) => String(s).padEnd(n);
console.log(`\n${remoteBranches.length} branch(es) on ${remote}, measured against ${base}\n`);

console.log(`✔ ${absorbed.length} fully absorbed — every commit's content is already on ${base}`);
for (const r of absorbed.slice(0, 8)) console.log(`    ${r.branch}`);
if (absorbed.length > 8) console.log(`    … and ${absorbed.length - 8} more`);

if (behind.length) {
  console.log(`\n? ${behind.length} behind ${base} — possibly squashed and abandoned, possibly just old.`);
  console.log('  Check whether the work is on ' + base + ' before deleting; add --include-behind to list them.');
  for (const r of behind) {
    console.log(`    ${pad(r.branch, 34)} would add ${pad(r.insertions, 8)} delete ${r.deletions}`);
  }
}

if (unmerged.length) {
  console.log(`\n✋ ${unmerged.length} carrying work not on ${base} — left alone`);
  for (const r of unmerged) {
    console.log(`    ${pad(r.branch, 34)} ${r.ahead} unmerged commit(s), +${r.insertions}/-${r.deletions}`);
  }
}

if (skipped.length) {
  console.log(`\n— ${skipped.length} skipped`);
  for (const r of skipped) console.log(`    ${pad(r.branch, 34)} ${r.why}`);
}

if (openPrs === null) {
  console.log('\n⚠ Could not check for open pull requests (gh missing or not authenticated).');
  console.log('  Confirm none of the branches below has one before deleting.');
}

console.log(`\n${deletable.length} branch(es) safe to delete.`);
if (!deletable.length) process.exit(0);

if (showCommand) {
  console.log('\nReview the list above, then run:\n');
  const lines = [];
  for (let i = 0; i < deletable.length; i += 4) lines.push(`    ${deletable.slice(i, i + 4).join(' ')}`);
  console.log(`  git push ${remote} --delete \\\n${lines.join(' \\\n')}\n`);
} else {
  console.log('Re-run with --command to print the delete command.');
}
