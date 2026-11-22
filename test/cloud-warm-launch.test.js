'use strict';

/**
 * WARM LAUNCH — the retained server view, kept across restarts.
 * docs/KHAYT-CLOUD-DELTA-SYNC.md §7.
 *
 * The saving is easy to demonstrate and is not what most of this file is about.
 * `cloudBackend` is rebuilt on every unlock, so before this the first pull of
 * every session fetched the base and the whole chain; now it can ask `?since=`.
 *
 * What needs pinning is the guard. A view restored from disk is a claim about
 * what the SERVER holds, and everything newer than that claim is what gets
 * pushed. Within a session the claim cannot rot dangerously — local state only
 * moves forward. Across a restart it can: a store restored from a backup, rolled
 * back by `.prev` recovery, or copied in from another machine is OLDER than the
 * view, and adopting the view then pushes the older records over the newer ones
 * for every device. A cold pull has no such failure, because the merge engine
 * keeps the higher rev.
 *
 * So the tests that matter here are the ones that make the cache refuse itself.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const sc = require('../lib/sync-crypto.js');
const { createCloudBackend, viewSafeForLocal } = require('../lib/cloud-backend.js');
const { createViewCache } = require('../lib/cloud-view-cache.js');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');
const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };

function loadEngine() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

function freshDek(pass = 'p') {
  const { keyset } = sc.createKeyset(pass, { kdf: FAST_KDF });
  return sc.unlockWithPassphrase(pass, keyset);
}

function tmpdir(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `khayt-warm-${tag}-`));
}

/**
 * The same delta-capable fixture as cloud-delta-push.test.js: one base blob per
 * shop plus an ordered chain of opaque deltas, `?since=` returning only what is
 * newer and the base only when the caller is behind it.
 */
function makeDeltaServer() {
  const base = new Map();
  const chain = new Map();
  const bytes = { blob: 0, delta: 0, pull: 0 };
  const headRev = (shopId) => {
    const arr = chain.get(shopId) || [];
    if (arr.length) return arr[arr.length - 1].rev;
    return base.has(shopId) ? base.get(shopId).rev : 0;
  };
  return {
    bytes,
    chainLength(shopId) { return (chain.get(shopId) || []).length; },
    async handle({ method, path: rawPath, body }) {
      const [p, query] = String(rawPath).split('?');
      const d = String(p).match(/^\/v1\/shops\/([^/]+)\/deltas$/);
      if (d) {
        if (method !== 'POST') return { status: 405 };
        const shopId = d[1];
        const head = headRev(shopId);
        if ((body.baseRev | 0) !== head) return { status: 409, body: { rev: head } };
        const rev = head + 1;
        const arr = chain.get(shopId) || [];
        arr.push({ rev, ciphertext: body.ciphertext });
        chain.set(shopId, arr);
        bytes.delta += JSON.stringify(body).length;
        return { status: 200, body: { rev, deltaCount: arr.length } };
      }
      const m = String(p).match(/^\/v1\/shops\/([^/]+)\/store$/);
      if (!m) return { status: 404 };
      const shopId = m[1];
      if (method === 'GET') {
        const b = base.get(shopId);
        if (!b) return { status: 204 };
        const sinceRaw = new URLSearchParams(query || '').get('since');
        const since = (sinceRaw === null || sinceRaw === '') ? null : (sinceRaw | 0);
        const deltas = (chain.get(shopId) || []).filter((x) => x.rev > (since === null ? 0 : since));
        const out = { rev: headRev(shopId), deltas };
        if (since === null || since < b.rev) out.ciphertext = b.ciphertext;
        bytes.pull += JSON.stringify(out).length;
        return { status: 200, body: out };
      }
      if (method === 'PUT') {
        const head = headRev(shopId);
        if ((body.baseRev | 0) !== head) return { status: 409, body: { rev: head } };
        const rev = head + 1;
        base.set(shopId, { rev, ciphertext: body.ciphertext });
        chain.set(shopId, []);
        bytes.blob += JSON.stringify(body).length;
        return { status: 200, body: { rev } };
      }
      return { status: 405 };
    },
  };
}

