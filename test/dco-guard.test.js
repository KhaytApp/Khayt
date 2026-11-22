const { test } = require('node:test');
const assert = require('node:assert/strict');
const { verdict } = require('../scripts/check-dco.js');

/**
 * CONTRIBUTING.md claimed unsigned PRs "can't be merged" while nothing checked,
 * so they could. These pin down what the guard demands and — the part that
 * decides whether it survives — what it must NOT block: a guard that fails a PR
 * for GitHub's own "Update branch" merge gets switched off within a week.
 */

const commit = (over = {}) => ({
  sha: 'a'.repeat(40),
  author: 'Turki Alballaa',
  email: 'alballaa@gmail.com',
  body: 'do a thing',
  ...over,
});

test('a commit with no sign-off is refused', () => {
  const r = verdict([commit()]);
  assert.equal(r.ok, false);
  assert.equal(r.unsigned.length, 1);
  assert.match(r.unsigned[0].why, /no Signed-off-by/);
});

test('a properly signed commit passes', () => {
  const r = verdict([commit({ body: 'do a thing\n\nSigned-off-by: Turki Alballaa <alballaa@gmail.com>' })]);
  assert.equal(r.ok, true);
});

test('the sign-off email must be the AUTHOR — someone else signing certifies nothing', () => {
  const r = verdict([commit({ body: 'do a thing\n\nSigned-off-by: Someone Else <someone@else.com>' })]);
  assert.equal(r.ok, false);
  assert.match(r.unsigned[0].why, /authored by alballaa@gmail\.com/);
});

test('email comparison ignores case, so GitHub casing quirks do not fail a real sign-off', () => {
  const r = verdict([commit({ email: 'Alballaa@Gmail.com', body: 'x\n\nSigned-off-by: T <alballaa@gmail.com>' })]);
  assert.equal(r.ok, true);
});

test('several sign-offs pass as long as one is the author', () => {
  const body = 'x\n\nSigned-off-by: Reviewer <rev@example.com>\nSigned-off-by: Turki Alballaa <alballaa@gmail.com>';
  assert.equal(verdict([commit({ body })]).ok, true);
});

test('a Co-Authored-By line is not a sign-off', () => {
  const r = verdict([commit({ body: 'x\n\nCo-Authored-By: Claude <noreply@anthropic.com>' })]);
  assert.equal(r.ok, false);
});

test('one unsigned commit among signed ones still fails, and names only that one', () => {
  const signed = commit({ sha: 'b'.repeat(40), body: 'x\n\nSigned-off-by: T <alballaa@gmail.com>' });
  const r = verdict([signed, commit({ sha: 'c'.repeat(40) })]);
  assert.equal(r.ok, false);
  assert.equal(r.unsigned.length, 1);
  assert.equal(r.unsigned[0].sha, 'c'.repeat(40));
});

test('an empty range passes — a CI wiring gap is not a contributor error', () => {
  assert.equal(verdict([]).ok, true);
  assert.equal(verdict(undefined).ok, true);
});

test('trailing whitespace and odd spacing in the trailer still count', () => {
  const r = verdict([commit({ body: 'x\n\nSigned-off-by:   Turki Alballaa   <alballaa@gmail.com>   ' })]);
  assert.equal(r.ok, true);
});

/* ── which branch it compares against ──────────────────────────────────── */

const { resolveBaseRef, DEFAULT_BASE_CANDIDATES } = require('../scripts/check-dco.js');

/**
 * The guard defaulted to the local `main` branch. In a git worktree that ref is
 * never checked out and so never moves: it holds whatever `main` was when the
 * worktree was created. Everything merged since then counts as "on this branch",
 * and the guard blames the author of a squash commit GitHub wrote — a failure
 * that says nothing about the work being checked, on a branch that is perfectly
 * signed. It reported exactly that three times in one day.
 */

/** Pretend only these refs exist. */
const has = (...refs) => (ref) => refs.includes(ref);

test('an explicit base wins, and is not second-guessed', () => {
  // CI passes origin/<base>. Quietly checking against a different branch than
  // the one asked for would validate the wrong range and still report green.
  const r = resolveBaseRef('origin/release-1.x', has('main'));
  assert.deepEqual(r, { ref: 'origin/release-1.x', explicit: true });
});

test('with no explicit base, what local main FOLLOWS is preferred over local main', () => {
  // The whole bug in one assertion.
  const r = resolveBaseRef('', has('main@{upstream}', 'main'));
  assert.equal(r.ref, 'main@{upstream}');
  assert.equal(r.explicit, false);
});

test('a detached local main still resolves, via the canonical remote', () => {
  // A worktree whose `main` tracks nothing has no @{upstream}.
  assert.equal(resolveBaseRef('', has('upstream/main', 'origin/main', 'main')).ref, 'upstream/main');
});

test('a contributor with only a fork remote gets origin/main', () => {
  assert.equal(resolveBaseRef('', has('origin/main', 'main')).ref, 'origin/main');
});

test('a clone with no remotes at all still works', () => {
  // A plain `git init`, or a source archive. Local main is the only thing there,
  // and in that case it is also correct — nothing else could be more current.
  assert.equal(resolveBaseRef('', has('main')).ref, 'main');
});

test('local main is the LAST resort, never the first', () => {
  assert.equal(DEFAULT_BASE_CANDIDATES[DEFAULT_BASE_CANDIDATES.length - 1], 'main');
  assert.ok(DEFAULT_BASE_CANDIDATES.indexOf('main@{upstream}') < DEFAULT_BASE_CANDIDATES.indexOf('main'));
});

test('when nothing resolves it says so rather than guessing', () => {
  // The caller turns a null ref into "base ref not found", which exits 0: a
  // missing base is a wiring fault, not a contributor error.
  assert.deepEqual(resolveBaseRef('', () => false), { ref: null, explicit: false });
});
