'use strict';
/**
 * The "Before you update" items in the shop's language (Turki, Nov 23):
 * release-gates.json `i18n`, filled at the cut from
 * scripts/release-gates-translations.json, picked by lib/launch-gate.js.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const G = require('../lib/launch-gate.js');
const W = require('../scripts/write-release-gates.js');

const gates = { '4.11.0': ['A', 'B'], '4.10.0': ['C'] };
const text = { '4.11.0': { ar: ['أ', 'ب'], de: ['A-de', null] }, '4.10.0': { ar: ['ج'] } };
const run = (lang, extra = {}) => G.pending({ current: '4.11.0', seen: { lastRun: '4.9.0' }, gates, hasBook: true, isNewer: G.isNewer, text, lang, ...extra }).items;

test('the items come in the app\'s language', () => {
  assert.deepEqual(run('ar'), ['ج', 'أ', 'ب']);
});

test('fallback: a missing item, a missing language, English, or no text at all is English', () => {
  assert.deepEqual(run('de'), ['C', 'A-de', 'B'], 'a null item and a version with no German');
  assert.deepEqual(run('ja'), ['C', 'A', 'B'], 'a language nobody translated');
  assert.deepEqual(run('en'), ['C', 'A', 'B']);
  assert.deepEqual(run(''), ['C', 'A', 'B']);
  assert.deepEqual(run('ar', { text: null }), ['C', 'A', 'B']);
  assert.deepEqual(run(undefined, { text: undefined }), G.pending({ current: '4.11.0', seen: { lastRun: '4.9.0' }, gates, hasBook: true, isNewer: G.isNewer }).items, 'as before #2679+i18n');
});

test('an array of another length is not trusted: English, never a shifted item', () => {
  assert.deepEqual(run('ar', { text: { '4.11.0': { ar: ['only one'] } } }), ['C', 'A', 'B']);
  assert.deepEqual(run('ar', { text: { '4.11.0': { ar: ['', '  '] } } }), ['C', 'A', 'B'], 'blank is English');
});

test('the same English item in two versions shows once, in the language', () => {
  const g = { '4.10.0': ['X'], '4.11.0': ['X', 'Y'] };
  const t = { '4.10.0': { ar: ['س'] }, '4.11.0': { ar: ['س', 'ص'] } };
  assert.deepEqual(G.pending({ current: '4.11.0', seen: { lastRun: '4.9.0' }, gates: g, hasBook: true, isNewer: G.isNewer, text: t, lang: 'ar' }).items, ['س', 'ص']);
});

test('still loads under JavaScriptCore\'s rules and picks the language there', () => {
  const ctx = {}; vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'launch-gate.js'), 'utf8'), ctx);
  ctx.args = { current: '4.0.0-beta.43', seen: { lastRun: '4.0.0-beta.42' }, gates: { '4.0.0-beta.43': ['M'] }, hasBook: true, text: { '4.0.0-beta.43': { ar: ['م'] } }, lang: 'ar' };
  assert.equal(vm.runInContext('args.isNewer = KhaytLaunchGate.isNewer; KhaytLaunchGate.pending(args).items[0]', ctx), 'م');
});

// ── The generator ─────────────────────────────────────────────────────────
const sec = (v, mac, gate) => `## [${v}] - 2026-11-20\n\n${mac ? '*Khayt for macOS only.*\n\n' : ''}### Before you update\n\n- ${gate}\n\n`;
const log = sec('4.11.0', false, 'Desk one') + sec('4.0.0-beta.42', true, 'Mac one');

test('generator: translations fill i18n by the English item\'s id; gates and mac stay English', () => {
  const tr = { items: { [W.itemId('Desk one')]: { en: 'Desk one', ar: 'مكتب', fr: 'Bureau' }, [W.itemId('Mac one')]: { ar: 'ماك' } } };
  const r = W.build(log, tr);
  assert.deepEqual(r.gates, { '4.11.0': ['Desk one'] });
  assert.deepEqual(r.mac, { '4.0.0-beta.42': ['Mac one'] });
  assert.deepEqual(r.i18n.gates, { '4.11.0': { ar: ['مكتب'], fr: ['Bureau'] } });
  assert.deepEqual(r.i18n.mac, { '4.0.0-beta.42': { ar: ['ماك'] } });
  assert.ok(W.untranslated(r).includes('gates 4.11.0 #1 de'));
});

test('generator: an item whose English changed loses its translation (English, not a stale text)', () => {
  const tr = { items: { [W.itemId('Desk one, as first written')]: { ar: 'قديم' } } };
  assert.deepEqual(W.build(log, tr).i18n.gates, {});
});

test('the shipped file: desktop and Mac English unchanged by translations, and Arabic for the current items', () => {
  const file = JSON.parse(fs.readFileSync(W.OUT, 'utf8'));
  const changelog = fs.readFileSync(path.join(__dirname, '..', 'CHANGELOG.md'), 'utf8');
  const bare = W.build(changelog, { items: {} });
  assert.deepEqual(file.gates, bare.gates, 'translations never touch the desktop gates');
  assert.deepEqual(file.mac, bare.mac);
  assert.equal(JSON.stringify(file.gates), JSON.stringify(bare.gates), 'byte for byte');
  for (const [key, v] of [['gates', '4.11.0'], ['mac', '4.0.0-beta.42']]) {
    const ar = file.i18n[key][v] && file.i18n[key][v].ar;
    assert.ok(Array.isArray(ar) && ar.length === file[key][v].length && ar.every((x) => typeof x === 'string' && /[؀-ۿ]/.test(x)), `${key} ${v} has Arabic for every item`);
    assert.ok(ar.every((x) => !/\bKhayt\b/.test(x)), 'Arabic writes خيط, never Latin Khayt');
  }
});

test('the translations file: every entry names a current or past English item and only known languages', () => {
  const t = JSON.parse(fs.readFileSync(W.TRANSLATIONS, 'utf8'));
  for (const [id, entry] of Object.entries(t.items)) {
    if (typeof entry.en === 'string') assert.equal(W.itemId(entry.en), id, `id ${id} matches its English`);
    for (const k of Object.keys(entry)) assert.ok(k === 'en' || W.LANGS.includes(k), `${id}: ${k}`);
  }
});

test('desktop: the window asks in its language, and main passes the translations', () => {
  const ui = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'update-ui.js'), 'utf8');
  assert.match(ui, /hubAPI\?\.launchGate\?\.\(lang\)/);
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /return \(f\.i18n && f\.i18n\.gates\) \|\| null;/);
  const pre = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  assert.match(pre, /launchGate: +\(lang\) => ipcRenderer\.invoke\('hub:launch-gate', String\(lang \|\| ''\)\)/);
});
