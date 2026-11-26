'use strict';
/**
 * Review of 4.12.0, LOW-7: an accept in the update dialog covers the items it
 * SHOWED, in the words it showed them, not the whole version. The dialog's
 * text came from the release (unsigned to this build), so the new build's
 * first launch skips only items whose own text is one the person was shown.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const G = require('../lib/launch-gate.js');
const { registerLaunchGate } = require('../lib/main/launch-gate.js');

const gates = { '4.12.0': ['Update every computer first.', 'Sign in to send a file.'], '4.11.0': ['Old item.'] };
const text = { '4.12.0': { ar: ['حدّث كل الأجهزة أولاً.', 'سجّل الدخول لإرسال ملف.'] } };
const at = (seen, lang) => G.pending({ current: '4.12.0', seen: { lastRun: '4.11.0', ...seen }, gates, hasBook: true, isNewer: G.isNewer, text, lang }).items;

test('the items the dialog showed, in these words, are read; nothing else is', () => {
  assert.deepEqual(at({ acceptedFor: '4.12.0', acceptedItems: ['Update every computer first.', 'Sign in to send a file.'] }), []);
  // A replaced text in the dialog: the build's own item is shown again.
  assert.deepEqual(at({ acceptedFor: '4.12.0', acceptedItems: ['Update every computer first.', 'Nothing important changed.'] }), ['Sign in to send a file.']);
  // Shown in Arabic, read in Arabic.
  assert.deepEqual(at({ acceptedFor: '4.12.0', acceptedItems: ['حدّث كل الأجهزة أولاً.', 'سجّل الدخول لإرسال ملف.'] }, 'ar'), []);
  // A tampered TRANSLATION (the English untouched) does not count as reading the real one.
  assert.deepEqual(at({ acceptedFor: '4.12.0', acceptedItems: ['حدّث كل الأجهزة أولاً.', 'لا شيء مهم.'] }, 'ar'), ['سجّل الدخول لإرسال ملف.']);
  // Read in English, launched in Arabic: the English counts.
  assert.deepEqual(at({ acceptedFor: '4.12.0', acceptedItems: ['Update every computer first.', 'Sign in to send a file.'] }, 'ar'), []);
  // No items sent: nothing is marked read.
  assert.deepEqual(at({ acceptedFor: '4.12.0', acceptedItems: [] }), ['Update every computer first.', 'Sign in to send a file.']);
});

test('a record without marks (from before this, the Mac\'s, the first-launch sheet) keeps the version mark, as before', () => {
  assert.deepEqual(at({ acceptedFor: '4.12.0' }), []);
  assert.deepEqual(G.pending({ current: '4.12.0', seen: { lastRun: '4.10.0', acceptedFor: '4.11.0' }, gates, hasBook: true, isNewer: G.isNewer }).items,
    ['Update every computer first.', 'Sign in to send a file.'], 'a version past the mark is still asked');
});

test('marks cover only versions up to acceptedFor', () => {
  const items = G.pending({ current: '4.12.0', seen: { lastRun: '4.10.0', acceptedFor: '4.11.0', acceptedItems: ['Old item.', 'Update every computer first.'] }, gates, hasBook: true, isNewer: G.isNewer }).items;
  assert.deepEqual(items, ['Update every computer first.', 'Sign in to send a file.'], 'a mark for 4.11.0 does not read 4.12.0\'s items');
});

test('L1: with no record of its own, the gate counts from the version that last opened the book, when the host knows it', () => {
  const run = (lastKnown) => G.pending({ current: '4.12.0', seen: null, gates, hasBook: true, isNewer: G.isNewer, lastKnown }).items;
  assert.deepEqual(run('4.11.0'), ['Update every computer first.', 'Sign in to send a file.'], 'a 4.11.0 book is not asked about 4.11.0 again');
  assert.deepEqual(run('4.11.2'), ['Update every computer first.', 'Sign in to send a file.']);
  assert.deepEqual(run('4.10.3'), ['Old item.', 'Update every computer first.', 'Sign in to send a file.'], 'a book from before 4.11.0 still reads it');
  assert.deepEqual(run('4.12.0'), [], 'the same version: nothing');
  // Unknown or not a version: the floor, as before (the safe way to be wrong).
  for (const bad of [null, undefined, '', 'garbage', '4.11', 7]) {
    assert.deepEqual(run(bad), ['Old item.', 'Update every computer first.', 'Sign in to send a file.'], String(bad));
  }
  // The file's own record still wins.
  assert.deepEqual(G.pending({ current: '4.12.0', seen: { lastRun: '4.10.0' }, gates, hasBook: true, isNewer: G.isNewer, lastKnown: '4.11.0' }).items,
    ['Old item.', 'Update every computer first.', 'Sign in to send a file.']);
  // A fresh install is never asked, whatever the marker says.
  assert.deepEqual(G.pending({ current: '4.12.0', seen: null, gates, hasBook: false, isNewer: G.isNewer, lastKnown: '4.10.0' }).items, []);
});

test('L1: main hands the rule the version read at start (lastKnownVersion)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lg-'));
  const handlers = new Map();
  try {
    registerLaunchGate({ ipcMain: { handle: (n, f) => handlers.set(n, f) }, userDataDir: () => dir, current: '4.12.0', gates, hasBook: () => true,
      isNewer: G.isNewer, lastKnownVersion: () => '4.11.0' });
    assert.deepEqual(handlers.get('hub:launch-gate')(null, 'en').items, ['Update every computer first.', 'Sign in to send a file.']);
    const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
    assert.match(src, /lastKnownVersion: \(\(\) => \{ let v = null; try \{ v = fs\.readFileSync\(path\.join\(app\.getPath\('userData'\), LAST_APP_VERSION_FILE\)/,
      'read once as the app starts, before writeAppVersionBackup overwrites it');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('main: the dialog\'s accept records the shown items, bounded; the first-launch accept clears them', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lg-'));
  const handlers = new Map();
  try {
    registerLaunchGate({ ipcMain: { handle: (n, f) => handlers.set(n, f) }, userDataDir: () => dir, current: '4.11.0', gates: {}, hasBook: () => true,
      isNewer: G.isNewer, offeredVersion: () => '4.12.0' });
    const file = path.join(dir, G.FILE);
    const read = () => JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(handlers.get('hub:launch-gate-accepted-in-update')(null, { version: '4.12.0', items: ['A', '', 7, 'x'.repeat(5000)] }), { ok: true });
    assert.deepEqual([read().acceptedFor, read().acceptedItems.length, read().acceptedItems[0], read().acceptedItems[1].length], ['4.12.0', 2, 'A', 4000]);
    // An older caller that sends the version alone: no marks, so nothing is read at the first launch.
    handlers.get('hub:launch-gate-accepted-in-update')(null, '4.12.0');
    assert.deepEqual(read().acceptedItems, []);
    // Never a version the updater did not offer.
    assert.equal(handlers.get('hub:launch-gate-accepted-in-update')(null, { version: '9.0.0', items: ['A'] }).ok, false);
    // The first-launch sheet shows the build's own items: the version mark alone.
    handlers.get('hub:launch-gate-accept')();
    assert.equal(read().acceptedItems, null);
    assert.equal(read().acceptedFor, '4.11.0');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
