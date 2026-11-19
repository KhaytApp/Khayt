'use strict';
/**
 * A crafted release feed cannot freeze the updater through lib/updater.js
 * notesSince's "is this note HTML?" check.
 *
 * 4.11.0 release review (LOW-2): `/<[a-z][\s\S]*>/i` re-scanned to the end of
 * the note from every `<letter`, so `<a` × n with no `>` was quadratic. It is
 * now `looksLikeHtml`, an indexOf walk. Pinned: 1-8 MB of `<a` with no `>` in
 * well under a second, about linear between them, and the same answer as the
 * old regex on ordinary notes.
 */
const Module = require('module');
const origRequire = Module.prototype.require;
Module.prototype.require = function (id) {
  if (id === 'electron-updater') {
    return { autoUpdater: { autoDownload: false, autoInstallOnAppQuit: true, allowPrerelease: false, fullChangelog: false, on() {} } };
  }
  return origRequire.apply(this, arguments);
};
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { notesSince, looksLikeHtml } = require('../lib/updater.js');

const ms = (f) => { const t = process.hrtime.bigint(); f(); return Number(process.hrtime.bigint() - t) / 1e6; };
const hostile = (bytes) => '<a'.repeat(Math.ceil(bytes / 2));

test('looksLikeHtml: 1 MB of <a with no > is fast', () => {
  const s = hostile(1 << 20);
  let r;
  const t = ms(() => { r = looksLikeHtml(s); });
  assert.equal(r, false);
  assert.ok(t < 200, `${t.toFixed(1)} ms`);
});

test('notesSince: 8 MB of <a with no > stays linear', () => {
  const feed = (b) => [{ version: '9.0.1', note: hostile(b) }, { version: '9.0.0', note: 'plain' }];
  const small = feed(1 << 20);
  const big = feed(8 << 20);
  const one = Math.max(ms(() => notesSince(small, '8.9.9')), 1);
  const eight = ms(() => notesSince(big, '8.9.9'));
  assert.ok(eight < 1000, `8 MB took ${eight.toFixed(1)} ms`);
  assert.ok(eight < one * 8 * 6 + 50, `1 MB ${one.toFixed(1)} ms, 8 MB ${eight.toFixed(1)} ms`);
});

// The notes go on into lib/major-changes.js parseMajorChanges, which had the
// same shape of regex in four more places: the tag strip (`<[^>]+>`, and
// `<li\b[^>]*>` — 30 s for 150 KB), the script/style blocks, the markdown link
// in an item (`[` × n), and `plain` re-run on the whole item at every
// continuation line. Each case starts with real HTML or a real consent section
// so the hostile text reaches the code that used to be slow.
const { parseMajorChanges } = require('../lib/major-changes.js');
const repeatTo = (unit, bytes) => unit.repeat(Math.ceil(bytes / unit.length));
const SECTION_HTML = '<h3>Before you update</h3><ul><li>';
const SECTION_MD = '### Before you update\n- ';
const NOTES = {
  'HTML then <a with no >': (b) => '<p>x</p>' + repeatTo('<a', b),
  'HTML then <li with no >': (b) => '<p>x</p>' + repeatTo('<li', b),
  'HTML then <h1 with no >': (b) => '<p>x</p>' + repeatTo('<h1', b),
  'HTML then <script with no closer': (b) => '<p>x</p>' + repeatTo('<script></script><script', b),
  'a consent item of [ with no ]': (b) => SECTION_HTML + repeatTo('[', b),
  'a consent item of [x]( with no )': (b) => SECTION_MD + repeatTo('[x](', b),
  'a consent item wrapped over many lines': (b) => SECTION_MD + repeatTo('more words on a line\n', b),
};
for (const [name, make] of Object.entries(NOTES)) {
  test(`parseMajorChanges: ${name}: 8 MB stays linear`, () => {
    const small = make(1 << 20);
    const big = make(8 << 20);
    const one = Math.max(ms(() => parseMajorChanges(small)), 1);
    const eight = ms(() => parseMajorChanges(big));
    assert.ok(eight < 1500, `8 MB took ${eight.toFixed(1)} ms`);
    assert.ok(eight < one * 8 * 6 + 50, `1 MB ${one.toFixed(1)} ms, 8 MB ${eight.toFixed(1)} ms`);
  });
}

