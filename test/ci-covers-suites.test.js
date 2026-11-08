const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const ci = fs.readFileSync(path.join(ROOT, '.github/workflows/ci.yml'), 'utf8');

/**
 * A test suite nobody runs is a file that looks like coverage and is not.
 *
 * `npm test` runs the UNIT suite only — `node --test test/*.test.js`. Every e2e
 * suite is a separate npm script that runs ONLY if ci.yml names it, so adding
 * `test:e2e:whatever` to package.json and stopping there produces a suite that
 * never executes, passes review, and protects nothing. It cannot fail, so it
 * never tells anyone it is not running.
 *
 * Found on 2026-08-28, before a release: two suites were in that state.
 * `test:e2e:consumables` and — the one that matters — `test:e2e:cloudstorage`,
 * which covers print-library tiering: the 3.7.0 line's headline feature and the
 * only deliberately destructive thing in the print library, since it MOVES a
 * shop's files off its disk. Both passed when finally run; the suites were fine,
 * they were simply never asked anything.
 *
 * This is the same defect as the rest of that week in a different costume: a
 * guard that silently is not a guard.
 */

/**
 * `test:e2e:all` is not a suite. It RUNS the suites — locally, in one command,
 * reading the list from package.json so it cannot drift.
 *
 * It exists because the same defect this file is about bit again from the other
 * side: forty-five e2e suites, and it is far too easy to run two of them, see
 * two greens and push. A change that moved order creation into a shared module
 * reached CI with `NewOrderRules is not defined` — caught by `test:e2e:qc`, and
 * by nothing else that had been run.
 *
 * Excluded from the coverage check rather than added to ci.yml: CI already runs
 * every suite by name, and naming this one too would run all forty-five a second
 * time. Its own test below proves it actually covers them.
 */
const RUNNER = 'test:e2e:all';

const e2eScripts = Object.keys(pkg.scripts)
  .filter((k) => k.startsWith('test:e2e'))
  .filter((k) => k !== RUNNER);

/**
 * Suites deliberately not in ci.yml, each with the reason and where it DOES run.
 * An entry here is a decision; an absence is an accident.
 */
const ELSEWHERE = {
  // Needs a macOS runner with an iOS 27 SDK, so it lives in ios-contract.yml,
  // whose `ios-relevant` job skips it on PRs that touch nothing the phone
  // builds from (CLAUDE.md, "Required: LAN server and companion models").
  'test:ios-contract': '.github/workflows/ios-contract.yml',
};

test('every e2e suite is actually run by CI', () => {
  const missing = e2eScripts.filter((s) => !ci.includes(`npm run ${s}`) && !(s in ELSEWHERE));
  assert.deepEqual(missing, [], missing.length
    ? `these suites exist and run nowhere:\n  ${missing.join('\n  ')}\n` +
      `Add a step to .github/workflows/ci.yml, or list it in ELSEWHERE here with ` +
      `the workflow that does run it and why.`
    : undefined);
});

test('every suite CI names is a script that exists', () => {
  // The other direction: a renamed script leaves ci.yml running `npm run` on a
  // name npm does not have. npm exits non-zero, so this one is loud rather than
  // silent — but it fails the whole job with "Missing script", which is a worse
  // place to find out than here.
  const named = [...ci.matchAll(/npm run (test:[a-z0-9:]+)/g)].map((m) => m[1]);
  const unknown = [...new Set(named)].filter((s) => !(s in pkg.scripts));
  assert.deepEqual(unknown, [], `ci.yml runs scripts that do not exist: ${unknown.join(', ')}`);
});

test('the suites named as running elsewhere really do', () => {
  // An ELSEWHERE entry is a claim about another file, and a claim nobody checks
  // is how the first list went stale.
  for (const [script, workflow] of Object.entries(ELSEWHERE)) {
    const abs = path.join(ROOT, workflow);
    assert.ok(fs.existsSync(abs), `${script} claims to run in ${workflow}, which does not exist`);
    assert.match(fs.readFileSync(abs, 'utf8'), new RegExp(`npm run ${script.replace(/:/g, ':')}`),
      `${workflow} does not run ${script}`);
  }
});

test('the runner runs every suite CI does', () => {
  // The exclusion above is a claim: that `test:e2e:all` covers what it is
  // excused from being listed for. A runner with a hard-coded list that had
  // gone stale would be worse than no runner, because it reports green.
  assert.ok(RUNNER in pkg.scripts, 'test:e2e:all has gone missing');
  const runner = fs.readFileSync(path.join(ROOT, 'scripts/e2e-all.mjs'), 'utf8');
  assert.match(runner, /pkg\.scripts/,
    'the runner writes its own list down instead of reading package.json, so it can drift');
  assert.match(runner, /startsWith\('test:e2e:'\)/, 'the runner does not select the e2e scripts');
  assert.match(runner, new RegExp(`!== '${RUNNER}'`),
    'the runner does not exclude itself, so it would run forever');
});
