#!/usr/bin/env node
/**
 * Every commit must carry the DCO sign-off CONTRIBUTING.md already requires.
 *
 * CONTRIBUTING.md says "PRs without a sign-off can't be merged". That was not
 * true: no check enforced it, so an unsigned PR merged exactly like a signed
 * one. A rule documented but unenforced is worse than no rule — it reads as a
 * gate to contributors who follow it and is invisible to everyone else, and the
 * sign-off is what carries a contribution into both the FSL and the commercial
 * license (see CLA.md). This makes the sentence true.
 *
 * What it asks for is exactly what `git commit -s` produces:
 *
 *   Signed-off-by: Your Name <you@example.com>
 *
 * The email must match the commit's author email, because the DCO is the AUTHOR
 * certifying their own work — a sign-off in someone else's name certifies
 * nothing. That is also the most common way this fails: committing from the
 * GitHub web UI authors as `…@users.noreply.github.com` while `git config` at
 * home says something else, so the trailer and the author disagree.
 *
 * Merge commits are exempt, and that exemption is load-bearing rather than
 * lazy: `main` requires branches to be up to date, so every PR that goes stale
 * gets an "Update branch" merge commit created by GitHub, which no human wrote
 * and nobody can sign. Demanding a sign-off there would fail PRs for the act of
 * keeping them current.
 */
'use strict';

const TRAILER = /^\s*Signed-off-by:\s*(.+?)\s*<([^>]+)>\s*$/i;

/**
 * Where to look for the base branch when nobody names one, in order.
 *
 * The local `main` branch is LAST on purpose. In a worktree it is a ref nothing
 * updates: you never check it out, so it sits at whatever `main` was when the
 * worktree was created. Every commit merged into the real main since then still
 * counts as "on this branch", and this guard then blames the author of a squash
 * commit GitHub wrote — reporting a failure that says nothing about the work
 * being checked, on a branch that is perfectly signed.
 *
 * A remote-tracking ref is what the PR is actually diffed against, and `git
 * fetch` keeps it current without anyone checking anything out.
 */
const DEFAULT_BASE_CANDIDATES = Object.freeze([
  // What local `main` follows, whatever the remote happens to be called.
  'main@{upstream}',
  // This repo's canonical remote; `origin` is a fork for most contributors.
  'upstream/main',
  'origin/main',
  // A plain clone with no remote at all — a fresh `git init`, or an archive.
  'main',
]);

/**
 * First candidate that resolves to a commit.
 *
 * @param {string} explicit    BASE_REF or argv — an answer, not a guess
 * @param {(ref: string) => boolean} exists
 * @param {string[]} candidates
 * @returns {{ref: string|null, explicit: boolean}}
 *
 * An explicit base is returned unchecked: CI sets it, and if it is wrong the
 * caller reports "base ref not found" rather than silently searching for a
 * different branch and validating against something nobody asked for.
 */
function resolveBaseRef(explicit, exists, candidates = DEFAULT_BASE_CANDIDATES) {
  if (explicit) return { ref: explicit, explicit: true };
  for (const ref of candidates) {
    if (exists(ref)) return { ref, explicit: false };
  }
  return { ref: null, explicit: false };
}

/** `Turki <a@b.c>` -> `a@b.c`, lowercased. Anything unparseable -> ''. */
const normalizeEmail = (email) => String(email || '').trim().toLowerCase();

/**
 * @param {{sha: string, author: string, email: string, body: string}[]} commits
 * @returns {{ok: boolean, reason: string, unsigned: object[]}}
 */
