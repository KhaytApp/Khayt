/**
 * POST /api/survey — a customer rating a finished job.
 *
 * The handler wrote the survey to disk, then told the window with
 * `storeData.printLog[idx].id` — names from ANOTHER handler's scope. That threw a
 * ReferenceError after the write: the customer was told it failed (400), and the
 * window never heard, so its copy of the job had no survey and its next save
 * wrote over it. Found in the v3.11.8 pre-release review.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 4011;
const TOKEN = 'printer-token-0123456789';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

let store;
const sent = [];
const win = { isDestroyed: () => false, webContents: { send: (ch, payload) => sent.push({ ch, payload }) } };
// Set by a test to change the book between the handler's read and its write.
let beforeWrite = null;

const freshStore = () => ({
  settings: { lanApi: { webhookToken: TOKEN } },
  machines: [{ id: 'm1', name: 'U1' }],
  printLog: [], inventory: [], clients: [], expenses: [], waitingList: [], wasteLog: [], tombstones: [],
});

before(async () => {
  store = freshStore();
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
    updateStoreOnDisk: async (fn) => {
      if (beforeWrite) { beforeWrite(); beforeWrite = null; }
      store = fn(store);
      return store;
    },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => win,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: '4321', bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
});


test('a survey is saved, the customer is told so, and the window hears which job', async () => {
  store.printLog = [{ id: 'J1', project: 'Vase', status: 'completed', surveyToken: 'tok-0123456789abcdef' }];
  const res = await fetch(`${BASE}/api/survey`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: 'tok-0123456789abcdef', orderId: 'J1', rating: 5, comment: 'lovely' }),
  });
  const body = await res.json();
  assert.equal(res.status, 200, JSON.stringify(body));
  assert.equal(store.printLog[0].survey.rating, 5);
  assert.equal(store.printLog[0].surveyToken, undefined, 'the token is spent');
  const msg = sent.find((m) => m.ch === 'lan-survey-submitted');
  assert.ok(msg, 'the window was told');
  assert.deepEqual(msg.payload, { orderId: 'J1', rating: 5 });
});
