/**
 * Khayt Cloud client — full encrypted round-trip against a LIVE local HTTP server
 * (an in-test reference server mirroring khayt-cloud's contract). Verifies the
 * whole path: keyset → register → encrypt → push → pull → decrypt, over real
 * fetch, with the server only ever seeing opaque ciphertext.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const cc = require('../lib/cloud-client.js');
const sc = require('../lib/sync-crypto.js');

const FAST_KDF = { algo: 'scrypt', N: 1024, r: 8, p: 1, keyLen: 32 };
const STORE = { printLog: [{ id: 'o1', price: 100 }], clients: [{ id: 'c1', name: 'Acme' }] };

let server, base, lastStored;
/** Every request the reference server saw: { method, path, auth }. Reset per test. */
const seen = [];

function refServer() {
  const tokens = new Map();   // shopId -> Set(token)  (supports multi-device)
  const blobs = new Map();    // shopId -> { rev, ciphertext }
  const accounts = new Map(); // email -> { shopId, password }
  const keysets = new Map();  // shopId -> keyset
  const published = new Map(); // pubToken -> { shopId, messages }
  const rand = () => Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
  const addToken = (shopId, token) => { (tokens.get(shopId) || tokens.set(shopId, new Set()).get(shopId)).add(token); };
  const readBody = (req) => new Promise((res) => {
    let s = ''; req.on('data', (c) => (s += c)); req.on('end', () => { try { res(JSON.parse(s || '{}')); } catch { res({}); } });
  });
  const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(body ? JSON.stringify(body) : ''); };
  const auth = (req, shopId) => {
    const m = /^Bearer\s+(.+)$/i.exec(req.headers.authorization || '');
    return m && tokens.get(shopId)?.has(m[1]);
  };
  return http.createServer(async (req, res) => {
    // Route on the path, keep the raw target. Both real backends do exactly this
    // — index.php via parse_url(PHP_URL_PATH), src/server.js via URL.pathname —
    // because `GET /store?since=7` is the same route as `GET /store`.
    const target = req.url;
    const query = new URL(req.url, 'http://localhost').searchParams;
    const path = req.url.split('?')[0].replace(/\/+$/, '') || '/';
    seen.push({
      method: req.method, path, target, since: query.get('since'),
      auth: req.headers.authorization || '',
      // Recorded so a test can assert what this device TELLS the server it can
      // read — the server refuses a shop a delta chain without it.
      cap: req.headers['x-delta-capable'] || '',
    });
    if (req.method === 'GET' && path === '/v1/health') return send(res, 200, { ok: true });
    if (req.method === 'POST' && path === '/v1/register') {
      const id = 'shop_' + rand(); const token = rand();
      addToken(id, token);
      return send(res, 200, { shopId: id, token });
    }
    if (req.method === 'POST' && path === '/v1/signup') {
      const body = await readBody(req);
      const email = String(body.email || '').toLowerCase();
      if (accounts.has(email)) return send(res, 409, { error: 'Email already registered' });
      const shopId = 'shop_' + rand(); const token = rand();
      addToken(shopId, token);
      accounts.set(email, { shopId, password: body.password });
      return send(res, 200, { accountId: 'acct_' + rand(), shopId, token });
    }
    if (req.method === 'POST' && path === '/v1/login') {
      const body = await readBody(req);
      const a = accounts.get(String(body.email || '').toLowerCase());
      if (!a || a.password !== body.password) return send(res, 401, { error: 'Wrong email or password' });
      const token = rand(); addToken(a.shopId, token);
      return send(res, 200, { shopId: a.shopId, token, keyset: keysets.get(a.shopId) || null });
    }
    const ks = /^\/v1\/shops\/([^/]+)\/keyset$/.exec(path);
    if (ks) {
      const shopId = ks[1];
      if (!auth(req, shopId)) return send(res, 401, { error: 'bad token' });
      if (req.method === 'GET') {
        return keysets.has(shopId) ? send(res, 200, { keyset: keysets.get(shopId) }) : send(res, 204);
      }
      if (req.method === 'PUT') {
        const body = await readBody(req);
        keysets.set(shopId, body.keyset);
        return send(res, 200, { ok: true });
      }
    }
    const m = /^\/v1\/shops\/([^/]+)\/store$/.exec(path);
    if (m) {
      const shopId = m[1];
      if (!auth(req, shopId)) return send(res, 401, { error: 'bad token' });
      if (req.method === 'GET') {
        const b = blobs.get(shopId);
        return b ? send(res, 200, { ciphertext: b.ciphertext, rev: b.rev }) : send(res, 204);
      }
      if (req.method === 'PUT') {
        const body = await readBody(req);
        const cur = blobs.get(shopId); const curRev = cur ? cur.rev : 0;
        if ((body.baseRev | 0) !== curRev) return send(res, 409, { rev: curRev });
        const rev = curRev + 1;
        lastStored = body.ciphertext;
        blobs.set(shopId, { rev, ciphertext: body.ciphertext });
        return send(res, 200, { rev });
      }
    }
    // ---- Portal: publish, owner reply, owner read, customer's public read ----
    const pub = /^\/v1\/shops\/([^/]+)\/published\/([^/]+)$/.exec(path);
    if (req.method === 'PUT' && pub) {
      if (!auth(req, pub[1])) return send(res, 401, { error: 'bad token' });
      await readBody(req);
      published.set(pub[2], { shopId: pub[1], messages: [] });
      return send(res, 200, { ok: true });
    }
    const oReply = /^\/v1\/shops\/([^/]+)\/published\/([^/]+)\/message$/.exec(path);
    if (req.method === 'POST' && oReply) {
      if (!auth(req, oReply[1])) return send(res, 401, { error: 'Invalid token or unknown shop' });
      const item = published.get(oReply[2]);
      if (!item || item.shopId !== oReply[1]) return send(res, 404, { error: 'Not found' });
      const body = await readBody(req);
      const msg = { from: 'shop', text: String(body.text || ''), at: 1 };
      item.messages.push(msg);
      return send(res, 200, { ok: true, message: msg });
    }
    // khayt-cloud #10: same thread as the public route below, but the caller
    // must hold the shop's token AND the item must belong to that shop.
    const oRead = /^\/v1\/shops\/([^/]+)\/published\/([^/]+)\/messages$/.exec(path);
    if (req.method === 'GET' && oRead) {
      if (!auth(req, oRead[1])) return send(res, 401, { error: 'Invalid token or unknown shop' });
      const item = published.get(oRead[2]);
      if (!item || item.shopId !== oRead[1]) return send(res, 404, { error: 'Not found' });
      return send(res, 200, { messages: item.messages });
    }
    const pRead = /^\/v1\/p\/([^/]+)\/messages$/.exec(path);
    if (req.method === 'GET' && pRead) {
      const item = published.get(pRead[1]);
      if (!item) return send(res, 404, { error: 'Not found' });
      return send(res, 200, { messages: item.messages });
    }
    return send(res, 404, { error: 'not found' });
  });
}

