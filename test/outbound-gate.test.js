'use strict';
/**
 * lib/main/outbound-fetch.js: the desktop's gate for the "make no internet
 * calls" switch (P8 PR 2), and the read before the book is in memory that
 * keeps Sentry from starting while the shop is offline.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createOutboundGate, OutboundBlocked, isBlocked, offlineAtStartup } = require('../lib/main/outbound-fetch.js');

function gate(over = {}) {
  let settings = over.settings === undefined ? {} : over.settings;
  let local = over.local || {};
  let countOff = !!over.countOff;
  let t = 1_700_000_000_000;
  const g = createOutboundGate({
    getSettings: () => settings, readLocal: () => local, writeLocal: (v) => { local = v; },
    readInstallCountOff: () => countOff, now: () => t,
  });
  return { g, set: (s) => { settings = s; }, setCountOff: (v) => { countOff = v; }, tick: () => { t += 1000; } };
}

test('online, nothing changes; offline, a purpose is refused and counted', () => {
  const { g, set } = gate();
  assert.equal(g.check('updates').allowed, true);
  set({ network: { offline: true } });
  const r = g.check('updates');
  assert.deepEqual([r.allowed, r.reason], [false, 'offline']);
  assert.deepEqual(g.blocked().updates.count, 1);
  assert.throws(() => g.gate('cloud'), (e) => e instanceof OutboundBlocked && isBlocked(e) && e.purpose === 'cloud' && e.reason === 'offline');
  set({ network: { offline: true, keep: ['cloud'] } });
  assert.equal(g.gate('cloud').reason, 'kept');
});

test('opted-out is not a block: telemetryConsent asks often, and most shops never opt in', () => {
  const { g } = gate({ settings: { telemetry: { crashOptIn: false } } });
  for (let i = 0; i < 5; i++) assert.equal(g.check('crash-reports').reason, 'opted-out');
  assert.equal(g.blocked()['crash-reports'], undefined);
});

test('this computer can be stricter, and the install count keeps its own switch (D3)', () => {
  const { g, setCountOff } = gate();
  assert.equal(g.check('install-count').allowed, true);
  setCountOff(true);
  assert.equal(g.check('install-count').reason, 'opted-out');
  g.setLocal({ offline: true });
  assert.equal(g.check('webhooks').reason, 'offline-here');
  assert.equal(g.local().offline, true);
  g.setLocal({ offline: 'yes' });
  assert.equal(g.local().offline, false, 'setLocal writes a boolean');
});

test('the book not read yet: wait', () => {
  const { g } = gate({ settings: null });
  assert.equal(g.check('install-count').reason, 'settings-unknown');
});

test('for(purpose) gates before the real fetch, every time', async () => {
  const { g, set } = gate();
  let calls = 0;
  const f = g.for('storage', async () => { calls += 1; return 'ok'; });
  assert.equal(await f('https://s3.example.com'), 'ok');
  set({ network: { offline: true } });
  await assert.rejects(f('https://s3.example.com'), (e) => isBlocked(e));
  assert.equal(calls, 1);
});

test('describe carries the counts for the Settings list', () => {
  const { g } = gate({ settings: { network: { offline: true } } });
  g.check('updates'); g.check('updates');
  const row = g.describe().find((r) => r.purpose === 'updates');
  assert.deepEqual([row.allowed, row.blockedCount, typeof row.lastBlockedAt], [false, 2, 'string']);
});

test('offlineAtStartup: the store or this computer says offline; unreadable fails toward offline', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-outbound-'));
  const store = path.join(dir, 'khayt-store.json'), local = path.join(dir, 'network-local.json');
  fs.writeFileSync(store, JSON.stringify({ settings: { telemetry: { crashOptIn: true } } }));
  assert.equal(offlineAtStartup(fs, store, local), false);
  fs.writeFileSync(store, JSON.stringify({ settings: { network: { offline: true } } }));
  assert.equal(offlineAtStartup(fs, store, local), true);
  fs.writeFileSync(store, JSON.stringify({ settings: { network: { offline: false } } }));
  fs.writeFileSync(local, JSON.stringify({ offline: true }));
  assert.equal(offlineAtStartup(fs, store, local), true, 'this computer');
  fs.rmSync(local);
  fs.writeFileSync(store, '{"settings":{"network":{"offline":true');
  assert.equal(offlineAtStartup(fs, store, local), true, 'a cut-off file');
  fs.writeFileSync(store, JSON.stringify({ settings: { network: { offline: 'true' } } }));
  assert.equal(offlineAtStartup(fs, store, local), true, 'read as the runtime gate reads it: present and not false');
  fs.writeFileSync(local, JSON.stringify({ offline: 1 }));
  fs.writeFileSync(store, JSON.stringify({ settings: {} }));
  assert.equal(offlineAtStartup(fs, store, local), true, 'this computer, written as 1');
  fs.rmSync(local);
  assert.equal(offlineAtStartup(fs, path.join(dir, 'none.json'), local), true, 'no store: Sentry would not start anyway');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('cloud: the last sync after this computer turns the switch on, and only it (design §1.4; reviews of #2628)', async () => {
  const { g, set, tick } = gate({ settings: {} });
  assert.equal(g.check('cloud').allowed, true);
  // A change that arrives from elsewhere (a pull, the LAN) opens nothing.
  set({ network: { offline: true } }); g.observe();
  await assert.rejects(g.lastPush(async () => g.gate('cloud')), (e) => isBlocked(e));
  // This computer's window saves it: the window opens.
  set({}); g.observe({ fromSave: true }); set({ network: { offline: true } }); g.observe({ fromSave: true });
  // Only the sync's own chain passes; another cloud call meanwhile is refused.
  let other = null;
  const push1 = g.lastPush(async () => {
    g.gate('cloud');
    try { g.gate('cloud'); } catch (_) { /* same chain: fine */ }
    return { conflict: true };   // a 409: someone pushed since
  });
  try { g.gate('cloud'); other = 'passed'; } catch (e) { other = e.reason; }
  assert.deepEqual(await push1, { conflict: true });
  assert.equal(other, 'offline', 'a vault upload or the lead-time publisher is not the sync');
  // The 409 did not spend it: pull and push again go through.
  assert.deepEqual(await g.lastPull(async () => { g.gate('cloud'); return { pulled: 1 }; }), { pulled: 1 });
  assert.deepEqual(await g.lastPush(async () => { g.gate('cloud'); return { ok: 1 }; }), { ok: 1 });
  // Landed: closed.
  await assert.rejects(g.lastPush(async () => g.gate('cloud')), (e) => isBlocked(e));
  // Opened and never used for 30 s: none later.
  set({}); g.observe({ fromSave: true }); set({ network: { offline: true } }); g.observe({ fromSave: true });
  for (let i = 0; i < 31; i++) tick();
  await assert.rejects(g.lastPush(async () => g.gate('cloud')), (e) => isBlocked(e));
  // This computer's own switch is not the shop's: no window for it.
  set({}); g.observe({ fromSave: true }); g.setLocal({ offline: true });
  await assert.rejects(g.lastPush(async () => g.gate('cloud')), (e) => isBlocked(e) && e.reason === 'offline-here');
});

