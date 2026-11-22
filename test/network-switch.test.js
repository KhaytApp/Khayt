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

// ── the calls ──────────────────────────────────────────────────────────────

const SCOPE = 'https://cloud.example|' + SHOP;
function harness(over = {}) {
  const dek = crypto.randomBytes(32);
  const server = { value: null, puts: [], gets: 0, status: null, blocked: false, putStatus: null, hang: false, getFail: false };
  let book = { network: Object.assign({}, over.network || {}) };
  let file = { v: 2, scopes: { [SCOPE]: Object.assign({}, over.mine || {}) } };
  let sess = over.locked ? null : { url: 'https://cloud.example', shopId: SHOP, token: 't', role: 'role' in over ? over.role : 'owner', dek, scope: SCOPE };
  let may = over.mayChange !== false;
  const notes = [];
  const logs = [];
  const local = { offline: false, sets: 0 };
  let changes = 0;
  const client = {
    async getNetworkSwitch(url, shopId, token, opts) {
      server.gets += 1; server.lastGetPurpose = opts && opts.purpose;
      const once = server.allowOnce && opts && opts.purpose === 'switch-sync';
      if (once) server.allowOnce = false;
      if (server.blocked && !once) { const e = new Error('outbound blocked: switch-sync (offline)'); e.code = 'outbound.blocked'; throw e; }
      if (server.getFail) throw new Error('ECONNREFUSED');
      if (server.status) return { status: server.status, body: null };
      if (!server.value) return { status: 404, body: { reason: 'none' } };
      if (server.onGet) await server.onGet();
      return { status: 200, body: server.value };
    },
    async putNetworkSwitch(url, shopId, token, body) {
      if (server.hang) return new Promise(() => {});
      server.puts.push(body);
      if (server.onPut) await server.onPut();
      // A 409 names the newer stamp the server holds, as the real route does;
      // with none newer held, 10:05 (or the test's server.conflictAt).
      if (server.putStatus) {
        const held = server.value && server.value.changedAt > body.changedAt ? server.value.changedAt : null;
        return { status: server.putStatus, body: { reason: 'stale', changedAt: server.conflictAt || held || '2026-11-22T10:05:00.000Z' } };
      }
      server.value = { changedAt: body.changedAt, receivedAt: 'x', ciphertext: body.ciphertext };
      return { status: 200, body: { ok: true, changedAt: body.changedAt } };
    },
  };
  const sync = createNetworkSwitchSync({
    client, crypto: sc, now: () => over.now || NOW,
    session: () => sess, mayChange: () => may,
    getSettings: () => book,
    updateNetwork: async (fn) => { const n = fn(book.network || {}); book = Object.assign({}, book, { network: n }); },
    notify: (n) => notes.push(n),
    readMine: () => JSON.parse(JSON.stringify(file)),
    writeMine: (v) => { file = JSON.parse(JSON.stringify(v)); },
    log: (m) => logs.push(m),
    setLocalOffline: () => { local.offline = true; local.sets += 1; },
    changed: () => { changes += 1; },
    // Main's gate lets ONE switch-sync GET through the shop's switch (lib/main/outbound-fetch.js).
    allowSwitchSyncOnce: over.noOnce ? undefined : () => { server.allowOnce = true; server.onceAsked = (server.onceAsked || 0) + 1; },
  });
  const publishRemote = (p) => { server.value = { changedAt: p.changedAt, receivedAt: 'x', ciphertext: sc.encryptStore(p, dek) }; };
  return { sync, server, dek, book: () => book, setBook: (n) => { book = { network: n }; }, mine: () => file.scopes[SCOPE] || {}, file: () => file,
    notes, logs, publishRemote, local, changes: () => changes, lock: () => { sess = null; }, unlock: () => { sess = { url: 'https://cloud.example', shopId: SHOP, token: 't', role: 'owner', dek, scope: SCOPE }; }, deny: () => { may = false; } };
}
const ON_NOW = { offline: true, keep: ['updates'], changedAt: '2026-11-22T10:00:00.000Z', changedBy: 'Sara' };

