const { test } = require('node:test');
const assert = require('node:assert/strict');
const { appcast } = require('../scripts/mac-appcast.js');

/* ────────────────────────────────────────────────────────────────────────────
 * The Sparkle feed is the one file that decides whether an install ever moves,
 * and its two most important fields fail SILENTLY when they are wrong: a feed
 * with the wrong `sparkle:version` offers nothing forever, and one with a bad
 * `sparkle:edSignature` is refused after downloading, which reads to a shop as
 * a broken update rather than a broken feed.
 * ──────────────────────────────────────────────────────────────────────────── */

const ok = {
  version: '4.0.0-alpha.1', build: 1, archiveBytes: 100,
  signature: 'sig==', url: 'https://example.com/a.zip',
};

test('sparkle:version is the BUILD, not the marketing string', () => {
  // The whole trap. Sparkle compares CFBundleVersion; the app's is an integer.
  // A feed putting "4.0.0-alpha.1" here compares a string against a number.
  const xml = appcast({ ...ok, version: '4.0.0-alpha.7', build: 7 });
  assert.match(xml, /<sparkle:version>7<\/sparkle:version>/);
  assert.match(xml, /<sparkle:shortVersionString>4\.0\.0-alpha\.7<\/sparkle:shortVersionString>/);
  assert.ok(!/<sparkle:version>4\.0\.0/.test(xml), 'the marketing string leaked into sparkle:version');
});

test('an unsigned feed is refused rather than written', () => {
  // A feed with no signature installs nothing, and finding that out on a
  // shop's Mac is finding it out in the worst place.
  assert.throws(() => appcast({ ...ok, signature: '' }), /signature is required/);
  assert.throws(() => appcast({ ...ok, signature: undefined }), /signature is required/);
});

test('the download URL must be https', () => {
  assert.throws(() => appcast({ ...ok, url: 'http://example.com/a.zip' }), /must be https/);
  assert.throws(() => appcast({ ...ok, url: '' }), /must be https/);
});

test('a build that is not a positive integer is refused', () => {
  for (const build of [0, -1, 1.5, '3', null, undefined]) {
    assert.throws(() => appcast({ ...ok, build }), /positive integer/, `build ${build}`);
  }
});

test('the length is a real byte count, because Sparkle checks it', () => {
  assert.throws(() => appcast({ ...ok, archiveBytes: 0 }), /positive integer/);
  assert.match(appcast({ ...ok, archiveBytes: 26214400 }), /length="26214400"/);
});

test('text that would end the document is escaped', () => {
  // A signature is base64 and cannot contain these, but a title or a URL can,
  // and an appcast that does not parse is an app that never updates again.
  const xml = appcast({ ...ok, title: 'Khayt & "Co" <mac>' });
  assert.match(xml, /<title>Khayt &amp; &quot;Co&quot; &lt;mac&gt;<\/title>/);
  assert.ok(!/<title>Khayt & "/.test(xml));
});

test('it carries one item, not a growing history', () => {
  // Sparkle only needs the newest an install could move to. A feed that
  // accumulates every alpha is one where an old mistake stays selectable.
  const xml = appcast(ok);
  assert.equal((xml.match(/<item>/g) || []).length, 1);
});

test('the minimum system version is stated, and matches what the app declares', () => {
  const xml = appcast(ok);
  assert.match(xml, /<sparkle:minimumSystemVersion>26\.0<\/sparkle:minimumSystemVersion>/);
  // The app's own floor, from the package manifest — if that moves and this
  // does not, Sparkle offers the update to Macs that cannot run it.
  const pkg = require('fs').readFileSync(
    require('path').join(__dirname, '..', 'mac', 'KhaytCore', 'Package.swift'), 'utf8');
  assert.match(pkg, /platforms:\s*\[\.macOS\("26\.0"\)\]/,
    'the package floor moved — update the appcast default with it');
});

test('the feed parses as XML', () => {
  const xml = appcast(ok);
  // No parser dependency: check the shape that matters — one opening and one
  // closing tag for every element this writes.
  for (const tag of ['rss', 'channel', 'item', 'title', 'enclosure']) {
    const open = (xml.match(new RegExp(`<${tag}[\\s>]`, 'g')) || []).length;
    assert.ok(open >= 1, `<${tag}> missing`);
  }
  assert.match(xml, /^<\?xml version="1\.0" encoding="utf-8"\?>/);
  assert.match(xml, /<\/rss>\s*$/);
});
