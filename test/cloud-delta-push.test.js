/**
 * Entity-level delta push — the protocol, proven against a reference server
 * before any of it is written in PHP.
 *
 * Blob-first sync costs `store size × saves`, so a shop pays for its whole
 * history on every card it drags and the bill grows quadratically with age
 * (docs/KHAYT-CLOUD-COST-PER-SHOP.md §4). Pushing only what changed removes the
 * size term entirely.
 *
 * The reference server here is a test FIXTURE, not shipped code. It models the
 * contract the real server would have to implement:
 *
 *   POST /v1/shops/{id}/deltas   { ciphertext, baseRev }
 *        200 { rev } · 409 { rev } on a stale head · 404 if unsupported
 *        409 { rev, compact: true } when the chain is full (`chainCap`)
 *   GET  /v1/shops/{id}/store[?since={rev}]
 *        200 { ciphertext?, rev, deltas: [{ rev, ciphertext }] }
 *        `ciphertext` only when the caller is behind the base; `rev` is always
 *        the head of the WHOLE chain, never of the returned slice.
 *
 * Writing the fixture first is the point: it is far cheaper to find out here
 * that the shape is wrong than after it exists in two server implementations
 * that a parity test pins together. The `?since=` half arrived the other way
 * round — the servers had it first — so the fixture models what they actually
 * do, and index.php is quoted where it is easy to get wrong.
 *
 * The most important test in this file is 'THE HAZARD'. It does not check that
 * the protocol works — it checks that the protocol is dangerous, and it is why
 * DELTA_WRITES shipped off for the whole readers-first half of the rollout. It
 * still passes now that the flag is on: the danger did not go away, the server
 * gate simply stops a chain forming while a device that would flatten it is
 * attached. The test nearest it in spirit is the warm pull's, further down:
 * that failure mode is silent too, and it eats local edits.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const sc = require('../lib/sync-crypto.js');
const { createCloudBackend, DELTA_WRITES, COMPACT_RATIO, MAX_CHAIN_DELTAS } = require('../lib/cloud-backend.js');

const ENGINE = path.join(__dirname, '..', 'lib', 'sync.js');
const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };

/** Each simulated device needs its own engine — `lastIndex` is module state. */
function loadEngine() {
  delete require.cache[require.resolve(ENGINE)];
  return require(ENGINE);
}

function freshDek(pass = 'p') {
  const { keyset } = sc.createKeyset(pass, { kdf: FAST_KDF });
  return sc.unlockWithPassphrase(pass, keyset);
}

/**
 * A delta-capable server: one base blob per shop plus an ordered chain of
 * opaque deltas. It never decrypts anything.
 */
function makeDeltaServer({ takesDeltas = true, gatedShops = null, gateStatus = 404, chainCap = Infinity } = {}) {
  const base = new Map();     // shopId -> { rev, ciphertext }
  const chain = new Map();    // shopId -> [{ rev, ciphertext }]
  const bytes = { blob: 0, delta: 0, pull: 0 };
  return {
    bytes,
    async handle({ method, path: rawPath, body }) {
      const [p, query] = String(rawPath).split('?');
      const d = String(p).match(/^\/v1\/shops\/([^/]+)\/deltas$/);
      if (d) {
        if (!takesDeltas) return { status: 404 };       // a Phase 1 server
        if (method !== 'POST') return { status: 405 };
        const shopId = d[1];
        // The per-shop gate of §4: this server takes deltas, just not for a shop
        // that still has a blob-only device attached. `gateStatus` is what the
        // desktop turns out to be sensitive to — see the last two tests here.
        if (gatedShops && gatedShops.has(shopId)) return { status: gateStatus };
        const head = headRev(shopId);
        if ((body.baseRev | 0) !== head) return { status: 409, body: { rev: head } };
        // Chain full. The real servers have three triggers and one of them — the
        // plan's size — is invisible to the desktop, so a bare count stands in
        // for "the server decided" here (docs/api-contract.md, POST /deltas).
        if ((chain.get(shopId) || []).length >= chainCap) return { status: 409, body: { rev: head, compact: true } };
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
        // `?since={rev}`: only entries newer than that rev, and the base only
        // when the caller is actually behind it. Mirrors index.php — including
        // the part that is easy to get wrong, that `rev` is the head of the
        // WHOLE chain and never of the filtered slice. A caller that is already
        // current gets no deltas back and must still be told the rev it is
        // current WITH, or its next push guards on a stale head and 409s.
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
        chain.set(shopId, []);                           // a full push compacts
        bytes.blob += JSON.stringify(body).length;
        return { status: 200, body: { rev } };
      }
      return { status: 405 };
    },
    /** Head = base rev, advanced by every delta appended after it. */
    chainLength(shopId) { return (chain.get(shopId) || []).length; },
  };

  function headRev(shopId) {
    const arr = chain.get(shopId) || [];
    if (arr.length) return arr[arr.length - 1].rev;
    return base.has(shopId) ? base.get(shopId).rev : 0;
  }
}