before(async () => {
  server = refServer();
  await new Promise((r) => server.listen(0, r));
  base = `http://localhost:${server.address().port}`;
});
after(() => server && server.close());

test('health + register reach the live server', async () => {
  assert.equal(await cc.health(base), true);
  const reg = await cc.register(base);
  assert.ok(reg.shopId && reg.token);
});

/* ---- Why the server could not be reached -------------------------------
 * "Server not reachable" covered a network that swallows the request, an
 * address that answers but is not a Khayt server, and a string that is not a
 * URL. Those need three different fixes, and a user told only the first one
 * cannot act. A real support thread — login sat on "Connecting…" and then said
 * nothing useful — is what these are for.
 * ---------------------------------------------------------------------- */

/* ---- emailFailed reaches the caller --------------------------------------
 * The server learned to say "I tried and the provider refused" (khayt-cloud #7)
 * so the app would stop opening a code dialog for a message that was never
 * accepted. A field the client drops on the floor is the same as not having it —
 * which is the shape of every bug this file has grown a test for today.
 * ---------------------------------------------------------------------- */

/** A server that answers the three send routes with whatever body we hand it. */
function mailServer(body) {
  const http = require('node:http');
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    });
  });
  return srv;
}

test('a refusal reported by the server reaches the caller', async () => {
  const http = require('node:http');
  const srv = mailServer({ ok: true, alreadyVerified: false, emailConfigured: true, emailFailed: true,
                           accountId: 'A', shopId: 'S', token: 'T' });
  await new Promise((r) => srv.listen(0, r));
  const base = `http://localhost:${srv.address().port}`;
  try {
    assert.equal((await cc.requestVerify(base, { email: 'a@b.co' })).emailFailed, true);
    assert.equal((await cc.requestReset(base, { email: 'a@b.co' })).emailFailed, true);
    assert.equal((await cc.signup(base, { email: 'a@b.co', password: 'x'.repeat(9) })).emailFailed, true);
  } finally { srv.close(); }
});