function verdict(commits) {
  const list = Array.isArray(commits) ? commits : [];
  if (!list.length) {
    // Nothing to certify. An empty range is a CI wiring question, not a
    // contributor error, so it must not fail the PR.
    return { ok: true, reason: 'no commits to check', unsigned: [] };
  }

  const unsigned = [];
  for (const c of list) {
    const author = normalizeEmail(c.email);
    const signoffs = String(c.body || '')
      .split('\n')
      .map((line) => TRAILER.exec(line))
      .filter(Boolean)
      .map((m) => ({ name: m[1], email: normalizeEmail(m[2]) }));

    if (!signoffs.length) {
      unsigned.push({ ...c, why: 'no Signed-off-by line' });
      continue;
    }
    if (!signoffs.some((s) => s.email === author)) {
      unsigned.push({
        ...c,
        why: `signed off by ${signoffs.map((s) => s.email).join(', ')}, but authored by ${author}`,
      });
    }
  }

  if (unsigned.length) {
    return {
      ok: false,
      reason: `${unsigned.length} of ${list.length} commit(s) are not signed off`,
      unsigned,
    };
  }
  return { ok: true, reason: `${list.length} commit(s) signed off`, unsigned: [] };
}

module.exports = { verdict, normalizeEmail, TRAILER, resolveBaseRef, DEFAULT_BASE_CANDIDATES };

if (require.main === module) {
  const { execFileSync } = require('child_process');
  const refExists = (ref) => {
    try {
      execFileSync('git', ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`], { stdio: 'ignore' });
      return true;
    } catch { return false; }
  };
  const chosen = resolveBaseRef(process.env.BASE_REF || process.argv[2], refExists);
  const base = chosen.ref || 'main';
  // Field/record separators. These are git's OWN escapes: git writes 0x1f/0x1e
  // into its output, while argv carries only the literal text "%x1f". Passing a
  // real NUL here instead throws ERR_INVALID_ARG_VALUE — which the catch below
  // used to report as "skipped, exit 0", i.e. a guard that passed everything.
  const FIELD = '\x1f';
  const RECORD = '\x1e';

  // A base ref that does not exist is a CI wiring fault, not a contributor's,
  // and failing the PR for it would teach people to ignore this check. Anything
  // ELSE going wrong is this script's bug and must fail loudly: a DCO gate that
  // exits 0 when it is broken is worse than no gate, because it reports green.
  if (!refExists(base)) {
    process.stdout.write(`DCO check skipped — base ref "${base}" not found in this checkout\n`);
    process.exit(0);
  }

  // --no-merges: see the header. %H sha, %an name, %ae author email, %B body.
  const raw = execFileSync(
    'git',
    ['log', '--no-merges', '--format=%H%x1f%an%x1f%ae%x1f%B%x1e', `${base}..HEAD`],
    { encoding: 'utf8' },
  );
  const commits = raw
    .split(RECORD)
    .map((chunk) => chunk.trim())
    .filter(Boolean)
    .map((chunk) => {
      const [sha, author, email, ...rest] = chunk.split(FIELD);
      return { sha: (sha || '').trim(), author, email, body: rest.join(FIELD) };
    });

  const r = verdict(commits);
  if (r.ok) {
    process.stdout.write(`DCO check ok — ${r.reason} (vs ${base})\n`);
    process.exit(0);
  }

  process.stderr.write(
    `\nDCO check failed — ${r.reason}, comparing against ${base}.\n\n` +
    r.unsigned.slice(0, 20).map((c) => `  ${c.sha.slice(0, 8)}  ${c.why}\n`).join('') +
    (r.unsigned.length > 20 ? `  …and ${r.unsigned.length - 20} more\n` : '') +
    `\nSign off by amending or rebasing so every commit ends with a line matching\n` +
    `its own author email:\n\n` +
    `  Signed-off-by: Your Name <you@example.com>\n\n` +
    `  git commit -s            # on the next commit\n` +
    `  git commit -s --amend    # to fix the most recent one\n` +
    `  git rebase --signoff ${base}   # to fix every commit on this branch\n\n` +
    `This certifies you wrote the change and agree to the CLA (CLA.md), which is\n` +
    `what lets it be carried under both licenses. See CONTRIBUTING.md.\n`
  );
  process.exit(1);
}
