/**
 * Khayt for OrcaSlicer on the Windows/Linux LAN server: pairing a slicer
 * (lib/main/connector-pairing.js), its /api/connectors/* routes
 * (lib/main/connector-routes.js), the "From slicer" inbox and slice records
 * (lib/main/slicer-inbox.js, connector-slices.js), the OctoPrint path
 * (lib/main/slicer-upload.js) and the _khayt._tcp advert (lib/mdns.js,
 * lib/main/lan-advertise.js). The Mac's LanConnectorPairing,
 * LanServer+Connector and LanServer+SlicerUpload are the reference; the
 * three shared vector files must pass through this code.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
const { createLanIdentity } = require(path.join(ROOT, 'lib/lan-identity.js'));
const Devices = require(path.join(ROOT, 'lib/lan-devices.js'));
const PP = require(path.join(ROOT, 'lib/main/phone-pairing.js'));
const CP = require(path.join(ROOT, 'lib/main/connector-pairing.js'));
const CR = require(path.join(ROOT, 'lib/main/connector-routes.js'));
const Inbox = require(path.join(ROOT, 'lib/main/slicer-inbox.js'));
const Slices = require(path.join(ROOT, 'lib/main/connector-slices.js'));
const Local = require(path.join(ROOT, 'lib/main/connector-local.js'));
const SU = require(path.join(ROOT, 'lib/main/slicer-upload.js'));
const Adv = require(path.join(ROOT, 'lib/main/lan-advertise.js'));
const Mdns = require(path.join(ROOT, 'lib/mdns.js'));
const ConnectorSlice = require(path.join(ROOT, 'lib/connector-slice.js'));
const ConnectorPrice = require(path.join(ROOT, 'lib/connector-price.js'));

const PORT = 3979;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const noop = () => {};
const seal = (s) => Buffer.from(Buffer.from(s, 'utf8').map((b) => b ^ 0x5a));
const unseal = (b) => Buffer.from(b.map((x) => x ^ 0x5a)).toString('utf8');
const b64 = (s) => Buffer.from(s, 'base64');
const sha = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const x25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), raw]), format: 'der', type: 'spki' });
const ed25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw]), format: 'der', type: 'spki' });
const rawPub = (k) => crypto.createPublicKey(k).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
const readJson = (f) => JSON.parse(fs.readFileSync(path.join(ROOT, f), 'utf8'));

let tmp;
before(() => { tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-connectors-')); });
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// ── The shared vectors, through the desktop's code ─────────────────────────

test('docs/connector-pair.vectors.json: commitment, offer, signature and check number', () => {
  const V = readJson('docs/connector-pair.vectors.json');
  assert.equal(V.cases.length, 8);
  for (const c of V.cases) {
    assert.equal(CP.commitment(c.pluginPublic, c.nonce).toString('base64'), c.commit, c.name);
    assert.equal(CP.offerMessage(c.deviceId, c.serverPublic, c.commit), c.offerMessage, c.name);
    assert.equal(CP.checkNumber(c.deviceId, c.identityPublic, c.serverPublic, c.pluginPublic, c.nonce), c.check, c.name);
    assert.equal(crypto.verify(null, Buffer.from(c.offerMessage), ed25519Public(b64(c.identityPublic)), b64(c.sig)), true, c.name);
  }
  // The phone's prefixes give other numbers: the two flavours never mix.
  const c = V.cases[0];
  assert.notEqual(PP.commitment(c.pluginPublic, c.nonce).toString('base64'), c.commit);
});

test('the window drawn with fixed keys reproduces a vector end to end', () => {
  const c = readJson('docs/connector-pair.vectors.json').cases[0];
  const x25519Private = (hex) => crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(hex, 'hex')]), format: 'der', type: 'pkcs8' });
  const idKey = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(c.identitySeedHex, 'hex')]), format: 'der', type: 'pkcs8' });
  const serverPrivate = x25519Private(c.serverPrivateHex);
  const w = CP.createConnectorPairing({ clock: () => 0, enabled: () => true, newKeyPair: () => ({ privateKey: serverPrivate }), newDeviceId: () => c.deviceId });
  w.open();
  const o = w.request({ commit: c.commit, name: 'Orca', app: 'OrcaSlicer', version: '2.5.1', identity: { publicKey: c.identityPublic, sign: (m) => crypto.sign(null, Buffer.from(m), idKey).toString('base64') } }).offer;
  assert.deepEqual([o.publicKey, o.sig, o.identity, o.deviceId], [c.serverPublic, c.sig, c.identityPublic, c.deviceId]);
  assert.equal(w.reveal(o.pairId, o.pollSecret, c.pluginPublic, c.nonce), 'accepted');
  assert.equal(w.snapshot().pending.check, c.check);
});

test('docs/connector-routes.vectors.json: the declared-hash head, the reply MAC and the seal', () => {
  const V = readJson('docs/connector-routes.vectors.json');
  for (const c of V.request) {
    const key = Buffer.from(c.keyHex, 'hex');
    assert.equal(sha(b64(c.bodyB64)), c.bodyHash, c.name);
    const canonical = Devices.canonicalRequest(c.method, c.target, c.time, c.nonce, null, c.bodyHash);
    assert.equal(canonical, c.canonical, c.name);
    assert.equal(Devices.requestMac(key, canonical), c.mac, c.name);
  }
  for (const c of V.reply) {
    assert.equal(Devices.replyMac(Buffer.from(c.keyHex, 'hex'), c.nonce, c.status, b64(c.bodyB64)), c.mac, c.name);
  }
  for (const c of V.seal) {
    const k = CR.sealKey(Buffer.from(c.keyHex, 'hex'), c.connectorId);
    assert.equal(k.toString('hex'), c.sealKeyHex, c.name);
    assert.equal(CR.sealAad(c.method, c.path).toString(), c.aad, c.name);
    const env = JSON.parse(CR.seal(b64(c.plainB64), k, CR.sealAad(c.method, c.path), b64(c.nonceB64)).toString());
    assert.deepEqual(env, { v: 1, alg: 'A256GCM', nonce: c.nonceB64, ct: c.ctB64 }, c.name);
    assert.equal(CR.unseal(JSON.stringify(env), k, CR.sealAad(c.method, c.path)).toString('base64'), c.plainB64, c.name);
    // Bound to its route: the same envelope under another path does not open.
    assert.equal(CR.unseal(JSON.stringify(env), k, CR.sealAad('POST', '/api/connectors/price')), null, c.name);
  }
});

test('lan-devices verify accepts a head signed over the declared hash (vector), once', () => {
  const c = readJson('docs/connector-routes.vectors.json').request[0];
  // Enrol a connector whose derived key is the vector's: admit it, then swap the stored key in a test file.
  const keyPath = path.join(tmp, 'vec-devices.key');
  const id = 'dev_AbCdEfGhIjKlMnOpQrSt';
  fs.writeFileSync(keyPath, JSON.stringify({ v: 1, pinSalt: crypto.randomBytes(32).toString('base64'), pinTag: '', devices: [
    { deviceId: id, name: 'Orca', key: Buffer.from(c.keyHex, 'hex').toString('base64'), createdAt: 'x', lastSeenAt: 'x', kind: 'connector' }] }));
  const devs = Devices.createLanDevices({ fs, keyPath, now: () => Number(c.time) * 1000 });
  const headers = { 'x-khayt-device': id, 'x-khayt-time': c.time, 'x-khayt-nonce': c.nonce, 'x-khayt-mac': c.mac };
  assert.deepEqual({ ...devs.verify({ headers, method: c.method, target: c.target, body: null, pin: '', bodyHash: c.bodyHash }) }, { ok: true, deviceId: id });
  assert.equal(devs.verify({ headers, method: c.method, target: c.target, body: null, pin: '', bodyHash: c.bodyHash }).reason, 'device-replay');
  assert.equal(devs.kindOf(id), 'connector');
  assert.equal(devs.connector(id).key.toString('hex'), c.keyHex);
});

test('docs/connector-capture.vectors.json: the shared rule, as the route calls it', () => {
  const V = readJson('docs/connector-capture.vectors.json');
  for (const c of V.cases) {
    const got = ConnectorSlice.check(c.input, Object.assign({ maxFileBytes: CR.MAX_FILE_BYTES }, c.opts || {}));
    assert.deepEqual(got, c.expect, c.name);
  }
});

// ── Over HTTP ──────────────────────────────────────────────────────────────

let store, handlers, lanIdentity, lanDevices, connectorPairing, connectorLocal, slicerInbox, connectorSlices;
let mono = 0, rateT = 0, pairOn = true;
const advertCalls = [];
const ipc = (name, arg) => handlers.get(name)(null, arg);
const PRICE_SHOP = require(path.join(ROOT, 'test/fixtures/connector-price-vectors.json')).shop;

before(async () => {
  handlers = new Map();
  store = {
    printLog: [
      { id: 'o1', project: 'Fatima keychains', client: 'Fatima', status: 'printing', machineId: 'm1', date: '2026-10-01', price: 99 },
      { id: 'o2', project: 'Secret', client: 'X', status: 'pending', date: '2026-10-01' },
    ],
    machines: [{ id: 'm1', name: 'U1' }], clients: [],
    inventory: PRICE_SHOP.inventory, printers: PRICE_SHOP.printers, overheadPerHour: PRICE_SHOP.overheadPerHour,
    settings: Object.assign({}, PRICE_SHOP.settings, { shopName: 'Ward', lanApi: { intakeToken: 'tok' } }),
  };
  lanIdentity = createLanIdentity({ fs, keyPath: path.join(tmp, 'id.key'), seal, unseal });
  lanDevices = Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'devices.key'), seal, unseal });
  connectorPairing = CP.createConnectorPairing({ clock: () => mono, enabled: () => pairOn });
  connectorLocal = Local.createConnectorLocal({ fs, settingsPath: path.join(tmp, 'slicer.json'), keyPath: path.join(tmp, 'slicer.key'), seal, unseal });
  slicerInbox = Inbox.createSlicerInbox({ fs, root: path.join(tmp, 'From slicer') });
  connectorSlices = Slices.createConnectorSlices({ fs, dir: slicerInbox.slices });
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
    phonePairing: PP.createPhonePairing({ clock: () => mono, enabled: () => true }),
    connectorPairing, connectorLocal, slicerInbox, connectorSlices,
    lanAdvertiser: { start: (a) => { advertCalls.push(['start', a.bindLan, a.port]); return false; }, stop: () => advertCalls.push(['stop']) },
    connectorClock: () => rateT,
  });
  assert.ok((await ipc('hub:start-lan-server', { port: PORT, pin: PIN, bindLan: 'loopback' })).ok);
});
after(async () => { await handlers.get('hub:stop-lan-server')?.(null, {}); });

async function call(method, p, { headers = {}, body } = {}) {
  const buf = body == null ? undefined : (Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body)));
  const res = await fetch(BASE + p, { method, headers: buf && !headers['content-type'] ? { 'content-type': 'application/json', ...headers } : headers, body: buf });
  const raw = Buffer.from(await res.arrayBuffer());
  const text = raw.toString('utf8');
  let json = null; try { json = JSON.parse(text); } catch (_) { /* not json */ }
  return { status: res.status, json, text, raw, headers: res.headers, mac: res.headers.get('x-khayt-reply-mac') };
}

