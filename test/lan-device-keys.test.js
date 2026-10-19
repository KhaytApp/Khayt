/**
 * Per-device keys (lib/lan-devices.js): a paired phone sends the PIN once, to
 * POST /api/devices, and signs every request after that. The values come from
 * docs/lan-device-keys.vectors.json, which the phone and the Mac reproduce too,
 * so a byte that differs between the three shows up here first.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
const { createLanIdentity } = require(path.join(ROOT, 'lib/lan-identity.js'));
const Devices = require(path.join(ROOT, 'lib/lan-devices.js'));
const V = JSON.parse(fs.readFileSync(path.join(ROOT, 'docs/lan-device-keys.vectors.json'), 'utf8'));

const PORT = 3976;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const noop = () => {};
const seal = (s) => Buffer.from(Buffer.from(s, 'utf8').map((b) => b ^ 0x5a));
const unseal = (b) => Buffer.from(b.map((x) => x ^ 0x5a)).toString('utf8');
const b = (s) => Buffer.from(s, 'base64');

const x25519Private = (raw) => crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), raw]), format: 'der', type: 'pkcs8' });
const x25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), raw]), format: 'der', type: 'spki' });
const ed25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]), format: 'der', type: 'spki' });
// The identity key the vectors were signed with, written where createLanIdentity reads it.
function vectorIdentity(dir) {
  const key = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), b(V.enrol.identitySeed)]), format: 'der', type: 'pkcs8' });
  const keyPath = path.join(dir, `vec-${crypto.randomBytes(4).toString('hex')}.key`);
  fs.writeFileSync(keyPath, key.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  return createLanIdentity({ fs, keyPath });
}
const fixedPair = () => {
  const privateKey = x25519Private(b(V.macPrivate));
  return { privateKey, publicKey: crypto.createPublicKey(privateKey) };
};
const VEC_MS = 1792396800 * 1000;
const patchHeaders = {
  'x-khayt-device': V.deviceId, 'x-khayt-time': '1792396800',
  'x-khayt-nonce': '00112233445566778899aabbccddeeff', 'x-khayt-mac': V.patch.mac,
};

let tmp, handlers;
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-lan-dev-')); });
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// ── The shared vectors ────────────────────────────────────────────────────

test('the derived key, canonical strings and MACs match the vectors', () => {
  const shared = crypto.diffieHellman({ privateKey: x25519Private(b(V.macPrivate)), publicKey: x25519Public(b(V.phonePublic)) });
  assert.equal(shared.toString('base64'), V.shared);
  const key = Devices.deriveDeviceKey(shared, V.deviceId);
  assert.equal(key.toString('base64'), V.key);
  const patch = Devices.canonicalRequest('patch', '/api/orders/o_123?x=1%202', '1792396800', '00112233445566778899aabbccddeeff', Buffer.from(V.patch.body));
  assert.equal(patch, V.patch.canonical);
  assert.equal(Devices.requestMac(key, patch), V.patch.mac);
  const get = Devices.canonicalRequest('GET', '/api/store', '1792396800', 'ffeeddccbbaa99887766554433221100');
  assert.equal(get, V.get.canonical);
  assert.equal(Devices.requestMac(key, get), V.get.mac);
});

test('the enrolment message and its signature match the vectors', () => {
  const id = vectorIdentity(tmp);
  assert.equal(id.identity().publicKey, V.enrol.identityPublic);
  const msg = Devices.enrolMessage(V.deviceId, V.macPublic, V.phonePublic);
  assert.equal(msg, V.enrol.message);
  assert.equal(id.signEnrolment(msg), V.enrol.sig);
  assert.throws(() => id.signEnrolment('khayt-proof:00'), 'it signs enrolments and nothing else');
});

test('enrolling with the vector keys gives the vector answer, and the vector request passes', () => {
  const id = vectorIdentity(tmp);
  const devs = Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'vec-devices.key'), seal, unseal,
    now: () => VEC_MS, newKeyPair: fixedPair, newDeviceId: () => V.deviceId });
  const out = devs.enrol({ publicKey: V.phonePublic, name: 'Phone', pin: PIN, sign: (m) => id.signEnrolment(m) });
  assert.deepEqual(out, { deviceId: V.deviceId, publicKey: V.macPublic, sig: V.enrol.sig });
  const req = { headers: patchHeaders, method: 'PATCH', target: '/api/orders/o_123?x=1%202', body: Buffer.from(V.patch.body), pin: PIN };
  assert.deepEqual(devs.verify(req), { ok: true, deviceId: V.deviceId });
  assert.deepEqual(devs.verify(req), { ok: false, reason: 'device-replay' }, 'the same nonce twice');
});

// ── The rules ─────────────────────────────────────────────────────────────

function enrolled(opts = {}) {
  let t = VEC_MS;
  const clock = { set: (ms) => { t = ms; } };
  const devs = Devices.createLanDevices({ fs, keyPath: path.join(tmp, `d-${crypto.randomBytes(4).toString('hex')}.key`), seal, unseal,
    now: () => t, newKeyPair: fixedPair, newDeviceId: () => V.deviceId, ...opts });
  devs.enrol({ publicKey: V.phonePublic, name: 'Phone', pin: PIN, sign: () => 'sig' });
  return { devs, clock };
}
const patchReq = ({ headers = {}, ...over } = {}) => ({ method: 'PATCH', target: '/api/orders/o_123?x=1%202',
  body: Buffer.from(V.patch.body), pin: PIN, ...over, headers: { ...patchHeaders, ...headers } });

test('a changed body, path or method is refused as device-auth', () => {
  const { devs } = enrolled();
  assert.equal(devs.verify(patchReq({ body: Buffer.from('{"status":"done"}') })).reason, 'device-auth');
  assert.equal(devs.verify(patchReq({ target: '/api/orders/o_124?x=1%202' })).reason, 'device-auth');
  assert.equal(devs.verify(patchReq({ method: 'POST' })).reason, 'device-auth');
  assert.equal(devs.verify(patchReq({ headers: { 'x-khayt-mac': 'AAAA' } })).reason, 'device-auth', 'malformed');
  assert.equal(devs.verify(patchReq({ headers: { 'x-khayt-nonce': 'ABCDEF' } })).reason, 'device-auth', 'malformed');
  assert.equal(devs.verify(patchReq()).ok, true, 'and a failed attempt did not burn the nonce');
});

test('a clock more than 120 s out is told the computer\'s time', () => {
  const { devs, clock } = enrolled();
  clock.set(VEC_MS + 121_000);
  assert.deepEqual(devs.verify(patchReq()), { ok: false, reason: 'device-clock', now: 1792396921 });
  clock.set(VEC_MS + 120_000);
  assert.equal(devs.verify(patchReq()).ok, true);
});

test('a nonce is refused for as long as its request could still pass the clock', () => {
  const { devs, clock } = enrolled();
  assert.equal(devs.verify(patchReq()).ok, true);
  clock.set(VEC_MS + 100_000);
  assert.equal(devs.verify(patchReq()).reason, 'device-replay');
});

test('an unknown device, and every device after a PIN change, is device-unknown', () => {
  const { devs } = enrolled();
  assert.equal(devs.verify(patchReq({ headers: { 'x-khayt-device': 'dev_somebodyElse01' } })).reason, 'device-unknown');
  assert.equal(devs.verify(patchReq({ pin: '87654321' })).reason, 'device-unknown');
  assert.equal(devs.verify(patchReq()).reason, 'device-unknown', 'changing it back does not bring them back');
  assert.equal(devs.list().length, 0);
});

test('at most 32 devices: the 33rd replaces the one seen longest ago', () => {
  let n = 0, t = VEC_MS;
  const devs = Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'many.key'), seal, unseal, now: () => (t += 1000) });
  const phone = () => crypto.createPublicKey(crypto.generateKeyPairSync('x25519').privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
  const ids = [];
  for (; n < 33; n++) ids.push(devs.enrol({ publicKey: phone(), name: `P${n}`, pin: PIN, sign: () => 's' }).deviceId);
  const left = devs.list().map(d => d.deviceId);
  assert.equal(left.length, 32);
  assert.ok(!left.includes(ids[0]), 'the oldest went');
  assert.ok(left.includes(ids[32]));
});

test('a bad public key is refused, and the name is cut to 60 characters', () => {
  const devs = Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'bad.key'), seal, unseal });
  for (const k of [undefined, '', 'abc', Buffer.alloc(31).toString('base64'), Buffer.alloc(32).toString('base64')]) {
    assert.deepEqual(devs.enrol({ publicKey: k, name: 'x', pin: PIN, sign: () => 's' }), { error: 'publicKey' }, String(k));
  }
  const ok = devs.enrol({ publicKey: V.phonePublic, name: '  ' + 'n'.repeat(80) + '  ', pin: PIN, sign: () => 's' });
  assert.match(ok.deviceId, /^dev_[A-Za-z0-9_-]{12,40}$/);
  assert.equal(devs.list()[0].name.length, 60);
});

test('the keys are kept sealed and owner-only, and survive a restart', () => {
  const keyPath = path.join(tmp, 'kept.key');
  const mk = () => Devices.createLanDevices({ fs, keyPath, seal, unseal, now: () => VEC_MS, newKeyPair: fixedPair, newDeviceId: () => V.deviceId });
  mk().enrol({ publicKey: V.phonePublic, name: 'Phone', pin: PIN, sign: () => 's' });
  const onDisk = fs.readFileSync(keyPath, 'utf8');
  assert.match(onDisk, /^khayt-sealed:/);
  assert.ok(!onDisk.includes(V.key) && !onDisk.includes(V.deviceId));
  assert.equal((fs.statSync(keyPath).mode & 0o777).toString(8), '600');
  assert.equal(mk().verify(patchReq()).ok, true);
});

// ── Over HTTP ─────────────────────────────────────────────────────────────

let store;
function start(pin) {
  return handlers.get('hub:start-lan-server')(null, { port: PORT, pin, bindLan: 'loopback' });
}
let lanIdentity, lanDevices;
before(async () => {
  handlers = new Map();
  store = { printLog: [{ id: 'o1', project: 'P', client: 'C', status: 'pending', date: '2026-10-01' }], inventory: [], machines: [], clients: [], settings: { lanApi: { intakeToken: 'tok' } } };
  lanIdentity = createLanIdentity({ fs, keyPath: path.join(tmp, 'http-id.key'), seal, unseal });
  lanDevices = Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'http-devices.key'), seal, unseal });
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
  });
  const r = await start(PIN);
  assert.ok(r && r.ok, JSON.stringify(r));
});
after(async () => { await handlers.get('hub:stop-lan-server')?.(null, {}); });

// The phone's half, as docs/LAN_API.md describes it.
async function enrolPhone(headers = { 'x-khayt-pin': PIN }) {
  const pair = crypto.generateKeyPairSync('x25519');
  const phonePub = crypto.createPublicKey(pair.privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
  const res = await fetch(`${BASE}/api/devices`, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify({ publicKey: phonePub, name: 'Test iPhone' }) });
  if (res.status !== 200) return { status: res.status, body: await res.json().catch(() => null) };
  const out = await res.json();
  const shared = crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: x25519Public(b(out.publicKey)) });
  return { status: 200, out, phonePub, key: Devices.deriveDeviceKey(shared, out.deviceId) };
}
function sign(dev, method, target, body, { time = Math.floor(Date.now() / 1000), nonce = crypto.randomBytes(16).toString('hex') } = {}) {
  const mac = Devices.requestMac(dev.key, Devices.canonicalRequest(method, target, String(time), nonce, body ? Buffer.from(body) : undefined));
  return { 'x-khayt-device': dev.out.deviceId, 'x-khayt-time': String(time), 'x-khayt-nonce': nonce, 'x-khayt-mac': mac };
}

test('enrolment needs the PIN, and is signed by the identity key the phone pinned', async () => {
  assert.equal((await enrolPhone({})).status, 401);
  const dev = await enrolPhone();
  assert.equal(dev.status, 200);
  assert.match(dev.out.deviceId, /^dev_/);
  const { publicKey } = await (await fetch(`${BASE}/api/identity`, { headers: { 'x-khayt-pin': PIN } })).json();
  const msg = Devices.enrolMessage(dev.out.deviceId, dev.out.publicKey, dev.phonePub);
  assert.equal(crypto.verify(null, Buffer.from(msg, 'ascii'), ed25519Public(b(publicKey)), b(dev.out.sig)), true);
});

test('a signed request is let in without the PIN, wherever the PIN would be', async () => {
  const dev = await enrolPhone();
  assert.equal((await fetch(`${BASE}/api/orders`)).status, 401);
  const res = await fetch(`${BASE}/api/orders`, { headers: sign(dev, 'GET', '/api/orders') });
  assert.equal(res.status, 200);
  assert.equal((await res.json())[0].id, 'o1');
  const q = await fetch(`${BASE}/api/queue?x=1%202`, { headers: sign(dev, 'GET', '/api/queue?x=1%202') });
  assert.equal(q.status, 200, 'the request-target is signed as sent, query and all');
});

test('a signed write reaches its route with its body intact', async () => {
  const dev = await enrolPhone();
  const pair = crypto.generateKeyPairSync('x25519');
  const body = JSON.stringify({ publicKey: crypto.createPublicKey(pair.privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64'), name: 'Second' });
  const res = await fetch(`${BASE}/api/devices`, { method: 'POST', headers: { 'content-type': 'application/json', ...sign(dev, 'POST', '/api/devices', body) }, body });
  assert.equal(res.status, 200);
  assert.match((await res.json()).deviceId, /^dev_/);
  const tampered = await fetch(`${BASE}/api/devices`, { method: 'POST', headers: { 'content-type': 'application/json', ...sign(dev, 'POST', '/api/devices', body) }, body: body.replace('Second', 'Evil') });
  assert.equal(tampered.status, 401);
  assert.deepEqual(await tampered.json(), { reason: 'device-auth' });
});

test('the device headers alone decide, even beside a PIN', async () => {
  const dev = await enrolPhone();
  const good = await fetch(`${BASE}/api/orders`, { headers: { ...sign(dev, 'GET', '/api/orders'), 'x-khayt-pin': 'wrong-pin-here' } });
  assert.equal(good.status, 200);
  const bad = await fetch(`${BASE}/api/orders`, { headers: { ...sign(dev, 'GET', '/api/other'), 'x-khayt-pin': PIN } });
  assert.equal(bad.status, 401);
  assert.deepEqual(await bad.json(), { reason: 'device-auth' });
});

test('the 401 reasons the phone acts on', async () => {
  const dev = await enrolPhone();
  const h = sign(dev, 'GET', '/api/orders');
  assert.equal((await fetch(`${BASE}/api/orders`, { headers: h })).status, 200);
  const replay = await fetch(`${BASE}/api/orders`, { headers: h });
  assert.deepEqual([replay.status, await replay.json()], [401, { reason: 'device-replay' }]);
  const old = await fetch(`${BASE}/api/orders`, { headers: sign(dev, 'GET', '/api/orders', null, { time: Math.floor(Date.now() / 1000) - 600 }) });
  const oldBody = await old.json();
  assert.equal(old.status, 401);
  assert.equal(oldBody.reason, 'device-clock');
  assert.ok(Math.abs(oldBody.now - Date.now() / 1000) < 5);
  const ghost = { ...dev, out: { ...dev.out, deviceId: 'dev_notEnrolled00' } };
  const unknown = await fetch(`${BASE}/api/orders`, { headers: sign(ghost, 'GET', '/api/orders') });
  assert.deepEqual([unknown.status, await unknown.json()], [401, { reason: 'device-unknown' }]);
});

test('the queue page takes a signed request instead of the PIN form', async () => {
  const dev = await enrolPhone();
  const res = await fetch(`${BASE}/`, { headers: sign(dev, 'GET', '/') });
  assert.equal(res.status, 200);
  assert.doesNotMatch(await res.text(), /action="\/session"/);
});

test('changing the PIN removes every device', async () => {
  const dev = await enrolPhone();
  assert.equal((await fetch(`${BASE}/api/orders`, { headers: sign(dev, 'GET', '/api/orders') })).status, 200);
  await handlers.get('hub:stop-lan-server')(null, {});
  assert.ok((await start('98765432abc')).ok);
  try {
    // The first fetch after a restart can land on the old server's kept-alive socket.
    await fetch(`${BASE}/api/status?format=json`).catch(() => {});
    const res = await fetch(`${BASE}/api/orders`, { headers: sign(dev, 'GET', '/api/orders') });
    assert.deepEqual([res.status, await res.json()], [401, { reason: 'device-unknown' }]);
    assert.equal(lanDevices.list().length, 0);
  } finally {
    await handlers.get('hub:stop-lan-server')(null, {});
    assert.ok((await start(PIN)).ok);
  }
});
