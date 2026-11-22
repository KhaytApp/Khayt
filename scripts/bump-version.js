#!/usr/bin/env node
/**
 * Bump package.json + package-lock.json version (semver).
 * Usage: node scripts/bump-version.js patch|minor|major|beta
 */
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const pkgPath = path.join(root, 'package.json');
const lockPath = path.join(root, 'package-lock.json');

const kind = process.argv[2];
if (!['patch', 'minor', 'major', 'beta', 'set'].includes(kind)) {
  console.error('Usage: node scripts/bump-version.js <patch|minor|major|beta|set [version]>');
  process.exit(1);
}

const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
const m = /^(\d+)\.(\d+)\.(\d+)(?:-([\w.]+))?$/.exec(pkg.version);
if (!m) {
  console.error(`Invalid version in package.json: ${pkg.version}`);
  process.exit(1);
}

const prev = pkg.version;
let [major, minor, patch] = [+m[1], +m[2], +m[3]].map(Number);
const prerelease = m[4] || '';
let next;

if (kind === 'set') {
  // Explicit target, e.g. for a major-line beta: `set 3.0.0-beta.1`.
  next = process.argv[3];
  if (!/^\d+\.\d+\.\d+(?:-[\w.]+)?$/.test(next || '')) {
    console.error('set requires a semver, e.g. node scripts/bump-version.js set 3.0.0-beta.1');
    process.exit(1);
  }
} else if (kind === 'beta') {
  const betaMatch = /^beta\.(\d+)$/.exec(prerelease);
  if (betaMatch) {
    next = `${major}.${minor}.${patch}-beta.${Number(betaMatch[1]) + 1}`;
  } else {
    minor += 1;
    patch = 0;
    next = `${major}.${minor}.${patch}-beta.1`;
  }
} else if (kind === 'major') {
  major += 1;
  minor = 0;
  patch = 0;
  next = `${major}.${minor}.${patch}`;
} else if (kind === 'minor') {
  minor += 1;
  patch = 0;
  next = `${major}.${minor}.${patch}`;
} else {
  patch += 1;
  next = `${major}.${minor}.${patch}`;
}

pkg.version = next;
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');

if (fs.existsSync(lockPath)) {
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  lock.version = next;
  if (lock.packages && lock.packages['']) {
    lock.packages[''].version = next;
  }
  fs.writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n');
}

console.log(`Version bumped (${kind}): ${prev} → ${next}`);
console.log('Next: update CHANGELOG.md, commit, tag v' + next);