function pluginHalf() {
  const pair = crypto.generateKeyPairSync('x25519');
  const publicKey = rawPub(pair.privateKey);
  const nonce = crypto.randomBytes(16).toString('base64');
  return { pair, publicKey, nonce, commit: CP.commitment(publicKey, nonce).toString('base64') };
}
const ask = (plugin, extra = {}) => call('POST', '/api/connectors/pair', { body: { v: 2, commit: plugin.commit, name: 'Orca on PC', app: 'OrcaSlicer', version: '2.5.1', ...extra } });

/** The plugin's whole side, and the person's "Numbers match — approve". */
async function pairConnector() {
  store.settings.operatorLockEnabled = false;
  const opened = await ipc('hub:connector-pair-open');
  assert.equal(opened.ok, true, JSON.stringify(opened));
  const plugin = pluginHalf();
  const o = await ask(plugin);
  assert.equal(o.status, 200, o.text);
  const offer = o.json;
  assert.deepEqual(Object.keys(offer).sort(), ['deviceId', 'identity', 'pairId', 'pollSecret', 'publicKey', 'sig']);
  assert.equal(crypto.verify(null, Buffer.from(CP.offerMessage(offer.deviceId, offer.publicKey, plugin.commit)), ed25519Public(b64(offer.identity)), b64(offer.sig)), true);
  const r = await call('POST', `/api/connectors/pair/${offer.pairId}/reveal`, { headers: { 'x-khayt-poll': offer.pollSecret }, body: { publicKey: plugin.publicKey, nonce: plugin.nonce } });
  assert.deepEqual([r.status, r.json], [200, { state: 'waiting' }]);
  const shown = await ipc('hub:connector-pair-state');
  assert.equal(shown.pending.check, CP.checkNumber(offer.deviceId, offer.identity, offer.publicKey, plugin.publicKey, plugin.nonce));
  const approved = await ipc('hub:connector-pair-approve', { pairId: offer.pairId, check: shown.pending.check });
  assert.equal(approved.ok, true, JSON.stringify(approved));
  const shared = crypto.diffieHellman({ privateKey: plugin.pair.privateKey, publicKey: x25519Public(b64(offer.publicKey)) });
  return { offer, id: offer.deviceId, key: Devices.deriveDeviceKey(shared, offer.deviceId) };
}
function sign(dev, method, target, body, { bodyHash } = {}) {
  const time = String(Math.floor(Date.now() / 1000));
  const nonce = crypto.randomBytes(16).toString('hex');
  const mac = Devices.requestMac(dev.key, Devices.canonicalRequest(method, target, time, nonce, body, bodyHash));
  return { 'x-khayt-device': dev.id, 'x-khayt-time': time, 'x-khayt-nonce': nonce, 'x-khayt-mac': mac };
}
async function signed(dev, method, target, body, extra = {}) {
  const buf = body == null ? undefined : (Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body)));
  const headers = { ...sign(dev, method, target, buf), ...extra };
  const r = await call(method, target, { headers, body: buf });
  r.nonce = headers['x-khayt-nonce'];
  return r;
}
const macOk = (dev, r) => r.mac === Devices.replyMac(dev.key, r.nonce, r.status, r.raw);
const sealed = (dev, method, p, obj) => CR.seal(Buffer.from(JSON.stringify(obj)), CR.sealKey(dev.key, dev.id), CR.sealAad(method, p));
const opened = (dev, method, p, r) => JSON.parse(CR.unseal(r.raw, CR.sealKey(dev.key, dev.id), CR.sealAad(method, p)).toString());
function capture(bytes, name = 'Bracket_PLA.gcode', extra = {}) {
  const h = sha(bytes);
  return { v: 1, kind: 'slice', id: 'cap_' + h.slice(0, 8), idem: 'sha256:' + h, intent: 'inbox', file: { name, bytes: bytes.length, sha256: h },
    timeSec: 3725, filaments: [{ slot: 1, type: 'PLA', grams: 12.3 }], ...extra };
}
/** PUT the file, signed at its head over the declared hash. */
function putFile(dev, sliceId, body, { declared = sha(body), length = body.length, expect = false } = {}) {
  const target = `/api/connectors/slices/${sliceId}/file`;
  const headers = { ...sign(dev, 'PUT', target, null, { bodyHash: declared }), 'x-khayt-content-sha256': declared, 'content-length': String(length), host: `127.0.0.1:${PORT}` };
  if (expect) headers.expect = '100-continue';
  return new Promise((resolve, reject) => {
    let continued = false;
    const r = http.request({ host: '127.0.0.1', port: PORT, path: target, method: 'PUT', headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const raw = Buffer.concat(chunks);
        let json = null; try { json = JSON.parse(raw.toString()); } catch (_) { /* empty */ }
        resolve({ status: res.statusCode, json, raw, mac: res.headers['x-khayt-reply-mac'], nonce: headers['x-khayt-nonce'], continued, headers: res.headers });
      });
    });
    r.on('error', (e) => (e.code === 'ECONNRESET' || e.code === 'EPIPE' ? null : reject(e)));
    if (expect) { r.on('continue', () => { continued = true; r.end(body); }); r.flushHeaders(); }
    else r.end(body);
  });
}

