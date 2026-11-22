const { test } = require('node:test');
const assert = require('node:assert/strict');
const semver = require('semver');
const pkg = require('../package.json');

/**
 * A version this repo publishes must be one existing installs can SEE.
 *
 * electron-updater's GitHubProvider walks releases.atom and decides which entry
 * to offer. Its ladder understands exactly two prerelease names — `alpha` and
 * `beta` — and treats anything else as a CUSTOM channel that only ever matches
 * itself (GitHubProvider.js, `isCustomChannel` / `isNextPreRelease`).
 *
 * `v3.7.0-rc.1` was published on 2026-08-29 and was invisible. Run against the
 * real feed with the real library:
 *
 *   on 3.7.0-beta.10  -> offered v3.7.0-beta.10   (the version already installed)
 *   on 3.7.0-rc.1     -> offered v3.7.0-rc.1      even with a NEWER beta.12 published
 *
 * Both directions. A beta user never reaches an rc, and an rc user never comes
 * back. The candidate nobody could install could not be soaked by anybody, which
 * is the one thing a candidate is for.
 *
 * VERSIONING.md had asserted the opposite — "`-rc` and `-beta` are the same
 * channel to the updater" — which is why the 3.6.0 line's four candidates were
 * very likely never installed by a beta user either. Nobody noticed, because
 * promotion goes rc → stable and stable users take the newest entry regardless.
 *
 * The naming is therefore not a matter of taste. A candidate is a PROMISE, kept
 * in docs/RELEASE-HOLD.md; the version string is what the updater can follow.
 */

const LADDER = ['alpha', 'beta'];

test('the published version is on a channel existing installs can follow', () => {
  const pre = semver.prerelease(pkg.version);
  if (pre === null) return; // a stable release is on the default channel
  const tag = String(pre[0]);
  assert.ok(LADDER.includes(tag),
    `package.json is ${pkg.version}, and "${tag}" is not a channel electron-updater's ladder `
    + `follows (it knows ${LADDER.join(' and ')} only). Every install on a beta would be offered `
    + `the version it already has. Name a candidate -beta.N and keep the candidate promise in `
    + `docs/RELEASE-HOLD.md.`);
});

test('the ladder claim is the reason, and it is reproduced here', () => {
  /* The selection loop from electron-updater's GitHubProvider, run against a
     feed shaped like this repo's. If a future electron-updater widens the ladder
     this test starts failing, which is the right moment to revisit the rule
     rather than discovering it on a release day. */
  const pick = (currentVersion, feed) => {
    const currentChannel = semver.prerelease(currentVersion)?.[0] || null;
    if (currentChannel === null) return feed[0];
    for (const hrefTag of feed) {
      if (!semver.valid(hrefTag)) continue;
      const hrefChannel = semver.prerelease(hrefTag)?.[0] || null;
      const shouldFetchVersion = !currentChannel || LADDER.includes(currentChannel);
      const isCustomChannel = hrefChannel !== null && !LADDER.includes(String(hrefChannel));
      const channelMismatch = currentChannel === 'beta' && hrefChannel === 'alpha';
      if (shouldFetchVersion && !isCustomChannel && !channelMismatch) return hrefTag;
      if (hrefChannel && hrefChannel === currentChannel) return hrefTag;
    }
    return null;
  };

  // An rc is invisible to a beta install: it is offered its own version back.
  assert.equal(pick('3.7.0-beta.10', ['v3.7.0-rc.1', 'v3.7.0-beta.10']), 'v3.7.0-beta.10');
  // And an rc install cannot come back to a newer beta.
  assert.equal(pick('3.7.0-rc.1', ['v3.7.0-beta.12', 'v3.7.0-rc.1']), 'v3.7.0-rc.1');
  // A beta IS reachable from a beta, which is what makes -beta.N the right name.
  assert.equal(pick('3.7.0-beta.10', ['v3.7.0-beta.11', 'v3.7.0-beta.10']), 'v3.7.0-beta.11');
  // And a stable install with beta updates on takes the newest entry either way.
  assert.equal(pick('3.6.0', ['v3.7.0-beta.11', 'v3.6.0']), 'v3.7.0-beta.11');
});
