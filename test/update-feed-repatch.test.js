const { test } = require('node:test');
const assert = require('node:assert/strict');

// The script is ESM (it lives alongside the other build .mjs scripts), so it is
// pulled in dynamically rather than required.
const load = () => import('../scripts/repatch-update-feed.mjs');

/**
 * Signing/stapling changes artifact bytes after electron-builder wrote the feed,
 * so the feed then describes bytes that no longer exist and electron-updater
 * refuses the download. These pin the two things that matter: every hash that
 * belongs to a changed file is rewritten (including the top-level mirror, which
 * is the one a hand-edit forgets), and lines that are none of this script's
 * business are returned byte-for-byte.
 */

// Verbatim shape of bedready-v1.0.0/latest.yml.
const WIN_FEED = [
  'version: 1.0.0',
  'files:',
  '  - url: BedReady-1.0.0-win-x64-Setup.exe',
  '    sha512: OLDHASH==',
  '    size: 131838380',
  'path: BedReady-1.0.0-win-x64-Setup.exe',
  'sha512: OLDHASH==',
  "releaseDate: '2026-08-03T20:00:15.411Z'",
  '',
].join('\n');

const H = { 'BedReady-1.0.0-win-x64-Setup.exe': { sha512: 'NEWHASH==', size: 999 } };

test('the files[] entry and the top-level mirror are both rewritten', async () => {
  const { repatch } = await load();
  const r = repatch(WIN_FEED, H);
  assert.match(r.text, /^ {4}sha512: NEWHASH==$/m);
  assert.match(r.text, /^ {4}size: 999$/m);
  assert.match(r.text, /^sha512: NEWHASH==$/m, 'top-level sha512 must track path:');
  assert.equal(/OLDHASH/.test(r.text), false, 'no stale hash may survive');
});

test('lines this script has no business touching come back byte-for-byte', async () => {
  const { repatch } = await load();
  const out = (await load()).repatch(WIN_FEED, H).text.split('\n');
  assert.equal(out[0], 'version: 1.0.0');
  assert.equal(out[1], 'files:');
  assert.equal(out[2], '  - url: BedReady-1.0.0-win-x64-Setup.exe');
  assert.equal(out[5], 'path: BedReady-1.0.0-win-x64-Setup.exe');
  assert.equal(out[7], "releaseDate: '2026-08-03T20:00:15.411Z'", 'quoting must survive');
});

test('an artifact that is not on disk is left completely alone', async () => {
  const { repatch } = await load();
  const r = repatch(WIN_FEED, {});
  assert.equal(r.text, WIN_FEED);
  assert.deepEqual(r.changed, []);
  assert.deepEqual(r.skipped, ['BedReady-1.0.0-win-x64-Setup.exe']);
});

test('a multi-file feed rewrites only the file that changed', async () => {
  const { repatch } = await load();
  const feed = [
    'version: 1.0.0',
    'files:',
    '  - url: A.exe',
    '    sha512: AAA==',
    '    size: 1',
    '  - url: B.exe',
    '    sha512: BBB==',
    '    size: 2',
    'path: A.exe',
    'sha512: AAA==',
    '',
  ].join('\n');
  const r = repatch(feed, { 'A.exe': { sha512: 'NEW==', size: 10 } });
  assert.match(r.text, /- url: A\.exe\n    sha512: NEW==\n    size: 10/);
  assert.match(r.text, /- url: B\.exe\n    sha512: BBB==\n    size: 2/, 'B is untouched');
  assert.deepEqual(r.skipped, ['B.exe']);
});

test('the top-level sha512 follows path:, not merely the first file', async () => {
  const { repatch } = await load();
  const feed = [
    'version: 1.0.0',
    'files:',
    '  - url: A.exe',
    '    sha512: AAA==',
    '    size: 1',
    '  - url: B.exe',
    '    sha512: BBB==',
    '    size: 2',
    'path: B.exe',
    'sha512: BBB==',
    '',
  ].join('\n');
  const r = repatch(feed, { 'B.exe': { sha512: 'NEWB==', size: 20 } });
  // The mac feed's `path:` is the .zip while the .dmg is also listed — patching
  // the top-level from the wrong entry is exactly how an update breaks.
  assert.match(r.text, /^sha512: NEWB==$/m);
  assert.match(r.text, /- url: A\.exe\n    sha512: AAA==/, 'A must not be dragged along');
});

test('sha512 is base64 of the digest, which is what electron-updater compares', async () => {
  const { sha512Base64 } = await load();
  const { createHash } = require('node:crypto');
  const buf = Buffer.from('bed ready');
  assert.equal(sha512Base64(buf), createHash('sha512').update(buf).digest('base64'));
  assert.equal(/^[A-Za-z0-9+/]+={0,2}$/.test(sha512Base64(buf)), true, 'base64, not hex');
});
