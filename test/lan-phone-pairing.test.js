/**
 * Pairing a phone by a code, with a role (C1 + C9), on the Windows/Linux LAN
 * server: lib/main/phone-pairing.js (the window and the commit-then-reveal
 * state machine), lib/lan-devices.js admitPhone / rulesRecord, and the routes
 * and role checks in lib/lan-server.js. The Mac's LanConnectorPairing (phone
 * flavour) and LanServer.phonePairRoute / roleRefusal / deviceSelf are the
 * reference: the same statuses and bodies (docs/LAN_API.md).
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
const { createLanIdentity } = require(path.join(ROOT, 'lib/lan-identity.js'));
const Devices = require(path.join(ROOT, 'lib/lan-devices.js'));
const PP = require(path.join(ROOT, 'lib/main/phone-pairing.js'));
const Roles = require(path.join(ROOT, 'lib/device-roles.js'));

const PORT = 3977;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const noop = () => {};
const seal = (s) => Buffer.from(Buffer.from(s, 'utf8').map((b) => b ^ 0x5a));
const unseal = (b) => Buffer.from(b.map((x) => x ^ 0x5a)).toString('utf8');
const b64 = (s) => Buffer.from(s, 'base64');
const x25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), raw]), format: 'der', type: 'spki' });
const ed25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]), format: 'der', type: 'spki' });
const rawPub = (k) => crypto.createPublicKey(k).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');

let tmp;
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-phone-pair-')); });
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// ── The window, on its own (an injected monotonic clock) ──────────────────

function phoneHalf() {
  const pair = crypto.generateKeyPairSync('x25519');
  const publicKey = rawPub(pair.privateKey);
  const nonce = crypto.randomBytes(16).toString('base64');
  return { pair, publicKey, nonce, commit: PP.commitment(publicKey, nonce).toString('base64') };
}
const fakeIdentity = (() => {
  const k = crypto.generateKeyPairSync('ed25519');
  return { publicKey: rawPub(k.privateKey), sign: (m) => crypto.sign(null, Buffer.from(m), k.privateKey).toString('base64') };
})();
function windowAt() {
  let t = 1000;
  const w = PP.createPhonePairing({ clock: () => t, enabled: () => true });
  return { w, advance: (ms) => { t += ms; } };
}
const ask = (w, phone) => w.request({ commit: phone.commit, name: 'Phone', app: 'Khayt', version: '1', address: '10.0.0.2', identity: fakeIdentity });

test('off by default: open does nothing, and enabled() that throws is off', () => {
  const off = PP.createPhonePairing({ clock: () => 0 });
  assert.equal(off.open(), false);
  assert.equal(off.isOpen(), false);
  const throws = PP.createPhonePairing({ clock: () => 0, enabled: () => { throw new Error('x'); } });
  assert.equal(throws.open(), false);
});

test('the window lasts 120 s on the monotonic clock', () => {
  const { w, advance } = windowAt();
  assert.equal(w.open(), true);
  advance(119_999);
  assert.equal(w.isOpen(), true);
  advance(1);
  assert.equal(w.isOpen(), false);
  assert.equal(w.snapshot().lastClosed, 'timedOut');
  assert.deepEqual(ask(w, phoneHalf()), { refusal: 'closed' });
});

test('at most 3 offers per opened window, whatever became of them; then it shuts', () => {
  const { w } = windowAt();
  w.open();
  const one = ask(w, phoneHalf()).offer;
  assert.deepEqual(ask(w, phoneHalf()), { refusal: 'busy' }, 'one request at a time');
  w.deny();
  assert.equal(w.poll(one.pairId, one.pollSecret), 'denied');
  const two = ask(w, phoneHalf()).offer;
  assert.equal(w.reveal(two.pairId, two.pollSecret, phoneHalf().publicKey, crypto.randomBytes(16).toString('base64')), 'refused');
  const three = ask(w, phoneHalf()).offer;
  assert.equal(w.snapshot().offersLeft, 0);
  assert.deepEqual(w.cancel(three.pairId, three.pollSecret), { state: 'cancelled' });
  assert.equal(w.isOpen(), false);
  assert.equal(w.snapshot().lastClosed, 'offersUsed');
  assert.equal(w.poll(three.pairId, three.pollSecret), 'expired');
});

test('a bad commitment spends no offer; an unrevealed offer expires after 30 s and frees the slot', () => {
  const { w, advance } = windowAt();
  w.open();
  assert.deepEqual(w.request({ commit: 'AAAA', identity: fakeIdentity }), { refusal: 'badCommit' });
  assert.deepEqual(w.request({ commit: Buffer.alloc(31).toString('base64'), identity: fakeIdentity }), { refusal: 'badCommit' });
  assert.equal(w.snapshot().offersLeft, 3);
  const p = phoneHalf();
  const o = ask(w, p).offer;
  advance(30_001);
  assert.equal(w.poll(o.pairId, o.pollSecret), 'expired');
  assert.equal(w.reveal(o.pairId, o.pollSecret, p.publicKey, p.nonce), 'unknown', 'too late: it is gone');
  assert.ok(ask(w, phoneHalf()).offer, 'the slot is free');
});

test('reveal: wrong secret spends nothing; a match gives the number; a second is "already"; approve needs the one shown', () => {
  const { w } = windowAt();
  w.open();
  const p = phoneHalf();
  const o = ask(w, p).offer;
  assert.equal(w.reveal(o.pairId, 'not-the-secret', p.publicKey, p.nonce), 'unknown');
  assert.equal(w.snapshot().pending.revealed, false);
  assert.equal(w.approve({ pairId: o.pairId, check: '000000' }, () => assert.fail('nothing to approve yet')), false);
  assert.equal(w.reveal(o.pairId, o.pollSecret, p.publicKey, p.nonce), 'accepted');
  assert.equal(w.reveal(o.pairId, o.pollSecret, p.publicKey, p.nonce), 'already');
  const check = PP.checkNumber(o.deviceId, o.identity, o.publicKey, p.publicKey, p.nonce);
  assert.equal(w.snapshot().pending.check, check);
  assert.equal(w.approve({ pairId: o.pairId, check: check === '000000' ? '000001' : '000000' }, () => assert.fail('another number')), false);
  assert.throws(() => w.approve({ pairId: o.pairId, check }, () => { throw new Error('keychain'); }));
  assert.equal(w.poll(o.pairId, o.pollSecret), 'waiting', 'an enrolment that failed changes nothing');
  let got = null;
  assert.equal(w.approve({ pairId: o.pairId, check }, (r) => { got = r; }), true);
  assert.equal(got.deviceId, o.deviceId);
  assert.equal(got.phonePublic, p.publicKey);
  assert.equal(w.poll(o.pairId, o.pollSecret), 'approved');
  assert.deepEqual(w.cancel(o.pairId, o.pollSecret), { answered: 'approved' }, 'an approval is never undone');
  assert.equal(w.isOpen(), false);
  assert.equal(w.snapshot().lastClosed, 'paired');
  assert.ok(!JSON.stringify(w.snapshot()).includes(o.pollSecret), 'the screen never sees the secret');
});

test('refused reveals: a short nonce, an all-zero key, a key that is not the one committed', () => {
  const zero = Buffer.alloc(32).toString('base64');
  const cases = [
    (p) => { const n = crypto.randomBytes(15).toString('base64'); return { commit: PP.commitment(p.publicKey, n).toString('base64'), key: p.publicKey, nonce: n }; },
    () => { const n = crypto.randomBytes(16).toString('base64'); return { commit: PP.commitment(zero, n).toString('base64'), key: zero, nonce: n }; },
    (p) => ({ commit: p.commit, key: phoneHalf().publicKey, nonce: p.nonce }),
  ];
  for (const make of cases) {
    const { w } = windowAt();
    w.open();
    const c = make(phoneHalf());
    const o = w.request({ commit: c.commit, identity: fakeIdentity }).offer;
    assert.equal(w.reveal(o.pairId, o.pollSecret, c.key, c.nonce), 'refused');
    assert.equal(w.poll(o.pairId, o.pollSecret), 'expired');
  }
});

// ── Over HTTP ─────────────────────────────────────────────────────────────

let store, handlers, lanIdentity, lanDevices, mono = 0, pairOn = true;
const ipc = (name, arg) => handlers.get(name)(null, arg);
function start(pin) { return ipc('hub:start-lan-server', { port: PORT, pin, bindLan: 'loopback' }); }
before(async () => {
  handlers = new Map();
  store = { printLog: [{ id: 'o1', project: 'P', client: 'C', status: 'pending', date: '2026-10-01' }, { id: 'q1', project: 'Q', client: 'C', status: 'quote', date: '2026-10-01' }],
    inventory: [], machines: [], clients: [], settings: { lanApi: { intakeToken: 'tok' } } };
  lanIdentity = createLanIdentity({ fs, keyPath: path.join(tmp, 'id.key'), seal, unseal });
  lanDevices = Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'devices.key'), seal, unseal });
  registerLanServer({
    fs,
    ipcMain: { handle: (n, f) => handlers.set(n, f) },
    BrowserWindow: class { static getAllWindows() { return []; } },
    safeJsonParse: (s, f) => { try { return JSON.parse(s); } catch { return f; } },
    syncLanServerStoreFromDisk: noop,
    resolveStoreSecret: (v) => v,
    isStoreSecretMasked: () => false,
    migrateLanApiSecrets: noop,
    ensureLanIntakeToken: () => ({ token: 'tok', generated: false }),
    ensureLanIntakePin: () => ({ pin: '1234', generated: false }),
    ensureLanCalendarToken: () => ({ token: 'cal', generated: false }),
    writeStoreToDisk: async () => {},
    persistLanStoreUpdate: async (s) => { store = s; },
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
    lanIdentity,
    lanDevices,
    phonePairing: PP.createPhonePairing({ clock: () => mono, enabled: () => pairOn }),
  });
  assert.ok((await start(PIN)).ok);
});
after(async () => { await handlers.get('hub:stop-lan-server')?.(null, {}); });

const asOwner = () => { store.settings.operatorLockEnabled = false; };
function asOperator(roleKey) {
  store.operators = [{ id: 'op1', name: 'Someone', roleKey }];
  store.settings.operatorLockEnabled = true;
  store.settings.activeOperatorId = roleKey ? 'op1' : null;
}

async function call(method, p, { headers = {}, body } = {}) {
  const res = await fetch(BASE + p, { method, headers: body != null ? { 'content-type': 'application/json', ...headers } : headers, body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)) });
  const text = await res.text();
  let json = null; try { json = JSON.parse(text); } catch (_) { /* not json */ }
  return { status: res.status, json, text, mac: res.headers.get('x-khayt-reply-mac') };
}
const offerOf = (phone, extra = {}) => call('POST', '/api/devices/pair', { body: { v: 2, commit: phone.commit, name: 'Test phone', app: 'Khayt', version: '1.0', ...extra } });