test('cloud with a book on disk that cannot be read: not held back (it is how such a shop restores)', () => {
  let unreadable = true;
  const g = createOutboundGate({ getSettings: () => null, readLocal: () => ({}), bookUnreadable: () => unreadable });
  assert.equal(g.check('cloud').allowed, true);
  assert.equal(g.check('updates').reason, 'settings-unknown', 'only cloud');
  unreadable = false;
  assert.equal(g.check('cloud').reason, 'settings-unknown');
});

test('PR 3 wiring: every cloud request asks the gate', () => {
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
  const cc = read('lib/cloud-client.js');
  assert.match(cc, /return async \(\{ method, path, body \}\) => \{\s*\n\s*askGate\(\);/);
  assert.match(cc, /const base = validateCloudBaseUrl\(baseUrl\);\s*\n\s*askGate\(\);\s*\n\s*\/\/ outbound: cloud\s*\n\s*const res = await fetch\(`\$\{base\}\/v1\/shops\/\$\{seg\(shopId\)\}\/intake/);
  const main = read('main.js');
  assert.match(main, /cloudClient\.setOutboundGate\(\(purpose\) => outboundGate\.gate\(purpose\)\);/);
  assert.equal((main.match(/outboundFetch: outboundGate\.for\('cloud'\),/g) || []).length, 2, 'both vault clients');
  assert.match(main, /outboundGate\.lastPush\(\(\) => cloudBackend\.push\(snapshot\)\)/);
  assert.match(main, /outboundGate\.lastPull\(\(\) => cloudBackend\.pull\(\)\)/);
  assert.match(main, /outboundGate\.observe\(\{ fromSave: true \}\)/);
  for (const f of ['lib/main/vault-backup.js', 'lib/main/vault-links.js']) assert.match(read(f), /fetch: cloudFetch\(\)/, f);
  // The gate throws before any fetch: no gate set means no change (tests, other callers).
  const C = require('../lib/cloud-client.js');
  C.setOutboundGate(() => { const e = new Error('blocked'); e.code = 'outbound.blocked'; throw e; });
  return C.httpTransport('https://cloud.khaytapp.com', 't')({ method: 'GET', path: '/v1/x' })
    .then(() => assert.fail('should not send'), (e) => assert.equal(e.code, 'outbound.blocked'))
    .finally(() => C.setOutboundGate(null));
});

test('the switch going on purges what was saved up before it (D5), once per change', () => {
  let purged = 0;
  let settings = {};
  let local = {};
  const g = createOutboundGate({ getSettings: () => settings, readLocal: () => local, writeLocal: (v) => { local = v; }, onOffline: () => { purged += 1; } });
  g.check('updates');
  assert.equal(purged, 0);
  settings = { network: { offline: true } };
  g.check('updates'); g.check('cloud');
  assert.equal(purged, 1, 'once');
  settings = {}; g.check('updates');
  g.setLocal({ offline: true });
  assert.equal(purged, 2, 'this computer\'s switch too');
});

test('round 2 (Nov 22): only the owner changes the switch under the staff lock, the book\'s and this computer\'s', () => {
  const PP = require('../lib/main/printer-permission.js');
  const ops = [{ id: 'own', roleKey: 'owner' }, { id: 'mgr', roleKey: 'manager' }, { id: 'op', roleKey: 'operator' }];
  const book = (lock, who, network) => ({ settings: { operatorLockEnabled: lock, activeOperatorId: who, network }, operators: ops });
  assert.equal(PP.mayChangeNetwork(book(false, null)), true, 'lock off: anyone, as RBAC has always said');
  assert.equal(PP.mayChangeNetwork(book(true, 'own')), true);
  for (const who of ['mgr', 'op', null, 'gone']) assert.equal(PP.mayChangeNetwork(book(true, who)), false, String(who));
  assert.equal(PP.mayChangeNetwork(null), false, 'no book read: no');
  // The book: a manager's save that turns the switch off is put back as it is on disk.
  const disk = book(true, 'mgr', { offline: true, keep: ['storefront'] });
  const g = PP.guardSave(book(true, 'mgr', { offline: false }), disk);
  assert.deepEqual(g.store.settings.network, { offline: true, keep: ['storefront'] });
  assert.ok(g.refused.includes('settings.network'));
  // The owner's goes through.
  const go = PP.guardSave(book(true, 'own', { offline: false }), book(true, 'own', { offline: true }));
  assert.deepEqual(go.store.settings.network, { offline: false });
  assert.ok(!go.refused.includes('settings.network'));
  // This computer's own switch: main asks the same rule first.
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const h = main.slice(main.indexOf("ipcMain.handle('hub:outbound-set-local'"));
  assert.match(h.slice(0, 400), /if \(!PrinterPermission\.mayChangeNetwork\(lanServerStore\)\) return \{ ok: false, error: 'not_permitted' \};/);
});
