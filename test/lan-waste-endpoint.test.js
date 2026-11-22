/**
 * POST /api/waste — logging a failed print at the machine.
 *
 * Waste gets recorded where it happens or it does not get recorded at all, and
 * unrecorded waste is exactly the number a shop most needs. The desktop's own
 * waste form is a walk back to the desk holding a failed part.
 *
 * Unlike the quote endpoint this WRITES, so the tests care about three things
 * beyond the happy path: that it cannot be reached without the owner PIN, that
 * the record it writes matches the shape the desktop's own form produces, and
 * that the date is the shop's calendar day rather than UTC's — the bug class
 * this codebase has already shipped once (see test/local-dates.test.js).
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3992;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

let store;
let sent = [];

function freshStore() {
  return {
    wasteLog: [],
    inventory: [{ id: 'f-pla', material: 'PLA', weight: 1000, cost: 100 }],
    settings: {}, printLog: [], machines: [], clients: [], waitingList: [], tombstones: [],
  };
}

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
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    // Capture what the desktop would be told, so the notify path is covered too.
    getMainWindow: () => ({
      isDestroyed: () => false,
      webContents: { send: (channel, payload) => sent.push({ channel, payload }) },
    }),
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

const logWaste = (entry, opts = {}) => fetch(`${BASE}/api/waste`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(opts.noPin ? {} : { 'x-khayt-pin': PIN }) },
  body: opts.raw !== undefined ? opts.raw : JSON.stringify(entry),
});

test('a failed print is recorded with the fields the desktop form produces', async () => {
  store = freshStore(); sent = [];
  const r = await logWaste({
    material: 'PLA', failureType: 'warping', weight: 45, cost: 4.5,
    reason: 'bed adhesion', notes: 'third attempt', machineId: 'm-1',
  });
  assert.equal(r.status, 201);
  const body = await r.json();

  assert.equal(store.wasteLog.length, 1);
  const e = store.wasteLog[0];
  assert.equal(e.material, 'PLA');
  assert.equal(e.failureType, 'warping');
  assert.equal(e.weight, 45);
  assert.equal(e.cost, 4.5);
  assert.equal(e.reason, 'bed adhesion');
  assert.equal(e.machineId, 'm-1');
  assert.ok(e.id, 'every entry needs an id the desktop can dedupe on');
  assert.equal(body.entry.id, e.id, 'the caller is told what was written');
});

test('newest first, matching the desktop\'s own ordering', async () => {
  store = freshStore();
  await logWaste({ material: 'PLA' });
  await logWaste({ material: 'PETG' });
  assert.deepEqual(store.wasteLog.map((w) => w.material), ['PETG', 'PLA']);
});

test('the date is the SHOP\'S calendar day, not UTC\'s', async () => {
  // A failure logged at 01:00 in Riyadh belongs to that day's waste, not
  // yesterday's. This exact mistake shipped across seven sites once already.
  store = freshStore();
  await logWaste({ material: 'PLA' });
  const now = new Date();
  const localToday = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  assert.equal(store.wasteLog[0].date, localToday);
});

test('an unusable entry is refused — material is required', async () => {
  // Mirrors the desktop form, which will not save without one: a waste entry
  // with no material cannot be costed or reconciled against a spool.
  store = freshStore();
  for (const body of [{}, { material: '' }, { material: '   ' }, { weight: 50 }]) {
    const r = await logWaste(body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} should be refused`);
  }
  assert.equal(store.wasteLog.length, 0, 'nothing was written');
});

test('logging waste needs the owner PIN', async () => {
  store = freshStore();
  const r = await logWaste({ material: 'PLA' }, { noPin: true });
  assert.equal(r.status, 401);
  assert.equal(store.wasteLog.length, 0, 'and wrote nothing');
});

test('deducting is opt-in, and takes the grams off the matching spool', async () => {
  store = freshStore();
  await logWaste({ material: 'PLA', weight: 250, deduct: true });
  assert.equal(store.inventory[0].weight, 750);
});

test('without deduct the spool is untouched', async () => {
  // The shop may have already deducted it, or be logging someone else's stock.
  store = freshStore();
  await logWaste({ material: 'PLA', weight: 250 });
  assert.equal(store.inventory[0].weight, 1000);
});

test('a deduction cannot drive a spool negative', async () => {
  store = freshStore();
  await logWaste({ material: 'PLA', weight: 5000, deduct: true });
  assert.equal(store.inventory[0].weight, 0, 'clamped at empty, never below');
});

test('deducting against a material with no spool logs the waste anyway', async () => {
  // Losing the waste record because the spool is gone would be the wrong
  // trade — the entry is the point.
  store = freshStore();
  const r = await logWaste({ material: 'Nylon', weight: 60, deduct: true });
  assert.equal(r.status, 201);
  assert.equal(store.wasteLog.length, 1);
  assert.equal((await r.json()).deducted, null);
});

test('the desktop is told, so an open app does not diverge from disk', async () => {
  store = freshStore(); sent = [];
  await logWaste({ material: 'PLA', weight: 100, deduct: true });
  const msg = sent.find((s) => s.channel === 'lan-waste-logged');
  assert.ok(msg, 'no lan-waste-logged event was sent');
  assert.equal(msg.payload.entry.material, 'PLA');
  assert.deepEqual(msg.payload.deducted, { id: 'f-pla', weight: 900 },
    'the deduction travels too, or the two views disagree until a reload');
});

test('junk and oversized fields are refused or clamped, not stored raw', async () => {
  store = freshStore();
  for (const raw of ['', 'not json', '[]', 'null', '123']) {
    assert.equal((await logWaste(null, { raw })).status, 400, `body ${JSON.stringify(raw)}`);
  }
  const r = await logWaste({ material: 'X'.repeat(9000), reason: 'Y'.repeat(9000), weight: -5 });
  assert.equal(r.status, 201);
  const e = store.wasteLog[0];
  assert.ok(e.material.length <= 200, `material not capped: ${e.material.length}`);
  assert.ok(e.reason.length <= 500, `reason not capped: ${e.reason.length}`);
  assert.equal(e.weight, 0, 'a negative weight is clamped, not stored');
});