let dev, phone;
test('pairing a slicer: off is the ordinary 404; open, commit, reveal, approve; kind connector', async () => {
  pairOn = false;
  try {
    for (const [m, p] of [['POST', '/api/connectors/pair'], ['GET', '/api/connectors/self'], ['GET', '/api/connectors/queue'], ['GET', '/api/connectors/nope']]) {
      const r = await call(m, p, m === 'POST' ? { body: { v: 2, commit: pluginHalf().commit } } : {});
      assert.equal(r.status, 404, `${m} ${p}`);
      assert.equal(r.json.reason, undefined);
    }
    assert.deepEqual(await ipc('hub:connector-pair-open'), { ok: false, error: 'off' });
  } finally { pairOn = true; }
  const closed = await ask(pluginHalf());
  assert.deepEqual([closed.status, closed.json.reason], [403, 'pairing-closed']);
  // An operator may not open the window; a manager may.
  store.operators = [{ id: 'op1', name: 'S', roleKey: 'operator' }];
  store.settings.operatorLockEnabled = true;
  store.settings.activeOperatorId = 'op1';
  assert.deepEqual(await ipc('hub:connector-pair-open'), { ok: false, error: 'not_permitted' });
  store.operators[0].roleKey = 'manager';
  assert.equal((await ipc('hub:connector-pair-open')).ok, true);
  store.settings.operatorLockEnabled = false;
  for (const body of [{ commit: pluginHalf().commit }, { v: 1, publicKey: 'x' }, { v: 2 }]) {
    const r = await call('POST', '/api/connectors/pair', { body });
    assert.deepEqual([r.status, r.json.reason], [400, 'pairing-upgrade'], JSON.stringify(body));
  }
  const notJson = await call('POST', '/api/connectors/pair', { body: 'nope' });
  assert.deepEqual([notJson.status, notJson.json], [400, { error: 'commit' }]);
  const short = await ask({ commit: Buffer.alloc(16).toString('base64') });
  assert.deepEqual([short.status, short.json], [400, { error: 'commit' }]);
  assert.equal((await ipc('hub:connector-pair-state')).offersLeft, 3, 'none of those spent an offer');
  const first = pluginHalf();
  const o = await ask(first);
  assert.equal(o.status, 200);
  const busy = await ask(pluginHalf());
  assert.deepEqual([busy.status, busy.json.reason], [409, 'pairing-busy']);
  const poll = await call('GET', `/api/connectors/pair/${o.json.pairId}`, { headers: { 'x-khayt-poll': o.json.pollSecret } });
  assert.deepEqual([poll.status, poll.json], [200, { state: 'waiting' }]);
  const wrong = await call('GET', `/api/connectors/pair/${o.json.pairId}`, { headers: { 'x-khayt-poll': 'nope' } });
  assert.deepEqual([wrong.status, wrong.json], [404, { state: 'unknown' }]);
  const bad = await call('POST', `/api/connectors/pair/${o.json.pairId}/reveal`, { headers: { 'x-khayt-poll': o.json.pollSecret }, body: { publicKey: pluginHalf().publicKey, nonce: first.nonce } });
  assert.deepEqual([bad.status, bad.json], [403, { state: 'expired', reason: 'bad-reveal' }]);
  // A Host that is not this computer is 421.
  const status = await new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path: '/api/connectors/pair', method: 'POST', headers: { host: 'evil.example', 'content-type': 'application/json' } }, (res) => { res.resume(); resolve(res.statusCode); });
    r.on('error', reject);
    r.end(JSON.stringify({ v: 2, commit: pluginHalf().commit }));
  });
  assert.equal(status, 421);
  await ipc('hub:connector-pair-close');

  dev = await pairConnector();
  const listed = lanDevices.list().find((x) => x.deviceId === dev.id);
  assert.deepEqual([listed.kind, listed.priceGrant, listed.name, listed.codePaired], ['connector', null, 'Orca on PC', false]);
  const after = await call('GET', `/api/connectors/pair/${dev.offer.pairId}`, { headers: { 'x-khayt-poll': dev.offer.pollSecret } });
  assert.deepEqual(after.json, { state: 'approved' });
  assert.equal((await ipc('hub:connector-pair-state')).open, false, 'approve closes the window');
});

test('a connector key opens /api/connectors/* only: 403 connector-scope elsewhere, signed or not', async () => {
  for (const p of ['/api/queue', '/api/orders', '/api/devices/self', '/api/status?format=json', '/v1/orders', '/api/connectors/../queue']) {
    const r = await signed(dev, 'GET', p);
    assert.deepEqual([r.status, r.json], [403, { ok: false, reason: 'connector-scope' }], p);
  }
  const unsigned = await call('GET', '/api/queue', { headers: { 'x-khayt-device': dev.id } });
  assert.deepEqual([unsigned.status, unsigned.json.reason], [403, 'connector-scope']);
  const upload = await call('POST', '/api/files/local', { headers: { 'x-khayt-device': dev.id, 'content-type': 'multipart/form-data; boundary=x' }, body: '--x--\r\n' });
  assert.deepEqual([upload.status, upload.json.reason], [403, 'connector-scope']);
});

