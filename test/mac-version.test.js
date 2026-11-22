const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { read, SEMVER, FILE } = require('../scripts/bump-mac-version.js');

/* ────────────────────────────────────────────────────────────────────────────
 * The native Mac app's version is its OWN, and its build number only goes up.
 *
 * Two separate failures are guarded here and neither one reports an error when
 * it happens:
 *
 *   1. A Mac build numbered from `package.json` calls itself whatever the
 *      ELECTRON app is on. Those products ship on their own schedules now.
 *   2. `CFBundleVersion` must be digits and dots, so the marketing string
 *      cannot be it. Stripping the suffix gives 4.0.0 for BOTH `4.0.0-alpha.1`
 *      and `4.0.0-alpha.2` — and Sparkle compares that field, so every tester
 *      would be told they are up to date. The build is fine, the feed is fine,
 *      and nobody updates.
 * ──────────────────────────────────────────────────────────────────────────── */

test('the Mac version is semver and the build is a positive integer', () => {
  const v = read();
  assert.match(v.version, SEMVER);
  assert.ok(Number.isInteger(v.build) && v.build >= 1, `build is ${v.build}`);
});

test('the build number is NOT derived from the version string', () => {
  // The whole point. If somebody "simplifies" this back to a stripped version,
  // two alphas in a row become invisible to Sparkle.
  const src = fs.readFileSync(path.join(__dirname, '..', 'mac', 'make-app.sh'), 'utf8');
  assert.match(src, /BUILD_VERSION=.*mac\/version\.json.*\.build/,
    'CFBundleVersion must come from version.json\'s build field');
  assert.ok(!/BUILD_VERSION=.*sed.*[^0-9.]/.test(src),
    'CFBundleVersion is being derived from the marketing string again');
});

test('the Mac app does not take its version from package.json', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'mac', 'make-app.sh'), 'utf8');
  assert.ok(!/VERSION=.*package\.json/.test(src),
    'make-app.sh is numbering the Mac app from the Electron version again');
});

test('bumping a version always moves the build too', () => {
  // A new marketing string carrying the old build number is the exact case
  // version.json exists to prevent, so the bump is not optional.
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'bump-mac-version.js'), 'utf8');
  assert.match(src, /build:\s*current\.build \+ 1/);
  // And there is no branch that leaves it alone.
  assert.ok(!/build:\s*current\.build\b(?!\s*\+)/.test(src));
});

test('version.json is exactly the two fields, so nothing drifts into it', () => {
  const raw = JSON.parse(fs.readFileSync(FILE, 'utf8'));
  assert.deepEqual(Object.keys(raw).sort(), ['build', 'version']);
});

test('the Mac version is ahead of the Electron one, which is the point', () => {
  // Not a rule about numbering — a check that the two files are genuinely
  // different sources. If someone points version.json back at package.json,
  // this is what notices.
  const mac = read().version;
  const electron = require('../package.json').version;
  assert.notEqual(mac, electron,
    'the Mac app and the Electron app are reporting the same version');
});