/** A device: a backend bound to (server, shop, dek) with its own engine. */
function device(server, shopId, dek, { deltaWrites = true, engine = loadEngine() } = {}) {
  const backend = createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc,
    shopId,
    getDek: () => dek,
    sync: engine,
    deltaWrites,
  });
  return { backend, engine };
}

/** A store the sync engine has stamped, the way a real save would leave it. */
function stamped(engine, over = {}) {
  const s = { printLog: [], clients: [], inventory: [], tombstones: [], ...over };
  engine.stampChanges(s);
  return s;
}

test('the whole store goes up first — there is nothing to delta against yet', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  const res = await a.backend.push(store);

  assert.equal(res.conflict, false);
  assert.equal(res.delta, undefined, 'the first push cannot be a delta');
  assert.equal(server.chainLength('shopA'), 0);
});

test('a change after that ships only the change, and it is much smaller', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  // A store with some history behind it — the case blob-first punishes.
  const store = stamped(a.engine, {
    printLog: Array.from({ length: 400 }, (_, i) => ({ id: 'o' + i, price: 100 + i, notes: 'x'.repeat(60) })),
  });
  await a.backend.push(store);
  const blobBytes = server.bytes.blob;

  // One new order, as a save would produce it.
  store.printLog.push({ id: 'new', price: 999 });
  a.engine.stampChanges(store);
  const res = await a.backend.push(store);

  assert.equal(res.delta, true, 'the second push should be a delta');
  assert.equal(server.chainLength('shopA'), 1);
  assert.ok(
    server.bytes.delta * 10 < blobBytes,
    `a one-record delta (${server.bytes.delta} B) should be far under a whole-store push (${blobBytes} B)`,
  );
});

test('another device folds base + deltas back into the identical store', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);

  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);
  await a.backend.push(store);

  store.clients.push({ id: 'c3', name: 'Gamma' });
  a.engine.stampChanges(store);
  await a.backend.push(store);

  assert.equal(server.chainLength('shopA'), 2, 'two deltas on top of one base');

  const pulled = await b.backend.pull();
  const names = pulled.store.clients.map((c) => c.name).sort();
  assert.deepEqual(names, ['Acme', 'Beta Ltd', 'Gamma'],
    'a device that never saw the deltas individually still ends up with all three');
});

test('the server holds ciphertext only — a delta leaks nothing but its size', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);

  let seen = '';
  const spy = device(
    { handle: async (req) => { seen += JSON.stringify(req.body || {}); return server.handle(req); } },
    'shopA', dek, { engine: a.engine },
  );
  spy.backend._setServerRev(1);
  await spy.backend.push(store);

  assert.ok(!seen.includes('Beta Ltd'), 'no plaintext record content on the wire');
  assert.ok(!seen.includes('clients'), 'not even the collection name');
});

test('a stale head is refused, and the refused edit survives to the next push', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  await b.backend.pull();                       // b is now current

  store.clients.push({ id: 'c2', name: 'from A' });
  a.engine.stampChanges(store);
  await a.backend.push(store);                  // A moves the head

  const bStore = stamped(b.engine, { clients: [{ id: 'c3', name: 'from B' }] });
  const res = await b.backend.push(bStore);     // B is building on a stale head
  assert.equal(res.conflict, true, 'a delta built on a stale head must be refused');

  // The property that matters is not "a counter did not move" — it is that the
  // refused edit is still queued. Resolve the conflict the way the caller does,
  // and B's client must actually reach the server.
  const fresh = await b.backend.pull();
  b.engine.applyDeltas(fresh.store, { deltas: [{ collection: 'clients', record: bStore.clients[0] }], tombstones: [] }, {});
  const retry = await b.backend.push(fresh.store);
  assert.equal(retry.conflict, false);

  const check = device(server, 'shopA', dek);
  const names = (await check.backend.pull()).store.clients.map((c) => c.name).sort();
  assert.deepEqual(names, ['Acme', 'from A', 'from B'],
    'a refused delta must survive into the next payload, or the edit it carried is lost everywhere');
});

