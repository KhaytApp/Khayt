/**
 * POST /api/orders/:id/photos on the desktop (lib/lan-server.js), the route the
 * native Mac's LanServer serves (#2277, docs/LAN_API.md): a paired phone adds a
 * photo to a job. Only a signed, enrolled phone may; the body is the JPEG itself,
 * at most 8 MB; the file is written before the record, as the order editor's own
 * Add Photo files it; and the window is told so its next save keeps the photo.
 *
 * The image work is Electron's (encodeLanJobPhoto in main.js), so it is injected
 * here as a stub that knows a JPEG by its first bytes.
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
const ApiTokens = require(path.join(ROOT, 'lib/api-tokens.js'));

const PORT = 3973;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const noop = () => {};
const seal = (s) => Buffer.from(Buffer.from(s, 'utf8').map((b) => b ^ 0x5a));
const unseal = (b) => Buffer.from(b.map((x) => x ^ 0x5a)).toString('utf8');
const x25519Public = (raw) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), raw]), format: 'der', type: 'spki' });

const jpeg = (n = 64) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), crypto.randomBytes(Math.max(0, n - 4))]);
const encodeJobPhoto = (buf) => (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8
  ? { ok: true, thumb: 'data:image/jpeg;base64,VEhVTUI=', full: buf }
  : { ok: false, reason: 'not-an-image' });

let tmp, photosDir, handlers, store, sent, writeToken;
before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-lan-photos-'));
  photosDir = path.join(tmp, 'order-photos');
  fs.mkdirSync(photosDir);
  handlers = new Map();
  sent = [];
  const minted = ApiTokens.generateToken({ label: 'writer', scopes: ['orders:read', 'orders:write'] });
  writeToken = minted.token;
  store = {
    printLog: [
      { id: 'J1', project: 'Vase', client: 'C', status: 'completed', date: '2026-11-01', printPhotos: [] },
      { id: 'J2', project: 'Lamp', client: 'C', status: 'printing', date: '2026-11-02' },
    ],
    inventory: [], machines: [], clients: [],
    settings: { lanApi: { intakeToken: 'tok', apiTokens: [minted.record] } },
  };
  const win = { isDestroyed: () => false, webContents: { send: (channel, payload) => sent.push({ channel, payload }) } };
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
    getMainWindow: () => win,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
    orderPhotosDir: () => photosDir,
    encodeJobPhoto,
    lanIdentity: createLanIdentity({ fs, keyPath: path.join(tmp, 'id.key'), seal, unseal }),
    lanDevices: Devices.createLanDevices({ fs, keyPath: path.join(tmp, 'devices.key'), seal, unseal }),
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, JSON.stringify(r));
});
after(async () => {
  await handlers.get('hub:stop-lan-server')?.(null, {});
  fs.rmSync(tmp, { recursive: true, force: true });
});

async function enrolPhone() {
  const pair = crypto.generateKeyPairSync('x25519');
  const phonePub = crypto.createPublicKey(pair.privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
  const res = await fetch(`${BASE}/api/devices`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-khayt-pin': PIN }, body: JSON.stringify({ publicKey: phonePub, name: 'Phone' }) });
  assert.equal(res.status, 200);
  const out = await res.json();
  const shared = crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: x25519Public(Buffer.from(out.publicKey, 'base64')) });
  return { out, key: Devices.deriveDeviceKey(shared, out.deviceId) };
}
function sign(dev, method, target, body) {
  const time = String(Math.floor(Date.now() / 1000));
  const nonce = crypto.randomBytes(16).toString('hex');
  const mac = Devices.requestMac(dev.key, Devices.canonicalRequest(method, target, time, nonce, body));
  return { 'x-khayt-device': dev.out.deviceId, 'x-khayt-time': time, 'x-khayt-nonce': nonce, 'x-khayt-mac': mac };
}
const post = (dev, id, body) => {
  const target = `/api/orders/${encodeURIComponent(id)}/photos`;
  return fetch(BASE + target, { method: 'POST', headers: { 'content-type': 'image/jpeg', ...sign(dev, 'POST', target, body) }, body });
};
const job = (id) => store.printLog.find((o) => o.id === id);

test('a paired phone adds a photo: the file first, then the record, and the window is told', async () => {
  const dev = await enrolPhone();
  const img = jpeg(4096);
  sent.length = 0;
  const res = await post(dev, 'J1', img);
  assert.equal(res.status, 201);
  const out = await res.json();
  assert.equal(out.ok, true);
  assert.equal(out.index, 0);
  assert.match(out.filename, /^J1-0-[0-9a-z]+\.jpg$/, "the editor's {orderId}-{index}-{base36 ms} name");
  assert.deepEqual(fs.readFileSync(path.join(photosDir, out.filename)), img, 'the copy on disk is what the encoder made');
  assert.deepEqual(job('J1').printPhotos, [{ thumb: 'data:image/jpeg;base64,VEhVTUI=', filename: out.filename }]);
  assert.deepEqual(sent, [{ channel: 'lan-order-photo-added', payload: { id: 'J1', photo: { thumb: 'data:image/jpeg;base64,VEhVTUI=', filename: out.filename } } }]);

  const second = await (await post(dev, 'J1', jpeg())).json();
  assert.equal(second.index, 1, 'the index is its place in printPhotos');
  assert.equal(job('J1').printPhotos.length, 2);
});

test('a job with no printPhotos yet, and one in any status, takes the photo', async () => {
  const dev = await enrolPhone();
  const res = await post(dev, 'J2', jpeg());
  assert.equal(res.status, 201);
  assert.equal(job('J2').printPhotos.length, 1);
  assert.equal(job('J2').status, 'printing', 'the status is left alone');
});

test('the owner PIN alone, or an API token, is refused: only a paired phone adds photos', async () => {
  const before = JSON.stringify(store.printLog);
  const pinOnly = await fetch(`${BASE}/api/orders/J1/photos`, { method: 'POST', headers: { 'x-khayt-pin': PIN }, body: jpeg() });
  assert.equal(pinOnly.status, 403);
  assert.deepEqual(await pinOnly.json(), { ok: false, reason: 'device-key-required' });
  const token = await fetch(`${BASE}/v1/orders/J1/photos`, { method: 'POST', headers: { authorization: 'Bearer ' + writeToken }, body: jpeg() });
  assert.equal(token.status, 403);
  assert.deepEqual(await token.json(), { ok: false, reason: 'device-key-required' });
  const nobody = await fetch(`${BASE}/api/orders/J1/photos`, { method: 'POST', body: jpeg() });
  assert.equal(nobody.status, 401);
  assert.equal(JSON.stringify(store.printLog), before, 'nothing written');
});

test('the refusals the phone reads: not-found, not-an-image, too-large', async () => {
  const dev = await enrolPhone();
  const files = fs.readdirSync(photosDir).length;
  const before = JSON.stringify(store.printLog);

  const missing = await post(dev, 'NOPE', jpeg());
  assert.equal(missing.status, 404);
  assert.deepEqual(await missing.json(), { ok: false, reason: 'not-found' });

  const text = await post(dev, 'J1', Buffer.from('not a picture'));
  assert.equal(text.status, 415);
  assert.deepEqual(await text.json(), { ok: false, reason: 'not-an-image' });

  const empty = await post(dev, 'J1', Buffer.alloc(0));
  assert.equal(empty.status, 413);
  assert.deepEqual(await empty.json(), { ok: false, reason: 'too-large' });

  const over = await post(dev, 'J1', jpeg(8 * 1048576 + 1));
  assert.equal(over.status, 413);
  assert.equal((await over.json()).reason, 'too-large');

  assert.equal(fs.readdirSync(photosDir).length, files, 'no file left behind');
  assert.equal(JSON.stringify(store.printLog), before, 'and no record');
});

test('a photo at the 8 MB cap is taken', async () => {
  const dev = await enrolPhone();
  const res = await post(dev, 'J2', jpeg(8 * 1048576));
  assert.equal(res.status, 201);
});

test('the window adds the photo to its own copy of the job, once', () => {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/app-boot.js'), 'utf8');
  const at = src.indexOf('onLanOrderPhotoAdded((payload)');
  assert.ok(at > 0, 'app-boot listens for lan-order-photo-added');
  const body = src.slice(at, src.indexOf('\n  }\n', at));
  assert.match(body, /\[\.\.\.photos, \{ thumb: photo\.thumb, filename: photo\.filename \}\]/, 'ADDED to what the job holds, not replaced');
  assert.match(body, /some\(\(p\) => p && p\.filename === photo\.filename\)/, 'a repeat is ignored');
  assert.match(body, /saveAll\(\)/);
  const preload = fs.readFileSync(path.join(ROOT, 'preload.js'), 'utf8');
  assert.match(preload, /onLanOrderPhotoAdded:.*'lan-order-photo-added'/);
});
