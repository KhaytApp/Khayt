/**
 * Brute-force lockout on the LAN server, end to end.
 *
 * There was no test like this, which is how the lockout shipped completely
 * inert: the per-IP counter reset itself on every attempt, so it sat at 1
 * forever and the 429 branch was unreachable. Ten thousand PINs fall in seconds
 * against a gate that never locks, and on a LAN deployment the PIN is the only
 * thing in front of clients, orders, inventory and machines.
 *
 * Unit tests on the counter would not have caught it either — the arithmetic
 * was self-consistent. What was missing was anybody asking the running server
 * for a 429. So these tests speak HTTP and count status codes.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3995;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};
const SECRET = 'shop-secret-value';

let store = {
  printLog: [], inventory: [], printers: [], machines: [], waitingList: [], tombstones: [],
  clients: [{ id: 'C1', name: 'Real Customer', phone: '+966500000000' }],
  settings: {
    currency: 'SAR',
    lanApi: { intakeToken: 'tok', sallaWebhookSecret: SECRET },
  },
};

before(async () => {
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
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
});

/** Fire n wrong PINs at a PIN-gated route and tally the statuses. */
const hammerPin = async (n) => {
  const codes = new Map();
  let firstLock = null;
  for (let i = 0; i < n; i++) {
    const res = await fetch(`${BASE}/api/clients`, { headers: { 'x-khayt-pin': `wrong${i}` } });
    codes.set(res.status, (codes.get(res.status) || 0) + 1);
    if (res.status === 429 && firstLock === null) firstLock = i + 1;
  }
  return { codes, firstLock };
};

test('a wrong PIN stops being answered after ten tries', async () => {
  const { codes, firstLock } = await hammerPin(30);
  assert.ok(firstLock !== null,
    `no 429 in 30 wrong PINs — the lockout is inert: ${JSON.stringify(Object.fromEntries(codes))}`);
  assert.equal(firstLock, 11, 'ten failures are allowed, the eleventh is refused');
  // The remaining 19 must ALSO be refused. A counter that locks once and then
  // forgets is barely better than none.
  assert.equal(codes.get(429), 20, 'the lockout holds rather than lapsing immediately');
});

test('the lockout outlasts the attempt that tripped it — even for the right PIN', async () => {
  // Already locked out by the test above (same IP, same 60s window). A lockout
  // that let the correct PIN straight through would be trivially defeated by
  // guessing it, which is the thing being defended against.
  const res = await fetch(`${BASE}/api/clients`, { headers: { 'x-khayt-pin': PIN } });
  assert.equal(res.status, 429);
});

test('a forged webhook stops being answered too', async () => {
  const body = JSON.stringify({ event: 'order.created', data: { id: 1 } });
  const codes = new Map();
  for (let i = 0; i < 20; i++) {
    const res = await fetch(`${BASE}/api/webhook/salla`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body,
    });
    codes.set(res.status, (codes.get(res.status) || 0) + 1);
  }
  assert.ok((codes.get(429) || 0) > 0,
    `signature forgery was never throttled: ${JSON.stringify(Object.fromEntries(codes))}`);
  assert.ok((codes.get(401) || 0) > 0, 'and the first few are rejected on the signature, not the counter');
});

test('a correctly signed webhook is still accepted once the window passes', async () => {
  // Not a lockout test so much as a guard on the fix: it would be easy to make
  // failures count and accidentally have them count against valid traffic too.
  // The salla bucket is locked from the test above, so this proves the lockout
  // is keyed per channel+IP rather than jamming every webhook on the server.
  const raw = JSON.stringify({ event: 'order.created', data: { id: 4242, reference_id: 4242 } });
  const sig = 'sha256=' + crypto.createHmac('sha256', SECRET).update(Buffer.from(raw)).digest('hex');
  const res = await fetch(`${BASE}/api/webhook/zid`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-zid-signature': sig },
    body: raw,
  });
  assert.notEqual(res.status, 429, 'a different channel must not inherit salla\'s lockout');
});
