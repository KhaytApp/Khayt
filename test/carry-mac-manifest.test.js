/**
 * The carried macOS manifest, checked against the URL electron-updater will
 * actually build from it.
 *
 * This is the only place the fix can be tested. The code runs in one step of
 * release.yml, on a tag push, on a release where macOS was skipped — so
 * exercising it for real costs a release, and the bug it fixes is invisible to
 * the maintainer cutting that release. A mac user already on the carried
 * version is told they are up to date and never requests anything; only a user
 * further back resolves the manifest as an update and hits the 404. Nothing is
 * logged on the release side either way.
 *
 * So the assertions below reproduce electron-updater's own resolution rather
 * than trusting the shape of the YAML: `GitHubProvider.resolveFiles()` prepends
 * the tag of the release the feed pointed at, and `new URL()` normalises what
 * comes out. Both halves are what the fix depends on.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { rewriteManifest, pickSourceRelease, bareName } = require('../scripts/carry-mac-manifest.js');

/** A real beta.3 manifest, trimmed to the fields that decide a download. */
const MANIFEST = [
  'version: 3.7.0-beta.3',
  'files:',
  '  - url: Khayt-3.7.0-beta.3-arm64-mac.zip',
  '    sha512: iwkWEAwtZk6/0uO0uiCN6egkiWFbY/qum8R6LoLZCE8=',
  '    size: 160925184',
  '  - url: Khayt-3.7.0-beta.3-arm64.dmg',
  '    sha512: AAAAEAwtZk6/0uO0uiCN6egkiWFbY/qum8R6LoLZCE8=',
  '    size: 161980416',
  'path: Khayt-3.7.0-beta.3-arm64-mac.zip',
  'sha512: iwkWEAwtZk6/0uO0uiCN6egkiWFbY/qum8R6LoLZCE8=',
  "releaseDate: '2026-08-23T14:02:40.000Z'",
  '',
].join('\n');

/**
 * What electron-updater does with a `url:` from the manifest, reproduced:
 * GitHubProvider.getBaseDownloadPath(tag, url) then newUrlFromBase().
 */
/**
 * Resolve a manifest reference the way the app's updater ACTUALLY does.
 *
 * This used to be three lines of hand-written URL joining — a model of
 * electron-updater, living in the test that was supposed to prove
 * electron-updater would find the file. That is the same mistake the first
 * Repetier fix shipped and #764 had to find again: a test that asserts against
 * an inline copy of the thing it is testing can only ever confirm the copy.
 *
 * It would have stayed green through a change to `GitHubProvider`'s download
 * path, a trailing slash in `newUrlFromBase`, or a provider swap — while the
 * real download 404'd. And this mechanism's failure is invisible by
 * construction: the manifest still fetches 200, the version inside it still
 * reads correctly, and only the DOWNLOAD breaks, for exactly the users furthest
 * behind, who are the ones the carry exists to serve.
 *
 * So it now calls electron-updater's own `resolveFiles` with `GitHubProvider`'s
 * own `getBaseDownloadPath`. Checked against the real published feed on
 * 2026-08-27: the beta.10 release's carried manifest resolves to
 * `…/download/v3.7.0-beta.8/Khayt-3.7.0-beta.8-arm64-mac.zip`, which serves,
 * while the verbatim-copy form resolves into v3.7.0-beta.10 and 404s. The old
 * hand model gave the same answers — it was correct, and it was not pinned to
 * anything.
 *
 * The deep import is deliberate. If electron-updater restructures, this fails
 * loudly at require time and someone re-checks the carry against the new
 * internals, which is the outcome to want; a shallower import would keep
 * passing while meaning less.
 */
const { resolveFiles } = require('electron-updater/out/providers/Provider.js');

/** GitHubProvider.getBaseDownloadPath, which is what transforms the reference. */
const baseDownloadPath = (tag, fileName) =>
  `/KhaytApp/Khayt/releases/download/${tag}/${fileName}`;

function resolveAsUpdater(url, releaseTag) {
  const [file] = resolveFiles(
    // sha512 is required by resolveFiles and is not what is under test here;
    // the real manifest carries one, and the checksum's survival across the
    // rewrite has its own test below.
    { tag: releaseTag, files: [{ url, sha512: 'not-under-test' }] },
    new URL('https://github.com'),
    (p) => baseDownloadPath(releaseTag, p.replace(/ /g, '-')),
  );
  return file.url.href;
}

/** Every `url:`/`path:` value in a manifest, in order. */
function refs(yaml) {
  return yaml
    .split('\n')
    .map((l) => /^\s*(?:-\s+)?(?:url|path):\s*(.+?)\s*$/.exec(l))
    .filter(Boolean)
    .map((m) => m[1]);
}