test('a Phase 1 server needs no flag — the client falls back to the blob', async () => {
  const server = makeDeltaServer({ takesDeltas: false });
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);

  const res = await a.backend.push(store);
  assert.equal(res.conflict, false);
  assert.equal(res.delta, undefined, 'no delta route means a whole-store push');
  assert.equal(server.bytes.delta, 0, 'nothing was sent to the delta endpoint');

  // And it round-trips, which is the property that actually matters.
  const b = device(server, 'shopA', dek);
  const pulled = await b.backend.pull();
  assert.equal(pulled.store.clients.length, 2);
});

test('a pull with deltas but no engine refuses rather than returning a stale store', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);
  await a.backend.push(store);

  // Same server, but a backend with no delta engine wired in.
  const blind = createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc, shopId: 'shopA', getDek: () => dek,
  });
  await assert.rejects(() => blind.pull(), /no sync engine/,
    'silently dropping the deltas would hand the caller a store missing its newest edits');
});

test('DELTA_WRITES is ON, and a build without the engine still refuses to write', () => {
  // This asserted `false` for the whole readers-first half of the rollout. The
  // condition it was waiting on — a server that refuses a delta push for a shop
  // with a blob-only device attached — is met: khayt-cloud#16 refuses with 404,
  // which is the status the client already falls back on. THE HAZARD below is
  // unchanged and still passes; what changed is that a chain can no longer form
  // while a device that would flatten it is attached.
  assert.equal(DELTA_WRITES, true);

  const server = makeDeltaServer();
  const a = createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc, shopId: 'shopA', getDek: () => freshDek(), sync: loadEngine(),
  });
  assert.equal(a.writesDeltas(), true, 'the default build writes deltas');

  // The flag is necessary but not sufficient, and this is the half that must
  // never regress: a build whose delta engine failed to load cannot fold a
  // chain, so it must not write one either — or it would create a chain that it
  // then flattens on its own next full push.
  const engineless = createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc, shopId: 'shopA', getDek: () => freshDek(),
  });
  assert.equal(engineless.writesDeltas(), false,
    'no engine means no delta writes, whatever the flag says');
});

