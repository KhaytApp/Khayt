'use strict';
/**
 * lib/launch-gate.js: the first-launch gate's rule, moved out of lib/main so
 * the Mac can bundle it (its "Khayt was updated" sheet, Mac page 28). The
 * desktop's behaviour is test/release-gates.test.js, unchanged.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const G = require('../lib/launch-gate.js');
const Main = require('../lib/main/launch-gate.js');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'lib', 'launch-gate.js'), 'utf8');

test('the desktop side runs the shared rule, not a copy', () => {
  assert.equal(Main.pending, G.pending);
  assert.equal(Main.FLOOR, G.FLOOR);
  assert.equal(Main.FILE, G.FILE);
  const mainSrc = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main', 'launch-gate.js'), 'utf8');
  assert.doesNotMatch(mainSrc, /function pending\(/);
});

test('loads without require, as JavaScriptCore loads it, and answers the same', () => {
  assert.doesNotMatch(SRC, /\brequire\(/);
  const ctx = {}; vm.createContext(ctx);
  vm.runInContext(SRC, ctx);
  ctx.gates = { '4.0.0-beta.43': ['A'], '4.0.0-beta.44': ['B'], '4.0.0-beta.9': ['old'] };
  const out = vm.runInContext("JSON.stringify(KhaytLaunchGate.pending({ current: '4.0.0-beta.44', seen: { lastRun: '4.0.0-beta.42' }, gates, hasBook: true, isNewer: KhaytLaunchGate.isNewer }))", ctx);
  assert.deepEqual(JSON.parse(out), { items: ['A', 'B'], versions: ['4.0.0-beta.43', '4.0.0-beta.44'] });
});

test('floor: a book with no record counts from the caller\'s floor; the default is the desktop\'s', () => {
  const gates = { '4.0.0-beta.43': ['A'], '4.0.0-beta.42': ['B'] };
  const run = (floor) => G.pending({ current: '4.0.0-beta.43', seen: null, gates, hasBook: true, isNewer: G.isNewer, floor }).items;
  assert.deepEqual(run('4.0.0-beta.42'), ['A']);
  assert.deepEqual(run('4.0.0-beta.41'), ['B', 'A']);
  assert.deepEqual(G.pending({ current: '4.11.0', seen: null, gates: { '4.11.0': ['X'], '4.10.3': ['Y'] }, hasBook: true, isNewer: G.isNewer }).items, ['X'], 'default floor 4.10.3');
  assert.deepEqual(run(''), G.pending({ current: '4.0.0-beta.43', seen: null, gates, hasBook: true, isNewer: G.isNewer }).items, 'empty floor is the default');
});

test('compareVersions orders as lib/updater.js isVersionNewer does', () => {
  // lib/updater.js needs electron to load; its version functions are pure,
  // so they are lifted out of its source and run as written.
  const up = fs.readFileSync(path.join(__dirname, '..', 'lib', 'updater.js'), 'utf8');
  const body = up.slice(up.indexOf('function isPrereleaseVersion('), up.indexOf('function isVersionNewer('));
  const fn = up.slice(up.indexOf('function isVersionNewer('));
  const isVersionNewer = new Function(body + fn.slice(0, fn.indexOf('\n}\n') + 2) + '; return isVersionNewer;')();
  const vs = ['4.0.0-alpha.1', '4.0.0-alpha.2', '4.0.0-beta.2', '4.0.0-beta.9', '4.0.0-beta.10', '4.0.0-beta.42', '4.0.0-rc.1', '4.0.0',
    '4.0.1', '4.10.0', '4.10.3', '4.11.0', '4.11.0-beta.1', '4.2.0', '10.0.0', '4.0.0-beta', '4.0.0-beta.x'];
  for (const a of vs) for (const b of vs) {
    assert.equal(G.isNewer(a, b), isVersionNewer(a, b), `${a} vs ${b}`);
    assert.equal(G.compareVersions(a, b) > 0, isVersionNewer(a, b), `${a} vs ${b}`);
  }
  assert.ok(G.compareVersions('4.0.0-beta.10', '4.0.0-beta.9') > 0);
  assert.equal(G.compareVersions('4.0.0-beta.9', '4.0.0-beta.9'), 0);
});

test('a downgrade (current older than the last run) and the same build show nothing', () => {
  const gates = { '4.0.0-beta.43': ['A'] };
  for (const lastRun of ['4.0.0-beta.44', '4.0.0-beta.43']) {
    assert.deepEqual(G.pending({ current: '4.0.0-beta.43', seen: { lastRun }, gates, hasBook: true, isNewer: G.isNewer }), { items: [], versions: [] });
  }
  assert.deepEqual(G.pending({ current: '4.0.0-beta.43', seen: null, gates, hasBook: false, isNewer: G.isNewer }).items, [], 'no book: nothing');
});

// ── lib/release-gates.json carries the Mac's versions (agreed with the Mac, Nov 23) ──
const { build } = require('../scripts/write-release-gates.js');
const sec = (v, mac, gate) => `## [${v}] - 2026-11-20\n\n${mac ? '*Khayt for macOS only. The Windows and Linux app is on its own version.*\n\n' : ''}${gate ? `### Before you update\n\n- ${gate}\n\n` : ''}### Fixed\n\n- x\n\n`;

test('Mac sections go to `mac`, desktop ones to `gates`, never across', () => {
  const log = '# Changelog\n\n## [Unreleased]\n\n' + sec('4.11.0', false, 'Desk') + sec('4.0.0-beta.42', true, 'MacA') + sec('4.10.3', false, null) + sec('4.0.0-beta.9', true, 'MacOld') + sec('4.0.0-beta.10', true, 'MacB');
  const r = build(log);
  assert.deepEqual(r.gates, { '4.11.0': ['Desk'] });
  assert.deepEqual(r.mac, { '4.0.0-beta.42': ['MacA'], '4.0.0-beta.10': ['MacB'], '4.0.0-beta.9': ['MacOld'] });
  assert.deepEqual(Object.keys(r.mac), ['4.0.0-beta.42', '4.0.0-beta.10', '4.0.0-beta.9'], 'newest first by version, not file order');
  assert.ok(Object.values(r.mac).every(Array.isArray), 'plain arrays of items');
});

test('the writer fails when a section\'s version and its macOS-only line disagree', () => {
  assert.throws(() => build(sec('4.0.0-beta.43', false, 'x')), /4\.0\.0-beta\.43/);
  assert.throws(() => build(sec('4.12.0', true, 'x')), /4\.12\.0/);
  assert.doesNotThrow(() => build(sec('4.0.0', false, 'x')), 'the desktop\'s own 4.0.0');
});

test('the shipped file has the Mac map, and the Mac reads its gates with the shared rule', () => {
  const file = require('../lib/release-gates.json');
  assert.ok(file.mac && typeof file.mac === 'object');
  assert.ok(file.mac['4.0.0-beta.42'] && file.mac['4.0.0-beta.42'].length);
  for (const v of Object.keys(file.gates)) assert.doesNotMatch(v, /^4\.0\.0-/, 'no Mac version in the desktop gates');
  const p = G.pending({ current: '4.0.0-beta.42', seen: { lastRun: '4.0.0-beta.41' }, gates: file.mac, hasBook: true, isNewer: G.isNewer });
  assert.deepEqual(p.versions, ['4.0.0-beta.42']);
});