test('the connector routes take a connector only: unsigned 401, the PIN or a phone 403 connector-only', async () => {
  const none = await call('GET', '/api/connectors/self');
  assert.deepEqual([none.status, none.json], [401, { reason: 'device-auth' }]);
  const pin = await call('GET', '/api/connectors/self', { headers: { 'x-khayt-pin': PIN } });
  assert.deepEqual([pin.status, pin.json], [403, { ok: false, reason: 'connector-only' }]);
  // A phone enrolled with the PIN.
  const pair = crypto.generateKeyPairSync('x25519');
  const e = await call('POST', '/api/devices', { headers: { 'x-khayt-pin': PIN }, body: { publicKey: rawPub(pair.privateKey), name: 'Phone' } });
  if (e.status === 200) {
    const shared = crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: x25519Public(b64(e.json.publicKey)) });
    phone = { id: e.json.deviceId, key: Devices.deriveDeviceKey(shared, e.json.deviceId) };
  } else {
    // The PIN window is closed on this server: admit a phone by code instead.
    const p = crypto.generateKeyPairSync('x25519');
    const srv = crypto.generateKeyPairSync('x25519');
    const id = PP.freshDeviceId();
    lanDevices.admitPhone({ serverPrivate: srv.privateKey, phonePublic: rawPub(p.privateKey), deviceId: id, name: 'Phone', role: 'owner', pin: PIN });
    const shared = crypto.diffieHellman({ privateKey: p.privateKey, publicKey: srv.publicKey });
    phone = { id, key: Devices.deriveDeviceKey(shared, id) };
  }
  const byPhone = await signed(phone, 'GET', '/api/connectors/self');
  assert.deepEqual([byPhone.status, byPhone.json], [403, { ok: false, reason: 'connector-only' }]);
  const badMac = await call('GET', '/api/connectors/self', { headers: { ...sign(dev, 'GET', '/api/connectors/queue'), host: `127.0.0.1:${PORT}` } });
  assert.deepEqual([badMac.status, badMac.json], [401, { reason: 'device-auth' }]);
  const method = await signed(dev, 'POST', '/api/connectors/queue');
  assert.deepEqual([method.status, method.json, method.headers.get('allow')], [405, { ok: false, reason: 'method' }, 'GET']);
  const unknown = await signed(dev, 'POST', '/api/connectors/slices/ABCDEFGHIJKLMNOP/pause');
  assert.equal(unknown.status, 404, 'no pause, resume or stop');
});

test('GET /api/connectors/self: who, the shop, the limits, the scopes; signed back', async () => {
  const r = await signed(dev, 'GET', '/api/connectors/self');
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { connectorId: dev.id, name: 'Orca on PC', shop: { name: 'Ward' }, limits: { maxFileBytes: 1 << 30, maxMetaBytes: 65536 }, scopes: ['slices:send', 'queue:read'] });
  assert.ok(macOk(dev, r));
  assert.equal(r.headers.get('cache-control'), 'no-store');
  const v1 = await signed(dev, 'GET', '/v1/connectors/self');
  assert.equal(v1.status, 200, '/v1 is /api');
});

test('POST /api/connectors/slices: sealed capture, 201, the same waiting, refusals', async () => {
  const body = Buffer.from('; generated by OrcaSlicer\nG28\nG1 X10 Y10\n; total filament used [g] = 12.30\n; estimated printing time (normal mode) = 1h 2m 5s\n');
  const p = '/api/connectors/slices';
  const r = await signed(dev, 'POST', p, sealed(dev, 'POST', p, capture(body, 'Bracket_PLA.gcode', { intent: 'print', machineId: 'm1', startPrint: true })));
  assert.equal(r.status, 201, r.text);
  assert.ok(macOk(dev, r));
  assert.ok(Slices.plausibleSliceId(r.json.sliceId));
  assert.equal(r.json.state, 'awaiting-file');
  assert.equal(r.json.intentHonoured, false, 'v1 never starts a print');
  assert.deepEqual(r.json.dropped, []);
  assert.match(r.json.uploadBy, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  const again = await signed(dev, 'POST', p, sealed(dev, 'POST', p, capture(body)));
  assert.deepEqual([again.status, again.json.sliceId, again.json.state], [200, r.json.sliceId, 'awaiting-file']);
  const bad = await signed(dev, 'POST', p, sealed(dev, 'POST', '/api/connectors/price', capture(body)));
  assert.deepEqual([bad.status, bad.json], [400, { ok: false, reason: 'seal' }]);
  const notJson = await signed(dev, 'POST', p, CR.seal(Buffer.from('nope'), CR.sealKey(dev.key, dev.id), CR.sealAad('POST', p)));
  assert.deepEqual([notJson.status, notJson.json], [400, { ok: false, reason: 'not-json' }]);
  for (const c of readJson('docs/connector-capture.vectors.json').cases.filter((x) => !x.expect.ok && !x.opts)) {
    const x = await signed(dev, 'POST', p, sealed(dev, 'POST', p, c.input));
    assert.deepEqual([x.status, x.json], [422, { ok: false, reason: c.expect.reason, field: c.expect.field }], c.name);
  }
  const big = await signed(dev, 'POST', p, Buffer.alloc(97 * 1024, 0x20));
  assert.deepEqual([big.status, big.json], [413, { ok: false, reason: 'too-large' }]);
  const state = await signed(dev, 'GET', `/api/connectors/slices/${r.json.sliceId}`);
  assert.deepEqual([state.status, state.json], [200, { sliceId: r.json.sliceId, state: 'awaiting-file' }]);
  dev.slice = { id: r.json.sliceId, body };
});

test('PUT .../file: judged from its head (no 100 Continue on a refusal), then filed in the inbox', async () => {
  const { id, body } = dev.slice;
  const noHash = await new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path: `/api/connectors/slices/${id}/file`, method: 'PUT', headers: sign(dev, 'PUT', `/api/connectors/slices/${id}/file`, null) }, (res) => { res.resume(); resolve(res.statusCode); });
    r.on('error', reject); r.end(body);
  });
  assert.equal(noHash, 400);
  const other = Buffer.from('G28\n');
  const notDeclared = await putFile(dev, id, other, { expect: true });
  assert.deepEqual([notDeclared.status, notDeclared.json.reason, notDeclared.continued], [409, 'hash-not-declared', false]);
  assert.ok(macOk(dev, notDeclared));
  const len = await putFile(dev, id, body, { length: body.length - 1 });
  assert.deepEqual([len.status, len.json.reason], [400, 'length-mismatch']);
  const unknown = await putFile(dev, 'ABCDEFGHIJKLMNOP', body);
  assert.deepEqual([unknown.status, unknown.json.reason], [404, 'unknown-slice']);
  const byPhone = await new Promise((resolve, reject) => {
    const target = `/api/connectors/slices/${id}/file`;
    const r = http.request({ host: '127.0.0.1', port: PORT, path: target, method: 'PUT', headers: { ...sign(phone, 'PUT', target, null, { bodyHash: sha(body) }), 'x-khayt-content-sha256': sha(body) } }, (res) => { res.resume(); resolve(res.statusCode); });
    r.on('error', reject); r.end(body);
  });
  assert.equal(byPhone, 403);
  const ok = await putFile(dev, id, body, { expect: true });
  assert.deepEqual([ok.status, ok.json, ok.continued], [201, { sliceId: id, state: 'in-inbox' }, true]);
  assert.ok(macOk(dev, ok));
  const items = slicerInbox.list();
  assert.equal(items.length, 1);
  const it = items[0];
  assert.deepEqual([it.name, it.bytes, it.sha256, it.source, it.connectorId, it.connectorName, it.sliceId],
    ['Bracket_PLA.gcode', body.length, sha(body), 'connector', dev.id, 'Orca on PC', id]);
  assert.deepEqual(it.suggested, { intent: 'print', machineId: 'm1', startPrint: true }, 'what was asked, kept, never acted on');
  assert.deepEqual([it.slots.length, it.slots[0].slot, it.slots[0].type, it.slots[0].grams], [1, 1, 'PLA', 12.3], 'the checked slots');
  assert.equal(it.grams, 12.3, 'the file\'s own figures are read');
  assert.equal(fs.readFileSync(slicerInbox.fileOf(it)).equals(body), true);
  assert.equal(store.printLog.length, 2, 'nothing in the book is written');
  const again = await putFile(dev, id, body);
  assert.deepEqual([again.status, again.json.reason], [409, 'not-awaiting-file']);
  const state = await signed(dev, 'GET', `/api/connectors/slices/${id}`);
  assert.deepEqual(state.json, { sliceId: id, state: 'in-inbox' });
  // On disk: ids, state, hash, size, times; never the file's name.
  const rec = fs.readFileSync(path.join(slicerInbox.slices, id + '.json'), 'utf8');
  assert.ok(!rec.includes('Bracket'));
  assert.deepEqual(Object.keys(JSON.parse(rec)), ['attempts', 'bytes', 'changedAt', 'connectorId', 'id', 'inboxId', 'sha256', 'state', 'uploadBy']);
  // The shop takes it out of the inbox: the plugin hears left-inbox.
  const inboxList = await ipc('hub:slicer-inbox-list');
  assert.equal(inboxList.items.length, 1);
  assert.equal((await ipc('hub:slicer-inbox-read', it.id)).file, slicerInbox.fileOf(it));
  assert.deepEqual(await ipc('hub:slicer-inbox-discard', it.id), { ok: true });
  const left = await signed(dev, 'GET', `/api/connectors/slices/${id}`);
  assert.deepEqual(left.json, { sliceId: id, state: 'left-inbox' });
});