test('a server that says nothing about it is not treated as a failure', async () => {
  // Older deployments do not report the field. Absent must read as false, or
  // every shop on one would be told their email is broken.
  const srv = mailServer({ ok: true, alreadyVerified: false, emailConfigured: true,
                           accountId: 'A', shopId: 'S', token: 'T' });
  await new Promise((r) => srv.listen(0, r));
  const base = `http://localhost:${srv.address().port}`;
  try {
    assert.equal((await cc.requestVerify(base, { email: 'a@b.co' })).emailFailed, false);
    assert.equal((await cc.requestReset(base, { email: 'a@b.co' })).emailFailed, false);
    assert.equal((await cc.signup(base, { email: 'a@b.co', password: 'x'.repeat(9) })).emailFailed, false);
  } finally { srv.close(); }
});

test('a clean send is not reported as refused', async () => {
  const srv = mailServer({ ok: true, alreadyVerified: false, emailConfigured: true, emailFailed: false,
                           accountId: 'A', shopId: 'S', token: 'T' });
  await new Promise((r) => srv.listen(0, r));
  const base = `http://localhost:${srv.address().port}`;
  try {
    assert.equal((await cc.requestVerify(base, { email: 'a@b.co' })).emailFailed, false);
  } finally { srv.close(); }
});

test('a healthy server reports ok, and health() stays a boolean', async () => {
  assert.deepEqual(await cc.healthDetail(base), { ok: true, reason: 'ok' });
  assert.equal(await cc.health(base), true, 'the boolean contract is unchanged');
});

test('a server that answers but is not Khayt is named as such, not "unreachable"', async () => {
  const http = require('node:http');
  const wrong = http.createServer((_q, res) => { res.writeHead(500); res.end('nope'); });
  await new Promise((r) => wrong.listen(0, r));
  try {
    const d = await cc.healthDetail(`http://localhost:${wrong.address().port}`);
    assert.equal(d.ok, false);
    assert.equal(d.reason, 'http', 'it answered — that is not the same as unreachable');
    assert.equal(d.status, 500, 'and the status is carried so the user can act on it');
    assert.equal(await cc.health(`http://localhost:${wrong.address().port}`), false);
  } finally { wrong.close(); }
});

test('a network that swallows the request reports a timeout, with its budget', async () => {
  // Accepts the connection and never answers — the shape a firewall or proxy
  // produces, and the one that used to hang the UI for thirty seconds.
  const http = require('node:http');
  const blackhole = http.createServer(() => { /* deliberately no response */ });
  await new Promise((r) => blackhole.listen(0, r));
  try {
    const started = Date.now();
    const d = await cc.healthDetail(`http://localhost:${blackhole.address().port}`, { timeoutMs: 300 });
    const elapsed = Date.now() - started;
    assert.equal(d.ok, false);
    assert.equal(d.reason, 'timeout', 'a silent server is a timeout, not "unreachable"');
    assert.equal(d.timeoutMs, 300, 'and reports the budget it waited, so the UI can say how long');
    // Reporting the budget is not the same as honouring it. Without this the
    // option could be ignored entirely and the test would still pass — thirty
    // seconds later, which is the bug this whole change is about.
    assert.ok(elapsed < 3000, `waited ${elapsed}ms for a 300ms budget — the timeout is not being applied`);
  } finally { blackhole.close(); }
});

test('the default health budget is far below the general one', async () => {
  // The bug was a 30s general timeout applied to a one-line GET.
  assert.ok(cc.HEALTH_TIMEOUT_MS <= 10000,
    `a health probe waiting ${cc.HEALTH_TIMEOUT_MS}ms reads as a frozen app`);
});

test('a string that is not a URL is a bad address, not a dead server', async () => {
  for (const bad of ['not a url', '', 'ftp://example.com']) {
    const d = await cc.healthDetail(bad);
    assert.equal(d.ok, false, JSON.stringify(bad));
    assert.equal(d.reason, 'bad-url', JSON.stringify(bad));
    assert.ok(d.detail, 'and carries something worth showing the user');
  }
});

test('http:// to a public host is refused before any password is sent', async () => {
  // The existing guard, now reachable through healthDetail's bad-url branch.
  const d = await cc.healthDetail('http://cloud.example.com');
  assert.equal(d.reason, 'bad-url');
  assert.match(d.detail, /https/i);
});

