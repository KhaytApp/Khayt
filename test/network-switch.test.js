'use strict';
/**
 * The shop's switch through Khayt Cloud (khayt-cloud #223; Turki, Nov 22):
 * lib/network-switch.js (the rules) and lib/main/network-switch-sync.js (the
 * calls), against a fake server and the real store envelope (lib/sync-crypto).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const NS = require('../lib/network-switch.js');
const sc = require('../lib/sync-crypto.js');
const { createNetworkSwitchSync } = require('../lib/main/network-switch-sync.js');

const SHOP = 'shop_abc';
const T = (iso) => Date.parse(iso);
const NOW = T('2026-11-22T10:00:00.000Z');
const plain = (over) => Object.assign({ kind: 'khayt-network-switch', v: 1, shopId: SHOP, offline: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara' }, over);
const judge = (p, o) => NS.judge(p, Object.assign({ serverChangedAt: p && p.changedAt, shopId: SHOP, highestSeen: '2026-11-22T08:00:00.000Z', now: NOW }, o));

test('judge: a value that passes every check is applied, cleaned', () => {
  const r = judge(plain({ keep: ['updates', 'lan', 'switch-sync', 'nope', 'updates', 7] }));
  assert.equal(r.act, 'apply');
  assert.deepEqual(r.value, { offline: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara' });
});

test('judge: each of the five checks ignores, and says which', () => {
  const cases = [
    [null, {}, 'shape'], ['x', {}, 'shape'],
    [plain({ kind: 'khayt-store' }), {}, 'kind'], [plain({ v: 2 }), {}, 'kind'],
    [plain({ shopId: 'other' }), {}, 'shop'], [plain(), { shopId: '' }, 'shop'],
    [plain({ changedAt: '2026-11-22 09:00' }), {}, 'stamp'],
    [plain(), { serverChangedAt: '2026-11-22T09:00:00.001Z' }, 'stamp-mismatch'],
    [plain(), { highestSeen: '2026-11-22T09:00:00.000Z' }, 'not-newer'],
    [plain(), { highestSeen: '2026-11-22T09:30:00.000Z' }, 'not-newer'],
    [plain({ offline: 'true' }), {}, 'offline'], [plain({ offline: 1 }), {}, 'offline'],
    [plain({ keep: 'updates' }), {}, 'keep'],
    [plain({ changedBy: { name: 'x' } }), {}, 'changed-by'],
  ];
  for (const [p, o, why] of cases) assert.deepEqual([judge(p, o).act, judge(p, o).why], ['ignore', why], `${why} ${JSON.stringify(p)}`);
});

test('judge: changedBy is cut to 80 characters, shown as text only', () => {
  assert.equal(judge(plain({ changedBy: 'x'.repeat(500) })).value.changedBy.length, 80);
});

test('the age rule: a computer with no stamp asks before applying a week-old offline:true', () => {
  const old = plain({ changedAt: '2026-11-14T09:00:00.000Z' });
  assert.equal(judge(old, { highestSeen: null }).act, 'ask');
  assert.equal(judge(old, { highestSeen: '2026-11-01T00:00:00.000Z' }).act, 'apply', 'a computer with a stamp of its own applies it');
  assert.equal(judge(plain({ changedAt: '2026-11-14T09:00:00.000Z', offline: false }), { highestSeen: null }).act, 'apply', 'off always applies');
  assert.equal(judge(plain({ changedAt: '2026-11-16T09:00:00.000Z' }), { highestSeen: null }).act, 'apply', 'six days old applies');
});

test('applied: via cloud, this computer\'s untick kept; plainFor seals the book\'s switch', () => {
  const n = NS.applied({ offline: false, dropSwitchSync: true, keep: ['ai'] }, { offline: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara' });
  assert.deepEqual(n, { offline: true, dropSwitchSync: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara', via: 'cloud' });
  assert.deepEqual(NS.plainFor({ shopId: SHOP, network: { offline: true, keep: ['lan', 'updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara', via: 'cloud', dropSwitchSync: true } }),
    { kind: 'khayt-network-switch', v: 1, shopId: SHOP, offline: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara' });
  assert.equal(NS.plainFor({ shopId: SHOP, network: { offline: true } }), null, 'no stamp, nothing to send');
  assert.equal(NS.plainFor({ shopId: '', network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z' } }), null);
});

test('keepNewerNetwork: a window cannot save an older switch over one main applied', () => {
  const disk = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'cloud' } } };
  const stale = { settings: { other: 1, network: { offline: false, changedAt: '2026-11-22T08:00:00.000Z', dropSwitchSync: true } } };
  const out = NS.keepNewerNetwork(stale, disk);
  assert.deepEqual(out.settings.network, { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'cloud', dropSwitchSync: true });
  assert.equal(out.settings.other, 1);
  const fresh = { settings: { network: { offline: false, changedAt: '2026-11-22T09:30:00.000Z' } } };
  assert.equal(NS.keepNewerNetwork(fresh, disk), fresh, 'the person turning it off here is newer: saved');
  const local = { settings: { network: { offline: true, changedAt: '2026-11-22T10:00:00.000Z' } } };
  assert.equal(NS.keepNewerNetwork(stale, local), stale, 'only a value that came through the cloud is protected');
  assert.equal(NS.keepNewerNetwork({ settings: {} }, disk).settings.network.offline, true, 'a save with no switch keeps disk\'s');
});

test('loads without require, as JavaScriptCore loads it', () => {
  const ctx = {}; vm.createContext(ctx);
  for (const f of ['outbound', 'network-switch']) vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', f + '.js'), 'utf8'), ctx);
  ctx.P = plain();
  assert.equal(vm.runInContext(`KhaytNetworkSwitch.judge(P, { serverChangedAt: P.changedAt, shopId: '${SHOP}', highestSeen: null, now: ${NOW} }).act`, ctx), 'apply');
  assert.deepEqual(JSON.parse(vm.runInContext(`JSON.stringify(KhaytNetworkSwitch.cleanKeep(['updates', 'lan', 'x']))`, ctx)), ['updates']);
});

// ── the calls ──────────────────────────────────────────────────────────────

function harness(over = {}) {
  const dek = crypto.randomBytes(32);
  const server = { value: null, puts: [], gets: 0, status: null, blocked: false, putStatus: null, hang: false };
  let book = { network: Object.assign({}, over.network || {}) };
  let mine = Object.assign({}, over.mine || {});
  const notes = [];
  const logs = [];
  const client = {
    async getNetworkSwitch(url, shopId, token, opts) {
      server.gets += 1; server.lastGetPurpose = opts && opts.purpose;
      if (server.blocked) { const e = new Error('outbound blocked: switch-sync (offline)'); e.code = 'outbound.blocked'; throw e; }
      if (server.status) return { status: server.status, body: null };
      if (!server.value) return { status: 404, body: { reason: 'none' } };
      return { status: 200, body: server.value };
    },
    async putNetworkSwitch(url, shopId, token, body) {
      if (server.hang) return new Promise(() => {});
      server.puts.push(body);
      if (server.putStatus) return { status: server.putStatus, body: { reason: 'stale', changedAt: '2026-11-22T11:00:00.000Z' } };
      server.value = { changedAt: body.changedAt, receivedAt: 'x', ciphertext: body.ciphertext };
      return { status: 200, body: { ok: true, changedAt: body.changedAt } };
    },
  };
  const sync = createNetworkSwitchSync({
    client, crypto: sc, now: () => over.now || NOW,
    session: () => (over.locked ? null : { url: 'https://cloud.example', shopId: SHOP, token: 't', role: over.role || 'owner', dek }),
    getSettings: () => book,
    updateNetwork: async (fn) => { const n = fn(book.network || {}); book = Object.assign({}, book, { network: n }); },
    notify: (n) => notes.push(n),
    readMine: () => JSON.parse(JSON.stringify(mine)),
    writeMine: (v) => { mine = JSON.parse(JSON.stringify(v)); },
    log: (m) => logs.push(m),
  });
  const publishRemote = (p) => { server.value = { changedAt: p.changedAt, receivedAt: 'x', ciphertext: sc.encryptStore(p, dek) }; };
  return { sync, server, dek, book: () => book, mine: () => mine, notes, logs, publishRemote };
}

test('pull: a value from another computer is applied, the window told, the stamp kept', async () => {
  const h = harness({ mine: { highestSeen: '2026-11-22T08:00:00.000Z' } });
  h.publishRemote(plain());
  const r = await h.sync.pull();
  assert.equal(r.act, 'apply');
  assert.deepEqual(h.book().network, { offline: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara', via: 'cloud' });
  assert.equal(h.notes.length, 1);
  assert.equal(h.mine().highestSeen, '2026-11-22T09:00:00.000Z');
  assert.equal(h.server.lastGetPurpose, 'switch-sync');
  // The same value again is not newer: ignored.
  assert.equal((await h.sync.pull()).why, 'not-newer');
});

test('pull: another shop\'s key, a replay with a lying server stamp, or a store blob are ignored, logged without content', async () => {
  const h = harness({ mine: { highestSeen: '2026-11-22T08:00:00.000Z' } });
  h.server.value = { changedAt: '2026-11-22T09:00:00.000Z', ciphertext: sc.encryptStore(plain(), crypto.randomBytes(32)) };
  assert.equal((await h.sync.pull()).why, 'sealed');
  h.publishRemote(plain());
  h.server.value.changedAt = '2026-11-22T09:59:00.000Z';
  assert.equal((await h.sync.pull()).why, 'stamp-mismatch');
  h.publishRemote({ printLog: [], settings: {}, changedAt: '2026-11-22T09:00:00.000Z' });
  assert.equal((await h.sync.pull()).why, 'kind');
  assert.equal(h.book().network.offline, undefined, 'nothing applied');
  for (const l of h.logs) assert.match(l, /^network switch: ignored, [a-z-]+$/);
});

test('pull: the age rule holds a week-old value until the person answers', async () => {
  const h = harness();
  h.publishRemote(plain({ changedAt: '2026-11-10T09:00:00.000Z' }));
  assert.equal((await h.sync.pull()).act, 'ask');
  assert.equal(h.book().network.offline, undefined);
  assert.equal(h.sync.state().pending.changedAt, '2026-11-10T09:00:00.000Z');
  assert.deepEqual(await h.sync.answerPending(true), { ok: true, applied: true });
  assert.equal(h.book().network.offline, true);
  const h2 = harness();
  h2.publishRemote(plain({ changedAt: '2026-11-10T09:00:00.000Z' }));
  await h2.sync.pull();
  assert.deepEqual(await h2.sync.answerPending(false), { ok: true, applied: false });
  assert.equal(h2.book().network.offline, undefined);
  assert.equal((await h2.sync.pull()).why, 'not-newer', 'a declined value is not asked again');
});

test('pull: a 404 unties an offline computer from the cloud (it stops calling); locked or blocked does nothing', async () => {
  const h = harness({ network: { offline: true, via: 'cloud', changedAt: '2026-11-22T09:00:00.000Z' } });
  assert.equal((await h.sync.pull()).status, 404);
  assert.equal(h.book().network.via, null);
  assert.equal(h.book().network.offline, true, 'its value stands');
  assert.equal((await harness({ locked: true }).sync.pull()).why, 'locked');
  const b = harness(); b.server.blocked = true;
  assert.equal((await b.sync.pull()).why, 'blocked');
});

test('publish on: only with this computer\'s option, only the owner, as the last call', async () => {
  const net = { offline: true, keep: ['updates'], changedAt: '2026-11-22T10:00:00.000Z', changedBy: 'Sara' };
  const off = harness();
  assert.deepEqual(await off.sync.publish({ offline: true, network: net }), { ok: true, sent: false });
  assert.equal(off.server.puts.length, 0, 'option off: nothing sent');
  const h = harness({ mine: { share: true } });
  const r = await h.sync.publish({ offline: true, network: net });
  assert.equal(r.ok, true); assert.equal(r.via, 'cloud');
  assert.equal(h.server.puts.length, 1);
  assert.equal(h.server.puts[0].changedAt, '2026-11-22T10:00:00.000Z');
  const opened = sc.decryptStore(h.server.puts[0].ciphertext, h.dek);
  assert.deepEqual(opened, { kind: 'khayt-network-switch', v: 1, shopId: SHOP, offline: true, keep: ['updates'], changedAt: '2026-11-22T10:00:00.000Z', changedBy: 'Sara' });
  assert.equal(h.mine().highestSeen, '2026-11-22T10:00:00.000Z', 'its own value is seen: never applied back');
  assert.equal((await h.sync.pull()).why, 'not-newer');
  const mgr = harness({ mine: { share: true }, role: 'manager' });
  assert.equal((await mgr.sync.publish({ offline: true, network: net })).why, 'role');
});

test('publish off: asks first and sends offline:false when a value is published, whatever this computer\'s option', async () => {
  const net = { offline: false, keep: [], changedAt: '2026-11-22T10:00:00.000Z', changedBy: 'Sara' };
  const h = harness();
  h.publishRemote(plain());
  const r = await h.sync.publish({ offline: false, network: net });
  assert.equal(r.sent, true);
  assert.equal(sc.decryptStore(h.server.puts[0].ciphertext, h.dek).offline, false);
  assert.equal(h.server.lastGetPurpose, 'cloud');
  const none = harness();
  assert.deepEqual(await none.sync.publish({ offline: false, network: net }), { ok: true, sent: false });
});

test('publish: a 409 is returned and kept for the window, never retried or applied silently; the PUT is capped at 10 s', async () => {
  const h = harness({ mine: { share: true } });
  h.server.putStatus = 409;
  const r = await h.sync.publish({ offline: true, network: { offline: true, changedAt: '2026-11-22T10:00:00.000Z' } });
  assert.equal(r.why, 'stale');
  assert.deepEqual(r.conflict, { at: '2026-11-22T11:00:00.000Z', mine: '2026-11-22T10:00:00.000Z', offline: true });
  assert.equal(h.server.puts.length, 1, 'not retried');
  assert.deepEqual(h.sync.state().lastConflict, r.conflict);
  assert.equal(h.book().network.offline, undefined, 'nothing applied');
  assert.equal(require('../lib/main/network-switch-sync.js').PUT_CAP_MS, 10000);
});

test('setShare: the owner turns it on; anyone may turn it off; the stamp is never lowered', async () => {
  const mgr = harness({ role: 'manager' });
  assert.equal(mgr.sync.setShare(true).why, 'role');
  assert.equal(mgr.sync.setShare(false).ok, true);
  const h = harness({ mine: { highestSeen: '2026-11-22T09:00:00.000Z' } });
  assert.equal(h.sync.setShare(true).share, true);
  h.publishRemote(plain({ changedAt: '2026-11-22T08:30:00.000Z' }));
  assert.equal((await h.sync.pull()).why, 'not-newer');
  assert.equal(h.mine().highestSeen, '2026-11-22T09:00:00.000Z');
});

test('desktop wiring: the gate purpose, the save guard, the window note, start at unlock', () => {
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
  const cc = read('lib/cloud-client.js');
  assert.match(cc, /if \(purpose === 'switch-sync'\) return outboundGate\('switch-sync', url\);/);
  assert.match(cc, /async function getNetworkSwitch\(/);
  const main = read('main.js');
  assert.match(main, /keepNewerNetwork\(merged, guardDisk\)/);
  assert.match(main, /networkSwitchSync\.start\(\);\s*\n\s*return \{ ok: true \};/);
  assert.match(main, /updateStoreOnDiskAllowingLock\([\s\S]{0,400}\['settings\.network'\]\)/);
  const iu = read('renderer/internet-use.js');
  assert.match(iu, /networkSwitchPublish\(\{ offline: true, network: next/);
  assert.match(iu, /onNetworkApplied\(/);
});