test('a file whose bytes do not match is sent once more, then the slice expires', async () => {
  const body = Buffer.from('G28\nG1 X1\n; mismatch case\n');
  const p = '/api/connectors/slices';
  const a = await signed(dev, 'POST', p, sealed(dev, 'POST', p, capture(body, 'Two.gcode')));
  assert.equal(a.status, 201);
  const wrong = Buffer.from(body); wrong[0] = 0x58;
  const one = await putFile(dev, a.json.sliceId, wrong, { declared: sha(body) });
  assert.deepEqual([one.status, one.json], [422, { ok: false, reason: 'hash-mismatch', retry: true }]);
  const two = await putFile(dev, a.json.sliceId, wrong, { declared: sha(body) });
  assert.deepEqual([two.status, two.json], [422, { ok: false, reason: 'hash-mismatch', retry: false }]);
  const gone = await putFile(dev, a.json.sliceId, body);
  assert.deepEqual([gone.status, gone.json.reason], [404, 'unknown-slice']);
  assert.equal((await signed(dev, 'GET', `/api/connectors/slices/${a.json.sliceId}`)).json.state, 'expired');
});

test('GET /api/connectors/queue: sealed, no customer data, keyed ETag, 304, 1 per 10 s', async () => {
  rateT = 1000;
  const q = await signed(dev, 'GET', '/api/connectors/queue');
  assert.equal(q.status, 200, q.text);
  assert.ok(macOk(dev, q));
  const snap = opened(dev, 'GET', '/api/connectors/queue', q);
  assert.deepEqual(snap.shop, { name: 'Ward' });
  assert.deepEqual(snap.jobs.map((j) => [j.id, j.stage, j.machine]), [['o1', 'printing', 'U1'], ['o2', 'pending', null]]);
  for (const leak of ['Fatima', 'Secret', '99']) assert.ok(!JSON.stringify(snap).includes(leak), leak);
  const content = Object.assign({}, snap); delete content.at;
  const etag = q.headers.get('etag');
  assert.equal(etag, CR.queueEtag(JSON.stringify(content), dev.key, dev.id));
  assert.notEqual(etag, '"' + sha(Buffer.from(JSON.stringify(content))).slice(0, 32) + '"', 'keyed, not a plain hash');
  const limited = await signed(dev, 'GET', '/api/connectors/queue', null, { 'if-none-match': etag });
  assert.deepEqual([limited.status, limited.json.reason, limited.headers.get('retry-after')], [429, 'rate', '10']);
  assert.ok(macOk(dev, limited), 'a 429 is signed too');
  rateT += 10;
  const same = await signed(dev, 'GET', '/api/connectors/queue', null, { 'if-none-match': `"x", ${etag}` });
  assert.deepEqual([same.status, same.raw.length, same.headers.get('etag')], [304, 0, etag]);
  assert.ok(macOk(dev, same));
  rateT += 10;
});

