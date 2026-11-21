'use strict';
/**
 * The "Before you update" gate on the first launch of a new version
 * (lib/main/launch-gate.js), for installs the update dialog never sees:
 * the Microsoft Store and installers run by hand (4.11.0, Nov 20).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { pending } = require('../lib/main/launch-gate.js');
const { build, render, OUT } = require('../scripts/write-release-gates.js');

// A plain x.y.z comparison is enough for these vectors; main passes the updater's.
const parts = (v) => String(v).split('-')[0].split('.').map(Number);
const isNewer = (a, b) => { const x = parts(a), y = parts(b); for (let i = 0; i < 3; i++) { if (x[i] !== y[i]) return x[i] > y[i]; } return false; };
const gates = { '4.11.0': ['A', 'B'], '4.10.0': ['C'], '4.3.0': ['D'] };
const run = (seen, extra = {}) => pending({ current: '4.11.0', seen, gates, hasBook: true, isNewer, ...extra }).items;

test('lib/release-gates.json is what CHANGELOG.md says (run scripts/write-release-gates.js at the cut)', () => {
  const want = render(build(fs.readFileSync(path.join(__dirname, '..', 'CHANGELOG.md'), 'utf8')));
  assert.equal(fs.readFileSync(OUT, 'utf8'), want);
});

test('it ships: lib/ is in the app, and the gates of the newest release are there', () => {
  const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));
  assert.ok(pkg.build.files.includes('lib/**/*'));
  const g = JSON.parse(fs.readFileSync(OUT, 'utf8')).gates;
  assert.ok(Object.keys(g).length > 0);
});

test('from the version before: this version\'s items', () => {
  assert.deepEqual(run({ lastRun: '4.10.3' }), ['A', 'B']);
});

test('skipping releases: every gate since, oldest first, each item once', () => {
  assert.deepEqual(run({ lastRun: '4.9.0' }), ['C', 'A', 'B']);
  assert.deepEqual(run({ lastRun: '4.2.0' }), ['D', 'C', 'A', 'B']);
  const dup = pending({ current: '4.11.0', seen: { lastRun: '4.9.0' }, gates: { '4.10.0': ['X'], '4.11.0': ['X', 'Y'] }, hasBook: true, isNewer }).items;
  assert.deepEqual(dup, ['X', 'Y']);
});

test('already read in the update dialog: not asked again; read for an older version: only what is newer', () => {
  assert.deepEqual(run({ lastRun: '4.10.3', acceptedFor: '4.11.0' }), []);
  assert.deepEqual(run({ lastRun: '4.9.0', acceptedFor: '4.10.0' }), ['A', 'B']);
});

test('the same build, an older one, or a version with no gate: nothing', () => {
  assert.deepEqual(run({ lastRun: '4.11.0' }), []);
  assert.deepEqual(run({ lastRun: '4.12.0' }), []);
  assert.deepEqual(run({ lastRun: '4.11.0' }, { current: '4.11.1' }), []);
});

test('nothing remembered: a fresh install is not warned; a shop\'s book counts as coming from the floor (4.10.3)', () => {
  const { FLOOR } = require('../lib/main/launch-gate.js');
  assert.equal(FLOOR, '4.10.3');
  assert.deepEqual(run(null, { hasBook: false }), []);
  assert.deepEqual(run(null), ['A', 'B']);
  assert.deepEqual(run('junk'), ['A', 'B']);
  // A later build with no gate of its own still shows what came after the floor
  // (reviews of #2610: the first draft showed nothing here).
  assert.deepEqual(run(null, { current: '4.11.1' }), ['A', 'B']);
  assert.deepEqual(run(null, { current: '4.12.0' }), ['A', 'B']);
  assert.deepEqual(run(null, { current: '4.10.3' }), [], 'nothing after the floor yet');
});

test('accepted in the update dialog: only for a version the updater offered, never higher', () => {
  const { registerLaunchGate } = require('../lib/main/launch-gate.js');
  const files = {};
  const fsFake = { readFileSync: (f) => { if (!(f in files)) throw new Error('ENOENT'); return files[f]; }, writeFileSync: (f, d) => { files[f] = d; } };
  const handlers = {};
  let offered = '';
  registerLaunchGate({
    ipcMain: { handle: (ch, fn) => { handlers[ch] = fn; } }, userDataDir: () => '/u', current: '4.11.0', gates,
    hasBook: () => true, isNewer, fs: fsFake, path: require('path'), offeredVersion: () => offered,
  });
  const accept = (v) => handlers['hub:launch-gate-accepted-in-update']({}, v);
  assert.equal(accept('4.12.0').ok, false, 'nothing offered yet');
  offered = '4.12.0';
  assert.equal(accept('99.0.0').ok, false, 'higher than offered');
  assert.equal(accept('4.11.0').ok, false, 'not newer than this build');
  assert.equal(accept('4.12.0').ok, true);
  assert.equal(JSON.parse(files[require('path').join('/u', 'last-run-version.json')]).acceptedFor, '4.12.0');
  const upd = fs.readFileSync(path.join(__dirname, '..', 'lib/updater.js'), 'utf8');
  assert.match(upd, /noteOffered\(interpreted\.version\);\s*\n\s*const since/);
  assert.match(upd, /if \(interpreted\.status === 'available'\) noteOffered\(interpreted\.version\);/);
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8'), /offeredVersion: \(\) => require\('\.\/lib\/updater'\)\.offeredUpdateVersion\(\)/);
});

test('the window holds it: no Later, no Escape, Continue only once ticked, and an accept in the update dialog is remembered', () => {
  const ui = fs.readFileSync(path.join(__dirname, '..', 'renderer/update-ui.js'), 'utf8');
  const fn = ui.slice(ui.indexOf('async function showLaunchGateIfNeeded'), ui.indexOf('const api = {'));
  assert.match(fn, /id="launchGateContinue" disabled/);
  assert.match(fn, /e\.key === 'Escape'/);
  // Re-review: later dialogs are held back too, and given back on Continue.
  assert.match(fn, /new MutationObserver\(/);
  assert.match(fn, /later\.disconnect\(\);\s*\n\s*for \(const el of madeInert\) el\.inert = false;/);
  assert.doesNotMatch(fn, /data-upd="later"/);
  assert.match(ui, /launchGateAcceptedInUpdate\?\.\(activeUpdateInfo\.version\)/);
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'renderer/app-boot.js'), 'utf8'), /showLaunchGateIfNeeded\(\)/);
  for (const l of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const s = fs.readFileSync(path.join(__dirname, '..', `renderer/locales/${l}.js`), 'utf8');
    for (const k of ['upd.launch_title', 'upd.launch_accept', 'upd.launch_continue']) assert.match(s, new RegExp(`"${k.replace('.', '\\.')}":`), `${l} ${k}`);
  }
});
