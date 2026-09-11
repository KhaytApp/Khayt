#!/usr/bin/env node
'use strict';
/**
 * Put the Mac app's version into the website, from the release that published it.
 *
 * The download button on khaytapp.com links `/releases/latest`, which resolves
 * itself — but the line under it names a version, and a named version is a
 * claim. This repo's own history is full of claims that stopped being true and
 * stayed on the page: `check-release-claims.js` exists because four files
 * disagreed about the current release at once.
 *
 * So the release lane writes it, the way it writes the appcast. Nobody has to
 * remember, which is the only version of "remember to update the site" that
 * works.
 *
 * The marker is `data-mac-version` on the element. Matching the version string
 * itself would mean a script searching a page for a number it is about to
 * change — which is how `update_version.py` came to rewrite the wrong product.
 *
 *   node scripts/mac-site-version.js <index.html> [--version 4.0.0-alpha.2]
 */
const fs = require('fs');

/** Replace the version at the head of the marked line, leaving the rest. */
function setMacVersion(html, version) {
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(String(version || ''))) {
    throw new Error(`"${version}" is not a semver version`);
  }
  const marked = /(<[^>]*\bdata-mac-version\b[^>]*>)([^<]*)(<\/)/;
  const m = html.match(marked);
  if (!m) throw new Error('no element carrying data-mac-version — nothing to update');
  // Only the leading version token changes; "· macOS 26+ · notarized" is prose
  // that belongs to the page, not to the release.
  const rest = m[2].replace(/^\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\s*/, '');
  return html.replace(marked, `${m[1]}${version} ${rest}${m[3]}`);
}

module.exports = { setMacVersion };

if (require.main === module) {
  const file = process.argv[2];
  const i = process.argv.indexOf('--version');
  const version = i > -1 ? process.argv[i + 1]
    : JSON.parse(fs.readFileSync(require('path').join(__dirname, '..', 'mac', 'version.json'), 'utf8')).version;
  if (!file) { console.error('usage: mac-site-version.js <index.html> [--version X]'); process.exit(2); }
  const before = fs.readFileSync(file, 'utf8');
  const after = setMacVersion(before, version);
  if (before === after) { console.error(`already ${version} — nothing to change`); process.exit(0); }
  fs.writeFileSync(file, after);
  console.error(`site: Mac version → ${version}`);
}