test('THE HAZARD: a blob-only desktop silently destroys every delta', async () => {
  // This is the test that justifies the flag above, and it is written to FAIL
  // if the hazard ever stops being real — at which point the flag can go.
  //
  // The old client is not broken and not out of date in any way it can detect.
  // It pulls, gets a 200 with a base blob, ignores the `deltas` field it has
  // never heard of, merges into it, and pushes a well-formed full store with a
  // correct baseRev. Nothing rejects it. The newer edits are simply gone.
  //
  // Compare the compression rollout, which this otherwise resembles: a beta.16
  // client meeting a gzipped blob STOPS, loudly. This one keeps working.
  const server = makeDeltaServer();
  const dek = freshDek();
  const modern = device(server, 'shopA', dek);

  const store = stamped(modern.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await modern.backend.push(store);

  store.clients.push({ id: 'c2', name: 'Only in the delta' });
  modern.engine.stampChanges(store);
  await modern.backend.push(store);
  assert.equal(server.chainLength('shopA'), 1);

  // A Phase 1 desktop: no sync engine, so no idea deltas exist.
  const old = createCloudBackend({
    transport: async (req) => {
      const res = await server.handle(req);
      // Model the old client faithfully: it only ever read these two fields.
      if (res.status === 200 && res.body && res.body.deltas) {
        return { status: 200, body: { ciphertext: res.body.ciphertext, rev: res.body.rev } };
      }
      return res;
    },
    crypto: sc, shopId: 'shopA', getDek: () => dek,
  });

  const seenByOld = await old.pull();
  assert.equal(seenByOld.store.clients.length, 1,
    'the old client cannot see the delta — this is the setup, not yet the damage');

  seenByOld.store.clients.push({ id: 'c9', name: 'Added by the old client' });
  const res = await old.push(seenByOld.store);
  assert.equal(res.conflict, false, 'and nothing rejects its push');

  // The damage, from a device that CAN read deltas.
  const check = device(server, 'shopA', dek);
  const after = await check.backend.pull();
  const names = after.store.clients.map((c) => c.name);
  assert.ok(!names.includes('Only in the delta'),
    'if this ever fails, the hazard is gone and DELTA_WRITES can be reconsidered');
  assert.deepEqual(names.sort(), ['Acme', 'Added by the old client'],
    'a committed edit was destroyed by a client doing nothing wrong');
});

// ── compaction ──────────────────────────────────────────────────────────────
//
// A chain has to be reset by a full push, or a cold device pays for the base
// plus every delta ever appended — and every one of them is a decrypt. The two
// bounds are derived in scripts/cloud-cost-model.mjs; these pin the behaviour.

test('a chain past the byte ratio is compacted by a full push', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  // A real-sized base, so the chain has room to grow before the ratio binds.
  const store = bigStore(a.engine);
  await a.backend.push(store);
  const baseAfterFirst = a.backend.chainState().baseWireBytes;
  assert.ok(baseAfterFirst > 0, 'the base size is recorded');

  // Push deltas until the backend says it is due, then once more.
  let guard = 0;
  while (!a.backend.chainState().dueForCompaction && guard++ < 200) {
    store.clients.push({ id: 'c' + guard, name: 'client ' + guard });
    a.engine.stampChanges(store);
    await a.backend.push(store);
  }
  const due = a.backend.chainState();
  assert.ok(due.dueForCompaction, 'the chain should become due for compaction');
  assert.ok(due.chainWireBytes > COMPACT_RATIO * due.baseWireBytes
    || due.chainCount >= MAX_CHAIN_DELTAS, 'due for the documented reason');

  store.clients.push({ id: 'last', name: 'triggers the compaction' });
  a.engine.stampChanges(store);
  const res = await a.backend.push(store);

  assert.equal(res.delta, undefined, 'the compacting push is a full one, not a delta');
  assert.equal(server.chainLength('shopA'), 0, 'the server chain is reset');
  assert.equal(a.backend.chainState().chainCount, 0);
  assert.equal(a.backend.chainState().chainWireBytes, 0);
});

test('a chain the SERVER calls full is compacted by a full push, not pulled forever', async () => {
  // Cap at 2 on a real-sized store, so the desktop's own rule is nowhere near
  // firing: this is the plan-size case, where only the server knows.
  const server = makeDeltaServer({ chainCap: 2 });
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = bigStore(a.engine);
  await a.backend.push(store);
  for (let i = 0; i < 2; i++) {
    store.clients.push({ id: 'd' + i, name: 'delta ' + i });
    a.engine.stampChanges(store);
    assert.equal((await a.backend.push(store)).delta, true);
  }
  assert.equal(a.backend.chainState().dueForCompaction, false,
    'the desktop must not see this coming, or the test proves nothing');

  store.clients.push({ id: 'full', name: 'refused as a delta' });
  a.engine.stampChanges(store);
  const res = await a.backend.push(store);

  // Before the fix this came back { conflict: true }, the caller pulled (a no-op
  // at its own head) and pushed the same delta into the same 409, forever.
  assert.equal(res.conflict, false, 'a full chain is not a conflict — pulling cannot fix it');
  assert.equal(res.delta, undefined, 'the answer to a full chain is the whole store');
  assert.equal(server.chainLength('shopA'), 0, 'the server chain is compacted');
  assert.equal(a.backend.chainState().dueForCompaction, false, 'and the demand is cleared');

  const check = device(server, 'shopA', dek);
  const names = (await check.backend.pull()).store.clients.map((c) => c.name);
  assert.ok(names.includes('refused as a delta'), 'the edit the refused delta carried still arrives');

  // Deltas resume after the compaction rather than every push staying a blob.
  store.clients.push({ id: 'after', name: 'after' });
  a.engine.stampChanges(store);
  assert.equal((await a.backend.push(store)).delta, true);
});

