#!/usr/bin/env node
/**
 * Make a carried-forward `latest-mac.yml` point at the release that actually
 * holds the mac binaries.
 *
 * macOS is opt-in at release time (`BUILD_MAC`, see release.yml — mac minutes
 * bill at 10x), so most betas ship Windows + Linux only. A release with no
 * `latest-mac.yml` 404s for every macOS user with beta updates on, which
 * lib/updater.js shows as "Update check failed", so release.yml copies the
 * manifest forward from the last release that had one.
 *
 * Copying it verbatim is not enough, and the reason is a detail of
 * electron-updater: the download URL is built from the tag of the release the
 * *feed* pointed at, not from the version recorded inside the manifest.
 *
 *     GitHubProvider.resolveFiles()
 *       -> getBaseDownloadPath(updateInfo.tag, file.url)
 *       -> `/{owner}/{repo}/releases/download/${tag}/${file.url}`
 *
 * `tag` there is the newest release. So a verbatim carried manifest naming
 * `Khayt-3.7.0-beta.3-arm64-mac.zip` inside release `v3.7.0-beta.4` resolves to
 *
 *     /releases/download/v3.7.0-beta.4/Khayt-3.7.0-beta.3-arm64-mac.zip   404
 *
 * because that release has no mac assets — that being the whole reason the
 * manifest was carried. The bug hides well: a mac user already on `beta.3` reads
 * the carried manifest, sees `3.7.0-beta.3`, compares it to what they are
 * running and is correctly told they are up to date, so nothing is ever
 * requested. Only a mac user further behind — still on `beta.1` or `beta.2` —
 * resolves it as an update, downloads, and gets the 404 the carry existed to
 * prevent.
 *
 * The fix is to make the reference relative, so the tag the provider prepends is
 * cancelled by the URL parser rather than fought:
 *
 *     url: ../v3.7.0-beta.3/Khayt-3.7.0-beta.3-arm64-mac.zip
 *     -> /releases/download/v3.7.0-beta.4/../v3.7.0-beta.3/Khayt-...zip
 *     -> /releases/download/v3.7.0-beta.3/Khayt-...zip                    200
 *
 * `new URL()` normalises the `..` away (WHATWG URL, same in every runtime
 * electron-updater supports). The blockmap path follows for free: it is derived
 * from the already-resolved URL, so the differential downloader looks in the
 * same release the binary came from.
 *
 * The other half is `pickSourceRelease`. It requires the source release to hold
 * a real `*-mac.zip`, not merely a `latest-mac.yml`, so a carried manifest is
 * never itself carried forward. Without that rule a run of mac-less betas
 * chains `../` prefixes one release at a time and drifts further from the
 * binaries with every cut.
 *
 * It also sorts, rather than trusting the order the releases API returns. That
 * list is NOT newest-first: drafts come first as a group, in their own order,
 * and this repo has stale drafts from months back sitting at the head of it.
 * Taking the first match would have carried the manifest from whatever old
 * release happened to lead the list. Drafts are dropped outright — the release
 * being built is itself a draft while this job runs, and a draft's assets are
 * not downloadable by an updater in the first place.
 */
'use strict';

/** The asset electron-updater downloads to perform a macOS update. */
const MAC_BINARY = /-mac\.zip$/;

/** Manifest filename for the macOS update channel. */
const MAC_MANIFEST = 'latest-mac.yml';

/**
 * Strip a `../<tag>/` prefix that a previous carry may have added, so the
 * rewrite is idempotent and never nests.
 */
function bareName(value) {
  let out = String(value).trim();
  while (out.startsWith('../')) {
    const slash = out.indexOf('/', 3);
    if (slash === -1) break;
    out = out.slice(slash + 1);
  }
  return out;
}

/**
 * Rewrite every asset reference in a `latest-mac.yml` so it resolves against
 * `sourceTag` rather than the release the manifest is being uploaded to.
 *
 * Only `url:` and `path:` carry filenames; `path` is electron-updater's
 * deprecated single-file fallback, read when `files` is absent, so both have to
 * move together or a manifest without a `files` list would still 404.
 */
function rewriteManifest(yaml, sourceTag) {
  if (!sourceTag) throw new Error('rewriteManifest: sourceTag is required');
  return String(yaml)
    .split('\n')
    .map((line) => {
      const m = /^(\s*(?:-\s+)?(?:url|path):\s*)(.+?)(\s*)$/.exec(line);
      if (!m) return line;
      const [, head, rawValue, tail] = m;
      // Preserve whatever quoting electron-builder chose.
      const quote = /^(['"]).*\1$/.test(rawValue) ? rawValue[0] : '';
      const value = quote ? rawValue.slice(1, -1) : rawValue;
      // An absolute URL already says where it lives; leave it alone.
      if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) return line;
      return `${head}${quote}../${sourceTag}/${bareName(value)}${quote}${tail}`;
    })
    .join('\n');
}

/**
 * Choose the release to carry the macOS manifest from: the most recently
 * published one that shipped an actual mac build.
 *
 * `releases` is `{ tagName, assets: [name], draft, publishedAt }` per entry, as
 * returned by the releases API — in the order the API chose, which is not the
 * order this needs. Returns null when no release has a mac build, which is not
 * an error: there is nothing for a mac user to update to either way.
 */
function pickSourceRelease(releases, currentTag) {
  return (
    (releases || [])
      .filter((r) => r && !r.draft && r.tagName !== currentTag)
      // Newest first, by publication. Anything undated sorts last rather than
      // winning by accident.
      .sort((a, b) => String(b.publishedAt || '').localeCompare(String(a.publishedAt || '')))
      .find((r) => {
        const assets = r.assets || [];
        return assets.includes(MAC_MANIFEST) && assets.some((a) => MAC_BINARY.test(a));
      })?.tagName ?? null
  );
}

module.exports = { rewriteManifest, pickSourceRelease, bareName, MAC_MANIFEST, MAC_BINARY };

if (require.main === module) {
  const fs = require('node:fs');
  const [mode, ...rest] = process.argv.slice(2);
  const flag = (name) => {
    const i = rest.indexOf(name);
    return i === -1 ? null : rest[i + 1];
  };

  if (mode === 'pick') {
    const releases = JSON.parse(fs.readFileSync(0, 'utf8'));
    const tag = pickSourceRelease(releases, flag('--current'));
    if (tag) process.stdout.write(`${tag}\n`);
    process.exit(0);
  }

  if (mode === 'rewrite') {
    const file = rest.filter((a) => !a.startsWith('--') && a !== flag('--source'))[0];
    if (!file) {
      console.error('usage: carry-mac-manifest.js rewrite --source <tag> <file>');
      process.exit(2);
    }
    fs.writeFileSync(file, rewriteManifest(fs.readFileSync(file, 'utf8'), flag('--source')));
    process.exit(0);
  }

  console.error('usage: carry-mac-manifest.js pick --current <tag> < releases.json');
  console.error('       carry-mac-manifest.js rewrite --source <tag> <file>');
  process.exit(2);
}
