/**
 * Phase 1 slice 2 — CloudBackend + blob-first sync protocol.
 * See docs/KHAYT-3.0-PHASE1-SPEC.md §5/§11.
 *
 * The reference server is an in-memory test FIXTURE (not shipped — the offline
 * app stays backend-free). It models the §4 store API: GET returns the blob +
 * rev (204 if none); PUT applies an optimistic rev compare-and-set, returning
 * 409 on a stale baseRev. Tenant isolation is structural: a backend for shop X
 * only ever addresses /v1/shops/X/store.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const sc = require('../lib/sync-crypto.js');
const { createCloudBackend } = require('../lib/cloud-backend.js');

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };
const STORE = { printLog: [{ id: 'o1', price: 100 }], clients: [{ id: 'c1', name: 'Acme' }] };

function makeRefServer() {
  const blobs = new Map(); // shopId -> { rev, ciphertext }
  const snaps = new Map(); // shopId -> [{ id, rev, ciphertext, createdAt }]
  let seq = 0, clock = 1;
  return {
    async handle({ method, path: rawPath, body }) {
      // Route on the path alone. This server is blob-only and knows nothing of
      // `?since=`, and a real one ignores it the same way — index.php routes on
      // parse_url(PHP_URL_PATH) — so a warm client asking a Phase 1 server for a
      // slice gets the whole blob back and folds nothing. That downgrade is the
      // behaviour under test here, not an accident of the fixture.
      const path = String(rawPath).split('?')[0];
      const sn = String(path).match(/^\/v1\/shops\/([^/]+)\/snapshots(?:\/(\d+))?$/);
      if (sn) {
        const shopId = sn[1];
        const arr = snaps.get(shopId) || [];
        if (method !== 'GET') return { status: 405 };
        if (sn[2]) {
          const s = arr.find((x) => String(x.id) === sn[2]);
          return s ? { status: 200, body: { id: s.id, rev: s.rev, createdAt: s.createdAt, ciphertext: s.ciphertext } } : { status: 404 };
        }
        return { status: 200, body: { snapshots: arr.slice().reverse().map((s) => ({ id: s.id, rev: s.rev, createdAt: s.createdAt, bytes: JSON.stringify(s.ciphertext).length })) } };
      }
      const m = String(path).match(/^\/v1\/shops\/([^/]+)\/store$/);
      if (!m) return { status: 404 };
      const shopId = m[1];
      if (method === 'GET') {
        const cur = blobs.get(shopId);
        return cur ? { status: 200, body: { ciphertext: cur.ciphertext, rev: cur.rev } } : { status: 204 };
      }
      if (method === 'PUT') {
        const curRev = blobs.has(shopId) ? blobs.get(shopId).rev : 0;
        if ((body.baseRev | 0) !== curRev) return { status: 409, body: { rev: curRev } };
        const rev = curRev + 1;
        blobs.set(shopId, { rev, ciphertext: body.ciphertext });
        const arr = snaps.get(shopId) || [];
        arr.push({ id: ++seq, rev, ciphertext: body.ciphertext, createdAt: clock++ });
        snaps.set(shopId, arr);
        return { status: 200, body: { rev } };
      }
      return { status: 405 };
    },
    raw(shopId) { return blobs.get(shopId); },
  };
}

// A device = a CloudBackend bound to (server, shopId, dek).
function device(server, shopId, dek) {
  return createCloudBackend({
    transport: (req) => server.handle(req),
    crypto: sc,
    shopId,
    getDek: () => dek,
  });
}

function freshDek(pass = 'p') {
  const { keyset } = sc.createKeyset(pass, { kdf: FAST_KDF });
  return sc.unlockWithPassphrase(pass, keyset);
}

test('round-trip: push on one device, pull + decrypt on another (same shop/DEK)', async () => {
  const server = makeRefServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  const res = await a.push(STORE);
  assert.equal(res.conflict, false);
  assert.equal(res.rev, 1);

  const pulled = await b.pull();
  assert.equal(pulled.rev, 1);
  assert.deepEqual(pulled.store, STORE);
});

test('server stores ciphertext only — no plaintext shop data at rest', async () => {
  const server = makeRefServer();
  const a = device(server, 'shopA', freshDek());
  await a.push(STORE);
  const stored = JSON.stringify(server.raw('shopA'));
  assert.ok(!stored.includes('printLog'), 'no plaintext collection name');
  assert.ok(!stored.includes('Acme'), 'no plaintext client name');
  assert.ok(server.raw('shopA').ciphertext.ct, 'only an opaque AEAD blob is stored');
});

test('stale push → 409 → pull → re-push succeeds (single-writer safety net)', async () => {
  const server = makeRefServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek);

  await a.push(STORE);                       // server rev = 1
  const stale = await b.push({ ...STORE, clients: [] }); // b still thinks baseRev 0
  assert.equal(stale.conflict, true);
  assert.equal(stale.serverRev, 1);

  await b.pull();                            // b learns rev 1 (+ merges in real app)
  const retry = await b.push({ ...STORE, extra: true });
  assert.equal(retry.conflict, false);
  assert.equal(retry.rev, 2);
});

test('tenant isolation: a backend for shop B never sees shop A data', async () => {
  const server = makeRefServer();
  await device(server, 'shopA', freshDek()).push(STORE);

  // shop B has its own (different) DEK and only addresses /shops/shopB/store
  const b = device(server, 'shopB', freshDek('other'));
  const pulled = await b.pull();
  assert.equal(pulled.store, null, 'shop B sees no store (204), never shop A\'s blob');
  assert.equal(server.raw('shopB'), undefined);
});

test('wrong DEK cannot decrypt a pulled blob (E2E holds across the protocol)', async () => {
  const server = makeRefServer();
  await device(server, 'shopA', freshDek('right')).push(STORE);
  const wrong = device(server, 'shopA', freshDek('different')); // valid shop, wrong key
  await assert.rejects(() => wrong.pull(), /unable to authenticate|bad decrypt|tag/i);
});

test('snapshot history: list prior versions + restore one by decrypting (cross-device)', async () => {
  const server = makeRefServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  const b = device(server, 'shopA', dek); // another device, same shop+key

  await a.push(STORE);                                  // rev 1
  await a.push({ ...STORE, extra: 'v2' });              // rev 2 (head)

  const list = await b.listSnapshots();
  assert.equal(list.length, 2);
  assert.equal(list[0].rev, 2, 'newest first');
  assert.equal(list[1].rev, 1);
  assert.ok(list[0].bytes > 0);

  // Restore the OLDER version on device B → decrypts to the original store.
  const older = await b.getSnapshot(list[1].id);
  assert.equal(older.rev, 1);
  assert.deepEqual(older.store, STORE);

  assert.equal(await b.getSnapshot(999999), null, 'unknown id → null');
});

test('snapshot restore respects E2E: wrong DEK cannot decrypt a fetched snapshot', async () => {
  const server = makeRefServer();
  await device(server, 'shopA', freshDek('right')).push(STORE);
  const wrong = device(server, 'shopA', freshDek('different'));
  const list = await wrong.listSnapshots(); // metadata is not encrypted
  assert.equal(list.length, 1);
  await assert.rejects(() => wrong.getSnapshot(list[0].id), /unable to authenticate|bad decrypt|tag/i);
});

test('SyncBackend interface: pushDeltas/pullDeltas/status integrate', async () => {
  const server = makeRefServer();
  const dek = freshDek();
  const a = device(server, 'shopA', dek);
  assert.equal(a.name, 'cloud');
  assert.equal(a.status(), 'idle');
  const r = await a.pushDeltas(STORE);
  assert.equal(r.conflict, false);
  const p = await a.pullDeltas();
  assert.deepEqual(p.store, STORE);
  assert.equal(a.status(), 'idle');
});

/* ── A failure a shop can act on ──────────────────────────────────────────────
 *
 * Every non-200 used to become `push failed: HTTP 413`, and the settings badge
 * said only "Sync error". So a shop that had outgrown its plan saw a red light
 * with no cause and no next step, indefinitely — while the server had already
 * explained it in a sentence the owner could act on. The status code is still
 * carried, because that is what a bug report needs.
 */