/**
 * A device that keeps its view in `dir`. Calling this again with the same dir is
 * a RESTART: same shop, same disk, a brand-new backend — which is exactly what
 * an unlock does.
 */
function device(server, shopId, dek, dir, { localStore = null, engine = loadEngine(), deltaWrites = true } = {}) {
  const backend = createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc,
    shopId,
    getDek: () => dek,
    sync: engine,
    deltaWrites,
    viewCache: dir ? createViewCache({ dir, shopId, crypto: sc, getDek: () => dek }) : null,
    getLocalSnapshot: () => localStore,
  });
  return { backend, engine };
}

function stamped(engine, over = {}) {
  const s = { printLog: [], clients: [], inventory: [], tombstones: [], ...over };
  engine.stampChanges(s);
  return s;
}

const clone = (v) => JSON.parse(JSON.stringify(v));

/* ── The saving ─────────────────────────────────────────────────────────── */

test('a relaunched device starts warm and never re-fetches the base', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('save');

  const first = device(server, 'shopA', dek, dir);
  const store = stamped(first.engine, {
    printLog: Array.from({ length: 300 }, (_, i) => ({ id: 'o' + i, price: i, notes: 'x'.repeat(60) })),
    clients: [{ id: 'c1', name: 'Acme' }],
  });
  await first.backend.push(store);

  // Another device appends, so there is something for the relaunch to fetch. It
  // shares the engine that stamped the store: `stampChanges` decides what moved
  // from what it has seen before, so a fresh engine restamps every record and
  // the "one record changed" delta silently becomes the whole store.
  const other = device(server, 'shopA', dek, tmpdir('other'), { engine: first.engine });
  await other.backend.pull();
  const appended = clone(store);
  appended.clients.push({ id: 'c2', name: 'Beta Ltd' });
  first.engine.stampChanges(appended);
  await other.backend.push(appended);

  // RESTART: a new backend over the same directory, with the local store on disk.
  const relaunch = device(server, 'shopA', dek, dir, { localStore: store });
  assert.equal(relaunch.backend.isWarm(), true,
    'the backend is warm BEFORE its first pull — that is the whole feature');

  server.bytes.pull = 0;
  const warm = await relaunch.backend.pull();
  const warmBytes = server.bytes.pull;

  assert.deepEqual(warm.store.clients.map((c) => c.name).sort(), ['Acme', 'Beta Ltd'],
    'a warm launch produces the store a cold one would');

  // The same launch with no cache, for the comparison that matters.
  server.bytes.pull = 0;
  const cold = device(server, 'shopA', dek, null);
  await cold.backend.pull();
  assert.ok(warmBytes * 3 < server.bytes.pull,
    `warm launch (${warmBytes} B) must be a fraction of a cold one (${server.bytes.pull} B)`);
});

test('the view on disk is ciphertext — a stolen cache file is not a store', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('enc');
  const d = device(server, 'shopA', dek, dir);
  await d.backend.push(stamped(d.engine, { clients: [{ id: 'c1', name: 'Distinctive Customer Name' }] }));

  const files = fs.readdirSync(dir).filter((f) => f.startsWith('cloud-view-'));
  assert.equal(files.length, 1, 'exactly one cache file, keyed by shop');
  const raw = fs.readFileSync(path.join(dir, files[0]), 'utf8');
  assert.ok(!raw.includes('Distinctive Customer Name'), 'no plaintext record in the cache file');
  assert.ok(!raw.includes('"clients"'), 'not even the collection names');
});

/* ── The guard ──────────────────────────────────────────────────────────── */

