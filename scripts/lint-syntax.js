#!/usr/bin/env node
/**
 * Syntax-check every source file in the tree.
 *
 * This replaced a 153-entry chain of literal `node --check <path> &&` calls in
 * package.json. That list was maintained by hand, so it drifted the moment
 * anyone added a file: 68 real modules — lib/bambu.js, lib/kpi.js,
 * lib/forecast.js, lib/mdns.js among them — had never been checked at all, and
 * the chain broke twice in one session when files were added or deleted.
 *
 * Discovery is now a walk, so a new file is covered the moment it exists and a
 * deleted one stops being referenced. `test/lint-coverage.test.js` asserts the
 * walk still reaches every source file, so an over-broad EXCLUDE can't quietly
 * shrink the net.
 *
 * Checking is `node --check` per file, matching the old behaviour exactly:
 * .js parses as CommonJS, .mjs as ESM. Runs pooled so 221 files stay fast.
 */
'use strict';

const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

/** Files and directories that are checked. Anything not under one of these is not source. */
const ROOTS = [
  'main.js',
  'preload.js',
  'electron-builder.bedready.js',
  'lib',
  'renderer',
  'scripts',
  // The "Save to Khayt" browser extension. Its own package.json says
  // `type: module`, so `node --check` reads src/*.js as the modules they are.
  'extension-khayt',
];

/**
 * Directories never walked. Keep this list short and justified — every entry is
 * a hole in the net, which is the exact failure mode this script exists to end.
 */
const EXCLUDE_DIRS = new Set(['node_modules', '.git', 'dist', 'out', 'release']);

const EXTS = new Set(['.js', '.mjs', '.cjs']);

/** Every source file the linter will check, repo-relative and sorted. */
function discover(root = ROOT) {
  const found = [];
  const walk = (rel) => {
    const abs = path.join(root, rel);
    let st;
    try { st = fs.statSync(abs); } catch { return; }
    if (st.isFile()) {
      if (EXTS.has(path.extname(rel))) found.push(rel);
      return;
    }
    if (!st.isDirectory()) return;
    if (EXCLUDE_DIRS.has(path.basename(rel))) return;
    for (const entry of fs.readdirSync(abs)) walk(path.join(rel, entry));
  };
  for (const r of ROOTS) walk(r);
  return found.sort();
}

function check(file) {
  return new Promise((resolve) => {
    execFile(process.execPath, ['--check', path.join(ROOT, file)], (err, _out, stderr) => {
      resolve(err ? { file, error: String(stderr || err.message).trim() } : null);
    });
  });
}

/** Run `check` over the list with a bounded worker pool. */
async function checkAll(files, concurrency = 8) {
  const failures = [];
  let next = 0;
  const worker = async () => {
    for (;;) {
      const i = next++;
      if (i >= files.length) return;
      const bad = await check(files[i]);
      if (bad) failures.push(bad);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, files.length) }, worker));
  return failures;
}

async function main() {
  const files = discover();
  const failures = await checkAll(files);
  if (failures.length) {
    failures.sort((a, b) => a.file.localeCompare(b.file));
    for (const f of failures) {
      process.stderr.write(`\n✗ ${f.file}\n${f.error.split('\n').slice(0, 6).join('\n')}\n`);
    }
    process.stderr.write(`\nsyntax check failed: ${failures.length} of ${files.length} file(s)\n`);
    process.exit(1);
  }
  process.stdout.write(`syntax check ok — ${files.length} files\n`);
}

module.exports = { discover, ROOTS, EXCLUDE_DIRS, EXTS };

if (require.main === module) {
  main().catch((e) => { process.stderr.write(String(e && e.stack || e) + '\n'); process.exit(1); });
}