test('a 409 without `compact` is still a moved head, and still a conflict', async () => {
  const server = makeDeltaServer({ chainCap: 1000 });
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);
  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  await b.backend.pull();
  store.clients.push({ id: 'c2', name: 'from A' });
  a.engine.stampChanges(store);
  await a.backend.push(store);
  const res = await b.backend.push(stamped(b.engine, { clients: [{ id: 'c3', name: 'B' }] }));
  assert.equal(res.conflict, true, 'only `compact: true` may turn a 409 into a full push');
  assert.equal(b.backend.chainState().dueForCompaction, false);
});

test('compaction loses nothing — the store still round-trips afterwards', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = bigStore(a.engine);
  await a.backend.push(store);
  for (let i = 0; i < 60; i++) {
    store.clients.push({ id: 'c' + i, name: 'client ' + i });
    a.engine.stampChanges(store);
    await a.backend.push(store);
  }

  const b = device(server, 'shopA', dek);
  const pulled = await b.backend.pull();
  assert.equal(pulled.store.clients.length, 61,
    'every record survives however the chain was compacted along the way');
});

/** A store big enough that a delta is genuinely cheaper than a fresh base. */
const bigStore = (engine) => stamped(engine, {
  printLog: Array.from({ length: 400 }, (_, i) => ({ id: 'o' + i, price: 100 + i, notes: 'x'.repeat(60) })),
  clients: [{ id: 'c1', name: 'A' }],
});

test('a pull adopts the server chain, not just what this device appended', async () => {
  // Two devices push onto one chain. A backend that counted only its own deltas
  // would think the chain was half as long as it is and compact too late.
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = bigStore(a.engine);
  await a.backend.push(store);
  for (const name of ['two', 'three', 'four']) {
    store.clients.push({ id: name, name });
    a.engine.stampChanges(store);
    await a.backend.push(store);
  }
  assert.equal(server.chainLength('shopA'), 3);

  await b.backend.pull();
  assert.equal(b.backend.chainState().chainCount, 3,
    'B sees the whole chain, including deltas it never sent');
  assert.ok(b.backend.chainState().baseWireBytes > 0, 'and the base it was built on');
});

test('a SMALL store compacts almost immediately, so deltas never make it worse', async () => {
  // Both a delta and a whole small store are dominated by the same ~1.1 KB
  // crypto/base64 envelope, so for a tiny shop a delta buys nothing — and the
  // ratio rule notices without being told, because one delta already exceeds
  // COMPACT_RATIO × a tiny base.
  //
  // This is the property that makes the policy safe to enable everywhere rather
  // than only for large shops: the saving scales with store size, and where
  // there is no saving the backend falls back to the blob on its own.
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'A' }] });
  await a.backend.push(store);
  for (let i = 0; i < 6; i++) {
    store.clients.push({ id: 'c' + i, name: 'client ' + i });
    a.engine.stampChanges(store);
    await a.backend.push(store);
  }

  assert.ok(server.chainLength('shopA') <= 2,
    `a tiny store should keep compacting, not build a chain (got ${server.chainLength('shopA')})`);

  const b = device(server, 'shopA', dek);
  assert.equal((await b.backend.pull()).store.clients.length, 7,
    'and it still round-trips exactly');
});

test('an unknown base size still bounds the chain by count', () => {
  // The ratio cannot be evaluated without a base, and "no opinion" would let a
  // chain run away on exactly the path where that state was lost.
  assert.equal(MAX_CHAIN_DELTAS, 1000);
  assert.equal(COMPACT_RATIO, 2);
});

/* ---------------------------------------------------------------------------
 * The pull half. `?since=` is a requirement, not an optimisation: without it a
 * warm device re-downloads the base AND the whole chain every time, which makes
 * pulls WORSE than blob-only and can cancel the push saving on its own.
 * ------------------------------------------------------------------------- */