/** The phone's whole side, and the person's Approve. */
async function pairPhone(role, { approveAs = asOwner } = {}) {
  asOwner();
  const opened = await ipc('hub:phone-pair-open');
  assert.equal(opened.ok, true, JSON.stringify(opened));
  const phone = phoneHalf();
  const o = await offerOf(phone);
  assert.equal(o.status, 200, o.text);
  const offer = o.json;
  assert.deepEqual(Object.keys(offer).sort(), ['deviceId', 'identity', 'pairId', 'pollSecret', 'publicKey', 'sig']);
  // The phone checks the identity signed this offer for ITS commit.
  assert.equal(crypto.verify(null, Buffer.from(PP.offerMessage(offer.deviceId, offer.publicKey, phone.commit)), ed25519Public(b64(offer.identity)), b64(offer.sig)), true);
  assert.equal(offer.identity, lanIdentity.identity().publicKey);
  const r = await call('POST', `/api/devices/pair/${offer.pairId}/reveal`, { headers: { 'x-khayt-poll': offer.pollSecret }, body: { publicKey: phone.publicKey, nonce: phone.nonce } });
  assert.deepEqual([r.status, r.json], [200, { state: 'waiting' }]);
  const phoneCheck = PP.checkNumber(offer.deviceId, offer.identity, offer.publicKey, phone.publicKey, phone.nonce);
  const shown = await ipc('hub:phone-pair-state');
  assert.equal(shown.pending.check, phoneCheck, 'both screens show the same number');
  approveAs();
  const approved = await ipc('hub:phone-pair-approve', { role, pairId: offer.pairId, check: shown.pending.check });
  asOwner();
  const shared = crypto.diffieHellman({ privateKey: phone.pair.privateKey, publicKey: x25519Public(b64(offer.publicKey)) });
  return { approved, offer, out: { deviceId: offer.deviceId }, key: Devices.deriveDeviceKey(shared, offer.deviceId) };
}
function sign(dev, method, target, body, { time = Math.floor(Date.now() / 1000), nonce = crypto.randomBytes(16).toString('hex') } = {}) {
  const mac = Devices.requestMac(dev.key, Devices.canonicalRequest(method, target, String(time), nonce, body ? Buffer.from(body) : undefined));
  return { 'x-khayt-device': dev.out.deviceId, 'x-khayt-time': String(time), 'x-khayt-nonce': nonce, 'x-khayt-mac': mac };
}
async function signed(dev, method, target, body) {
  const text = body == null ? undefined : JSON.stringify(body);
  const headers = sign(dev, method, target, text);
  const r = await call(method, target, { headers, body: text });
  r.nonce = headers['x-khayt-nonce'];
  return r;
}
const macOk = (dev, r) => r.mac === Devices.replyMac(dev.key, r.nonce, r.status, Buffer.from(r.text));
async function enrolWithPin() {
  const pair = crypto.generateKeyPairSync('x25519');
  const r = await call('POST', '/api/devices', { headers: { 'x-khayt-pin': PIN }, body: { publicKey: rawPub(pair.privateKey), name: 'PIN phone' } });
  assert.equal(r.status, 200, r.text);
  const shared = crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: x25519Public(b64(r.json.publicKey)) });
  return { out: r.json, key: Devices.deriveDeviceKey(shared, r.json.deviceId) };
}