test('THE ROLLBACK: a restored-from-backup store refuses the cached view', async () => {
  // The failure this whole guard exists for. Without it: local holds o1 at rev
  // 1, the view says the server holds rev 2, the difference is pushed, and the
  // newer record is destroyed everywhere.
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('rollback');

  const d = device(server, 'shopA', dek, dir);
  const old = stamped(d.engine, { printLog: [{ id: 'o1', price: 10 }] });
  await d.backend.push(old);

  const current = clone(old);
  current.printLog[0].price = 99;
  d.engine.stampChanges(current);
  await d.backend.push(current);
  assert.ok(current.printLog[0].rev > old.printLog[0].rev, 'the fixture really did move the rev on');

  // RESTART onto the OLD store, as a backup restore would leave it.
  const relaunch = device(server, 'shopA', dek, dir, { localStore: old });
  assert.equal(relaunch.backend.isWarm(), false, 'the cached view is refused');

  // And the refusal is what saves the record: a cold pull returns the newer one.
  const pulled = await relaunch.backend.pull();
  assert.equal(pulled.store.printLog[0].price, 99, 'the newer record survives the rollback');
});

test('a refused view is deleted, not merely ignored', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('refused');
  const d = device(server, 'shopA', dek, dir);
  const store = stamped(d.engine, { printLog: [{ id: 'o1', price: 10 }] });
  await d.backend.push(store);

  const behind = clone(store);
  behind.printLog[0].rev = 0;
  device(server, 'shopA', dek, dir, { localStore: behind });

  assert.equal(fs.readdirSync(dir).filter((f) => f.startsWith('cloud-view-')).length, 0,
    'a view this device cannot reconcile with is removed, not left for the next launch');
});

test('a locally deleted record is a deletion going forward, so the view still stands', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('tomb');
  const d = device(server, 'shopA', dek, dir);
  const store = stamped(d.engine, {
    printLog: [{ id: 'o1', price: 10 }, { id: 'o2', price: 20 }],
  });
  await d.backend.push(store);

  // Local deletes o2 the way the app does — record gone, tombstone left behind.
  const local = clone(store);
  local.printLog = local.printLog.filter((r) => r.id !== 'o2');
  local.tombstones = [{ collection: 'printLog', id: 'o2', deletedAt: new Date().toISOString() }];

  const relaunch = device(server, 'shopA', dek, dir, { localStore: local });
  assert.equal(relaunch.backend.isWarm(), true,
    'an ordinary local delete must not cost every launch a cold pull');
});

test('no local store to check against means no warm launch', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('nolocal');
  const d = device(server, 'shopA', dek, dir);
  await d.backend.push(stamped(d.engine, { clients: [{ id: 'c1', name: 'Acme' }] }));

  const relaunch = device(server, 'shopA', dek, dir, { localStore: null });
  assert.equal(relaunch.backend.isWarm(), false,
    'unverifiable is treated as unsafe — the conservative default is a cold pull');
});

