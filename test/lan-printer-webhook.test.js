/**
 * POST /api/webhook/printer/:machineId — a printer moving its own job.
 *
 * The handler used to write the new status by hand, with `printStartedAt` and
 * `printDoneAt`: names nothing else in the app reads. Everything that shows a
 * print's elapsed time or ETA reads `printingStartedAt` and the running
 * `timerStart`, so a job a printer started had neither. It now goes through
 * `KhaytOrderStatus.apply`, the rule a move on the board uses.
 *
 * And the re-check inside the write: its comment promised that a status the
 * shop set on the desktop in between would not be undone by an older machine
 * event, but it re-found the job by id and never looked at the status.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3987;
const TOKEN = 'printer-token-0123456789';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

let store;
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
    getMainWindow: () => null,
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

const fire = (event) => fetch(`${BASE}/api/webhook/printer/m1`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', 'x-khayt-webhook-token': TOKEN },
  body: JSON.stringify({ event }),
});

const job = (status, extra = {}) => ({ id: 'J1', project: 'Bracket', machineId: 'm1', status, ...extra });

test('a print the printer starts has a start time and a running timer', async () => {
  store = { ...freshStore(), printLog: [job('pending')] };
  const r = await fire('print_started');
  assert.equal(r.status, 200);
  const o = store.printLog[0];
  assert.equal(o.status, 'printing');
  assert.ok(o.printingStartedAt, 'printingStartedAt is what every elapsed and ETA figure reads');
  assert.ok(o.timerStart, 'the print timer runs');
  assert.equal(o.printStartedAt, undefined, 'the old name nothing reads is not written');
  assert.deepEqual(o.statusHistory.map(h => h.status), ['printing']);
});

test('a print the printer finishes stops the timer and keeps the first start', async () => {
  store = { ...freshStore(), printLog: [job('printing', { printingStartedAt: '2026-10-01T08:00:00.000Z', timerStart: '2026-10-01T08:00:00.000Z' })] };
  const r = await fire('print_done');
  assert.equal(r.status, 200);
  const o = store.printLog[0];
  assert.equal(o.status, 'post');
  assert.equal(o.timerStart, undefined);
  assert.equal(o.printingStartedAt, '2026-10-01T08:00:00.000Z');
  assert.equal(o.printDoneAt, undefined);
});

test('a status the shop set in between is not undone by the machine event', async () => {
  store = { ...freshStore(), printLog: [job('pending')] };
  // The shop puts the job on hold after the handler picked it, before it writes.
  beforeWrite = () => {
    store = { ...store, printLog: [{ ...store.printLog[0], status: 'on_hold' }] };
  };
  const r = await fire('print_started');
  assert.equal(r.status, 200);
  assert.equal(store.printLog[0].status, 'on_hold');
});

test('a wrong token moves nothing', async () => {
  store = { ...freshStore(), printLog: [job('pending')] };
  const r = await fetch(`${BASE}/api/webhook/printer/m1`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-khayt-webhook-token': 'nope' },
    body: JSON.stringify({ event: 'print_started' }),
  });
  assert.equal(r.status, 401);
  assert.equal(store.printLog[0].status, 'pending');
});