test('full E2E round-trip: encrypt → push → pull → decrypt equals the store', async () => {
  const { shopId, token } = await cc.register(base);
  const { keyset } = cc.createKeyset('sync-pass', { kdf: FAST_KDF });
  const dek = cc.unlockWithPassphrase('sync-pass', keyset);
  const backend = cc.backendFor(base, shopId, token, dek);

  const pushed = await backend.push(STORE);
  assert.equal(pushed.conflict, false);
  assert.equal(pushed.rev, 1);

  // server stored ONLY opaque ciphertext (no plaintext)
  assert.ok(lastStored && lastStored.ct, 'opaque AEAD blob stored');
  assert.ok(!JSON.stringify(lastStored).includes('Acme'), 'no plaintext on the server');

  const pulled = await backend.pull();
  assert.equal(pulled.rev, 1);
  assert.deepEqual(pulled.store, STORE);
});

test('the sync backend tells the server it can read a delta chain', async () => {
  // Without this header the server treats the device as blob-only and never gives
  // the shop a chain — absence has to mean "cannot", because an old build sends
  // nothing. So the whole delta rollout hinges on this one header going out, and
  // nothing else in this repo would notice if it stopped.
  const { shopId, token } = await cc.register(base);
  const { keyset } = cc.createKeyset('sync-pass', { kdf: FAST_KDF });
  const dek = cc.unlockWithPassphrase('sync-pass', keyset);

  seen.length = 0;
  const backend = cc.backendFor(base, shopId, token, dek);
  await backend.push(STORE);
  await backend.pull();

  const storeCalls = seen.filter((r) => r.path === `/v1/shops/${shopId}/store`);
  assert.ok(storeCalls.length >= 2, 'the push and the pull both went to /store');
  for (const c of storeCalls) {
    assert.equal(c.cap, '1', `${c.method} /store must announce delta capability`);
  }
});

test('a warm launch survives the process: the next backend asks for a slice', async () => {
  // The wiring, over real fetch. cloud-warm-launch.test.js pins the behaviour;
  // what is checked here is that backendFor actually hands the cache and the
  // local-store check down to it — a backend built without them is silently
  // cold, and every test that mocks the backend directly would still pass.
  const fs = require('node:fs');
  const os = require('node:os');
  const nodePath = require('node:path');
  const dir = fs.mkdtempSync(nodePath.join(os.tmpdir(), 'khayt-warm-wire-'));

  const { shopId, token } = await cc.register(base);
  const { keyset } = cc.createKeyset('sync-pass', { kdf: FAST_KDF });
  const dek = cc.unlockWithPassphrase('sync-pass', keyset);
  const opts = { cacheDir: dir, getLocalSnapshot: () => STORE };

  await cc.backendFor(base, shopId, token, dek, opts).push(STORE);

  // A new backend over the same directory — what an unlock builds after a restart.
  seen.length = 0;
  const relaunched = cc.backendFor(base, shopId, token, dek, opts);
  assert.equal(relaunched.isWarm(), true, 'the retained view outlived the backend that wrote it');
  await relaunched.pull();

  const get = seen.find((r) => r.method === 'GET' && r.path === `/v1/shops/${shopId}/store`);
  assert.equal(get.since, String(relaunched.serverRev()), 'the first pull of the session asks ?since=');

  // And without a cache directory nothing changes for anyone: still cold.
  seen.length = 0;
  await cc.backendFor(base, shopId, token, dek).pull();
  const cold = seen.find((r) => r.method === 'GET' && r.path === `/v1/shops/${shopId}/store`);
  assert.equal(cold.since, null, 'a backend with no cache asks for everything, as before');
});

test('a transport that is not the sync backend stays silent about capability', async () => {
  // The trap on the other side: the server records this on store reads, so a call
  // that arrives without the header from a device that CAN fold would mark it
  // blob-only. Only transports that genuinely read a store may speak here, and
  // the plain one must not claim anything.
  seen.length = 0;
  await cc.health(base);
  const probe = seen.find((r) => r.path === '/v1/health');
  assert.equal(probe.cap, '', 'a plain transport announces nothing');
});