test('a rotated key cannot read the old cache, and says so by going cold', async () => {
  const server = makeDeltaServer();
  const dek = freshDek('one');
  const dir = tmpdir('rotate');
  const d = device(server, 'shopA', dek, dir);
  const store = stamped(d.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await d.backend.push(store);

  const relaunch = device(server, 'shopA', freshDek('two'), dir, { localStore: store });
  assert.equal(relaunch.backend.isWarm(), false, 'a view it cannot decrypt is not a view');
});

test('a cache file belonging to another shop is never folded onto this one', () => {
  const dir = tmpdir('shopmix');
  const dek = freshDek();
  const a = createViewCache({ dir, shopId: 'shopA', crypto: sc, getDek: () => dek });
  a.save({ rev: 5, view: { clients: [{ id: 'c1', rev: 1 }] }, baseWireBytes: 1, chainWireBytes: 0, chainCount: 0 });

  // Same bytes, presented as shopB's — a moved or hand-copied file.
  const moved = createViewCache({ dir, shopId: 'shopB', crypto: sc, getDek: () => dek });
  fs.copyFileSync(a.file, moved.file);
  assert.equal(moved.load(), null, 'the id inside the file is checked, not assumed from its name');
});

/* ── What rides along with the view ─────────────────────────────────────── */

test('the base size survives the restart, so compaction still fires', async () => {
  // The quiet one. `baseWireBytes` is only ever learned from a cold reply or
  // from this device's own full push — and a device that launches warm sees
  // neither. Drop the counters and the byte half of the compaction policy stops
  // applying for good, leaving only MAX_CHAIN_DELTAS, with nothing to show for
  // it but cold pulls that grow steadily dearer.
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('counters');

  const first = device(server, 'shopA', dek, dir);
  const store = stamped(first.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await first.backend.push(store);
  const base = first.backend.chainState().baseWireBytes;
  assert.ok(base > 0, 'the first full push learns the base size');

  const relaunch = device(server, 'shopA', dek, dir, { localStore: store });
  assert.equal(relaunch.backend.chainState().baseWireBytes, base,
    'and the relaunched device still knows it');
});

test('the rev and the view are restored together or not at all', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('pair');
  const d = device(server, 'shopA', dek, dir);
  const store = stamped(d.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await d.backend.push(store);
  const rev = d.backend.serverRev();

  const relaunch = device(server, 'shopA', dek, dir, { localStore: store });
  assert.equal(relaunch.backend.serverRev(), rev, 'the rev came back with the view');
  assert.equal(relaunch.backend.isWarm(), true);

  // A push straight after a warm launch guards on the restored rev, so if the
  // pair had drifted apart this is where it would 409.
  const next = clone(store);
  next.clients.push({ id: 'c2', name: 'Beta Ltd' });
  relaunch.engine.stampChanges(next);
  const res = await relaunch.backend.push(next);
  assert.equal(res.conflict, false, 'the restored rev is the one the server is on');
});

test('moving the rev by hand takes the cached view with it', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('setrev');
  const d = device(server, 'shopA', dek, dir);
  const store = stamped(d.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await d.backend.push(store);
  assert.equal(fs.readdirSync(dir).filter((f) => f.startsWith('cloud-view-')).length, 1);

  d.backend._setServerRev(9);
  assert.equal(fs.readdirSync(dir).filter((f) => f.startsWith('cloud-view-')).length, 0,
    'a rev with no view behind it must not be left on disk for the next launch');
});

test('an unwritable cache costs a cold launch, never a sync', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const store = stamped(loadEngine(), { clients: [{ id: 'c1', name: 'Acme' }] });

  const brokenCache = {
    load() { throw new Error('disk is on fire'); },
    save() { throw new Error('disk is on fire'); },
    clear() { throw new Error('disk is on fire'); },
  };
  const backend = createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc,
    shopId: 'shopA',
    getDek: () => dek,
    sync: loadEngine(),
    deltaWrites: true,
    viewCache: brokenCache,
    getLocalSnapshot: () => store,
  });

  const res = await backend.push(store);
  assert.equal(res.conflict, false, 'the push went through regardless');
  const pulled = await backend.pull();
  assert.ok(pulled.store, 'and so did the pull');
});

/* ── The restore that happens while the app is running ──────────────────── */

/**
 * `viewSafeForLocal` stands at construction — unlock and launch. A restore
 * performed mid-session walks past it: the backend is not rebuilt, so the view,
 * the rev and the pushed-revs cursor all outlive the event that moved local
 * state backwards. That is what `forgetServerView()` is for, and these three
 * tests are the hazard, the fix, and the part `_setServerRev` would miss.
 */

/** A restore, as the renderer performs it: local becomes the older store. */
async function pushTwice(server, dir, dek, deltaWrites) {
  const d = device(server, 'shopA', dek, dir, { deltaWrites });
  const old = stamped(d.engine, { printLog: [{ id: 'o1', price: 10 }] });
  await d.backend.push(clone(old));

  const current = clone(old);
  current.printLog[0].price = 99;
  d.engine.stampChanges(current);
  await d.backend.push(current);
  assert.ok(current.printLog[0].rev > old.printLog[0].rev, 'the fixture really did move the rev on');
  return { d, old };
}

test('THE HAZARD: a mid-session restore pushes the older store straight over the newer one', async () => {
  // Characterises the bug rather than the fix, so a "fix" that changes nothing
  // cannot pass the next test by accident. deltaWrites:false because that is
  // what ships today, and it is the destructive half: a full push whose baseRev
  // the server accepts REPLACES the base, and every device pulls the old store.
  const server = makeDeltaServer();
  const dek = freshDek();
  const { d, old } = await pushTwice(server, tmpdir('hazard'), dek, false);

  const res = await d.backend.push(clone(old));
  assert.equal(res.conflict, false, 'nothing rejects it — that is the whole problem');

  const witness = device(server, 'shopA', dek, null);
  const seen = await witness.backend.pull();
  assert.equal(seen.store.printLog[0].price, 10,
    'the newer record is gone from the server, and nothing said so');
});