test('POST /api/connectors/price: off by the switch or the grant; an allow-list per grant', async () => {
  const p = '/api/connectors/price';
  const facts = require(path.join(ROOT, 'test/fixtures/connector-price-vectors.json')).cases[0].facts;
  const ask = async () => {
    const r = await signed(dev, 'POST', p, sealed(dev, 'POST', p, facts));
    assert.equal(r.status, 200, r.text);
    assert.ok(macOk(dev, r));
    return opened(dev, 'POST', p, r);
  };
  assert.deepEqual(await ask(), { prices: 'off' }, 'the switch is off by default');
  store.settings.operatorLockEnabled = false;
  assert.equal((await ipc('hub:connector-prices-set', { on: true })).on, true);
  assert.deepEqual(await ask(), { prices: 'off' }, 'on, but this device has no grant');
  assert.equal((await ipc('hub:connector-grant-set', { deviceId: dev.id, grant: 'price' })).ok, true);
  const priced = ConnectorPrice.priceSlice(facts, { settings: store.settings, inventory: store.inventory, printers: store.printers, overheadPerHour: store.overheadPerHour });
  const price = await ask();
  assert.deepEqual(Object.keys(price).sort(), ['basis', 'currency', 'prices', 'qty', 'rounded', 'total', 'unit', ...(priced.round ? ['round'] : [])].sort());
  assert.equal(price.total, priced.total);
  assert.equal(price.cost, undefined, 'a price device never sees the cost');
  assert.deepEqual((await signed(dev, 'GET', '/api/connectors/self')).json.scopes, ['slices:send', 'queue:read', 'price:read']);
  await ipc('hub:connector-grant-set', { deviceId: dev.id, grant: 'cost' });
  const cost = await ask();
  assert.deepEqual(cost.cost, { unit: priced.cost.unit, total: priced.cost.total });
  assert.deepEqual(Object.keys(cost.margin).sort(), Object.keys(priced.margin).filter((k) => ['pct', 'pctOnCost', 'amount'].includes(k)).sort());
  assert.deepEqual((await signed(dev, 'GET', '/api/connectors/self')).json.scopes, ['slices:send', 'queue:read', 'price:read', 'cost:read']);
  // An operator may not change either; a grant that is not known is refused.
  store.operators = [{ id: 'op1', name: 'S', roleKey: 'operator' }];
  store.settings.operatorLockEnabled = true;
  store.settings.activeOperatorId = 'op1';
  assert.deepEqual(await ipc('hub:connector-prices-set', { on: false }), { ok: false, error: 'not_permitted' });
  store.settings.operatorLockEnabled = false;
  assert.deepEqual(await ipc('hub:connector-grant-set', { deviceId: dev.id, grant: 'everything' }), { ok: false, error: 'bad_request' });
  await ipc('hub:connector-prices-set', { on: false });
  assert.deepEqual(await ask(), { prices: 'off' }, 'the switch off wins over any grant');
  const bad = await signed(dev, 'POST', p, Buffer.from('{}'));
  assert.deepEqual([bad.status, bad.json], [400, { ok: false, reason: 'seal' }]);
  // The rule's answer through each grant: only the allow-listed keys.
  const extra = { ...priced, secret: 'x', cost: { ...priced.cost, spool: 'S1' }, margin: { ...priced.margin, hidden: 1 } };
  assert.equal(CR.priceAnswer(extra, 'price').secret, undefined);
  assert.equal(CR.priceAnswer(extra, 'cost').cost.spool, undefined);
  assert.equal(CR.priceAnswer(extra, 'cost').margin.hidden, undefined);
  assert.deepEqual(CR.priceAnswer({ unpriced: 'no-material', total: 5 }, 'cost'), { prices: 'on', unpriced: 'no-material' });
});

test('rate limits per connector, on the injected clock: 30 announces an hour, 429 Retry-After', () => {
  let t = 0;
  const r = CR.createConnectorRoutes({ devices: {}, pairing: {}, identity: {}, inbox: {}, slices: {}, uploads: { active: 0 },
    enabled: () => true, pricesOn: () => false, getStore: () => ({}), pin: () => PIN, rateClock: () => t });
  for (let i = 0; i < 30; i++) assert.equal(r.rate('dev_a', 'announce'), null);
  const no = r.rate('dev_a', 'announce');
  assert.deepEqual([no[0], no[1].reason, no[2]['Retry-After']], [429, 'rate', '3600']);
  assert.equal(r.rate('dev_b', 'announce'), null, 'another connector has its own');
  t = 1800;
  assert.equal(r.rate('dev_a', 'announce')[2]['Retry-After'], '1800');
  t = 3600;
  assert.equal(r.rate('dev_a', 'announce'), null, 'an hour later the first is gone');
  for (let i = 0; i < 600; i++) r.rate('dev_c', 'all');
  assert.equal(r.rate('dev_c', 'all')[0], 429);
});

test('DELETE /api/connectors/self unpairs: the next request is device-revoked', async () => {
  const p = pluginHalf();
  void p;
  const second = await pairConnector();
  const del = await signed(second, 'DELETE', '/api/connectors/self');
  assert.deepEqual([del.status, del.json], [200, { ok: true }]);
  assert.ok(macOk(second, del));
  const after = await signed(second, 'GET', '/api/connectors/self');
  assert.deepEqual([after.status, after.json.reason], [401, 'device-revoked']);
});

// ── The OctoPrint path, and one dedupe for both ways in ─────────────────────

function multipart(name, bytes, { field = 'file', extra = '' } = {}) {
  const boundary = '----khayt' + crypto.randomBytes(6).toString('hex');
  const parts = [
    `--${boundary}\r\nContent-Disposition: form-data; name="print"\r\n\r\ntrue\r\n`,
    extra,
    `--${boundary}\r\nContent-Disposition: form-data; name="${field}"; filename="${name}"\r\nContent-Type: application/octet-stream\r\n\r\n`,
  ].join('');
  return { boundary, body: Buffer.concat([Buffer.from(parts), bytes, Buffer.from(`\r\n--${boundary}--\r\n`)]) };
}
const octo = (key, m) => call('POST', '/api/files/local', { headers: { 'x-api-key': key, 'content-type': `multipart/form-data; boundary=${m.boundary}` }, body: m.body });

test('GET /api/version and POST /api/files/local: 404 off; the key; the OctoPrint answers', async () => {
  const m0 = multipart('a.gcode', Buffer.from('G28\n'));
  assert.equal((await call('GET', '/api/version', { headers: { 'x-api-key': 'X' } })).status, 404);
  assert.equal((await octo('X', m0)).status, 404);
  store.settings.operatorLockEnabled = false;
  const on = await ipc('hub:slicer-upload-set', { on: true });
  assert.equal(on.on, true);
  assert.match(on.key, /^[0-9A-F]{32}$/);
  const key = on.key;
  assert.equal((await call('GET', '/api/version')).status, 401);
  const v = await call('GET', '/api/version', { headers: { 'x-api-key': key } });
  assert.deepEqual([v.status, v.text], [200, '{"api":"0.1","server":"1.10.0","text":"OctoPrint 1.10.0 (Khayt)"}']);
  assert.equal((await call('GET', `/api/version?apikey=${key}`)).status, 401, 'not accepted in the query');
  assert.equal((await octo('', m0)).status, 401);
  const wrongType = await octo(key, multipart('model.stl', Buffer.from('solid')));
  assert.deepEqual([wrongType.status, wrongType.json], [415, { error: 'Could not upload the file "model.stl", invalid type' }]);
  const noFile = await octo(key, multipart('a.gcode', Buffer.from('G28'), { field: 'other' }));
  assert.deepEqual([noFile.status, noFile.json], [400, { error: 'No file included' }]);
  const notMulti = await call('POST', '/api/files/local', { headers: { 'x-api-key': key, 'content-type': 'application/json' }, body: '{}' });
  assert.equal(notMulti.status, 400);
  const plate = Buffer.from('; generated by PrusaSlicer\nG28\n'.repeat(2000));
  const m = multipart('plate one.gcode', plate);
  const ok = await octo(key, m);
  assert.equal(ok.status, 201, ok.text);
  assert.deepEqual(ok.json, {
    done: true, effectivePrint: false, effectiveSelect: false,
    files: { local: { name: 'plate one.gcode', display: 'plate one.gcode', path: 'plate one.gcode', origin: 'local',
      refs: { resource: `http://127.0.0.1:${PORT}/api/files/local/plate%20one.gcode`, download: `http://127.0.0.1:${PORT}/downloads/files/local/plate%20one.gcode` } } },
  });
  assert.equal(ok.headers.get('location'), `http://127.0.0.1:${PORT}/api/files/local/plate%20one.gcode`);
  const item = slicerInbox.list().find((i) => i.name === 'plate one.gcode');
  assert.equal(item.sha256, sha(plate));
  assert.equal(item.source, undefined, 'the OctoPrint path has no source');
  assert.equal(fs.readFileSync(slicerInbox.fileOf(item)).equals(plate), true, 'the file part, exactly');
  dev.octoKey = key;
  dev.octoPlate = plate;
});

