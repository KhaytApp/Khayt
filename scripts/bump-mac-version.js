#!/usr/bin/env node
'use strict';
/**
 * Set the native Mac app's version, and always move its build number.
 *
 * `mac/version.json` is the Mac app's own version — see mac/VERSION.md for why
 * it is not `package.json`'s. This script exists so the two fields cannot drift
 * apart by hand: `build` is what Sparkle compares, and a release that forgot to
 * move it tells every tester they are already up to date.
 *
 *   node scripts/bump-mac-version.js 4.0.0-alpha.2   # version + build++
 *   node scripts/bump-mac-version.js --build         # build++ only
 */
const fs = require('fs');
const path = require('path');

const FILE = path.join(__dirname, '..', 'mac', 'version.json');
/** Semver, with an optional prerelease. Deliberately strict. */
const SEMVER = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;

function read() {
  const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
  if (!SEMVER.test(String(raw.version || ''))) {
    throw new Error(`mac/version.json has version "${raw.version}", which is not semver`);
  }
  if (!Number.isInteger(raw.build) || raw.build < 1) {
    throw new Error(`mac/version.json has build ${raw.build}, which is not a positive integer`);
  }
  return raw;
}

if (require.main === module) {
  const arg = process.argv[2];
  if (!arg) {
    console.error('usage: bump-mac-version.js <version|--build>');
    process.exit(2);
  }
  const current = read();
  const next = {
    version: arg === '--build' ? current.version : arg,
    // ALWAYS, including on a version change. A new marketing string with the
    // old build number is the exact case this file exists to prevent.
    build: current.build + 1,
  };
  if (!SEMVER.test(next.version)) {
    console.error(`"${next.version}" is not a semver version, e.g. 4.0.0-alpha.2`);
    process.exit(1);
  }
  fs.writeFileSync(FILE, JSON.stringify(next, null, 2) + '\n');
  console.log(`mac: ${current.version} (build ${current.build}) → ${next.version} (build ${next.build})`);
}

module.exports = { read, SEMVER, FILE };