test('THE FIX: forgetting the view turns that same restore into a conflict, and the newer record survives', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const { d, old } = await pushTwice(server, tmpdir('midsession'), dek, false);

  // What the renderer now does before it applies the snapshot.
  d.backend.forgetServerView();

  const res = await d.backend.push(clone(old));
  assert.equal(res.conflict, true,
    'a push guarded on rev 0 cannot overwrite a shop that has ever pushed');

  // And a 409 is pull → merge → re-push, so the restore repairs instead.
  const pulled = await d.backend.pull();
  assert.equal(pulled.store.printLog[0].price, 99, 'the newer record survives the restore');
});

test('forgetting takes the pushed-revs cursor with it, not just the view', async () => {
  // The reason _setServerRev is not enough on its own. It drops the view and the
  // cache file but leaves `pushedRevs`, and the cursor is the dangerous half: a
  // rolled-back record still disagrees with it, so it still ships.
  const server = makeDeltaServer();
  const dek = freshDek();
  const dir = tmpdir('cursor');
  const { d } = await pushTwice(server, dir, dek, true);

  assert.ok(d.backend.pushedCount() > 0, 'there is a cursor to lose');
  assert.equal(fs.readdirSync(dir).filter((f) => f.startsWith('cloud-view-')).length, 1);

  d.backend.forgetServerView();

  assert.equal(d.backend.isWarm(), false, 'no view');
  assert.equal(d.backend.serverRev(), 0, 'no rev — this is what makes the next push conflict');
  assert.equal(d.backend.pushedCount(), 0, 'and no cursor to measure a rolled-back record against');
  assert.deepEqual(d.backend.chainState(), { baseWireBytes: 0, chainWireBytes: 0, chainCount: 0, dueForCompaction: false },
    'the counters described a base this backend no longer claims');
  assert.equal(fs.readdirSync(dir).filter((f) => f.startsWith('cloud-view-')).length, 0,
    'on disk too, or the next launch restores the pair this just declared unusable');
});

/* ── The predicate on its own ───────────────────────────────────────────── */

test('viewSafeForLocal: the exact cases, without a server in the way', () => {
  const view = {
    printLog: [{ id: 'o1', rev: 3 }],
    tombstones: [{ collection: 'clients', id: 'c9' }],
  };

  assert.equal(viewSafeForLocal(view, {
    printLog: [{ id: 'o1', rev: 3 }], tombstones: [{ collection: 'clients', id: 'c9' }],
  }), true, 'identical is safe');

  assert.equal(viewSafeForLocal(view, {
    printLog: [{ id: 'o1', rev: 7 }], tombstones: [{ collection: 'clients', id: 'c9' }],
  }), true, 'local ahead is the normal case — unpushed edits');

  assert.equal(viewSafeForLocal(view, {
    printLog: [{ id: 'o1', rev: 2 }], tombstones: [{ collection: 'clients', id: 'c9' }],
  }), false, 'local behind is the rollback');

  assert.equal(viewSafeForLocal(view, {
    printLog: [], tombstones: [{ collection: 'clients', id: 'c9' }],
  }), false, 'a record local lost without deleting it');

  assert.equal(viewSafeForLocal(view, {
    printLog: [{ id: 'o1', rev: 3 }],
    clients: [{ id: 'c9', rev: 1 }],
    tombstones: [],
  }), false, 'local still holds what the server deleted, with no tombstone of its own');

  assert.equal(viewSafeForLocal(view, {
    printLog: [{ id: 'o1', rev: 3 }, { id: 'o2', rev: 1 }], tombstones: [{ collection: 'clients', id: 'c9' }],
  }), true, 'extra local records are just unpushed work');

  assert.equal(viewSafeForLocal(view, null), false, 'nothing to check against is not safe');
  assert.equal(viewSafeForLocal(null, {}), false, 'and neither is nothing to check');
});