test('a warm pull asks for the slice and folds it onto the view it kept', async () => {
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = stamped(a.engine, {
    printLog: Array.from({ length: 300 }, (_, i) => ({ id: 'o' + i, price: i, notes: 'x'.repeat(60) })),
    clients: [{ id: 'c1', name: 'Acme' }],
  });
  await a.backend.push(store);

  // B comes up cold: base + whole chain, and it now holds a server view.
  await b.backend.pull();
  assert.equal(b.backend.isWarm(), true, 'a pull leaves the backend warm');
  const coldBytes = server.bytes.pull;

  // A appends one record.
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);
  await a.backend.push(store);

  server.bytes.pull = 0;
  const warm = await b.backend.pull();

  assert.deepEqual(warm.store.clients.map((c) => c.name).sort(), ['Acme', 'Beta Ltd'],
    'the warm pull produces the same store a cold one would');
  // The bound is deliberately loose. This fixture's base is 400 records of the
  // same repeated filler, so it compresses far better than a real store and the
  // gap here (~7×) UNDERSTATES the saving rather than flattering it. What is
  // being pinned is the shape — the base is not on the wire at all — not a ratio.
  assert.ok(server.bytes.pull * 3 < coldBytes,
    `a warm pull (${server.bytes.pull} B) must be a fraction of a cold one (${coldBytes} B)`);
});

test('a warm pull that is already current still learns the head rev', async () => {
  // The subtle one, and the reason the server sends the whole chain's head
  // rather than the slice's: a caller that is current gets no deltas back, and
  // if it did not learn the rev it is current WITH, its next push would guard on
  // a stale head and 409 forever.
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  await a.backend.pull();
  const rev = a.backend.serverRev();

  const again = await a.backend.pull();
  assert.equal(again.rev, rev, 'a no-op warm pull reports the same head');

  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);
  const res = await a.backend.push(store);
  assert.equal(res.conflict, false, 'and the push after it is not refused as stale');
});

test('a compaction while a device was away comes back as a cold reply on its own', async () => {
  // The client asks for a slice; the server decides what it is entitled to. When
  // the base has moved past the caller's rev it sends the base too, so no special
  // case is needed here for "my view is older than the chain".
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = bigStore(a.engine);
  await a.backend.push(store);
  await b.backend.pull();                       // B is warm at the old base

  // Let A run the chain out until it compacts, all while B is away.
  let guard = 0;
  do {
    store.clients.push({ id: 'c' + guard, name: 'client ' + guard });
    a.engine.stampChanges(store);
    await a.backend.push(store);
  } while (server.chainLength('shopA') > 0 && guard++ < 200);
  assert.equal(server.chainLength('shopA'), 0, 'a full push compacted the chain');

  const pulled = await b.backend.pull();
  assert.equal(pulled.store.printLog.length, 400, 'B got a whole store back, not a slice');
  assert.equal(pulled.store.clients.length, store.clients.length,
    'B folds nothing and simply adopts the new base');
});

test('a warm pull ADDS to the chain count, so compaction still fires', async () => {
  // A warm reply shows only what is newer than `since`. Adopting its length as
  // the chain length would undercount every time and let a chain run past both
  // bounds — the failure would be a slow one, visible only as cold pulls that
  // got steadily more expensive.
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = bigStore(a.engine);             // big enough that deltas are chosen
  await a.backend.push(store);
  await b.backend.pull();

  for (const id of ['c2', 'c3', 'c4']) {
    store.clients.push({ id, name: id.toUpperCase() });
    a.engine.stampChanges(store);
    const res = await a.backend.push(store);
    assert.equal(res.delta, true, 'the setup needs real deltas, not full pushes');
    await b.backend.pull();                     // warm each time: one delta apiece
  }

  assert.equal(server.chainLength('shopA'), 3);
  assert.equal(b.backend.chainState().chainCount, 3,
    'B counted the whole chain, not just the last slice it was sent');
});

test('THE WARM-PULL TRAP: a local-only edit still ships after a warm pull', async () => {
  // The tempting target to fold onto is the local store, and it is quietly
  // wrong. Records arrive by reference, and the local store carries edits the
  // server has never seen; fold onto it and the markAllPushed that follows
  // records those local-only records as already sent, so they never ship.
  //
  // Nothing else here would notice: the store looks right on this device, the
  // push succeeds, and the record is simply absent from every other one.
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);

  const bStore = (await b.backend.pull()).store;  // B is warm

  // B makes an edit of its own and does NOT push it yet.
  bStore.clients.push({ id: 'b-local', name: 'B Only' });
  b.engine.stampChanges(bStore);

  // Meanwhile A pushes, and B pulls that in — warm, folding onto its view.
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);
  await a.backend.push(store);

  const pulled = await b.backend.pull();
  // The merge a real caller performs: A's records land in B's local store.
  b.engine.applyDeltas(bStore, { deltas: pulled.store.clients.map((record) => ({ collection: 'clients', record })), tombstones: [] }, {});

  await b.backend.push(bStore);
  const seen = (await a.backend.pull()).store.clients.map((c) => c.id).sort();
  assert.ok(seen.includes('b-local'),
    'B\'s unpushed local record survived the warm pull and reached the server');
  assert.deepEqual(seen, ['b-local', 'c1', 'c2']);
});

