#!/usr/bin/env node
/**
 * Every end-to-end smoke, in one command.
 *
 * There are forty-five of them and CI runs all forty-five. Locally it is far
 * too easy to run `test:e2e` and `test:e2e:bedready`, see two greens, and push
 * — which is exactly how a change that moved order creation into a shared
 * module reached CI with `NewOrderRules is not defined`, caught by
 * `test:e2e:qc` and by nothing else I had run.
 *
 * The list is READ FROM package.json rather than written down here, so it
 * cannot drift from the scripts that exist. `--only <substring>` runs the
 * matching ones when you know which area you touched.
 */
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));

/**
 * How long one suite may take before it is called hung.
 *
 * Every suite launches Electron, does its thing and quits; the slowest honest
 * one is well under a minute. Three is generous enough that a slow machine is
 * not reported as a hang, and short enough that a stuck suite does not eat an
 * afternoon.
 */
const TIMEOUT_MS = Number(process.env.KHAYT_E2E_TIMEOUT_MS || 180_000);

/**
 * Suites that pass and then do not exit, on this platform only.
 *
 * `test:e2e:david` prints "all assertions passed" and hangs in
 * `electronApp.close()` on macOS — it is the only suite that drives the print
 * flow (`generateWorkOrder`, `generateDeliveryNote`), and there is no print
 * system under the xvfb CI runs on. CI passes it; a local run sat on it for
 * ninety minutes.
 *
 * Reported as SKIP rather than run, because an all-suites command that is
 * always one red is a command nobody reads. It still runs in CI, which is where
 * the claim is actually checked — and `--only david` runs it here anyway for
 * anyone who wants to watch it hang.
 */
const HANGS_LOCALLY = {
  'test:e2e:david': 'hangs in electronApp.close() on macOS after passing; CI runs it under xvfb',
};

const only = (() => {
  const i = process.argv.indexOf('--only');
  return i === -1 ? null : process.argv[i + 1];
})();

const suites = Object.keys(pkg.scripts)
  .filter((s) => s === 'test:e2e' || s.startsWith('test:e2e:'))
  // `test:e2e:all` is this file; running it from itself would not end.
  .filter((s) => s !== 'test:e2e:all')
  .filter((s) => !only || s.includes(only))
  .sort();

if (suites.length === 0) {
  process.stderr.write(only ? `no e2e suite matches "${only}"\n` : 'no e2e suites found\n');
  process.exit(1);
}

process.stdout.write(`running ${suites.length} e2e suite(s)\n\n`);
const failed = [];
const started = Date.now();

for (const suite of suites) {
  // Named explicitly with --only, run it anyway: the point of the exemption is
  // to keep the default run honest, not to make the suite unreachable.
  if (!only && suite in HANGS_LOCALLY) {
    process.stdout.write(`  skip ${suite.padEnd(28)} ${HANGS_LOCALLY[suite]}\n`);
    continue;
  }
  const at = Date.now();
  const run = spawnSync('npm', ['run', '--silent', suite], {
    cwd: root, encoding: 'utf8', timeout: TIMEOUT_MS, killSignal: 'SIGKILL',
  });
  const secs = ((Date.now() - at) / 1000).toFixed(1);
  // A HANG IS NOT A PASS AND NOT A FAILURE, and it needs its own word. The
  // first run of this script sat on one suite for ninety minutes: every other
  // suite had finished in under ten seconds, and there was nothing on screen
  // to say which one was stuck or that anything was wrong. `spawnSync` reports
  // a timeout as `error.code === 'ETIMEDOUT'`, not as an exit status.
  const timedOut = run.error && run.error.code === 'ETIMEDOUT';
  const ok = !timedOut && run.status === 0;
  if (!ok) {
    failed.push({
      suite,
      output: timedOut
        ? `timed out after ${TIMEOUT_MS / 1000}s — the app was left running and had to be killed\n`
          + `${run.stdout || ''}${run.stderr || ''}`
        : `${run.stdout || ''}${run.stderr || ''}`,
    });
  }
  process.stdout.write(`${ok ? '  ok  ' : timedOut ? '  HUNG' : '  FAIL'} ${suite.padEnd(28)} ${secs}s\n`);
}

const total = ((Date.now() - started) / 1000).toFixed(0);
if (failed.length === 0) {
  const skipped = only ? 0 : suites.filter((s) => s in HANGS_LOCALLY).length;
  process.stdout.write(`\nall ${suites.length - skipped} e2e suites passed in ${total}s`
    + (skipped ? ` (${skipped} skipped locally — CI runs them)\n` : '\n'));
  process.exit(0);
}

// The whole output of each failure, at the end, so a run left in a scrollback
// still says what broke.
for (const f of failed) {
  process.stderr.write(`\n${'='.repeat(70)}\n${f.suite}\n${'='.repeat(70)}\n`);
  process.stderr.write(f.output.split('\n').slice(-40).join('\n') + '\n');
}
process.stderr.write(`\n${failed.length} of ${suites.length} e2e suites failed: ${failed.map((f) => f.suite).join(', ')}\n`);
process.exit(1);