/** A server that refuses with `status` and the sentence a real one would send. */
const refusingWith = (status, error) => ({
  transport: async () => ({ status, body: error === undefined ? undefined : { error } }),
  crypto: sc, shopId: 'shopA', getDek: () => freshDek(),
});

test('a push refused over the plan limit says so, not just "HTTP 413"', async () => {
  const b = createCloudBackend(refusingWith(413, 'Store exceeds your plan’s size limit'));
  // Pinned on the ACTIONABLE half, the way the portal 404 test is: a mutation
  // that dropped the server's sentence and kept the number must fail here.
  await assert.rejects(() => b.push(STORE), /exceeds your plan/,
    'the owner has to be told what to fix, not handed a status code');
  await assert.rejects(() => b.push(STORE), /413/, 'and the code survives for a bug report');
});

test('a push refused because this build cannot read the chain says what to DO', async () => {
  // The 412 the server returns when a delta chain exists and this device has not
  // said it can fold one. Failing loudly is the entire point of that refusal, and
  // a bare "HTTP 412" is not loud, it is just unexplained.
  const b = createCloudBackend(refusingWith(412, 'This shop has unsynced changes this build cannot read. Update Khayt to sync again.'));
  await assert.rejects(() => b.push(STORE), /Update Khayt to sync again/);
});

test('a pull failure passes the server’s reason through too', async () => {
  const b = createCloudBackend(refusingWith(500, 'Server error'));
  await assert.rejects(() => b.pull(), /pull failed: Server error \(HTTP 500\)/);
});

test('a refusal with no body still names the status', async () => {
  // Not every failure carries a sentence — a proxy or a dead gateway will not.
  // The message must stay useful rather than reading "push failed: undefined".
  const b = createCloudBackend(refusingWith(502));
  await assert.rejects(() => b.push(STORE), /push failed: HTTP 502$/);
});

test('a failed request carries its HTTP status, so a caller can tell a refusal from an outage', async () => {
  const sc = require('../lib/sync-crypto.js');
  const { createCloudBackend } = require('../lib/cloud-backend.js');
  const { keyset } = sc.createKeyset('p', { kdf: { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 } });
  const dek = sc.unlockWithPassphrase('p', keyset);
  const backend = createCloudBackend({
    transport: async () => ({ status: 412, body: { error: 'Update Khayt to sync again.' } }),
    crypto: sc, shopId: 's', getDek: () => dek,
  });
  await assert.rejects(backend.push({ clients: [] }), (e) => e.status === 412 && /Update Khayt/.test(e.message));
});