test('the store a pull returns is the caller\'s, not the retained view', async () => {
  // The other half of "cloned in and out". The caller merges the returned store
  // into local state by reference and then goes on editing it; if those were our
  // records, the view would drift into the local store one edit at a time and
  // the next warm fold would be built on edits the server never received.
  const server = makeDeltaServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);

  const first = (await b.backend.pull()).store;
  first.clients[0].name = 'LOCAL EDIT';           // as a caller would, after merging
  first.clients.push({ id: 'local', name: 'nope' });

  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);
  await a.backend.push(store);

  const second = (await b.backend.pull()).store;
  assert.equal(second.clients.find((c) => c.id === 'c1').name, 'Acme',
    'the warm fold was built on the server view, untouched by the caller');
  assert.equal(second.clients.some((c) => c.id === 'local'), false,
    'and the caller\'s local-only record never entered it');
});

/**
 * The two tests below are about the gate in §4 — the server-side refusal that
 * makes flipping DELTA_WRITES safe at all — and specifically about the status
 * code it refuses with, which the contract never named.
 *
 * The desktop treats only 404 and 405 as "this server cannot take deltas" and
 * falls back to the blob. Every other status is an error. So the gate's choice
 * of code decides whether a not-yet-adopted shop syncs quietly by blob or shows
 * its owner a sync error on every save — and the doc that specifies the gate
 * does not say which to use. These pin it from the side that has to live with it.
 */
test('a gated shop falls back to the blob, as long as the refusal is a 404', async () => {
  const server = makeDeltaServer({ gatedShops: new Set(['shopA']) });
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const open = device(server, 'shopB', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);

  const res = await a.backend.push(store);
  assert.equal(res.conflict, false);
  assert.equal(res.delta, undefined, 'a gated shop must not get a chain');
  assert.equal(server.chainLength('shopA'), 0);

  // Round-trips, which is the property that matters: the shop is merely paying
  // blob prices, not losing anything.
  const b = device(server, 'shopA', dek);
  assert.equal((await b.backend.pull()).store.clients.length, 2);

  // And the gate is per shop, not a server-wide off switch.
  const other = stamped(open.engine, { clients: [{ id: 'c9', name: 'Open' }] });
  await open.backend.push(other);
  other.clients.push({ id: 'c10', name: 'Second' });
  open.engine.stampChanges(other);
  await open.backend.push(other);
  assert.equal(server.chainLength('shopB'), 1, 'an eligible shop still gets deltas');
});

test('a gated shop whose refusal is a 403 errors instead — the status is load-bearing', async () => {
  const server = makeDeltaServer({ gatedShops: new Set(['shopA']), gateStatus: 403 });
  const dek = freshDek();
  const a = device(server, 'shopA', dek);

  const store = stamped(a.engine, { clients: [{ id: 'c1', name: 'Acme' }] });
  await a.backend.push(store);            // the first push is a blob anyway
  store.clients.push({ id: 'c2', name: 'Beta Ltd' });
  a.engine.stampChanges(store);

  await assert.rejects(() => a.backend.push(store), /delta push failed/,
    'anything but 404/405 surfaces as a sync error rather than a blob fallback');
  assert.equal(a.backend.status(), 'error');

  // The failure is loud but not lossy: the cursor did not advance, so the edit
  // is still in the next payload. That is what makes this a rollout hazard
  // rather than a data hazard — every save fails until the gate opens.
  const server2 = makeDeltaServer();
  const b = device(server2, 'shopA', dek);
  const fresh = stamped(b.engine, { clients: [{ id: 'c1', name: 'Acme' }, { id: 'c2', name: 'Beta Ltd' }] });
  await b.backend.push(fresh);
  assert.equal((await device(server2, 'shopA', dek).backend.pull()).store.clients.length, 2);
});