// The update dialog formats the same notes (lib/release-notes.js), with the
// same HTML check and the same script-block regex.
const { formatReleaseNotesText, sanitizeReleaseNotesHtml } = require('../lib/release-notes.js');
for (const [name, make] of Object.entries({
  '<a with no >': (b) => repeatTo('<a', b),
  'HTML then <script with no closer': (b) => '<p>x</p>' + repeatTo('<script></script><script', b),
})) {
  test(`formatReleaseNotesText: ${name}: 8 MB stays linear`, () => {
    const one = Math.max(ms(() => formatReleaseNotesText(make(1 << 20))), 1);
    const eight = ms(() => formatReleaseNotesText(make(8 << 20)));
    assert.ok(eight < 1500, `8 MB took ${eight.toFixed(1)} ms`);
    assert.ok(eight < one * 8 * 6 + 50, `1 MB ${one.toFixed(1)} ms, 8 MB ${eight.toFixed(1)} ms`);
  });
}

test('sanitizeReleaseNotesHtml still drops every script block, any case', () => {
  assert.equal(sanitizeReleaseNotesHtml('<p onclick="x">a<script>b</script>c<SCRIPT src=1></Script>d</p>'), '<p>acd</p>');
  assert.equal(sanitizeReleaseNotesHtml('a<script>b'), 'a<script>b', 'an unclosed one is left as the regex left it');
});

test('parseMajorChanges still strips tags, script blocks and links as before', () => {
  const r = parseMajorChanges('<h3>Before you update</h3><ul><li>The <b>buttons</b> moved'
    + '<script>alert(1)</script> — see [the guide](https://x.test/a)</li><li><>odd <a href="#">link</a></li></ul>'
    + '<h3>Fixed</h3><ul><li>not this</li></ul>');
  assert.deepEqual(r.items, ['The buttons moved — see the guide', '<>odd link']);
  const md = parseMajorChanges('### Before you update\n\n- **Bold** first line\n  wraps here\n- second\n\n### Fixed\n- no');
  assert.deepEqual(md.items, ['Bold first line wraps here', 'second']);
});

test('looksLikeHtml answers as the old regex did on ordinary notes', () => {
  const old = (s) => /<[a-z][\s\S]*>/i.test(s);
  const notes = [
    '',
    'plain text',
    '## 4.11.0\n\n- Fixed a thing',
    '<p>Hello</p>',
    '<ul>\n<li>one</li>\n</ul>',
    '<P CLASS="x">upper</P>',
    'a < b and c > d',
    'x <1> y',
    '<a',
    '<a>',
    'text <b',
    'arrow -> then <em',
    '> first then <a',
    '<>',
    '< a>',
    '<a\nmulti\nline>',
    'emoji 🎉 <span>ok</span>',
    'Arabic <strong>خيط</strong>',
    '<ſ>',
  ];
  for (const n of notes) assert.equal(looksLikeHtml(n), old(n), JSON.stringify(n));
});

test('notesSince still wraps HTML notes in <h2> headings and markdown in ##', () => {
  const html = notesSince([{ version: '2.0.1', note: '<p>b</p>' }, { version: '2.0.0', note: 'a' }], '1.9.9');
  assert.match(html.text, /<h2>[^<]* 2\.0\.1<\/h2>/);
  const md = notesSince([{ version: '2.0.1', note: 'b' }, { version: '2.0.0', note: 'a' }], '1.9.9');
  assert.match(md.text, /^## .* 2\.0\.1/);
});