test('a phone pairs by code: the numbers agree, the person approves with a role, and it signs from then on', async () => {
  const dev = await pairPhone('operator');
  assert.equal(dev.approved.ok, true, JSON.stringify(dev.approved));
  const poll = await call('GET', `/api/devices/pair/${dev.offer.pairId}`, { headers: { 'x-khayt-poll': dev.offer.pollSecret } });
  assert.deepEqual([poll.status, poll.json], [200, { state: 'approved' }]);
  const listed = lanDevices.list().find((d) => d.deviceId === dev.out.deviceId);
  assert.deepEqual([listed.role, listed.codePaired, listed.name], ['operator', true, 'Test phone']);
  const orders = await signed(dev, 'GET', '/api/orders');
  assert.equal(orders.status, 200);
  const self = await signed(dev, 'GET', '/api/devices/self');
  assert.equal(self.status, 200);
  assert.deepEqual(self.json, { deviceId: dev.out.deviceId, role: 'operator', scopes: [...Roles.scopesFor('operator')] });
  assert.ok(macOk(dev, self), '/api/devices/self is signed back');
});

test('the pair routes: 404 off, 403 closed, 400 bad body, 409 busy, 421 not local', async () => {
  pairOn = false;
  try {
    const off = await offerOf(phoneHalf());
    assert.deepEqual([off.status, off.json], [404, { error: 'not_found' }]);
    assert.deepEqual(await ipc('hub:phone-pair-open'), { ok: false, error: 'off' });
  } finally { pairOn = true; }
  await ipc('hub:phone-pair-close');
  const closed = await offerOf(phoneHalf());
  assert.equal(closed.status, 403);
  assert.equal(closed.json.reason, 'pairing-closed');
  asOwner();
  await ipc('hub:phone-pair-open');
  for (const body of [{ commit: phoneHalf().commit }, { v: 1, commit: phoneHalf().commit }, { v: 2 }, 'not json']) {
    const r = await call('POST', '/api/devices/pair', { body });
    assert.deepEqual([r.status, r.json], [400, { error: 'commit' }], JSON.stringify(body));
  }
  const short = await offerOf({ commit: Buffer.alloc(16).toString('base64') });
  assert.deepEqual([short.status, short.json], [400, { error: 'commit' }]);
  assert.equal((await ipc('hub:phone-pair-state')).offersLeft, 3, 'none of those spent an offer');
  assert.equal((await offerOf(phoneHalf())).status, 200);
  const busy = await offerOf(phoneHalf());
  assert.equal(busy.status, 409);
  assert.equal(busy.json.reason, 'pairing-busy');
  // A Host that is not this computer (DNS rebinding) is 421.
  const status = await new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path: '/api/devices/pair', method: 'POST', headers: { host: 'evil.example', 'content-type': 'application/json' } }, (res) => { res.resume(); resolve(res.statusCode); });
    r.on('error', reject);
    r.end(JSON.stringify({ v: 2, commit: phoneHalf().commit }));
  });
  assert.equal(status, 421);
  await ipc('hub:phone-pair-close');
});