test('carried verbatim, the download 404s — this is the bug', () => {
  // No rewrite: the reference is a bare filename from beta.3, uploaded to beta.4.
  const resolved = resolveAsUpdater('Khayt-3.7.0-beta.3-arm64-mac.zip', 'v3.7.0-beta.4');
  assert.equal(
    resolved,
    'https://github.com/KhaytApp/Khayt/releases/download/v3.7.0-beta.4/Khayt-3.7.0-beta.3-arm64-mac.zip'
  );
  // …and v3.7.0-beta.4 has no mac assets, which is why it was carried at all.
  assert.match(resolved, /download\/v3\.7\.0-beta\.4\/Khayt-3\.7\.0-beta\.3/);
});

test('rewritten, every reference resolves into the release that has the binaries', () => {
  const out = rewriteManifest(MANIFEST, 'v3.7.0-beta.3');
  for (const ref of refs(out)) {
    assert.equal(
      resolveAsUpdater(ref, 'v3.7.0-beta.4').startsWith(
        'https://github.com/KhaytApp/Khayt/releases/download/v3.7.0-beta.3/'
      ),
      true,
      `${ref} should resolve into v3.7.0-beta.3`
    );
  }
});

test('the manifest actually published on beta.10 resolves into beta.8', () => {
  // Not an invented shape: these are the two `url:` values fetched from
  // https://github.com/KhaytApp/Khayt/releases/download/v3.7.0-beta.10/latest-mac.yml
  // on 2026-08-27, and both resolved URLs were confirmed to serve on the same day.
  //
  // This is the live path right now, not a hypothetical. macOS is two cuts
  // behind on beta.8, so any mac user on beta.5–beta.7 who checks for updates
  // reads THIS manifest off the beta.10 release and downloads through exactly
  // this resolution.
  const published = [
    '../v3.7.0-beta.8/Khayt-3.7.0-beta.8-arm64-mac.zip',
    '../v3.7.0-beta.8/Khayt-3.7.0-beta.8-arm64.dmg',
  ];
  for (const ref of published) {
    assert.equal(
      resolveAsUpdater(ref, 'v3.7.0-beta.10'),
      `https://github.com/KhaytApp/Khayt/releases/download/v3.7.0-beta.8/${ref.split('/').pop()}`,
    );
  }
  // And the form a naive carry produces — a verbatim copy — lands in the release
  // that has no mac assets. Verified over HTTP the same day: 404.
  assert.equal(
    resolveAsUpdater('Khayt-3.7.0-beta.8-arm64-mac.zip', 'v3.7.0-beta.10'),
    'https://github.com/KhaytApp/Khayt/releases/download/v3.7.0-beta.10/Khayt-3.7.0-beta.8-arm64-mac.zip',
  );
});

test('the version inside the manifest is untouched — it is what stops a needless update', () => {
  const out = rewriteManifest(MANIFEST, 'v3.7.0-beta.3');
  assert.match(out, /^version: 3\.7\.0-beta\.3$/m);
});

test('checksums and sizes survive the rewrite', () => {
  const out = rewriteManifest(MANIFEST, 'v3.7.0-beta.3');
  assert.match(out, /sha512: iwkWEAwtZk6\/0uO0uiCN6egkiWFbY\/qum8R6LoLZCE8=/);
  assert.match(out, /size: 160925184/);
  assert.match(out, /releaseDate: '2026-08-23T14:02:40\.000Z'/);
});

test('the deprecated `path:` moves too — it is read when `files` is absent', () => {
  const out = rewriteManifest('version: 3.7.0-beta.3\npath: Khayt-3.7.0-beta.3-arm64-mac.zip\n', 'v3.7.0-beta.3');
  assert.match(out, /^path: \.\.\/v3\.7\.0-beta\.3\/Khayt-3\.7\.0-beta\.3-arm64-mac\.zip$/m);
});

test('rewriting twice does not nest prefixes', () => {
  const once = rewriteManifest(MANIFEST, 'v3.7.0-beta.3');
  const twice = rewriteManifest(once, 'v3.7.0-beta.3');
  assert.equal(twice, once);
  assert.equal(refs(twice).every((r) => !r.includes('../v3.7.0-beta.3/../')), true);
});

test('re-pointing an already-carried manifest replaces the prefix rather than stacking it', () => {
  const carried = rewriteManifest(MANIFEST, 'v3.7.0-beta.3');
  const repointed = rewriteManifest(carried, 'v3.7.0-beta.9');
  for (const ref of refs(repointed)) {
    assert.equal(ref.startsWith('../v3.7.0-beta.9/'), true, ref);
    assert.equal(ref.split('../').length, 2, `${ref} should carry exactly one ../`);
  }
});

test('an absolute URL is left alone', () => {
  const abs = 'files:\n  - url: https://cdn.example.com/Khayt-arm64-mac.zip\n';
  assert.equal(rewriteManifest(abs, 'v3.7.0-beta.3'), abs);
});

test('quoting is preserved', () => {
  const quoted = "path: 'Khayt-3.7.0-beta.3-arm64-mac.zip'\n";
  assert.match(rewriteManifest(quoted, 'v3.7.0-beta.3'), /^path: '\.\.\/v3\.7\.0-beta\.3\/Khayt-3\.7\.0-beta\.3-arm64-mac\.zip'$/m);
});

