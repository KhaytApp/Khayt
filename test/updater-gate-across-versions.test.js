'use strict';
/**
 * The consent gate across skipped releases (lib/updater.js notesSince).
 *
 * The gate read only the NEWEST release's notes, so a shop that skipped a
 * gated release was never asked about it: 4.9.0 → 4.10.1 would have taken
 * 4.10.0's redesign unasked (Nov 17). With electron-updater's fullChangelog,
 * releaseNotes is [{ version, note }] newest first, and every gated release
 * newer than the installed one is asked about, oldest first, each item once.
 */
const Module = require('module');
const origRequire = Module.prototype.require;
let stub;
Module.prototype.require = function (id) {
  if (id === 'electron-updater') {
    stub = stub || { autoDownload: false, autoInstallOnAppQuit: true, allowPrerelease: false, fullChangelog: false, on() {} };
    return { autoUpdater: stub };
  }
  return origRequire.apply(this, arguments);
};

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { notesSince, interpretUpdateCheckResult } = require('../lib/updater.js');

const gated = (title) => `<h3>Before you update</h3>\n<ul>\n<li><strong>${title}</strong> Read this.</li>\n</ul>\n<h3>Fixed</h3>\n<ul><li>Something.</li></ul>`;
const plain = '<h3>Fixed</h3>\n<ul><li>A small fix.</li></ul>';
// What GitHubProvider hands over for an update to 4.11.0: newest first.
const FEED = [
  { version: '4.11.0', note: plain },
  { version: '4.10.1', note: gated('Carried from 4.10.0 for 4.9 shops.') },
  { version: '4.10.0', note: gated('The redesign.') },
];

test('the updater asks electron-updater for every release since the installed one (Khayt)', () => {
  assert.equal(stub.fullChangelog, true);
});

test('skipping two gated releases asks about both, oldest first', () => {
  const r = notesSince(FEED, '4.9.0');
  assert.equal(r.majorChanges.needsConsent, true);
  assert.equal(r.majorChanges.items.length, 2);
  assert.match(r.majorChanges.items[0], /The redesign/);
  assert.match(r.majorChanges.items[1], /Carried from 4\.10\.0/);
});

test('a shop already past a gated release is not asked about it again', () => {
  // electron-updater lists only versions newer than the installed one, and
  // notesSince drops any older entry it is handed all the same.
  const r = notesSince(FEED, '4.10.0');
  assert.equal(r.majorChanges.items.length, 1);
  assert.match(r.majorChanges.items[0], /Carried/);
  const past = notesSince(FEED, '4.10.1');
  assert.equal(past.majorChanges.needsConsent, false);
  assert.deepEqual(past.majorChanges.items, []);
});

test('the same item in two releases is asked once', () => {
  const r = notesSince([{ version: '2.1.0', note: gated('Same.') }, { version: '2.0.0', note: gated('Same.') }], '1.9.0');
  assert.equal(r.majorChanges.items.length, 1);
});

test('the notes shown name each release, newest first; one release is shown as it is', () => {
  const r = notesSince(FEED, '4.9.0');
  const at = (v) => r.text.indexOf(`Khayt ${v}</h2>`);
  assert.ok(at('4.11.0') >= 0 && at('4.11.0') < at('4.10.1') && at('4.10.1') < at('4.10.0'));
  assert.equal(notesSince([FEED[0]], '4.10.1').text, plain);
});

test('a string is the newest release alone, as before; nothing is no notes', () => {
  const s = notesSince(gated('Only this.'), '1.0.0');
  assert.equal(s.majorChanges.needsConsent, true);
  assert.equal(s.text, gated('Only this.'));
  assert.deepEqual(notesSince(null, '1.0.0'), { text: '', majorChanges: { needsConsent: false, items: [] } });
});

test('the manual check carries the gate across versions too', () => {
  const r = interpretUpdateCheckResult({
    isPackaged: true, currentVersion: '4.9.0',
    updateInfo: { version: '4.11.0', releaseNotes: FEED },
  });
  assert.equal(r.status, 'available');
  assert.equal(r.majorChanges.items.length, 2);
  assert.match(r.releaseNotes, /Khayt 4\.10\.0/);
});

test('a version label cannot inject markup', () => {
  const r = notesSince([{ version: '9.0.0"><img src=x>', note: plain }, { version: '8.0.0', note: plain }], '1.0.0');
  assert.doesNotMatch(r.text, /<img/);
});
