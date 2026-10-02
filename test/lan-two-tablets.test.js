'use strict';
/**
 * Two tablets, one store, real HTTP, real disk.
 *
 * The endpoint tests stub the store as a plain variable, so a write is
 * instantaneous and nothing can contend. That is exactly the condition under
 * which this bug is invisible: every LAN endpoint read the in-memory store,
 * changed one key, and wrote the whole thing back, and `onStoreUpdated` only
 * refreshes that copy after the awaited write LANDS. A second request arriving
 * while the first write is in flight read the store as it was BEFORE the first
 * change, and its write — queued behind, so it landed last — put that back.
 *
 * So this harness gives the LAN server the REAL store-io, writing to a real
 * temp directory, and fires two requests at once. On the old code the first
 * order is gone from disk after the server has already answered 201.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
const { createStoreIo } = require(path.join(ROOT, 'lib/store-io.js'));
const { safeJsonParse } = require(path.join(ROOT, 'lib/safe-json.js'));

const PORT = 3990;
const PIN = '4321';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

let dataDir;
let io;
let store;

const freshStore = () => ({
  expenses: [], inventory: [], settings: {}, printLog: [], machines: [],
  clients: [], waitingList: [], wasteLog: [], tombstones: [],
});

before(async () => {
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-two-tablets-'));
  io = createStoreIo({
    app: { getPath: () => dataDir },
    fs,
    safeStorage: { isEncryptionAvailable: () => false },
    safeJsonParse,
    crypto: require('node:crypto'),
    onStoreUpdated: (d) => { store = d; },
    getStore: () => store,
  });
  store = freshStore();
  await io.persistLanStoreUpdate(store);

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
    writeStoreToDisk: io.writeStoreToDisk,
    persistLanStoreUpdate: io.persistLanStoreUpdate,
    updateStoreOnDisk: io.updateStoreOnDisk,
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
    receiptsDir: () => dataDir,
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
  fs.rmSync(dataDir, { recursive: true, force: true });
});

const post = (route, payload) => fetch(`${BASE}${route}`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', 'x-khayt-pin': PIN },
  body: JSON.stringify(payload),
});

/** What actually reached the file, not what the server remembers. */
const onDisk = () => io.recoverStoreRaw().data;

test('two endpoints writing at once: both changes reach the disk', async () => {
  const [a, b] = await Promise.all([
    post('/api/orders', { project: 'Tablet A order', client: 'A', price: 100 }),
    post('/api/expense', { amount: 42, category: 'filament', note: 'Tablet B expense' }),
  ]);
  assert.equal(a.status, 201, await a.text());
  assert.equal(b.status, 201, await b.text());

  const d = onDisk();
  assert.equal((d.printLog || []).length, 1,
    'the order was answered 201 and is not on disk — a concurrent write put the old store back');
  assert.equal((d.expenses || []).length, 1,
    'the expense was answered 201 and is not on disk');
});

test('many orders at once: every one is kept', async () => {
  // The shop floor at the start of a shift. Each response was a promise the
  // order was recorded.
  const N = 12;
  const rs = await Promise.all(Array.from({ length: N }, (_, i) =>
    post('/api/orders', { project: `Burst ${i}`, client: 'floor', price: 10 })));
  for (const r of rs) assert.equal(r.status, 201, await r.text());

  const kept = (onDisk().printLog || []).filter((o) => /^Burst /.test(o.project || ''));
  assert.equal(kept.length, N, `${N - kept.length} of ${N} orders were answered 201 and then lost`);
});
