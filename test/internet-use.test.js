'use strict';
/**
 * Settings › General › Internet use (P8 PR 5): the renderer's rules, its
 * strings in every language, the preload hook and the wiring. The real app
 * is driven by scripts/e2e-internet-use-smoke.mjs.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const ROOT = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(ROOT, f), 'utf8');
const LANGS = ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh'];
const Outbound = require('../lib/outbound.js');

function locale(lang) {
  const ctx = { globalThis: {} }; ctx.window = ctx.globalThis; vm.createContext(ctx);
  vm.runInContext(read(`renderer/locales/${lang}.js`), ctx);
  return ctx.globalThis.KhaytLocales[lang];
}

function load(settingsObj) {
  const en = locale('en');
  const ctx = {
    settings: settingsObj,
    t: (k, p) => { let s = en[k]; if (s === undefined) return k; for (const [a, b] of Object.entries(p || {})) s = s.split(`{${a}}`).join(String(b)); return s; },
    addEventListener() {}, document: { readyState: 'complete', getElementById: () => null, addEventListener() {} },
    setInterval() {}, Date, JSON, Object, Array, String, Number, Math,
  };
  ctx.window = ctx; vm.createContext(ctx);
  vm.runInContext(read('renderer/internet-use.js'), ctx);
  return ctx.KhaytInternetUse;
}

test('every Internet use string exists in all 9 languages, placeholders kept', () => {
  const en = locale('en');
  const keys = Object.keys(en).filter((k) => /^(iu\.|outbound\.blocked\.)/.test(k)).concat(['err.refused_network']);
  assert.ok(keys.length >= 100, `${keys.length}`);
  for (const lang of LANGS) {
    const l = locale(lang);
    for (const k of keys) {
      assert.equal(typeof l[k], 'string', `${lang} ${k}`);
      assert.ok(l[k].trim(), `${lang} ${k} empty`);
      const want = (en[k].match(/\{[a-z]+\}/g) || []).sort().join();
      assert.equal((l[k].match(/\{[a-z]+\}/g) || []).sort().join(), want, `${lang} ${k} placeholders`);
    }
  }
  // Every purpose the page lists has a name, a description and an in-sentence name.
  const iu = load({});
  for (const p of iu.ORDER) for (const pre of ['iu.p.', 'iu.d.', 'iu.in.']) assert.ok(en[pre + p], pre + p);
  for (const p of Outbound.PURPOSES) assert.ok(en['iu.in.' + p], 'iu.in.' + p);
  // No `t() || 'x'` fallbacks in the new code (they hide a missing key).
  assert.doesNotMatch(read('renderer/internet-use.js'), /tr\([^)]*\)\s*\|\|\s*'/);
});

test('rows in frame A order: every describe() purpose but the Mac-only lookups', () => {
  const iu = load({});
  assert.deepEqual([...iu.ORDER].sort(), Outbound.PURPOSES.filter((p) => p !== 'lookups').sort());
});

test('the state of a row: Blocked, Kept, Allowed, Off (its own switch), Not set up, Always', () => {
  const s = { network: { offline: true, keep: ['messaging'] }, telemetry: { crashOptIn: false }, emailConfig: { provider: 'sendgrid' }, webhooks: { enabled: false } };
  const iu = load(s);
  const rows = Outbound.describe(s, { local: {} });
  const st = (p, ctx) => iu.stateOf(rows.find((r) => r.purpose === p), ctx || {}).key;
  assert.equal(st('updates'), 'iu.st.blocked');
  assert.equal(st('messaging'), 'iu.st.kept');
  assert.equal(st('crash-reports'), 'iu.st.own_switch', 'its own switch, even while the master switch blocks it');
  assert.equal(st('webhooks'), 'iu.st.not_set_up');
  assert.equal(st('lan'), 'iu.st.always');
  assert.equal(st('install-count', { activeCount: { on: false } }), 'iu.st.own_switch');
  const online = Outbound.describe({}, { local: {} });
  assert.equal(iu.stateOf(online.find((r) => r.purpose === 'updates'), {}).key, 'iu.st.allowed');
});

test('the 30-day rule: blocked updates, measured from the last check, else from when the switch went on', () => {
  const iu = load({ network: { offline: true, changedAt: new Date(Date.now() - 40 * 864e5).toISOString() } });
  const row = { purpose: 'updates', allowed: false, reason: 'offline' };
  assert.equal(iu.updatesStale(row, { updatesLastCheckedAt: new Date(Date.now() - 29 * 864e5).toISOString() }), null);
  assert.equal(iu.updatesStale(row, { updatesLastCheckedAt: new Date(Date.now() - 32 * 864e5).toISOString() }), 32);
  assert.equal(iu.updatesStale(row, {}), 40, 'never checked: counted from the switch');
  assert.equal(iu.updatesStale({ purpose: 'updates', allowed: true, reason: 'kept' }, {}), null, 'kept: never red');
});

test('frame D: each refusal in its own words', () => {
  const iu = load({});
  assert.equal(iu.refusalText({ purpose: 'exchange-rates', reason: 'offline' }), 'Khayt is set to make no internet calls. This needs exchange rates.');
  assert.equal(iu.refusalText({ purpose: 'cloud', reason: 'offline-here' }), 'This computer is set to make no internet calls. This needs Khayt Cloud.');
  assert.equal(iu.refusalText({ purpose: 'messaging', reason: 'lan-host-public', host: 'ntfy.example.com' }), 'Khayt is set to make no internet calls, and ntfy.example.com is not on your shop’s network.');
  assert.equal(iu.refusalText({ purpose: 'messaging', reason: 'settings-unknown' }), 'Khayt is starting. Try again in a moment.');
  assert.equal(iu.refusalText(null), '');
});

test('the preload reports every refused reply, in each shape main gives, unchanged for the caller', () => {
  const pre = read('preload.js');
  assert.match(pre, /const hubAPI = \{/);
  assert.match(pre, /contextBridge\.exposeInMainWorld\('hubAPI', hubAPI\);/);
  // Run its shape reader on the shapes main produces.
  const start = pre.indexOf('const BLOCKED_TEXT');
  const end = pre.indexOf('function reportBlocked');
  const ctx = {}; vm.createContext(ctx);
  vm.runInContext(pre.slice(start, end) + '; this.blockedOf = blockedOf;', ctx);
  assert.deepEqual(JSON.parse(JSON.stringify(ctx.blockedOf({ ok: false, error: 'outbound.blocked', blocked: { purpose: 'ai', reason: 'offline' } }))), { purpose: 'ai', reason: 'offline' });
  assert.deepEqual(JSON.parse(JSON.stringify(ctx.blockedOf({ status: 'blocked', blocked: { purpose: 'updates', reason: 'offline-here' } }))), { purpose: 'updates', reason: 'offline-here' });
  assert.deepEqual(JSON.parse(JSON.stringify(ctx.blockedOf({ ok: false, error: 'outbound blocked: messaging (offline)' }))), { purpose: 'messaging', reason: 'offline' });
  assert.deepEqual(JSON.parse(JSON.stringify(ctx.blockedOf(new Error("Error invoking remote method 'hub:makerrun': Error: outbound blocked: makerrun (offline)")))), { purpose: 'makerrun', reason: 'offline' });
  for (const v of [null, { ok: true }, { ok: false, error: 'timeout' }, 'x', 42]) assert.equal(ctx.blockedOf(v), null);
  // Anchored: the same words inside some other text (a server's reply) are not a refusal.
  assert.equal(ctx.blockedOf({ ok: false, error: 'Server said: outbound blocked: cloud (offline)' }), null);
  // And the method's name travels with it, so the window toasts only a person's call.
  assert.match(pre, /reportBlocked\(b, k\)/);
});

test('wiring: the page under General, the banner, the refusal words, the last update check', () => {
  const html = read('renderer/index.html');
  assert.match(html, /id="settings-panel-internet"/);
  assert.match(html, /id="updatesOffBanner"/);
  assert.match(html, /<script src="internet-use\.js"><\/script>/);
  assert.match(read('renderer/shell.js'), /section === 'internet' \? 'general' : section/);
  assert.match(read('renderer/app-state.js'), /s === 'settings\.network'\) parts\.add\(t\('err\.refused_network'\)\)/);
  assert.match(read('renderer/update-ui.js'), /res\?\.status === 'blocked'/);
  const upd = read('lib/updater.js');
  assert.match(upd, /autoUpdater\.on\('update-available', \(info\) => \{\s*noteChecked\(\);/);
  assert.match(upd, /autoUpdater\.on\('update-not-available', \(info\) => \{\s*noteChecked\(\);/);
  const main = read('main.js');
  assert.match(main, /lastChecked = U\.lastUpdateCheckAt\(\); blockedSince = U\.updatesBlockedSince\(\);/);
  assert.match(main, /updatesLastCheckedAt: lastChecked,\s*\n\s*updatesBlockedSince: blockedSince,/);
  assert.match(main, /shop: \{\s*\n\s*offline: require\('\.\/lib\/outbound\.js'\)\.isOffline\(st, \{ local: \{\} \}\),/);
  assert.match(read('.github/workflows/ci.yml'), /test:e2e:internetuse/);
});

test('review of #2633: only person-started calls toast, and only the switch reasons', () => {
  const iu = load({});
  assert.equal(iu.refusalText({ purpose: 'crash-reports', reason: 'opted-out' }), '', 'a purpose\'s own opt-out is not the switch');
  assert.equal(iu.refusalText({ purpose: 'x', reason: 'unknown-purpose' }), '');
  assert.equal(iu.refusalText({ purpose: 'unrouted', reason: 'offline' }), 'Khayt is set to make no internet calls. This needs an address outside your shop’s network.');
  const src = read('renderer/internet-use.js');
  for (const auto of ['cloudPush', 'cloudPull', 'zatcaSubmit', 'sendNtfy', 'sendTelegram', 'cloudDigest', 'fireWebhook']) {
    assert.doesNotMatch(src.slice(src.indexOf('const PERSON_STARTED'), src.indexOf(']);', src.indexOf('const PERSON_STARTED'))), new RegExp(`'${auto}'`), auto + ' is automatic');
  }
  // Every name in the list is a real hubAPI method.
  const list = src.slice(src.indexOf('const PERSON_STARTED'), src.indexOf(']);', src.indexOf('const PERSON_STARTED'))).match(/'([A-Za-z0-9]+)'/g).map((x) => x.slice(1, -1));
  const pre = read('preload.js');
  for (const m of list) assert.match(pre, new RegExp(`\\b${m}:`), m);
});

test('review of #2633: a Keep tick keeps when and by whom; storage set up means the internet; the stamp only on an answer', () => {
  const src = read('renderer/internet-use.js');
  assert.match(src, /if \(!!next\.offline !== !!cur\.offline\) \{ next\.changedAt = new Date\(\)\.toISOString\(\); next\.changedBy = whoChanges\(\); \}/);
  const iu = load({});
  const offsite = (enabled, destination, ready) => ({ offsite: { settings: { enabled, destination }, ready } });
  assert.equal(iu.setUp('storage', offsite(true, 'folder', true)), false, 'a folder backup is not an internet call');
  assert.equal(iu.setUp('storage', offsite(false, 'bucket', true)), false, 'off is not set up');
  assert.equal(iu.setUp('storage', offsite(true, 'bucket', true)), true);
  assert.equal(iu.setUp('storage', { setup: { storageLibrary: true } }), true, 'the library\'s own bucket or Drive');
  assert.equal(load({ telegram: { botToken: 'x', chatId: '1' } }).setUp('messaging', {}), true, 'Telegram has no enabled flag');
  assert.equal(load({ eventWebhooks: { enabled: true, order_created: 'https://h.example/x' } }).setUp('webhooks', {}), true);
  const upd = read('lib/updater.js');
  assert.match(upd, /if \(result && result\.updateInfo && \(interpreted\.status === 'available'/);
  assert.match(upd, /fs\.renameSync\(tmp, checkFile\(\)\)/);
  assert.match(upd, /noteRefused = \(\) => \{/);
  // The 30-day clock: this computer's own switch time for offline-here, and the first refusal when nothing else.
  const row = { purpose: 'updates', allowed: false, reason: 'offline-here' };
  assert.equal(iu.updatesStale(row, { local: { changedAt: new Date(Date.now() - 31 * 864e5).toISOString() } }), 31);
  assert.equal(iu.updatesStale({ purpose: 'updates', allowed: false, reason: 'offline' }, { updatesBlockedSince: new Date(Date.now() - 45 * 864e5).toISOString() }), 45);
});