test('one SHA-256 dedupe for both ways in', async () => {
  const before = slicerInbox.list().length;
  // The plugin announces bytes the OctoPrint path already filed.
  const p = '/api/connectors/slices';
  const dup = await signed(dev, 'POST', p, sealed(dev, 'POST', p, capture(dev.octoPlate, 'Same.gcode')));
  assert.deepEqual([dup.status, dup.json.state, dup.json.duplicate], [200, 'in-inbox', true]);
  // The plugin files new bytes; the OctoPrint path then sends the same: one item.
  const fresh = Buffer.from('G28\n; only once\n');
  const a = await signed(dev, 'POST', p, sealed(dev, 'POST', p, capture(fresh, 'Once.gcode')));
  rateT += 3600;
  assert.equal((await putFile(dev, a.json.sliceId, fresh)).status, 201);
  const again = await octo(dev.octoKey, multipart('Once again.gcode', fresh));
  assert.equal(again.status, 201, 'the slicer is told its file arrived, which it has');
  assert.equal(slicerInbox.list().length, before + 1);
  // Ten wrong keys from one visitor: 429, in its own bucket (the PIN still works).
  for (let i = 0; i < 10; i++) assert.equal((await call('GET', '/api/version', { headers: { 'x-api-key': 'WRONG' } })).status, 403);
  assert.equal((await call('GET', '/api/version', { headers: { 'x-api-key': dev.octoKey } })).status, 429);
  assert.equal((await call('GET', '/api/queue', { headers: { 'x-khayt-pin': PIN } })).status, 200);
});

test('the inbox holds 100 at most: 409 inbox-full both ways', () => {
  const root = path.join(tmp, 'full-inbox');
  const inbox = Inbox.createSlicerInbox({ fs, root, maxWaiting: 2 });
  const put = (text) => { const f = inbox.spoolPath('x.gcode'); fs.writeFileSync(f, text); return inbox.file(f, 'x.gcode', { sha256: sha(Buffer.from(text)) }); };
  put('a'); put('b');
  assert.throws(() => put('c'), (e) => e instanceof Inbox.InboxFull);
  assert.throws(() => put('a'), (e) => e instanceof Inbox.InboxDuplicate && e.item.sha256 === sha(Buffer.from('a')), 'the duplicate is found before the cap');
  assert.equal(Inbox.MAX_WAITING, 100);
});

test('the sweep at launch: a slice waiting for its file becomes expired; half-spooled bodies go', () => {
  const root = path.join(tmp, 'sweep');
  let t = Date.parse('2026-11-22T10:00:00Z');
  const inbox = Inbox.createSlicerInbox({ fs, root });
  const s1 = Slices.createConnectorSlices({ fs, dir: inbox.slices, now: () => t });
  const base = { connectorId: 'dev_x', name: 'Client name.gcode', bytes: 3, sha256: 'a'.repeat(64), suggested: { intent: 'inbox' }, slots: null, attempts: 0, inboxId: null };
  s1.put({ ...base, id: 'AAAAAAAAAAAAAAAA', uploadBy: t + 600_000, state: 'awaiting-file', changedAt: t });
  s1.put({ ...base, id: 'BBBBBBBBBBBBBBBB', uploadBy: t, state: 'in-inbox', inboxId: 'SU-1-0000', changedAt: t });
  s1.put({ ...base, id: 'CCCCCCCCCCCCCCCC', uploadBy: t, state: 'expired', changedAt: t - 25 * 3600_000 });
  fs.writeFileSync(path.join(inbox.slices, 'garbage.json'), '{');
  for (const f of fs.readdirSync(inbox.slices)) assert.ok(!fs.readFileSync(path.join(inbox.slices, f), 'utf8').includes('Client name'));
  const spool = inbox.spoolPath('half.gcode');
  fs.writeFileSync(spool, 'G2');
  // The app restarts.
  t += 1000;
  const s2 = Slices.createConnectorSlices({ fs, dir: inbox.slices, now: () => t });
  s2.prune();
  assert.equal(s2.get('AAAAAAAAAAAAAAAA').state, 'expired');
  assert.equal(s2.get('AAAAAAAAAAAAAAAA').name, '', 'a file name was never written down');
  assert.equal(s2.get('BBBBBBBBBBBBBBBB').state, 'in-inbox');
  assert.equal(s2.get('CCCCCCCCCCCCCCCC'), null, 'expired a day ago: forgotten');
  assert.ok(!fs.existsSync(path.join(inbox.slices, 'garbage.json')));
  assert.equal(JSON.parse(fs.readFileSync(path.join(inbox.slices, 'AAAAAAAAAAAAAAAA.json'), 'utf8')).state, 'expired');
  assert.equal(inbox.sweepIncoming(), 1);
  assert.deepEqual(fs.readdirSync(inbox.incoming), []);
});

test('connector-local: both switches off by default, the key minted once and sealed', () => {
  const dir = path.join(tmp, 'local');
  fs.mkdirSync(dir);
  const L = Local.createConnectorLocal({ fs, settingsPath: path.join(dir, 's.json'), keyPath: path.join(dir, 'k'), seal, unseal });
  assert.equal(L.pricesOn(), false);
  assert.equal(L.acceptingUploads(), false);
  assert.equal(L.activeKey(), null, 'no key is in force while uploads are off');
  const k = L.currentKey();
  assert.match(k, /^[0-9A-F]{32}$/);
  assert.ok(fs.readFileSync(path.join(dir, 'k'), 'utf8').startsWith('khayt-sealed:'));
  const again = Local.createConnectorLocal({ fs, settingsPath: path.join(dir, 's.json'), keyPath: path.join(dir, 'k'), seal, unseal });
  assert.equal(again.currentKey(), k);
  assert.notEqual(again.regenerateKey(), k);
  fs.writeFileSync(path.join(dir, 's.json'), 'not json');
  assert.equal(again.pricesOn(), false, 'unreadable is off');
});

