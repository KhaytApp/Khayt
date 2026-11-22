#!/usr/bin/env node
/**
 * Bed Ready packaging wrapper.
 *
 * Bed Ready ships on its OWN independent version line (1.0.0-*), distinct from
 * Khayt's 3.x. We want that version baked into the packaged app's package.json
 * (so app.getVersion(), the About screen, dmg/nsis filenames, and update feeds
 * all read Bed Ready's number) WITHOUT permanently mutating the source tree.
 *
 * TWO source-tree hazards this wrapper defends against, both specific to this
 * repo's layout (the Electron app lives at the project root):
 *   1. We must swap package.json's `version` to Bed Ready's for the build.
 *   2. electron-builder itself PRUNES the root package.json in place while
 *      packaging (drops scripts/devDependencies/build, keeps a production-only
 *      manifest) — the same in-place-rewrite hazard that makes `extraMetadata`
 *      unusable here. It does not restore it.
 * So we snapshot the exact source bytes of package.json AND package-lock.json up
 * front and restore them no matter how the process ends:
 *   - normal exit / build failure  -> finally block
 *   - Ctrl-C / SIGTERM / SIGHUP    -> signal handlers (finally does NOT run on a
 *     signal kill; without these a killed build leaves a corrupted source tree)
 *   - uncaught exception           -> handler
 * Every restore path verifies the bytes are identical again before exiting.
 *
 * And then it looks AGAIN. Verifying the restore only proves the write landed, not that
 * nothing will overwrite it next — and the prune in (2) is done by npm processes
 * electron-builder spawns, which `spawnSync` does not wait for, so one can outlive the
 * build and land after the restore. That is not theoretical: a pack left package.json
 * pruned and carrying Bed Ready's version having logged a byte-identical restore and
 * exited 0, and the checkout stayed broken until the next `npm run` failed. The guard
 * therefore settles, repairs anything that moved, and fails the build rather than exit
 * quietly on a file it cannot keep restored. See lib/source-guard.js.
 *
 * The swap is ephemeral: only the electron-builder subprocess ever sees the
 * modified package.json; the on-disk source is identical before and after.
 *
 * Usage:  node scripts/build-bedready.mjs --dir
 *         node scripts/build-bedready.mjs --mac --arm64
 *         BEDREADY_VERSION=1.0.0-beta.2 node scripts/build-bedready.mjs --linux --x64
 */
import { readFileSync, writeFileSync } from 'fs';
import { spawnSync } from 'child_process';
import { createRequire } from 'module';
import path from 'path';
import { fileURLToPath } from 'url';

const require = createRequire(import.meta.url);
const { createSourceGuard } = require('../lib/source-guard.js');

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');

// Bed Ready's independent version line. Override per-release via BEDREADY_VERSION.
const BEDREADY_VERSION = process.env.BEDREADY_VERSION || '1.0.0-beta.1';

// Files electron-builder may rewrite in place while packaging a root-layout app. The
// guard snapshots their exact bytes, restores them on every exit path, and then keeps
// watching — because electron-builder's own npm children can outlive the build and
// overwrite the restore. See lib/source-guard.js for the failure that led to that.
const GUARDED = ['package.json', 'package-lock.json'].map((rel) => path.join(root, rel));
const guard = createSourceGuard(GUARDED, {
  log: (m) => console.log('[build-bedready] ' + m),
  error: (m) => console.error('[build-bedready] ' + m),
});
const restoreSources = (reason, opts) => guard.restore(reason, opts);

// finally does NOT run when the process is killed by a signal — restore there too.
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => {
    restoreSources(sig);
    process.exit(130);
  });
}
process.on('uncaughtException', (err) => {
  console.error('[build-bedready] uncaught:', err && err.stack || err);
  restoreSources('uncaughtException');
  process.exit(1);
});

const builderArgs = process.argv.slice(2);
if (builderArgs.length === 0) builderArgs.push('--dir'); // default: quick unpacked

// The bedready config now has a `publish` provider (so app-update.yml gets baked
// in and the latest*.yml/.blockmap update-feed metadata is generated). But we do
// NOT want electron-builder to upload during the build: the signed mac artifacts
// are published locally and win/linux by CI, each after their own post-build step
// (notarize / sign). `--publish never` keeps generation on, upload off. Skip it
// for --dir (unpacked) builds, where publish is irrelevant.
if (!builderArgs.includes('--dir') && !builderArgs.some((a) => a === '--publish')) {
  builderArgs.push('--publish', 'never');
}

let exitCode = 0;
try {
  const pkg = JSON.parse(guard.guarded[0].bytes.toString('utf8'));
  pkg.version = BEDREADY_VERSION;
  // Formatting of this temporary write is irrelevant — the source is restored
  // to its original bytes on every exit path; electron-builder only needs valid JSON.
  writeFileSync(guard.guarded[0].file, JSON.stringify(pkg, null, 2) + '\n');

  console.log(`[build-bedready] packaging Bed Ready ${BEDREADY_VERSION} (${builderArgs.join(' ')})`);
  // Windows: the launcher is npx.cmd, and recent Node refuses to spawn a .cmd
  // without a shell (EINVAL). Use shell:true on win32 so PATHEXT resolves npx
  // and the .cmd runs. POSIX keeps the plain spawn that already works in CI.
  const res = spawnSync(
    'npx',
    ['electron-builder', ...builderArgs, '--config', 'electron-builder.bedready.js'],
    { cwd: root, stdio: 'inherit', env: process.env, shell: process.platform === 'win32' },
  );
  if (res.error) console.error('[build-bedready] failed to launch electron-builder:', res.error.message);
  exitCode = res.status == null ? 1 : res.status;
} finally {
  const ok = restoreSources('finally');
  // The restore verified its own write, which only proves nothing had overwritten it YET.
  const stayed = guard.settleAndVerify();
  if (!ok || !stayed) process.exit(1);
  console.log('[build-bedready] guarded sources verified stable after the build.');
}

process.exit(exitCode);