test('reveal, poll and cancel: every status the phone acts on', async () => {
  asOwner();
  await ipc('hub:phone-pair-open');
  const p = phoneHalf();
  const { json: o } = await offerOf(p);
  const poll = (secret = o.pollSecret) => call('GET', `/api/devices/pair/${o.pairId}`, { headers: { 'x-khayt-poll': secret } });
  assert.deepEqual((await poll()).json, { state: 'waiting' });
  const wrong = await poll('nope');
  assert.deepEqual([wrong.status, wrong.json], [404, { state: 'unknown' }]);
  const unknownId = await call('GET', '/api/devices/pair/zzzzzzzzzzzz', { headers: { 'x-khayt-poll': o.pollSecret } });
  assert.deepEqual([unknownId.status, unknownId.json], [404, { state: 'unknown' }]);
  const badId = await call('GET', '/api/devices/pair/NOT-AN-ID', { headers: { 'x-khayt-poll': o.pollSecret } });
  assert.deepEqual([badId.status, badId.json], [404, { state: 'unknown' }]);
  const reveal = (secret, body) => call('POST', `/api/devices/pair/${o.pairId}/reveal`, { headers: { 'x-khayt-poll': secret }, body });
  const w404 = await reveal('nope', { publicKey: p.publicKey, nonce: p.nonce });
  assert.deepEqual([w404.status, w404.json], [404, { state: 'unknown' }], 'the wrong secret spends nothing');
  const ok = await reveal(o.pollSecret, { publicKey: p.publicKey, nonce: p.nonce });
  assert.deepEqual([ok.status, ok.json], [200, { state: 'waiting' }]);
  const again = await reveal(o.pollSecret, { publicKey: p.publicKey, nonce: p.nonce });
  assert.deepEqual([again.status, again.json], [409, { reason: 'already-revealed' }]);
  const del = (secret = o.pollSecret) => call('DELETE', `/api/devices/pair/${o.pairId}`, { headers: { 'x-khayt-poll': secret } });
  assert.deepEqual([(await del('nope')).status, (await del('nope')).json], [404, { state: 'unknown' }]);
  const c = await del();
  assert.deepEqual([c.status, c.json], [200, { state: 'cancelled' }]);
  assert.deepEqual((await poll()).json, { state: 'expired' });
  const c2 = await del();
  assert.deepEqual([c2.status, c2.json], [409, { state: 'expired' }]);
  assert.equal((await ipc('hub:phone-pair-state')).pending, null, 'the person\'s screen goes back to waiting');
  // A bad reveal expires its offer.
  const q = phoneHalf();
  const { json: o2 } = await offerOf(q);
  const bad = await call('POST', `/api/devices/pair/${o2.pairId}/reveal`, { headers: { 'x-khayt-poll': o2.pollSecret }, body: { publicKey: phoneHalf().publicKey, nonce: q.nonce } });
  assert.deepEqual([bad.status, bad.json], [403, { state: 'expired', reason: 'bad-reveal' }]);
  // That was the second offer of three, and the window is still open for the third.
  assert.equal((await ipc('hub:phone-pair-state')).offersLeft, 1);
  await ipc('hub:phone-pair-close');
});