test('a branch store is folded, not just decrypted — the org roll-up sees the newest edits', async () => {
  // Read-only, so a stale answer destroys nothing; it just reports a branch's
  // figures as they were before its newest orders, with nothing saying so.
  const { keyset } = cc.createKeyset('org-pass', { kdf: FAST_KDF });
  const dek = cc.unlockWithPassphrase('org-pass', keyset);
  const engine = require('../lib/sync.js');

  const base0 = { printLog: [{ id: 'o1', price: 100, rev: 1 }], clients: [], tombstones: [] };
  const later = { deltas: [{ collection: 'printLog', record: { id: 'o2', price: 250, rev: 1 } }], tombstones: [] };

  const folded = cc.decryptBranchStore({
    rev: 2,
    ciphertext: sc.encryptStore(base0, dek),
    deltas: [{ rev: 2, ciphertext: sc.encryptStore(later, dek) }],
  }, dek);

  assert.deepEqual(folded.printLog.map((o) => o.id).sort(), ['o1', 'o2'],
    'the delta that only exists in the chain is present');
  assert.equal(folded.printLog.reduce((n, o) => n + o.price, 0), 350,
    'and the roll-up total reflects it');
  assert.ok(engine, 'the fold used the real engine, not a stand-in');

  // A branch with no chain is the ordinary case and must be untouched.
  const plain = cc.decryptBranchStore({ rev: 1, ciphertext: sc.encryptStore(base0, dek), deltas: [] }, dek);
  assert.deepEqual(plain.printLog.map((o) => o.id), ['o1']);
});

test('wrong passphrase cannot decrypt a pulled blob', async () => {
  const { shopId, token } = await cc.register(base);
  const { keyset } = cc.createKeyset('right', { kdf: FAST_KDF });
  const dek = cc.unlockWithPassphrase('right', keyset);
  await cc.backendFor(base, shopId, token, dek).push(STORE);

  const { keyset: k2 } = cc.createKeyset('wrong', { kdf: FAST_KDF });
  const wrongDek = cc.unlockWithPassphrase('wrong', k2);
  await assert.rejects(() => cc.backendFor(base, shopId, token, wrongDek).pull());
});

test('accounts: signup → device 2 logs in, fetches keyset, and decrypts the same store', async () => {
  const email = `dev${Date.now()}@khaytapp.com`;
  const password = 'account-pass-1234';
  const passphrase = 'sync-secret';

  // Device 1: sign up, create + upload the encrypted keyset, push the store.
  const su = await cc.signup(base, { email, password });
  assert.ok(su.shopId && su.token, 'signup returns shop + token');
  const { keyset } = cc.createKeyset(passphrase, { kdf: FAST_KDF });
  await cc.putKeyset(base, su.shopId, su.token, keyset);
  const dek1 = cc.unlockWithPassphrase(passphrase, keyset);
  await cc.backendFor(base, su.shopId, su.token, dek1).push(STORE);

  // Wrong account password → no login.
  assert.equal(await cc.login(base, { email, password: 'nope' }), null);

  // Device 2: log in → same shop, fresh token, encrypted keyset returned.
  const lr = await cc.login(base, { email, password });
  assert.equal(lr.shopId, su.shopId, 'same shop across devices');
  assert.notEqual(lr.token, su.token, 'fresh device token');
  assert.ok(lr.keyset, 'keyset delivered to device 2');

  // Device 2 unlocks with the passphrase and decrypts device 1's store.
  const dek2 = cc.unlockWithPassphrase(passphrase, lr.keyset);
  const pulled = await cc.backendFor(base, lr.shopId, lr.token, dek2).pull();
  assert.deepEqual(pulled.store, STORE, 'device 2 sees the same decrypted data');
});

/* ── The owner reads their own thread, as themselves ───────────────────────
 * portalMessages() used to GET the customer's public /v1/p/{token}/messages
 * with no credentials at all. That single caller is why the route had to stay
 * open to anyone holding the portal link: closing it would have blanked the
 * owner's Messages button in every desktop in the field. khayt-cloud #10 added
 * the authenticated equivalent, so what these tests pin is not "the thread
 * still loads" — it is WHICH route it loads from and what it presents.
 * ---------------------------------------------------------------------- */

/** Publish an item under a fresh tracking token and put one shop reply on it. */
async function seedThread(text) {
  const { shopId, token } = await cc.register(base);
  const pubToken = 'trk_' + Math.random().toString(36).slice(2);
  await cc.publishPortal(base, shopId, token, pubToken, 'order', { id: 'o1' });
  await cc.portalReply(base, shopId, pubToken, token, text);
  return { shopId, token, pubToken };
}

