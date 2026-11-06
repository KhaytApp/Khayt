'use strict';
/**
 * The LAN follow-ups to #2252, desktop side:
 *  - an API token's lastUsedAt is stamped at most hourly (lib/api-tokens.js
 *    markUsed), and the window's older copy never winds it back on save
 *    (lib/store-io.js mergeStoreSecretsFromDisk);
 *  - the LAN writes the window used to save over now reach it: the events
 *    carry what the window needs, and app-boot.js takes each one.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const T = require('../lib/api-tokens.js');
const R = require('../lib/lan-rest.js');
const { harness } = require('./helpers/store-io-harness.js');

const H = 3600 * 1000;
const T0 = Date.UTC(2026, 10, 6, 9, 0, 0);

test('markUsed: stamps a token, then not again within the hour', () => {
  const tokens = [{ id: 'a', lastUsedAt: null }, { id: 'b', lastUsedAt: null }];
  const first = T.markUsed(tokens, 'a', T0);
  assert.equal(first[0].lastUsedAt, new Date(T0).toISOString());
  assert.equal(first[1].lastUsedAt, null, 'only that token');
  assert.equal(tokens[0].lastUsedAt, null, 'on a copy');
  assert.equal(T.markUsed(first, 'a', T0 + H - 1), null, 'inside the hour: nothing to write');
  assert.equal(T.markUsed(first, 'a', T0 + H)[0].lastUsedAt, new Date(T0 + H).toISOString());
  assert.equal(T.markUsed(first, 'nope', T0), null);
  assert.ok(T.markUsed([{ id: 'a', lastUsedAt: new Date(T0 + 5 * H).toISOString() }], 'a', T0), 'a stamp from the future (clock moved back) is replaced');
});

test("saving the window's copy keeps the later lastUsedAt from disk", () => {
  const io = harness();
  const disk = new Date(T0 + 2 * H).toISOString();
  io.putOnDisk({ settings: { lanApi: { apiTokens: [{ id: 'a', lastUsedAt: disk }, { id: 'b', lastUsedAt: null }] } } });
  const fromWindow = { settings: { lanApi: { apiTokens: [
    { id: 'a', lastUsedAt: new Date(T0).toISOString(), label: 'renamed' },
    { id: 'b', lastUsedAt: new Date(T0).toISOString() },
    { id: 'c', lastUsedAt: null },
  ] } } };
  const merged = io.mergeStoreSecretsFromDisk(fromWindow);
  const [a, b, c] = merged.settings.lanApi.apiTokens;
  assert.equal(a.lastUsedAt, disk, 'the server stamp is not wound back');
  assert.equal(a.label, 'renamed', "the window's own edit stands");
  assert.equal(b.lastUsedAt, new Date(T0).toISOString(), 'nothing on disk to prefer');
  assert.equal(c.lastUsedAt, null);
  assert.equal(merged.settings.lanApi.apiTokens.length, 3, 'a token the window revoked or added is its own business');
});

test('the LAN server stamps through markUsed, inside the write chain, and no longer leaves it undone', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  assert.match(src, /stampApiTokenUse\(apiTokenRec\.id, Date\.now\(\)\)/);
  assert.match(src, /updateStoreOnDisk\(\(cur\) => \{\s*const lanApi[\s\S]{0,200}ApiTokens\.markUsed/);
  assert.doesNotMatch(src, /lastUsedAt is intentionally not stamped/);
});

test('POST /api/orders tells the window the counters it advanced', () => {
  const out = R.orderCreate({ settings: { invPrefix: 'INV' }, printLog: [] }, { project: 'P' }, { nowMs: T0 });
  assert.equal(out.emit.payload.order.id, out.store.printLog[0].id);
  assert.equal(out.emit.payload.settingsChanged.invNumNext, out.store.settings.invNumNext);
  assert.equal('invPrefix' in out.emit.payload.settingsChanged, false, 'only what moved');
});

test('PATCH /api/waiting-list/:id tells the window the entry as it now stands', () => {
  const b = { waitingList: [{ id: 'w1', project: 'A', status: 'active' }], waitingListHistory: [] };
  const r = R.waitingListPatch(b, 'w1', { status: 'reminded', reminderDate: '2026-12-01' }, { nowMs: T0 });
  assert.deepEqual(r.emit.payload.entry, r.store.waitingList[0]);
  assert.equal(r.emit.payload.declined, false);
  const d = R.waitingListPatch(b, 'w1', { status: 'declined' }, { nowMs: T0 });
  assert.equal(d.emit.payload.declined, true);
  assert.equal(d.emit.payload.entry.declinedAt, new Date(T0).toISOString());
});

test('the window takes every LAN write it used to save over', () => {
  const boot = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-boot.js'), 'utf8');
  for (const h of ['onLanOrderCreated', 'onLanSpoolUpdated', 'onLanSpoolDeleted', 'onLanWaitingUpdated', 'onLanOrderUpdated', 'onLanSpoolAdded']) {
    assert.match(boot, new RegExp(`hubAPI\\.${h}\\(`), `${h} has a handler`);
  }
  const preload = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  const sent = new Set();
  for (const f of ['lib/lan-rest.js', 'lib/lan-server.js']) {
    const s = fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
    for (const m of s.matchAll(/channel: '(lan-[a-z-]+)'/g)) sent.add(m[1]);
  }
  for (const ch of sent) {
    const m = preload.match(new RegExp(`(onLan[A-Za-z]+):\\s*\\(\\(\\) => \\{[^\\n]*'${ch}'`));
    assert.ok(m, `${ch} reaches the window`);
    assert.match(boot, new RegExp(`hubAPI\\??\\.${m[1]}\\b`), `${ch} (${m[1]}) is taken by the window`);
  }
});

// ── API tokens are the owner's (rbac security/edit), as on the Mac ─────────

const lockedBook = (activeId, tokens = []) => ({
  settings: { operatorLockEnabled: true, activeOperatorId: activeId, lanApi: { apiTokens: tokens } },
  operators: [
    { id: 'OP-own', role: 'مدير', roleKey: 'owner' },
    { id: 'OP-mgr', role: 'Shop manager' },
    { id: 'OP-staff', role: 'Technician', roleKey: 'operator' },
  ],
});

test('mayManageTokens: the owner, or anyone with the lock off — never staff, never an unknown id', () => {
  assert.equal(T.mayManageTokens({ settings: {} }), true, 'lock off: as every permission');
  assert.equal(T.mayManageTokens(lockedBook('OP-own')), true);
  assert.equal(T.mayManageTokens(lockedBook('OP-mgr')), false, 'a manager reads Settings but holds no security');
  assert.equal(T.mayManageTokens(lockedBook('OP-staff')), false);
  assert.equal(T.mayManageTokens(lockedBook('OP-gone')), false);
  assert.equal(T.mayManageTokens(lockedBook(null)), false);
});

test("guardTokenSave: a manager's save cannot add or revoke a token; other edits and an owner's pass", () => {
  const a = { id: 'a', hash: 'h' };
  const disk = lockedBook('OP-mgr', [a]);
  const minted = { ...disk, settings: { ...disk.settings, lanApi: { apiTokens: [a, { id: 'b', hash: 'h2' }] } } };
  assert.deepEqual(T.guardTokenSave(minted, disk).settings.lanApi.apiTokens, [a], 'mint refused');
  const revoked = { ...disk, settings: { ...disk.settings, shopName: 'X', lanApi: { apiTokens: [] } } };
  const g = T.guardTokenSave(revoked, disk);
  assert.deepEqual(g.settings.lanApi.apiTokens, [a], 'revoke refused');
  assert.equal(g.settings.shopName, 'X', 'the rest of the save stands');
  const same = { ...disk, settings: { ...disk.settings, shopName: 'Y' } };
  assert.equal(T.guardTokenSave(same, disk), same, 'no token change: untouched');
  const owner = lockedBook('OP-own', [a]);
  const byOwner = { ...owner, settings: { ...owner.settings, lanApi: { apiTokens: [] } } };
  assert.deepEqual(T.guardTokenSave(byOwner, owner).settings.lanApi.apiTokens, [], 'the owner may');
});

test('main refuses the mint and guards the save; the window hides both controls from a non-owner', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const mint = main.slice(main.indexOf("ipcMain.handle('hub:mint-api-token'"), main.indexOf("ipcMain.handle('hub:mint-api-token'") + 900);
  assert.match(mint, /if \(!ApiTokens\.mayManageTokens\(book\)\) return \{ ok: false, error: 'not_allowed' \}/);
  assert.ok(mint.indexOf('mayManageTokens') < mint.indexOf('generateToken'), 'checked before anything is minted');
  assert.match(main, /ApiTokens\.guardTokenSave\(merged, readStoreDecryptedFromDisk\(\)\)/);
  const settingsJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
  assert.match(settingsJs, /operatorCan\('security', 'edit'\)/);
  assert.match(settingsJs, /\$\{mayManage \? `<button class="btn danger small" data-act="revoke-api-token"/);
});

test('the default admin made when the lock goes on is the owner by roleKey, not by its translated title', () => {
  const sec = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-security.js'), 'utf8');
  assert.match(sec, /role: t\('op\.role_admin'\),[\s\S]{0,400}roleKey: 'owner',/);
});
