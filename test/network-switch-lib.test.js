'use strict';
// lib/network-switch.js alone (the shared rule; the desktop's calls are test/network-switch.test.js on the client branch).
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
  // A stamp from the future protects nothing; the same stamp takes main's `via`.
  const future = { settings: { network: { offline: true, changedAt: '9999-12-31T23:59:59.999Z', via: 'cloud' } } };
  assert.equal(NS.keepNewerNetwork(stale, future, NOW), stale);
  const untied = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: null } } };
  const sameStamp = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'cloud', dropSwitchSync: true } } };
  const k = NS.keepNewerNetwork(sameStamp, Object.assign({}, untied, { settings: { network: Object.assign({}, untied.settings.network, { via: 'cloud' }) } }), NOW);
  assert.equal(k, sameStamp, 'same stamp, same via: unchanged');
});

test('keepNewerNetwork: on the same stamp, `via` is main\'s', () => {
  const disk = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'cloud' } } };
  const win = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'x', dropSwitchSync: true } } };
  assert.deepEqual(NS.keepNewerNetwork(win, disk, NOW).settings.network, { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'cloud', dropSwitchSync: true });
  // Main cleared it after a 404: a window still holding via:'cloud' does not put it back.
  const cleared = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: null } } };
  const stale = { settings: { network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', via: 'cloud' } } };
  assert.equal(NS.keepNewerNetwork(stale, cleared, NOW).settings.network.via, null);
});

test('loads without require, as JavaScriptCore loads it', () => {
  const ctx = {}; vm.createContext(ctx);
  for (const f of ['outbound', 'network-switch']) vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', f + '.js'), 'utf8'), ctx);
  ctx.P = plain();
  assert.equal(vm.runInContext(`KhaytNetworkSwitch.judge(P, { serverChangedAt: P.changedAt, shopId: '${SHOP}', highestSeen: null, now: ${NOW} }).act`, ctx), 'apply');
  assert.deepEqual(JSON.parse(vm.runInContext(`JSON.stringify(KhaytNetworkSwitch.cleanKeep(['updates', 'lan', 'x']))`, ctx)), ['updates']);
});


// ── stampAfter / justBefore (decision A, Nov 22), with the Mac's cap ───────

test('stampAfter: max(now, newest seen + 1 ms), as text from integer ms', () => {
  const N = Date.parse('2026-11-22T10:00:00.000Z');
  assert.equal(NS.stampAfter(N, ['2026-11-22T10:05:00.000Z']), '2026-11-22T10:05:00.001Z', '5 minutes ahead still counts');
  assert.equal(NS.stampAfter(N, ['2026-11-22T09:00:00.000Z', null, 'junk']), '2026-11-22T10:00:00.000Z');
  assert.equal(NS.stampAfter(N + 0.4, ['2026-11-22T10:00:00.000Z']), '2026-11-22T10:00:00.001Z', 'never equal to the stamp it must beat');
  assert.equal(NS.justBefore('2026-11-22T10:00:00.000Z'), '2026-11-22T09:59:59.999Z');
  assert.ok(NS.newer(NS.stampAfter(N, ['2026-11-22T10:03:00.999Z']), '2026-11-22T10:03:00.999Z'));
});

test('stampAfter ignores a seen stamp further ahead than FUTURE_MS (a wrong clock once, a restored book)', () => {
  const N = Date.parse('2026-11-22T10:00:00.000Z');
  assert.equal(NS.FUTURE_MS, 10 * 60 * 1000, 'the route\'s own limit');
  assert.equal(NS.stampAfter(N, ['2026-11-23T10:00:00.000Z']), '2026-11-22T10:00:00.000Z', 'a day ahead: ignored');
  assert.equal(NS.stampAfter(N, ['2026-11-23T10:00:00.000Z', '2026-11-22T10:05:00.000Z']), '2026-11-22T10:05:00.001Z', 'the sane one still counts');
  assert.equal(NS.stampAfter(N, ['2026-11-22T10:09:59.999Z']), '2026-11-22T10:10:00.000Z', '1 ms inside the limit counts, and lands exactly on it');
  assert.equal(NS.stampAfter(N, ['2026-11-22T10:10:00.000Z']), '2026-11-22T10:00:00.000Z', 'exactly at the limit is ignored: +1 ms would pass what judge accepts');
  assert.equal(NS.stampAfter(N, ['2026-11-22T10:10:00.001Z']), '2026-11-22T10:00:00.000Z', 'past it, ignored');
  // Whatever it returns, judge's own limit accepts it.
  for (const seen of ['2026-11-22T10:09:59.999Z', '2026-11-22T10:10:00.000Z']) {
    assert.ok(Date.parse(NS.stampAfter(N, [seen])) <= N + NS.FUTURE_MS);
  }
});