test('the multipart reader finds a delimiter split across chunks', () => {
  const m = multipart('x.gcode', Buffer.from('A'.repeat(5000)));
  for (const step of [1, 3, 7, 64, 4096]) {
    let got = Buffer.alloc(0);
    const r = SU.createMultipartReader(m.boundary, (p) => (p.name === 'file' ? { write: (b) => { got = Buffer.concat([got, b]); }, end() {} } : null));
    for (let i = 0; i < m.body.length; i += step) r.push(m.body.subarray(i, i + step));
    assert.equal(r.finish(), true, String(step));
    assert.equal(got.toString(), 'A'.repeat(5000), String(step));
  }
  assert.deepEqual(SU.disposition('Content-Disposition: form-data; name="file"; filename*=UTF-8\'\'%D8%B9.gcode'), { name: 'file', filename: 'ع.gcode' });
});

// ── Discovery ──────────────────────────────────────────────────────────────

test('mDNS: the advertisement packet (vectors), the goodbye, and questions', () => {
  const pkt = Mdns.encodeAdvertisement({ instance: 'Ward. Shop', service: '_khayt._tcp', host: 'pc-khayt', port: 3219, txt: { v: '1' }, ipv4: ['192.168.1.5', '10.0.0.2'] });
  assert.deepEqual(Array.from(pkt.subarray(0, 12)), [0, 0, 0x84, 0, 0, 0, 0, 6, 0, 0, 0, 0], 'a response, authoritative, 6 answers');
  assert.deepEqual(Mdns.decodeMessage(pkt), [
    { name: '_services._dns-sd._udp.local', type: 12, ptr: '_khayt._tcp.local' },
    { name: '_khayt._tcp.local', type: 12, ptr: 'Ward. Shop._khayt._tcp.local' },
    { name: 'Ward. Shop._khayt._tcp.local', type: 33, srv: { port: 3219, target: 'pc-khayt.local' } },
    { name: 'Ward. Shop._khayt._tcp.local', type: 16, txt: { v: '1' } },
    { name: 'pc-khayt.local', type: 1, a: '192.168.1.5' },
    { name: 'pc-khayt.local', type: 1, a: '10.0.0.2' },
  ]);
  // Exact bytes of the TXT and SRV records (class with cache-flush, TTLs).
  const hex = Buffer.from(pkt).toString('hex');
  assert.ok(hex.includes('0010800100001194000403763d31'), 'TXT, cache-flush, TTL 4500, "v=1"');
  assert.ok(hex.includes('0021800100000078'), 'SRV, cache-flush, TTL 120');
  const bye = Buffer.from(Mdns.encodeAdvertisement({ instance: 'Ward', host: 'h', port: 1, ipv4: [] })).toString('hex');
  assert.ok(bye.includes('000c000100001194'));
  const gone = Buffer.from(Mdns.encodeAdvertisement({ instance: 'Ward', host: 'h', port: 1, ipv4: [], ttl: 0 }));
  assert.ok(gone.toString('hex').includes('000c000100000000'), 'the goodbye carries TTL 0');
  assert.deepEqual(Mdns.decodeQuestions(Mdns.encodeQuery('_khayt._tcp.local', { unicast: true })), [{ name: '_khayt._tcp.local', type: 12, unicast: true }]);
  assert.deepEqual(Mdns.decodeQuestions(pkt), [], 'a response is not a question');
  assert.deepEqual(Array.from(Mdns.encodeTxt({})), [0]);
  // The shop's name, cut by BYTES to 63, never splitting a letter.
  const arabic = 'ورشة'.repeat(10);
  const name = Adv.advertisedName({ settings: { shopName: arabic } });
  assert.ok(Buffer.byteLength(name) <= 63 && arabic.startsWith(name) && name.length === 31);
  assert.equal(Adv.advertisedName({ settings: { shopName: '  ' } }), 'Khayt');
});

class FakeSocket extends EventEmitter {
  constructor(log) { super(); this.log = log; this.sent = []; }
  bind(port, cb) { this.log.push(['bind', port]); cb(); }
  addMembership(a) { this.log.push(['join', a]); }
  setMulticastTTL() {}
  send(buf, off, len, port, addr, cb) { this.sent.push(Buffer.from(buf)); this.log.push(['send', port, addr]); cb && cb(); }
  close() { this.log.push(['close']); }
}

test('the advert runs only while the server is on the LAN; never on loopback; goodbye on stop', async () => {
  const log = [];
  let sock = null;
  let t = 0;
  const timers = [];
  const ifaces = { en0: [{ family: 'IPv4', address: '192.168.1.5', internal: false }], lo: [{ family: 'IPv4', address: '127.0.0.1', internal: true }] };
  const a = Adv.createLanAdvertiser({ createSocket: () => (sock = new FakeSocket(log)), interfaces: () => ifaces, hostname: () => 'Shop PC.local',
    setTimeout: (fn) => { timers.push(fn); return null; }, now: () => t });
  assert.equal(a.start({ store: { settings: { shopName: 'Ward' } }, port: 3219, bindLan: 'loopback' }), false);
  assert.equal(sock, null, 'no socket for a loopback-only server');
  assert.equal(a.start({ store: { settings: { shopName: 'Ward' } }, port: 3219, bindLan: 'lan' }), true);
  assert.deepEqual(a.advertising(), { instance: 'Ward', host: 'Shop-PC-khayt', port: 3219 });
  assert.deepEqual(log.slice(0, 3), [['bind', 5353], ['join', '224.0.0.251'], ['send', 5353, '224.0.0.251']]);
  timers.forEach((f) => f());
  assert.equal(sock.sent.length, 2, 'announced twice');
  sock.emit('message', Buffer.from(Mdns.encodeQuery('_khayt._tcp.local')));
  assert.equal(sock.sent.length, 2, 'throttled: one answer a second');
  t = 2000;
  sock.emit('message', Buffer.from(Mdns.encodeQuery('_printer._tcp.local')));
  assert.equal(sock.sent.length, 2, 'not about us');
  sock.emit('message', Buffer.from(Mdns.encodeQuery('_khayt._tcp.local')));
  assert.equal(sock.sent.length, 3);
  const s = sock;
  a.stop();
  assert.equal(a.advertising(), null);
  const last = Mdns.decodeMessage(s.sent[s.sent.length - 1]);
  assert.equal(last.length, 5);
  assert.ok(Buffer.from(s.sent[s.sent.length - 1]).toString('hex').includes('000c000100000000'), 'goodbye, TTL 0');
  assert.deepEqual(log[log.length - 1], ['close']);
  // No address a phone can reach: nothing is advertised.
  assert.equal(Adv.createLanAdvertiser({ createSocket: () => assert.fail('no socket'), interfaces: () => ({ lo: ifaces.lo }), hostname: () => 'x' })
    .start({ store: {}, port: 1, bindLan: 'all' }), false);
});

test('the LAN server starts the advert with its binding, and stops it on stop', async () => {
  const starts = advertCalls.filter((c) => c[0] === 'start');
  assert.deepEqual(starts[0], ['start', 'loopback', PORT], 'told it is loopback: the advertiser declines');
  const n = advertCalls.length;
  await ipc('hub:stop-lan-server');
  assert.deepEqual(advertCalls.slice(n), [['stop']]);
  assert.ok((await ipc('hub:start-lan-server', { port: PORT, pin: PIN, bindLan: 'loopback' })).ok);
});
