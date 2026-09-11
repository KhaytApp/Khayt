const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const WF = path.join(__dirname, '..', '.github', 'workflows', 'mac-release.yml');
const yaml = fs.readFileSync(WF, 'utf8');

/* ────────────────────────────────────────────────────────────────────────────
 * The Mac app's release lane, and the one rule it must never break.
 *
 * electron-updater picks a release by walking THIS repo's `releases.atom`, and
 * that feed lists tags whether or not a release exists for them. A
 * `bedready-v*` tag once appeared in Khayt's update feed and every beta install
 * that resolved it asked for a `latest-mac.yml` that 404s — their update check
 * simply failed, and the fix was to stop tagging here at all.
 *
 * A Mac tag would be worse than Bed Ready's: `v4.0.0-alpha.1` parses as NEWER
 * than 3.7.0, so it would not merely appear in the feed — it would be chosen.
 * ──────────────────────────────────────────────────────────────────────────── */

test('the Mac lane is dispatched, never triggered by a tag', () => {
  assert.ok(!/^on:[\s\S]*?\bpush:/m.test(yaml.split('jobs:')[0]),
    'a push trigger would put Mac tags in this repository');
  assert.match(yaml.split('jobs:')[0], /workflow_dispatch:/);
});

test('nothing in the lane creates a tag in this repository', () => {
  // `gh release create` makes a tag wherever it runs, so every call must name
  // the other repo explicitly.
  const creates = yaml.split('\n').filter((l) => /gh release create/.test(l));
  assert.ok(creates.length >= 1, 'expected the lane to create a release');
  for (const line of creates) {
    const idx = yaml.indexOf(line);
    const block = yaml.slice(idx, idx + 400);
    assert.match(block, /--repo KhaytApp\/khayt-mac/,
      'a release is being created without naming KhaytApp/khayt-mac');
  }
  assert.ok(!/git tag|git push .*refs\/tags|git push upstream v/.test(yaml),
    'the lane pushes a tag');
});

test('it refuses to publish an unsigned update', () => {
  // Sparkle rejects an unsigned archive AFTER downloading it, which a shop
  // reads as a broken app rather than a broken release.
  assert.match(yaml, /SPARKLE_PRIVATE_KEY/);
  assert.match(yaml, /if \[ -z "\$SPARKLE_PRIVATE_KEY" \]/);
  assert.match(yaml, /sign_update/);
});

test('the private key is piped, never written to the runner disk', () => {
  assert.match(yaml, /\$SPARKLE_PRIVATE_KEY" \| "\$SIGN" -f - -p/,
    'the EdDSA key should reach sign_update on stdin');
  assert.ok(!/SPARKLE_PRIVATE_KEY["']? *> */.test(yaml), 'the key is being written to a file');
});

test('the release is uploaded before the feed advertises it', () => {
  // A feed naming an asset that is not there yet sends every install that
  // checks in between to a 404.
  // The STEP names, not any mention of them — "Publish the Sparkle feed" is
  // also the text of a workflow_dispatch input, 6,500 characters earlier, and
  // matching that made this test pass its own reversal.
  const release = yaml.indexOf('- name: Create the release');
  const feed = yaml.indexOf('- name: Publish the Sparkle feed');
  assert.ok(release > 0, 'no "Create the release" step');
  assert.ok(feed > 0, 'no "Publish the Sparkle feed" step');
  assert.ok(feed > release, 'the feed step must come after the release step');
});

test('the archive is made with ditto, not zip', () => {
  // A versioned framework is a farm of symlinks; `zip` flattens them and the
  // result unpacks into an app macOS will not run.
  assert.match(yaml, /ditto -c -k --keepParent/);
  assert.ok(!/^\s*zip -/m.test(yaml));
});

test('the build is notarised and stapled, or it cannot open elsewhere', () => {
  assert.match(yaml, /make-app\.sh --notarize/);
});

test('the feed URL is a domain we own, not a github.io address', () => {
  // SUFeedURL is baked into every shipped copy and cannot be changed on an
  // install that already exists.
  assert.match(yaml, /KHAYT_APPCAST: https:\/\/khaytapp\.com\/mac\/appcast\.xml/);
  // The URL the app is BUILT with, not any mention of an alternative — the
  // comment above it explains why khaytapp.com and not github.io, and a plain
  // search for that string finds the explanation.
  const feedUrls = yaml.split('\n')
    .filter((l) => /KHAYT_APPCAST:|SUFeedURL/.test(l) && !/^\s*#/.test(l));
  assert.ok(feedUrls.length >= 1);
  for (const line of feedUrls) {
    assert.ok(!/github\.io/.test(line), `the feed points at a github.io address: ${line.trim()}`);
  }
});

test('the app and the workflow agree about where the feed lives', () => {
  // Two places name it; if they drift, the app checks an address nothing
  // publishes to and reports no updates forever.
  const script = fs.readFileSync(path.join(__dirname, '..', 'mac', 'make-app.sh'), 'utf8');
  assert.match(script, /SUFeedURL<\/key><string>\$\{KHAYT_APPCAST\}/,
    'make-app.sh should take the feed URL from KHAYT_APPCAST');
});