test('the window shuts after 120 s on the monotonic clock, and with the server', async () => {
  asOwner();
  await ipc('hub:phone-pair-open');
  mono += 120_000;
  assert.equal((await offerOf(phoneHalf())).status, 403);
  assert.equal((await ipc('hub:phone-pair-state')).lastClosed, 'timedOut');
  await ipc('hub:phone-pair-open');
  await handlers.get('hub:stop-lan-server')(null, {});
  assert.equal((await ipc('hub:phone-pair-state')).lastClosed, 'serverStopped');
  assert.deepEqual(await ipc('hub:phone-pair-open'), { ok: false, error: 'server_stopped' });
  assert.ok((await start(PIN)).ok);
  await fetch(`${BASE}/api/status?format=json`).catch(() => {});
});

test('who may approve: the owner any role, a manager up to manager, nobody else', async () => {
  // A manager may open and approve up to manager, never owner.
  asOperator('manager');
  assert.deepEqual((await ipc('hub:phone-pair-state')).grantable, ['manager', 'operator', 'viewer']);
  assert.equal((await ipc('hub:phone-pair-state')).defaultRole, 'operator');
  const refused = await pairPhone('owner', { approveAs: () => asOperator('manager') });
  assert.deepEqual(refused.approved, { ok: false, error: 'role_not_grantable' });
  assert.equal(lanDevices.rulesRecord(refused.out.deviceId), null, 'nothing enrolled');
  await ipc('hub:phone-pair-close');
  const mgr = await pairPhone('manager', { approveAs: () => asOperator('manager') });
  assert.equal(mgr.approved.ok, true);
  assert.equal((await signed(mgr, 'GET', '/api/devices/self')).json.role, 'manager');
  // Operators, viewers and nobody signed in under the lock may not open it.
  for (const who of ['operator', 'viewer', null]) {
    asOperator(who);
    assert.deepEqual(await ipc('hub:phone-pair-open'), { ok: false, error: 'not_permitted' }, String(who));
    assert.deepEqual(await ipc('hub:phone-pair-approve', { role: 'viewer', pairId: 'x', check: '1' }), { ok: false, error: 'not_permitted' });
  }
  asOwner();
  // The owner may give owner; a number that is not the one shown enrols nothing.
  await ipc('hub:phone-pair-open');
  const p = phoneHalf();
  const { json: o } = await offerOf(p);
  await call('POST', `/api/devices/pair/${o.pairId}/reveal`, { headers: { 'x-khayt-poll': o.pollSecret }, body: { publicKey: p.publicKey, nonce: p.nonce } });
  const check = (await ipc('hub:phone-pair-state')).pending.check;
  assert.deepEqual(await ipc('hub:phone-pair-approve', { role: 'owner', pairId: o.pairId, check: check === '123456' ? '654321' : '123456' }), { ok: false, error: 'nothing_to_approve' });
  assert.equal((await ipc('hub:phone-pair-approve', { role: 'owner', pairId: o.pairId, check })).ok, true);
  assert.equal(lanDevices.rulesRecord(o.deviceId).role, 'owner');
});