test('the owner reads the thread on the authenticated route, carrying the shop token', async () => {
  const { shopId, token, pubToken } = await seedThread('On the printer now');

  seen.length = 0;
  const msgs = await cc.portalMessages(base, shopId, pubToken, token);
  assert.deepEqual(msgs.map((m) => m.text), ['On the printer now']);

  const read = seen.filter((r) => r.path.endsWith('/messages'));
  assert.equal(read.length, 1, 'one read, not a new one plus a fallback');
  assert.equal(read[0].path, `/v1/shops/${shopId}/published/${pubToken}/messages`);
  assert.equal(read[0].auth, `Bearer ${token}`,
    'without the Bearer header this is the public read wearing a longer path');
  assert.ok(!seen.some((r) => r.path.startsWith('/v1/p/')),
    'the customer-facing route must not be touched when the owner route answers');
});

test('a bad shop token is reported, not quietly retried on the public route', async () => {
  // A 401 is a caller without credentials, not a server without the route, and
  // the two must not collapse into one another. This guarded the migration
  // fallback; it outlives it, because 401 must stay distinct from the 404 that
  // now reports an out-of-date server.
  const { shopId, pubToken } = await seedThread('On the printer now');

  seen.length = 0;
  await assert.rejects(() => cc.portalMessages(base, shopId, pubToken, 'expired-token'),
    /Invalid token|HTTP 401/);
  assert.ok(!seen.some((r) => r.path.startsWith('/v1/p/')), 'no public read on a 401');
});

test('a server without the owner route is reported, never worked around', async () => {
  // This replaces the migration fallback, and asserts its opposite. The fallback
  // retried /v1/p/{token}/messages on a 404 — which also caught the 404 that
  // means "not this shop's token", and returned the thread anyway. That is the
  // exposure being closed, so the desktop must now have NO path to the public
  // route, even when the authenticated one is missing.
  const seenOld = [];
  const old = http.createServer((req, res) => {
    seenOld.push(req.url);
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
  });
  await new Promise((r) => old.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${old.address().port}`;
  try {
    // Pinned on the REMEDY, not on any part of the sentence. An earlier version
    // of this matched "not on this" as an alternative, and a mutation that
    // gutted the actionable half of the message sailed through it.
    await assert.rejects(() => cc.portalMessages(url, 'SHOP', 'trk1', 'tok'),
      /older than this version of Khayt — update it/,
      'a 404 here must tell the shop what to DO, not just say "HTTP 404"');
    assert.ok(!seenOld.some((u) => u.startsWith('/v1/p/')),
      'the public route was still tried — the fallback is not actually gone');
  } finally {
    await new Promise((r) => old.close(r));
  }
});


test('injected separators are percent-encoded on the wire, not real slashes', async () => {
  const rawSeen = [];
  const echo = http.createServer((req, res) => {
    rawSeen.push(req.url);   // raw, still-encoded request target
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true,"items":[],"messages":[]}');
  });
  await new Promise((r) => echo.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${echo.address().port}`;
  const EVIL = 'a/b/../../c';   // three separators + traversal

  try {
    await cc.deleteIntake(url, 'SHOP', 'tok', EVIL).catch(() => {});
    const p = rawSeen.find((x) => x.includes('/intake/'));
    assert.ok(p, 'intake request reached the server');
    const tail = p.split('/intake/')[1];              // whatever landed in the id segment
    assert.ok(!tail.includes('/'), `id must be one segment, got: ${tail}`);
    assert.ok(tail.includes('%2F') || tail.includes('%2f'), 'slashes were percent-encoded');
  } finally {
    await new Promise((r) => echo.close(r));
  }
});


test('publishing a job from the quote form names its request top level, never in the payload (Cloud #157)', async () => {
  const bodies = [];
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      bodies.push(JSON.parse(raw || '{}'));
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"ok":true}');
    });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${srv.address().port}`;
  try {
    await cc.publishPortal(url, 'SHOP', 'tok', 'trk_1', 'order', { id: 'o1' }, 'a@b.co', 'in_42');
    await cc.publishPortal(url, 'SHOP', 'tok', 'trk_2', 'order', { id: 'o2' }, 'a@b.co');
    assert.equal(bodies[0].intakeId, 'in_42');
    assert.equal(bodies[0].payload.intakeId, undefined, 'never inside the payload');
    assert.equal(bodies[0].customerEmail, 'a@b.co');
    assert.ok(!('intakeId' in bodies[1]), 'absent on a job that did not come in through the form');
  } finally {
    await new Promise((r) => srv.close(r));
  }
});
