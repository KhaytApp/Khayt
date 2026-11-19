'use strict';
/**
 * A crafted release feed cannot freeze the updater through lib/updater.js
 * notesSince's "is this note HTML?" check.
 *
 * 4.11.0 release review (LOW-2): `/<[a-z][\s\S]*>/i` re-scanned to the end of
 * the note from every `<letter`, so `<a` × n with no `>` was quadratic. It is
 * now `looksLikeHtml`, an indexOf walk. Pinned: 1 MB of `<a` with no `>` in
 * well under a second, and the same answer as the old regex on ordinary notes.
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

// notesSince as a whole is not linear yet: it hands every note on to
// lib/major-changes.js parseMajorChanges, which has the same shape of regex
// (8 MB of `<a` there takes minutes). Making that linear, and pinning
// notesSince at 8 MB, is a separate draft PR (notes-parser-linear), after the
// 4.11.0 release.

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