test('bareName strips a prefix and leaves a plain name', () => {
  assert.equal(bareName('../v3.7.0-beta.3/a-mac.zip'), 'a-mac.zip');
  assert.equal(bareName('a-mac.zip'), 'a-mac.zip');
});

/** Shorthand for a published release entry. */
const rel = (tagName, publishedAt, assets, extra = {}) => ({ tagName, publishedAt, assets, draft: false, ...extra });

/** A mac build, and a mac-less release that merely carries a manifest. */
const withMac = (tag, date) => rel(tag, date, ['latest-mac.yml', 'latest.yml', `Khayt-${tag.slice(1)}-arm64-mac.zip`]);
const carriedOnly = (tag, date) => rel(tag, date, ['latest-mac.yml', 'latest.yml']);

test('the source release must have a real mac build, not just a manifest', () => {
  const releases = [
    rel('v3.7.0-beta.4', '2026-08-23T17:47:09Z', ['latest.yml']),
    // A release that only CARRIES a manifest cannot serve the download itself.
    carriedOnly('v3.7.0-beta.3b', '2026-08-23T15:00:00Z'),
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
  ];
  assert.equal(pickSourceRelease(releases, 'v3.7.0-beta.5'), 'v3.7.0-beta.3');
});

test('the release being built is never its own source', () => {
  const releases = [
    withMac('v3.7.0-beta.4', '2026-08-23T17:47:09Z'),
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
  ];
  assert.equal(pickSourceRelease(releases, 'v3.7.0-beta.4'), 'v3.7.0-beta.3');
});

test('no mac build anywhere is null, not a throw', () => {
  assert.equal(pickSourceRelease([rel('v1', '2026-01-01T00:00:00Z', ['latest.yml'])], 'v2'), null);
  assert.equal(pickSourceRelease([], 'v2'), null);
  assert.equal(pickSourceRelease(null, 'v2'), null);
});

test('a run of mac-less betas still points at the one real build', () => {
  const releases = [
    carriedOnly('v3.7.0-beta.5', '2026-08-24T10:00:00Z'),
    carriedOnly('v3.7.0-beta.4', '2026-08-23T17:47:09Z'),
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
  ];
  const source = pickSourceRelease(releases, 'v3.7.0-beta.6');
  assert.equal(source, 'v3.7.0-beta.3');
  const out = rewriteManifest(MANIFEST, source);
  for (const ref of refs(out)) {
    assert.match(resolveAsUpdater(ref, 'v3.7.0-beta.6'), /download\/v3\.7\.0-beta\.3\//);
  }
});

test('drafts are never the source, however new they look', () => {
  // The release being built is itself a draft while this job runs, and a
  // draft's assets are not downloadable by an updater at all.
  const releases = [
    { tagName: 'v9.9.9-draft', publishedAt: null, draft: true, assets: ['latest-mac.yml', 'Khayt-9.9.9-arm64-mac.zip'] },
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
  ];
  assert.equal(pickSourceRelease(releases, 'v3.7.0-beta.4'), 'v3.7.0-beta.3');
});

test('the API order is not trusted — drafts lead the real list, out of date order', () => {
  // This is the shape `GET /repos/{o}/{r}/releases` actually returns for this
  // repo: stale drafts from months back at the head, published releases after.
  // Taking the first match would carry the manifest from an ancient release.
  const releases = [
    { tagName: 'v3.0.0-beta.13', publishedAt: null, draft: true, assets: ['latest-mac.yml', 'Khayt-3.0.0-beta.13-arm64-mac.zip'] },
    { tagName: 'v2.1.0', publishedAt: null, draft: true, assets: ['latest-mac.yml', 'Khayt-2.1.0-arm64-mac.zip'] },
    rel('v3.7.0-beta.4', '2026-08-23T17:47:09Z', ['latest.yml']),
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
    withMac('v3.6.0', '2026-08-21T05:20:40Z'),
  ];
  assert.equal(pickSourceRelease(releases, 'v3.7.0-beta.5'), 'v3.7.0-beta.3');
});

test('an out-of-order published list still yields the newest mac build', () => {
  const releases = [
    withMac('v3.6.0', '2026-08-21T05:20:40Z'),
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
    withMac('v3.6.0-rc.1', '2026-08-12T15:09:55Z'),
  ];
  assert.equal(pickSourceRelease(releases, 'v3.7.0-beta.4'), 'v3.7.0-beta.3');
});

test('an undated release never outranks a dated one', () => {
  const releases = [
    { tagName: 'v0.0.1-undated', draft: false, assets: ['latest-mac.yml', 'Khayt-0.0.1-arm64-mac.zip'] },
    withMac('v3.7.0-beta.3', '2026-08-23T14:02:40Z'),
  ];
  assert.equal(pickSourceRelease(releases, 'v3.7.0-beta.4'), 'v3.7.0-beta.3');
});
