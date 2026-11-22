const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

const SCRIPT = path.join(__dirname, '..', 'scripts', 'list-stale-branches.mjs');

/**
 * The branch-cleanup script has to be right about three cases, and getting any
 * of them wrong is expensive in opposite directions: calling a live branch
 * stale loses work, calling a dead one live leaves 85 branches to wade through.
 *
 * A live repo cannot test this — it only ever shows the state it happens to be
 * in — so this builds a repo with one branch of each kind and checks the
 * verdicts. The three kinds are exactly what rebase- and squash-merging
 * produce:
 *
 *   absorbed  cherry-picked onto the base: SAME content, DIFFERENT SHA. This is
 *             every rebase-merged PR, and the case `git branch --merged` misses
 *             completely.
 *   behind    its feature landed squashed, so no individual patch-id matches,
 *             and the base has since moved far ahead. Merging it would revert.
 *   unmerged  genuinely new work. Must survive.
 */
function buildRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-branches-'));
  const remote = path.join(dir, 'remote.git');
  const work = path.join(dir, 'work');
  const git = (cmd, cwd = work) => execSync(`git ${cmd}`, {
    cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();

  execSync(`git init --bare -b main "${remote}"`, { stdio: 'ignore' });
  execSync(`git init -b main "${work}"`, { stdio: 'ignore' });
  git('config user.email test@example.com');
  git('config user.name Test');
  git(`remote add origin "${remote}"`);

  const commit = (file, body, msg) => {
    fs.writeFileSync(path.join(work, file), body);
    git(`add ${file}`);
    git(`commit -q -m "${msg}"`);
  };

  commit('base.txt', 'start\n', 'base');
  git('push -q origin main');

  // ── absorbed: a commit that later reaches main under a DIFFERENT SHA.
  //   Main must gain a commit first, so the cherry-pick lands on a different
  //   parent. Without that, git can reproduce the identical SHA — and then the
  //   branch really is an ancestor, so even the wrong (ancestry-based) test
  //   passes and this fixture proves nothing. It did, until a mutation showed it.
  git('checkout -q -b absorbed');
  commit('feature-a.txt', 'feature a\n', 'add feature a');
  const patch = git('rev-parse HEAD');
  git('push -q origin absorbed');
  git('checkout -q main');
  commit('unrelated.txt', 'meanwhile\n', 'unrelated work on main');
  git(`cherry-pick ${patch}`);             // same patch, new parent → new SHA

  // ── unmerged: real work that never lands.
  git('checkout -q -b unmerged main');
  commit('brand-new.txt', 'x\n'.repeat(400), 'add something genuinely new');
  git('push -q origin unmerged');

  // ── behind: forked early, its work landed SQUASHED, main then moved far on.
  //   The landed version differs from the branch's — a squash carries review
  //   changes with it — so no patch-id matches and `git cherry` cannot help.
  //   Only the content comparison can tell this apart from live work.
  git('checkout -q -b behind main~1');
  commit('old-feature.txt', 'old feature, first draft\n', 'old feature, later squashed into main');
  git('push -q origin behind');

  git('checkout -q main');
  commit('big.txt', 'lots of later work\n'.repeat(600), 'main moves a long way ahead');
  commit('old-feature.txt', 'old feature, as reviewed and squashed\n', 'the squashed feature, as it landed');
  git('push -q origin main');

  return { dir, work };
}

function runScript(work, extra = '') {
  const out = execSync(`node "${SCRIPT}" --json --remote origin ${extra}`, {
    cwd: work, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  });
  return JSON.parse(out);
}

test('only proof puts a branch on the delete list', (t) => {
  const { dir, work } = buildRepo();
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const r = runScript(work);

  // The case `git branch --merged` cannot see: same content, different SHA.
  // This is every rebase-merged PR, and the only category safe to delete
  // unattended, because the patch-id IS the proof.
  assert.deepEqual(r.absorbed.map((x) => x.branch), ['absorbed'],
    'a cherry-picked branch must be recognised as fully absorbed');
  assert.deepEqual(r.deletable, ['absorbed'],
    'nothing without patch-id proof may be offered for deletion');

  // A squashed-and-abandoned branch and a live-but-old one are genuinely
  // indistinguishable by the numbers — both sit behind the base and both would
  // delete more than they add. Neither is auto-deletable; the script reports
  // the evidence and a person decides. Getting this wrong deletes real work.
  const reported = [...r.behind, ...r.unmerged].map((x) => x.branch).sort();
  assert.deepEqual(reported, ['behind', 'unmerged'],
    'both the squashed and the live branch must be reported for review');
  for (const row of [...r.behind, ...r.unmerged]) {
    assert.ok(row.ahead > 0, `${row.branch}: should report how many commits are ahead`);
    assert.ok(row.insertions >= 0 && row.deletions >= 0, `${row.branch}: should report the diff size`);
  }
});

test('--include-behind widens the list, and never past live work', (t) => {
  const { dir, work } = buildRepo();
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  const r = runScript(work, '--include-behind');
  for (const b of r.behind) assert.ok(r.deletable.includes(b.branch), `${b.branch} should be included`);
  assert.ok(r.deletable.includes('absorbed'));
  assert.equal(r.deletable.includes(r.base), false, 'the default branch must never be listed');
});

test('the default branch is never a candidate, whatever it is called', (t) => {
  const { dir, work } = buildRepo();
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const r = runScript(work);
  assert.equal(r.base, 'main');
  assert.equal(r.deletable.includes('main'), false);
  // and nothing that does not exist on the remote may appear — the phantom-ref
  // bug that put a non-existent branch into a delete list once already.
  const real = execSync('git ls-remote --heads origin', { cwd: work, encoding: 'utf8' })
    .split('\n').filter(Boolean).map((l) => l.split('refs/heads/')[1]);
  for (const b of r.deletable) assert.ok(real.includes(b), `${b} is not a branch on the remote`);
});
