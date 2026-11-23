'use strict';
/**
 * The pre-download "Before you update" items in the shop's language, from
 * the new release's release-gates.json asset (lib/update-gate-text.js,
 * lib/updater.js fetchGateAsset). Any failure is English and never in the
 * way of the update.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const T = require('../lib/update-gate-text.js');

const asset = {
  gates: { '4.12.0': ['New one', 'Shared'], '4.11.0': ['Old one'] },
  mac: { '4.0.0-beta.43': ['Mac one'] },
  i18n: {
    gates: { '4.12.0': { ar: ['جديد', 'مشترك'], de: ['Neu', null] }, '4.11.0': { ar: ['قديم'] } },
    mac: { '4.0.0-beta.43': { ar: ['ماك'] } },
  },
};

test('the dialog\'s English items are looked up by their text, across versions', () => {
  assert.deepEqual(T.translateItems(['Old one', 'New one', 'Shared'], asset, 'ar'), ['قديم', 'جديد', 'مشترك']);
  assert.deepEqual(T.translateItems(['New one', 'Shared'], asset, 'de'), ['Neu', 'Shared'], 'a gap stays English');
  assert.deepEqual(T.translateItems(['Mac one'], asset, 'ar', 'mac'), ['ماك']);
  assert.equal(T.translateItems(['Mac one'], asset, 'ar'), null, 'the desktop never reads the Mac\'s');
});

test('nothing to translate, or a bad asset: null (the caller keeps English)', () => {
  for (const bad of [null, undefined, 'x', 42, [], {}, { gates: {} }, { i18n: 'x' }, { gates: { '4.12.0': ['New one'] }, i18n: { gates: { '4.12.0': { ar: 'x' } } } },
    { gates: { '4.12.0': ['New one', 'Shared'] }, i18n: { gates: { '4.12.0': { ar: ['only one'] } } } }]) {
    assert.equal(T.translateItems(['New one'], bad, 'ar'), null, JSON.stringify(bad));
  }
  assert.equal(T.translateItems(['Not in the asset'], asset, 'ar'), null);
  assert.equal(T.translateItems(['New one'], asset, 'en'), null);
  assert.equal(T.translateItems(['New one'], asset, 'ja'), null);
  assert.equal(T.translateItems(['New one'], asset, '../x'), null);
  assert.equal(T.translateItems([], asset, 'ar'), null);
});

test('loads under JavaScriptCore\'s rules (the Mac\'s frame C reads the same asset)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'update-gate-text.js'), 'utf8');
  assert.doesNotMatch(src, /\brequire\(/);
  const ctx = {}; vm.createContext(ctx); vm.runInContext(src, ctx);
  ctx.asset = asset;
  assert.equal(vm.runInContext("KhaytUpdateGateText.translateItems(['Mac one'], asset, 'ar', 'mac')[0]", ctx), 'ماك');
});

// ── The fetch: bounded, gated, and never in the way ───────────────────────
const { fetchGateAsset } = (() => {
  // lib/updater.js needs electron to load; its fetchGateAsset is lifted out
  // of its source and run with Node's own modules.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'updater.js'), 'utf8');
  const start = src.indexOf("const GATE_ASSET_BASE");
  const end = src.indexOf('function registerUpdater(');
  const req = (m) => (m === './update-gate-text' ? T : require(m));
  return new Function('require', 'Buffer', 'AbortController', 'setTimeout', 'clearTimeout', 'globalThis',
    src.slice(start, end) + '; return { fetchGateAsset, GATE_ASSET_BASE };')(req, Buffer, AbortController, setTimeout, clearTimeout, globalThis);
})();
const allowed = () => ({ allowed: true });
const bodyOf = (s) => (async function* () { yield Buffer.from(s); })();

test('an unreachable asset, a 404, a bad body, a huge one or a hang: null, quickly', async () => {
  const cases = [
    async () => { throw new Error('ENOTFOUND'); },
    async () => ({ ok: false, status: 404, body: bodyOf('Not Found') }),
    async () => ({ ok: true, body: bodyOf('<html>not json') }),
    async () => ({ ok: true, body: (async function* () { for (let i = 0; i < 100; i++) yield Buffer.alloc(16 * 1024, 32); })() }),
    async (_u, o) => new Promise((_r, rej) => o.signal.addEventListener('abort', () => rej(new Error('aborted')))),
  ];
  for (const f of cases) {
    const t0 = Date.now();
    assert.equal(await fetchGateAsset('4.12.0', new Map(), allowed, { fetch: f, timeoutMs: 200 }), null);
    assert.ok(Date.now() - t0 < 2000);
  }
});

test('refused by "make no internet calls": nothing is fetched, and the refusal is not remembered', async () => {
  let calls = 0;
  const f = async () => { calls++; return { ok: true, body: bodyOf(JSON.stringify(asset)) }; };
  const cache = new Map();
  assert.equal(await fetchGateAsset('4.12.0', cache, () => ({ allowed: false, reason: 'offline' }), { fetch: f }), null);
  assert.equal(calls, 0);
  assert.equal(cache.size, 0);
  assert.deepEqual(await fetchGateAsset('4.12.0', cache, allowed, { fetch: f }), asset);
  assert.equal(calls, 1);
  await fetchGateAsset('4.12.0', cache, allowed, { fetch: f });
  assert.equal(calls, 1, 'cached per version');
});

test('the URL is the release\'s own asset on the updates host, for that version', async () => {
  let url = '';
  await fetchGateAsset('4.12.0-beta.1', new Map(), allowed, { fetch: async (u) => { url = u; return { ok: false }; } });
  assert.equal(url, 'https://github.com/khaytapp/Khayt/releases/download/v4.12.0-beta.1/release-gates.json');
});

test('wired: the dialog asks with its language and waits at most a few seconds; the release attaches the file', () => {
  const ui = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'update-ui.js'), 'utf8');
  assert.match(ui, /activeUpdateInfo\.majorChanges = await localisedMajor\(activeUpdateInfo\);/);
  assert.match(ui, /setTimeout\(\(\) => res\(null\), 5500\)/);
  const up = fs.readFileSync(path.join(__dirname, '..', 'lib', 'updater.js'), 'utf8');
  const h = up.slice(up.indexOf("ipcMain.handle('hub:update-gate-text'"), up.indexOf("ipcMain.handle('hub:start-update-download'"));
  assert.match(h, /catch \(_\) \{\s*return \{ items: null \};/);
  const wf = fs.readFileSync(path.join(__dirname, '..', '.github', 'workflows', 'release.yml'), 'utf8');
  assert.match(wf, /node scripts\/write-release-gates\.js --check\n\s*gh release upload "\$TAG" lib\/release-gates\.json --clobber/);
});