test('deny answers that request and keeps the window open', async () => {
  asOwner();
  await ipc('hub:phone-pair-open');
  const p = phoneHalf();
  const { json: o } = await offerOf(p);
  await ipc('hub:phone-pair-deny');
  assert.deepEqual((await call('GET', `/api/devices/pair/${o.pairId}`, { headers: { 'x-khayt-poll': o.pollSecret } })).json, { state: 'denied' });
  assert.equal((await ipc('hub:phone-pair-state')).open, true);
  await ipc('hub:phone-pair-close');
});

test('roles on every signed request: refused 403 role-scope, signed, before the route runs', async () => {
  const viewer = await pairPhone('viewer');
  const operator = await pairPhone('operator');
  const manager = await pairPhone('manager');
  assert.equal((await signed(viewer, 'GET', '/api/orders')).status, 200);
  const waste = await signed(viewer, 'POST', '/api/waste', { grams: 3 });
  assert.deepEqual([waste.status, waste.json], [403, { reason: 'role-scope', required: 'waste:write' }]);
  assert.ok(macOk(viewer, waste), 'the refusal verifies under the phone\'s key, over its nonce');
  // Pricing through a job update is quote:write, whatever the route's scope.
  const before = JSON.stringify(store.printLog);
  const price = await signed(operator, 'PATCH', '/api/orders/o1', { price: 5 });
  assert.deepEqual([price.status, price.json], [403, { reason: 'role-scope', required: 'quote:write' }]);
  const accept = await signed(operator, 'PATCH', '/api/orders/q1', { status: 'pending' });
  assert.deepEqual([accept.status, accept.json], [403, { reason: 'role-scope', required: 'quote:write' }], 'moving a quote on is pricing');
  assert.equal(JSON.stringify(store.printLog), before, 'the route never ran');
  assert.notEqual((await signed(operator, 'PATCH', '/api/orders/o1', { notes: 'x' })).json?.reason, 'role-scope');
  // The book, and enrolling another device, are beyond a manager.
  const book = await signed(manager, 'POST', '/api/store/deltas', { ops: [] });
  assert.deepEqual([book.status, book.json], [403, { reason: 'role-scope', required: 'book:write' }]);
  const enrol = await signed(manager, 'POST', '/api/devices', { publicKey: phoneHalf().publicKey, name: 'x' });
  assert.deepEqual([enrol.status, enrol.json], [403, { reason: 'role-scope', required: 'owner' }], 'a route the table does not name is the owner\'s');
  assert.ok(macOk(manager, enrol));
  // The queue page, outside /api, is the owner's too.
  assert.equal((await signed(viewer, 'GET', '/')).status, 403);
});

