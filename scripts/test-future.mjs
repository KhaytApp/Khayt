#!/usr/bin/env node
/**
 * Run the unit suite with the clock advanced, to find fixtures that will rot.
 *
 *   npm run test:future            # +400 days
 *   npm run test:future -- 60      # or name the offset
 *
 * See scripts/clock-shift.js for why this exists and why grep cannot replace it.
 *
 * The preload has to reach the test runner's CHILD processes — `node --test`
 * forks one per file — so it goes through NODE_OPTIONS rather than a bare
 * `--require`, which would apply only to this process. Any NODE_OPTIONS already
 * set is preserved rather than clobbered.
 *
 * The file list is built here rather than left to a shell glob, so this behaves
 * identically on every platform and matches exactly what `npm test` runs.
 */
import { spawnSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const days = Number(process.argv[2] || process.env.CLOCK_SHIFT_DAYS || 400);

if (!Number.isFinite(days) || days <= 0) {
  console.error(`test:future needs a positive number of days, got ${JSON.stringify(process.argv[2])}`);
  process.exit(2);
}

const files = readdirSync(path.join(ROOT, 'test'))
  .filter((f) => f.endsWith('.test.js'))
  .sort()
  .map((f) => path.join('test', f));

if (!files.length) {
  console.error('no test files found — refusing to report a pass over nothing');
  process.exit(2);
}

const preload = path.join(ROOT, 'scripts', 'clock-shift.js');
console.log(`Running ${files.length} test files with the clock +${days} days.\n`);

const r = spawnSync(process.execPath, ['--test', ...files], {
  cwd: ROOT,
  stdio: 'inherit',
  env: {
    ...process.env,
    CLOCK_SHIFT_DAYS: String(days),
    NODE_OPTIONS: `${process.env.NODE_OPTIONS || ''} --require ${JSON.stringify(preload)}`.trim(),
  },
});

process.exit(r.status === null ? 1 : r.status);
