/**
 * The LAN identity proof (lib/lan-identity.js): a paired phone checks that the
 * server answering to the shop's Bonjour name holds this computer's key before
 * it sends the PIN. Same two routes and the same bytes as the Mac's (#1942).
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
const { createLanIdentity, verifyProof } = require(path.join(ROOT, 'lib/lan-identity.js'));

const PORT = 3983;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const noop = () => {};
let tmp, handlers;
const nonce = () => crypto.randomBytes(16).toString('hex');
// A stand-in keychain: reversible, and visibly not the PEM.
const seal = (s) => Buffer.from(Buffer.from(s, 'utf8').map((b) => b ^ 0x5a));
const unseal = (b) => Buffer.from(b.map((x) => x ^ 0x5a)).toString('utf8');

before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-lan-id-'));
  handlers = new Map();
  let store = { printLog: [], inventory: [], machines: [], clients: [], settings: { lanApi: { intakeToken: 'tok' } } };
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
    lanIdentity: createLanIdentity({ fs, keyPath: path.join(tmp, 'id.key'), seal, unseal }),
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, JSON.stringify(r));
});
after(async () => {
  await handlers.get('hub:stop-lan-server')?.(null, {});
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('the public key is behind the PIN', async () => {
  assert.equal((await fetch(`${BASE}/api/identity`)).status, 401);
  const res = await fetch(`${BASE}/api/identity`, { headers: { 'x-khayt-pin': PIN } });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.alg, 'ed25519');
  assert.equal(Buffer.from(body.publicKey, 'base64').length, 32);
});

test('the proof is open, and verifies against that key', async () => {
  const { publicKey } = await (await fetch(`${BASE}/api/identity`, { headers: { 'x-khayt-pin': PIN } })).json();
  const n = nonce().toUpperCase();
  const res = await fetch(`${BASE}/api/proof?nonce=${n}`);
  assert.equal(res.status, 200);
  const { alg, sig } = await res.json();
  assert.equal(alg, 'ed25519');
  assert.equal(verifyProof(publicKey, n, sig), true, 'signed over the lower-cased nonce');
  assert.equal(verifyProof(publicKey, nonce(), sig), false, 'not over another nonce');
});

test('the signed bytes are exactly "khayt-proof:" + the lower-case nonce', async () => {
  const { publicKey } = await (await fetch(`${BASE}/api/identity`, { headers: { 'x-khayt-pin': PIN } })).json();
  const n = 'ABCDEF0123456789ABCDEF0123456789';
  const { sig } = await (await fetch(`${BASE}/api/proof?nonce=${n}`)).json();
  const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(publicKey, 'base64')]), format: 'der', type: 'spki' });
  assert.equal(crypto.verify(null, Buffer.from('khayt-proof:abcdef0123456789abcdef0123456789', 'ascii'), key, Buffer.from(sig, 'base64')), true);
});

test('a nonce that is not 32–128 hex characters is refused', async () => {
  for (const n of ['', 'abc', 'z'.repeat(32), 'a'.repeat(31), 'a'.repeat(129)]) {
    const res = await fetch(`${BASE}/api/proof?nonce=${n}`);
    assert.equal(res.status, 400, JSON.stringify(n));
    assert.deepEqual(await res.json(), { error: 'nonce' });
  }
});

test('the key is made once, kept sealed, and the same after a restart', () => {
  const keyPath = path.join(tmp, 'restart.key');
  const a = createLanIdentity({ fs, keyPath, seal, unseal }).identity().publicKey;
  const onDisk = fs.readFileSync(keyPath, 'utf8');
  assert.match(onDisk, /^khayt-sealed:/);
  assert.doesNotMatch(onDisk, /PRIVATE KEY/);
  assert.equal((fs.statSync(keyPath).mode & 0o777).toString(8), '600');
  assert.equal(createLanIdentity({ fs, keyPath, seal, unseal }).identity().publicKey, a);
});

test('a key that cannot be opened for a moment is not replaced', () => {
  const keyPath = path.join(tmp, 'locked.key');
  const a = createLanIdentity({ fs, keyPath, seal, unseal }).identity().publicKey;
  const before = fs.readFileSync(keyPath, 'utf8');
  assert.throws(() => createLanIdentity({ fs, keyPath, seal, unseal: () => { throw new Error('keychain locked'); } }).identity());
  assert.equal(fs.readFileSync(keyPath, 'utf8'), before, 'the key on disk is untouched');
  assert.equal(createLanIdentity({ fs, keyPath, seal, unseal }).identity().publicKey, a);
});

test('with no keychain the key is still owner-only', () => {
  const keyPath = path.join(tmp, 'plain.key');
  createLanIdentity({ fs, keyPath, seal: () => null, unseal }).identity();
  assert.equal((fs.statSync(keyPath).mode & 0o777).toString(8), '600');
});

test('the open route never takes the PIN into its answer', () => {
  // The rule the Mac lane named: no HMAC keyed by the PIN on an open route.
  const code = fs.readFileSync(path.join(ROOT, 'lib/lan-identity.js'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  assert.doesNotMatch(code, /createHmac|\bpin\b/i);
});