test('fails closed: an encoded slash, a dot segment or a control character in the path is the owner\'s', async () => {
  const manager = await pairPhone('manager');
  // Sent as written (http.request), since fetch would fold a dot segment away before signing.
  const raw = (target, text) => new Promise((resolve, reject) => {
    const headers = { 'content-type': 'application/json', ...sign(manager, 'POST', target, text) };
    const r = http.request({ host: '127.0.0.1', port: PORT, path: target, method: 'POST', headers, agent: false }, (res) => {
      let body = ''; res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, json: JSON.parse(body) }));
    });
    r.on('error', reject);
    r.end(text);
  });
  for (const target of ['/api/orders/o1%2Fapprove', '/api/orders/o1%00', '/api/orders/a%5Cb', '/api/orders/o1%2F..%2Fapprove']) {
    const r = await raw(target, JSON.stringify({ status: 'pending' }));
    assert.deepEqual([r.status, r.json], [403, { reason: 'role-scope', required: 'owner' }], target);
  }
  // A literal dot segment is folded by the URL parser BEFORE routing, and the
  // rule is asked about the route it folds to, never another: here a create
  // with a price, which is quote:write and beyond an operator.
  const operator = await pairPhone('operator');
  const text = JSON.stringify({ project: 'x', price: 9 });
  const folded = await new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path: '/api/orders/o1/%2e%2e', method: 'POST', agent: false,
      headers: { 'content-type': 'application/json', ...sign(operator, 'POST', '/api/orders/o1/%2e%2e', text) } }, (res) => {
      let body = ''; res.on('data', (c) => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, json: JSON.parse(body) }));
    });
    r.on('error', reject);
    r.end(text);
  });
  assert.deepEqual([folded.status, folded.json], [403, { reason: 'role-scope', required: 'quote:write' }]);
});