test('pull: a value from another computer is applied, the window told, the stamp kept', async () => {
  const h = harness({ mine: { highestSeen: '2026-11-22T08:00:00.000Z' } });
  h.publishRemote(plain());
  const r = await h.sync.pull();
  assert.equal(r.act, 'apply');
  assert.deepEqual(h.book().network, { offline: true, keep: ['updates'], changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara', via: 'cloud' });
  assert.equal(h.notes.length, 1);
  assert.equal(h.mine().highestSeen, '2026-11-22T09:00:00.000Z');
  assert.equal(h.server.lastGetPurpose, 'switch-sync');
  assert.equal((await h.sync.pull()).why, 'not-newer');
});

test('review HIGH: an older cloud value never overwrites a newer switch set here, sent or not', async () => {
  const h = harness({ mine: { highestSeen: '2026-11-22T08:00:00.000Z' }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  h.publishRemote(plain({ changedAt: '2026-11-22T09:00:00.000Z' }));
  assert.equal((await h.sync.pull()).why, 'not-newer');
  assert.equal(h.book().network.offline, false);
  // A pull already judged when a newer local switch lands is refused inside the write chain.
  const r = harness({ mine: { highestSeen: '2026-11-22T08:00:00.000Z' } });
  r.publishRemote(plain());
  r.server.onGet = async () => { r.setBook({ offline: false, changedAt: '2026-11-22T09:30:00.000Z' }); };
  assert.equal((await r.sync.pull()).why, 'not-newer');
  assert.equal(r.book().network.offline, false);
});

test('pull: another shop\'s key, a lying server stamp, a store blob, or a far-future stamp are ignored, logged without content', async () => {
  const h = harness({ mine: { highestSeen: '2026-11-22T08:00:00.000Z' } });
  h.server.value = { changedAt: '2026-11-22T09:00:00.000Z', ciphertext: sc.encryptStore(plain(), crypto.randomBytes(32)) };
  assert.equal((await h.sync.pull()).why, 'sealed');
  h.publishRemote(plain());
  h.server.value.changedAt = '2026-11-22T09:59:00.000Z';
  assert.equal((await h.sync.pull()).why, 'stamp-mismatch');
  h.publishRemote({ printLog: [], settings: {}, changedAt: '2026-11-22T09:00:00.000Z' });
  assert.equal((await h.sync.pull()).why, 'kind');
  h.publishRemote(plain({ changedAt: '9999-12-31T23:59:59.999Z' }));
  assert.equal((await h.sync.pull()).why, 'future');
  assert.equal(h.book().network.offline, undefined, 'nothing applied');
  assert.equal(h.mine().highestSeen, '2026-11-22T08:00:00.000Z', 'the mark never jumps to the future');
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
  // A computer whose book has a switch of its own is not "no stamp": it applies.
  const h3 = harness({ network: { offline: false, changedAt: '2026-11-01T09:00:00.000Z' } });
  h3.publishRemote(plain({ changedAt: '2026-11-10T09:00:00.000Z' }));
  assert.equal((await h3.sync.pull()).act, 'apply');
});

test('pull: a 404 unties an offline computer from the cloud and tells the window; locked or blocked does nothing', async () => {
  const h = harness({ network: { offline: true, via: 'cloud', changedAt: '2026-11-22T09:00:00.000Z' } });
  assert.equal((await h.sync.pull()).status, 404);
  assert.equal(h.book().network.via, null);
  assert.equal(h.book().network.offline, true, 'its value stands');
  assert.equal(h.notes.length, 1);
  assert.equal((await harness({ locked: true }).sync.pull()).why, 'locked');
  const b = harness(); b.server.blocked = true;
  assert.equal((await b.sync.pull()).why, 'blocked');
});

test('publish on: only with this computer\'s option, the owner, the staff lock allowing, a fresh stamp', async () => {
  const off = harness();
  assert.deepEqual(await off.sync.publish({ offline: true, network: ON_NOW }), { ok: true, sent: false });
  assert.equal(off.server.puts.length, 0, 'option off: nothing sent');
  const h = harness({ mine: { share: true } });
  const r = await h.sync.publish({ offline: true, network: ON_NOW });
  assert.equal(r.ok, true); assert.equal(r.via, 'cloud');
  const opened = sc.decryptStore(h.server.puts[0].ciphertext, h.dek);
  assert.deepEqual(opened, { kind: 'khayt-network-switch', v: 1, shopId: SHOP, offline: true, keep: ['updates'], changedAt: '2026-11-22T10:00:00.000Z', changedBy: 'Sara' });
  assert.equal(h.mine().highestSeen, '2026-11-22T10:00:00.000Z');
  assert.equal((await h.sync.pull()).why, 'not-newer', 'its own value is never applied back');
  assert.equal((await harness({ mine: { share: true }, role: 'manager' }).sync.publish({ offline: true, network: ON_NOW })).why, 'role');
  assert.equal((await harness({ mine: { share: true }, mayChange: false }).sync.publish({ offline: true, network: ON_NOW })).why, 'not_permitted');
  assert.equal((await harness({ mine: { share: true } }).sync.publish({ offline: true, network: Object.assign({}, ON_NOW, { changedAt: '2026-11-22T11:00:00.000Z' }) })).why, 'stamp', 'a stamp an hour away is not this change');
});

test('publish off: from the book, never the window; asks first, sends offline:false if published, whatever the option', async () => {
  const h = harness({ network: { offline: false, keep: [], changedAt: '2026-11-22T10:00:00.000Z', changedBy: 'Sara' } });
  h.publishRemote(plain());
  const r = await h.sync.publish({ offline: false, network: { offline: false, changedAt: '2026-11-22T10:00:01.000Z' } });
  assert.equal(r.sent, true);
  const sent = sc.decryptStore(h.server.puts[0].ciphertext, h.dek);
  assert.deepEqual([sent.offline, sent.changedAt], [false, '2026-11-22T10:00:00.000Z']);
  assert.equal(h.server.lastGetPurpose, 'cloud');
  // The save was refused: the book is still offline, nothing goes.
  const refused = harness({ network: { offline: true, changedAt: '2026-11-22T09:00:00.000Z' } });
  refused.publishRemote(plain());
  assert.equal((await refused.sync.publish({ offline: false })).why, 'not-saved');
  assert.equal(refused.server.puts.length, 0);
  const none = harness({ network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  assert.deepEqual(await none.sync.publish({ offline: false }), { ok: true, sent: false });
});

test('review M2: an off that could not go is sent again with the same stamp at the next tick', async () => {
  const h = harness({ network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z', via: 'cloud' } });
  h.publishRemote(plain());
  h.server.getFail = true;
  assert.equal((await h.sync.publish({ offline: false })).later, true);
  assert.equal(h.sync.state().pendingOff, true);
  h.server.getFail = false;
  await h.sync.tick();
  assert.equal(h.server.puts.length, 1);
  assert.equal(sc.decryptStore(h.server.puts[0].ciphertext, h.dek).changedAt, '2026-11-22T10:00:00.000Z');
  assert.equal(h.sync.state().pendingOff, false);
  // Turned off while Khayt Cloud was locked: sent at the next unlock's tick.
  const l = harness({ locked: true, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z', via: 'cloud' } });
  assert.equal((await l.sync.publish({ offline: false })).why, 'locked');
  l.unlock(); l.publishRemote(plain());
  await l.sync.tick();
  assert.equal(l.server.puts.length, 1);
});

test('rule 3: a 409 is held for the person, never applied by the timer, never retried', async () => {
  const h = harness({ mine: { share: true }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  h.publishRemote(plain());              // "off" goes only over a published value (GET first)
  h.server.putStatus = 409;
  const r = await h.sync.publish({ offline: false });
  assert.equal(r.why, 'stale');
  assert.equal(h.server.puts.length, 1);
  h.server.putStatus = null;
  h.publishRemote(plain({ changedAt: '2026-11-22T10:05:00.000Z' }));
  assert.equal((await h.sync.pull()).act, 'held');
  assert.equal(h.book().network.offline, false, 'the person\'s change stands until they choose');
  assert.deepEqual(h.sync.state().conflict, { at: '2026-11-22T10:05:00.000Z', mine: '2026-11-22T10:00:00.000Z', offline: false, held: true, theirs: true });
  assert.equal((await h.sync.answerConflict('adopt')).applied, true);
  assert.equal(h.book().network.offline, true);
  const k = harness({ mine: { share: true }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  k.publishRemote(plain());
  k.server.putStatus = 409;
  await k.sync.publish({ offline: false });
  k.server.putStatus = null;
  k.publishRemote(plain({ changedAt: '2026-11-22T10:05:00.000Z' }));
  await k.sync.pull();
  // Turning it OFF here: nothing to keep on this computer only (stricter-only, frame G).
  assert.deepEqual(await k.sync.answerConflict('keep'), { ok: false, why: 'looser' });
  assert.ok(k.sync.state().conflict, 'the conflict stays open for "Use the newer setting"');
  assert.equal(k.local.sets, 0);
  assert.equal(k.book().network.offline, false);
});

test('frame G: "Keep it on this computer only" after turning it ON keeps this computer offline and the shop takes the newer setting', async () => {
  const h = harness({ mine: { share: true } });
  h.server.conflictAt = new Date(NOW + 3 * 60000).toISOString();   // the 409 names what the GET later reads
  h.server.putStatus = 409;
  const on = Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() });
  h.setBook(on);
  const r = await h.sync.publish({ offline: true, network: on });
  assert.equal(r.why, 'stale');
  assert.equal(h.sync.state().conflict.offline, true);
  h.server.putStatus = null;
  h.publishRemote(plain({ offline: false, changedAt: new Date(NOW + 3 * 60000).toISOString() }));
  assert.equal((await h.sync.pull()).act, 'held');
  const k = await h.sync.answerConflict('keep');
  assert.equal(k.ok, true);
  assert.equal(k.kept, true);
  assert.equal(k.applied, true);
  assert.equal(h.local.offline, true, 'this computer stays offline on its own switch');
  assert.equal(h.book().network.offline, false, 'the shop follows the newer setting');
  assert.equal(h.sync.state().conflict, null);
  assert.equal((await harness().sync.answerConflict('keep')).why, 'none', 'no conflict, nothing to answer');
});

test('frame G: a second refusal of the PERSON\'s change says the clock may be behind; retries never count; a 200 clears it', async () => {
  const h = harness({ mine: { share: true }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  h.server.putStatus = 409;
  h.publishRemote(plain({ offline: true, changedAt: '2026-11-22T10:05:00.000Z' }));
  await h.sync.publish({ offline: false });
  assert.equal(h.sync.state().clockBehind, false);
  assert.ok(h.changes() >= 1, 'the conflict appearing tells the window');
  // H2: the next tick does not PUT the same change again, nor count it.
  const puts = h.server.puts.length;
  await h.sync.tick();
  assert.equal(h.server.puts.length, puts, 'no retry while the person has not answered');
  assert.equal(h.sync.state().clockBehind, false);
  assert.equal((await h.sync.answerConflict('adopt')).applied, true);
  // The person changes it again, and is refused again: now the clock line.
  h.setBook({ offline: false, changedAt: '2026-11-22T10:06:00.000Z' });
  h.publishRemote(plain({ offline: true, changedAt: '2026-11-22T10:07:00.000Z' }));
  await h.sync.publish({ offline: false });
  assert.equal(h.sync.state().clockBehind, true);
  h.server.putStatus = null;
  await h.sync.answerConflict('adopt');
  h.setBook({ offline: false, changedAt: '2026-11-22T10:08:00.000Z' });
  await h.sync.publish({ offline: false });
  assert.equal(h.sync.state().clockBehind, false);
  assert.equal(h.sync.state().owner, true);
  assert.equal(harness({ role: 'manager' }).sync.state().owner, false);
});

test('review H1/M1: the newer value is fetched at the 409, so both answers work after this computer went offline', async () => {
  for (const choice of ['adopt', 'keep']) {
    const h = harness({ mine: { share: true } });
    const on = Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() });
    h.publishRemote(plain({ offline: false, changedAt: new Date(NOW + 60000).toISOString() }));
    h.server.putStatus = 409;
    assert.equal((await h.sync.publish({ offline: true, network: on })).why, 'stale');
    assert.equal(h.sync.state().conflict.held, true, 'held at the 409, while still online');
    h.setBook(on);                 // the window saves "on" after the answer
    h.server.blocked = true;       // offline now: every switch-sync GET refused
    const r = await h.sync.answerConflict(choice);
    assert.equal(r.ok, true, choice);
    assert.equal(r.applied, true, choice);
    assert.equal(h.book().network.offline, false, `${choice}: the shop takes the newer setting`);
    assert.equal(h.local.offline, choice === 'keep', `${choice}: this computer's own switch`);
    assert.equal(h.sync.state().conflict, null);
  }
  // Nothing held and nothing reachable: not answered, the card stays, nothing changes.
  const n = harness({ mine: { share: true } });
  const on = Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() });
  n.server.putStatus = 409;
  await n.sync.publish({ offline: true, network: on });
  n.setBook(on);
  n.server.blocked = true;
  n.server.getFail = true;   // the one GET the answer makes fails too
  assert.deepEqual(await n.sync.answerConflict('keep'), { ok: false, why: 'unreachable' });
  assert.equal(n.local.sets, 0, 'this computer\'s switch untouched');
  assert.ok(n.sync.state().conflict, 'the card stays');
  assert.equal(n.book().network.offline, true);
});

test('review H2: a retry already in flight cannot open a conflict for a change the book no longer holds', async () => {
  // "Off" owed from earlier (turned off while sharing), sent by the tick, not the person.
  const h = harness({ mine: { share: true, highestSeen: '2026-11-22T09:00:00.000Z' }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  h.publishRemote(plain());           // "off" goes only over a published value (GET first)
  h.server.putStatus = 409;
  // While that PUT is out, the person answers / changes the switch: the book moves on.
  h.server.onPut = async () => { h.setBook({ offline: true, changedAt: '2026-11-22T10:01:00.000Z' }); };
  await h.sync.tick();
  assert.equal(h.server.puts.length, 1, 'the owed "off" was sent by the tick');
  assert.equal(h.sync.state().conflict, null, 'and its refusal opened nothing');
  assert.equal(h.sync.state().clockBehind, false);
});

test('per server and shop: another scope\'s stamps and held values never apply; the staff lock gates every answer', async () => {
  const h = harness({ mine: { share: true, highestSeen: '2026-11-22T09:30:00.000Z' } });
  const f = h.file();
  f.scopes['https://evil.example|other'] = { highestSeen: '9999-12-31T23:59:59.999Z', pending: plain() };
  h.publishRemote(plain({ changedAt: '2026-11-22T09:45:00.000Z' }));
  assert.equal((await h.sync.pull()).act, 'apply', 'another scope\'s far-future stamp does not block this one');
  const d = harness(); d.deny();
  assert.equal(d.sync.setShare(true).why, 'not_permitted');
  assert.equal((await d.sync.answerPending(true)).why, 'not_permitted');
  assert.equal((await d.sync.answerConflict('adopt')).why, 'not_permitted');
  assert.equal(harness({ role: 'manager' }).sync.setShare(true).why, 'role');
  assert.equal(harness({ locked: true }).sync.setShare(true).why, 'locked');
});

test('desktop wiring: only the book\'s own cloud, the staff lock, the gate purpose, the save guard, start at unlock', () => {
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
  const cc = read('lib/cloud-client.js');
  assert.match(cc, /if \(purpose === 'switch-sync'\) return outboundGate\('switch-sync', url\);/);
  const main = read('main.js');
  assert.match(main, /scope !== NSS\.scopeOf\(cloud\.url, cloud\.shopId\)/);
  assert.match(main, /mayChange: \(\) => PrinterPermission\.mayChangeNetwork\(bookForPrivacyCheck\(\)\)/);
  assert.match(main, /keepNewerNetwork\(merged, guardDisk, Date\.now\(\)\)/);
  assert.match(main, /networkSwitchSync\.start\(\);\s*\n\s*return \{ ok: true \};/);
  assert.match(main, /catch \(e\) \{ networkSwitchSync\.stop\(\);/);
  assert.match(read('lib/main/outbound-fetch.js'), /purpose !== 'switch-sync'\) noteAllowedHost/);
  const iu = read('renderer/internet-use.js');
  assert.match(iu, /networkSwitchPublish\(\{ offline: false \}\)/);
  assert.match(iu, /filter\(\(k\) => k !== 'switch-sync'\)/);
});

test('security review LOW-1: no cloud role recorded is not the owner; the share option greys and nothing is published', async () => {
  for (const role of [null, undefined, '']) {
    const h = harness({ mine: { share: true }, role });
    assert.equal((await h.sync.publish({ offline: true, network: ON_NOW })).why, 'role', String(role));
    assert.equal(h.server.puts.length, 0, 'nothing sent');
    assert.equal(harness({ role }).sync.setShare(true).why, 'role', String(role));
  }
  // main.js hands the sync the book's role as it is, never a default of owner.
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.doesNotMatch(main, /role: cloud\.role \|\| 'owner'/);
  assert.match(main, /role: typeof cloud\.role === 'string' && cloud\.role \? cloud\.role : null, scope/);
});

test('review of the banner: locking Khayt Cloud tells the window, and the question is no longer shown', () => {
  const h = harness({ mine: { pending: { offline: true, changedAt: '2026-11-22T09:00:00.000Z', changedBy: 'Sara' } } });
  assert.ok(h.sync.state().pending, 'a question waits while unlocked');
  const before = h.changes();
  h.sync.stop();        // main's hub:cloud-lock calls this, then drops the session
  h.lock();
  assert.ok(h.changes() > before, 'the window was told');
  assert.equal(h.sync.state().pending, null, 'and state() shows nothing to point to');
  const main = require('fs').readFileSync(require('path').join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /ipcMain\.handle\('hub:cloud-lock', \(\) => \{ networkSwitchSync\.stop\(\);/);
});

/* Dev Hub, Nov 22 (the Mac's review of the same flow). */
const conflictNotHeld = async (mineOn) => {
  const h = harness({ mine: { share: true } });
  const net = mineOn ? Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() })
    : { offline: false, changedAt: new Date(NOW).toISOString() };
  h.server.conflictAt = new Date(NOW + 60000).toISOString();   // what the 409 names, and the GET later reads
  h.server.putStatus = 409;
  h.server.getFail = true;            // the GET at the 409 fails: nothing held
  await h.sync.publish({ offline: mineOn, network: net });
  h.setBook(net);
  h.server.putStatus = null;
  h.server.getFail = false;
  return h;
};

test('a 409 alone names no direction: theirs is null until the other value is read, then which way it went', async () => {
  const h = await conflictNotHeld(true);
  assert.equal(h.sync.state().conflict.held, false);
  assert.equal(h.sync.state().conflict.theirs, null, 'not read: the window uses the general sentence');
  const k = harness({ mine: { share: true } });
  k.publishRemote(plain({ offline: true, changedAt: new Date(NOW + 60000).toISOString() }));
  k.server.putStatus = 409;
  await k.sync.publish({ offline: true, network: Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() }) });
  assert.equal(k.sync.state().conflict.theirs, true, 'read: the other computer also turned it ON (a clock behind)');
});

test('"Use the newer setting" with nothing held makes ONE switch-sync GET, even with the shop offline, and applies what it reads', async () => {
  const h = await conflictNotHeld(true);
  h.publishRemote(plain({ offline: false, changedAt: new Date(NOW + 60000).toISOString() }));
  h.server.blocked = true;            // offline by the shop's switch: only the one-shot gets through
  const gets = h.server.gets;
  const r = await h.sync.answerConflict('adopt');
  assert.equal(r.ok, true);
  assert.equal(r.applied, true);
  assert.equal(h.server.gets - gets, 1, 'exactly one GET');
  assert.equal(h.server.lastGetPurpose, 'switch-sync', 'as switch-sync, person-started');
  assert.equal(h.server.onceAsked, 1, 'main\'s gate was asked to let it through once');
  assert.equal(h.book().network.offline, false);
  assert.equal(h.sync.state().conflict, null);
});

test('"Use the newer setting": the one GET fails, so the question STAYS and the window says Khayt Cloud could not be reached', async () => {
  for (const fail of ['getFail', 'status']) {
    const h = await conflictNotHeld(true);
    h.publishRemote(plain({ offline: false, changedAt: new Date(NOW + 60000).toISOString() }));
    if (fail === 'getFail') h.server.getFail = true;
    if (fail === 'status') h.server.status = 503;
    const before = h.changes();
    const r = await h.sync.answerConflict('adopt');
    assert.deepEqual(r, { ok: false, why: 'unreachable' }, fail);
    assert.ok(h.sync.state().conflict, `${fail}: the question stays, never cleared with nothing applied`);
    assert.equal(h.book().network.offline, true, `${fail}: nothing changed`);
    assert.ok(h.changes() > before, `${fail}: the window is told to draw it again`);
  }
  // Without main's one-shot (a gate that refuses switch-sync offline), it is unreachable too.
  const n = harness({ mine: { share: true }, noOnce: true });
  n.server.putStatus = 409; n.server.getFail = true;
  const on = Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() });
  await n.sync.publish({ offline: true, network: on });
  n.setBook(on); n.server.putStatus = null; n.server.getFail = false;
  n.publishRemote(plain({ offline: false, changedAt: new Date(NOW + 60000).toISOString() }));
  n.server.blocked = true;
  assert.equal((await n.sync.answerConflict('adopt')).why, 'unreachable');
  assert.ok(n.sync.state().conflict);
});

test('"Keep it on this computer only" only when it really keeps this computer stricter than the newer value', async () => {
  // Both turned it ON (a clock behind): keeping it on here keeps nothing.
  const h = harness({ mine: { share: true } });
  h.publishRemote(plain({ offline: true, changedAt: new Date(NOW + 60000).toISOString() }));
  h.server.putStatus = 409;
  await h.sync.publish({ offline: true, network: Object.assign({}, ON_NOW, { changedAt: new Date(NOW).toISOString() }) });
  assert.deepEqual(await h.sync.answerConflict('keep'), { ok: false, why: 'not-stricter' });
  assert.equal(h.local.sets, 0, 'this computer\'s own switch untouched');
  assert.ok(h.sync.state().conflict, 'the question stays for "Use the newer setting"');
  assert.equal((await h.sync.answerConflict('adopt')).applied, true);
  // Not held at the 409, read on the answer, and it is ON too: still refused.
  const k = await conflictNotHeld(true);
  k.publishRemote(plain({ offline: true, changedAt: new Date(NOW + 60000).toISOString() }));
  assert.deepEqual(await k.sync.answerConflict('keep'), { ok: false, why: 'not-stricter' });
  assert.equal(k.local.sets, 0);
});

test('frame G words: a direction only when read and opposite; Keep only when stricter; "could not reach Khayt Cloud" said', () => {
  const ui = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'internet-use.js'), 'utf8');
  const g = ui.slice(ui.indexOf('function gCards('), ui.indexOf('function answerSay('));
  assert.match(g, /const known = typeof c\.theirs === 'boolean' && c\.theirs !== turningOn;/);
  assert.match(g, /const keep = known && turningOn;/);
  assert.match(g, /'iu\.g\.conflict_general_body'/);
  assert.match(ui, /if \(r\.why === 'unreachable'\) return toast\('⚠ ' \+ tr\('iu\.g\.unreachable'\)/);
  for (const l of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'locales', l + '.js'), 'utf8');
    for (const k of ['iu.g.conflict_general_body', 'iu.g.unreachable', 'iu.g.conflict_on_body', 'iu.g.conflict_off_body']) assert.match(src, new RegExp(`"${k.replace(/\./g, '\\.')}":`), `${l} ${k}`);
  }
});

// ── Cloud lane review of #2645 / #2646 ─────────────────────────────────────

async function conflicted() {
  const h = harness({ mine: { share: true }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  h.publishRemote(plain());                 // published, so "off" is sent
  h.server.putStatus = 409;                 // the server names 10:05 as its stamp
  await h.sync.publish({ offline: false });
  h.server.putStatus = null;
  return h;
}

test('security: "Use the newer setting" never applies a value older than the stamp the 409 named', async () => {
  const h = await conflicted();
  // A replayed value stamped between this computer's change (10:00) and the 409's (10:05).
  h.publishRemote(plain({ changedAt: '2026-11-22T10:02:00.000Z' }));
  const r = await h.sync.answerConflict('adopt');
  assert.deepEqual(r, { ok: false, why: 'not-held' });
  assert.equal(h.book().network.offline, false, 'nothing applied');
  assert.equal(h.sync.state().conflict.at, '2026-11-22T10:05:00.000Z', 'the question stays, with its stamp');
  // The real newer value: applied.
  h.publishRemote(plain({ changedAt: '2026-11-22T10:05:00.000Z' }));
  assert.deepEqual(await h.sync.answerConflict('adopt'), { ok: true, kept: false, applied: true });
  assert.equal(h.book().network.offline, true);
  assert.equal(h.sync.state().conflict, null);
});

test('nothing held: the answer keeps the conflict and its stamp until a value is applied', async () => {
  const h = await conflicted();
  h.server.getFail = true;
  assert.deepEqual(await h.sync.answerConflict('adopt'), { ok: false, why: 'unreachable' });
  assert.equal(h.sync.state().conflict.at, '2026-11-22T10:05:00.000Z');
  assert.equal(h.book().network.offline, false);
  h.server.getFail = false;
  h.publishRemote(plain({ changedAt: '2026-11-22T10:06:00.000Z' }));
  assert.equal((await h.sync.answerConflict('adopt')).applied, true);
  assert.equal(h.sync.state().conflict, null);
});

test('Dev Hub: turning it off at a sharing computer PUTs offline:false only over a published value; after a 404, nothing', async () => {
  const h = harness({ mine: { share: true }, network: { offline: false, changedAt: '2026-11-22T10:00:00.000Z' } });
  assert.deepEqual(await h.sync.publish({ offline: false }), { ok: true, sent: false });
  assert.equal(h.server.gets, 1, 'asked first');
  assert.equal(h.server.puts.length, 0, 'nothing published: nothing sent, so the switch is not published again');
  h.publishRemote(plain());
  assert.equal((await h.sync.publish({ offline: false })).sent, true);
  assert.equal(h.server.puts.length, 1);
});