test('a code-paired device whose role is garbled or lost reads as the least, never the owner', async () => {
  for (const role of ['superuser', 'Owner', 'owner ']) {
    const serverKey = crypto.generateKeyPairSync('x25519');
    const phone = crypto.generateKeyPairSync('x25519');
    const deviceId = PP.freshDeviceId();
    assert.deepEqual(lanDevices.admitPhone({ serverPrivate: serverKey.privateKey, phonePublic: rawPub(phone.privateKey), deviceId, name: 'G', role, pin: PIN }), { deviceId });
    const dev = { out: { deviceId }, key: Devices.deriveDeviceKey(crypto.diffieHellman({ privateKey: phone.privateKey, publicKey: serverKey.publicKey }), deviceId) };
    const self = await signed(dev, 'GET', '/api/devices/self');
    assert.deepEqual([self.status, self.json.role, self.json.scopes], [200, 'viewer', [...Roles.scopesFor('viewer')]], role);
    assert.equal((await signed(dev, 'GET', '/api/store')).status, 403);
  }
  // A record that says code-paired but lost its role and its version still carries the version to the rule.
  const keyPath = path.join(tmp, 'garbled.key');
  fs.writeFileSync(keyPath, JSON.stringify({ v: 1, pinSalt: crypto.randomBytes(32).toString('base64'), pinTag: '',
    devices: [{ deviceId: 'dev_GarbledPhone0001', name: 'x', key: crypto.randomBytes(32).toString('base64'), createdAt: 'a', lastSeenAt: 'a', codePaired: true }] }));
  const devs = Devices.createLanDevices({ fs, keyPath });
  assert.equal(Roles.roleOf(devs.rulesRecord('dev_GarbledPhone0001')), 'viewer');
});

test('/api/devices/self: the PIN without a device signature is 403 device-auth; a PIN-paired phone is the owner', async () => {
  const r = await call('GET', '/api/devices/self', { headers: { 'x-khayt-pin': PIN } });
  assert.deepEqual([r.status, r.json], [403, { reason: 'device-auth' }]);
  const pinPhone = await enrolWithPin();
  const self = await signed(pinPhone, 'GET', '/api/devices/self');
  assert.deepEqual([self.status, self.json.role], [200, 'owner']);
  assert.ok(macOk(pinPhone, self));
  assert.equal((await signed(pinPhone, 'GET', '/api/clients')).status, 200, 'the owner PIN phone is unchanged');
});

test('a PIN change signs out PIN-paired phones only; with the PIN cleared or short, everyone is refused', async () => {
  const code = await pairPhone('operator');
  const pinPhone = await enrolWithPin();
  assert.equal((await signed(pinPhone, 'GET', '/api/orders')).status, 200);
  await handlers.get('hub:stop-lan-server')(null, {});
  try {
    assert.ok((await start('98765432abc')).ok);
    await fetch(`${BASE}/api/status?format=json`).catch(() => {});
    assert.equal((await signed(code, 'GET', '/api/orders')).status, 200, 'paired by code: no PIN to change');
    const gone = await signed(pinPhone, 'GET', '/api/orders');
    assert.deepEqual([gone.status, gone.json], [401, { reason: 'device-unknown' }]);
    await handlers.get('hub:stop-lan-server')(null, {});
    assert.ok((await start('')).ok);
    await fetch(`${BASE}/api/status?format=json`).catch(() => {});
    const cleared = await signed(code, 'GET', '/api/orders');
    assert.equal(cleared.status, 401, 'no PIN: refused');
    assert.equal((await signed(code, 'GET', '/api/queue')).status, 401);
    assert.deepEqual(await ipc('hub:phone-pair-open'), { ok: false, error: 'pin' });
    await handlers.get('hub:stop-lan-server')(null, {});
    assert.ok((await start('1234')).ok);
    await fetch(`${BASE}/api/status?format=json`).catch(() => {});
    const short = await signed(code, 'GET', '/api/orders');
    assert.deepEqual([short.status, short.json.reason], [401, 'pin-too-short']);
    await handlers.get('hub:stop-lan-server')(null, {});
    assert.ok((await start(PIN)).ok);
    await fetch(`${BASE}/api/status?format=json`).catch(() => {});
    assert.equal((await signed(code, 'GET', '/api/orders')).status, 200, 'and it is still paired once a PIN is set');
  } finally {
    await handlers.get('hub:stop-lan-server')(null, {});
    assert.ok((await start(PIN)).ok);
  }
});

test('Remove signs a code-paired phone out: device-revoked, signed', async () => {
  await fetch(`${BASE}/api/status?format=json`).catch(() => {});
  const code = await pairPhone('viewer');
  assert.deepEqual(await ipc('hub:lan-device-remove', code.out.deviceId), { ok: true });
  const r = await signed(code, 'GET', '/api/orders');
  assert.deepEqual([r.status, r.json], [401, { reason: 'device-revoked' }]);
  assert.ok(macOk(code, r));
});
