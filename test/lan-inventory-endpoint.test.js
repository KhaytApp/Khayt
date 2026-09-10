/**
 * POST /api/inventory — adding a spool from the phone.
 *
 * This is where a shop actually adds a spool: at the shelf, holding the roll,
 * scanning its NFC tag or photographing its label. The desk is the exception.
 *
 * The endpoint used to compose the record itself — allowlist the body, stamp an
 * id, work out what was left — which was a second, older idea of what a spool
 * is, living in a file nobody edits when the shelf grows a field. It fell
 * behind: `spoolWeight` (what the roll weighed when it arrived, so cost per
 * kilo divides by the size of the spool rather than by whatever is left of it)
 * reached spools added at the desk and never reached one added from the phone.
 *
 * `lib/spool-edit.js` is the shelf's rule and `test/lan-server.test.js` pins
 * what it produces. THIS file exists for the other half — that the endpoint
 * actually calls it. A rule with tests and no caller is this codebase's most
 * repeated bug, so these go over real HTTP into a real store.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3996;   // 3991-3995 are taken by the other LAN endpoint suites
const PIN = '4321';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

let store;
let sent = [];

function freshStore() {
  return {
    inventory: [],
    settings: {}, printLog: [], machines: [], clients: [], waitingList: [],
    wasteLog: [], tombstones: [],
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

const addSpool = (body, opts = {}) => fetch(`${BASE}/api/inventory`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(opts.noPin ? {} : { 'x-khayt-pin': PIN }) },
  body: opts.raw !== undefined ? opts.raw : JSON.stringify(body),
});

/**
 * Exactly what `KhaytAPIClient.addSpool` puts on the wire, from a tag scan.
 * If this drifts, so does the test — which is the point of copying it.
 */
const asThePhoneSendsIt = () => ({
  id: 'spool-1757000000000',
  material: 'PLA',
  brand: 'Prusament',
  color: '#1B2A3C',
  weight: 750,
  weightTotal: 750,
  weightRemaining: 750,
  remaining: 750,
  purchasedAt: '2026-09-07',
  materialType: 'fdm',
  sku: 'PRU-PLA-GB',
  lot: 'L-7',
  printTemp: 215,
  bedTemp: 60,
});

test('a spool scanned at the shelf lands with what it weighed when it arrived', async () => {
  store = freshStore(); sent = [];
  const r = await addSpool(asThePhoneSendsIt());
  assert.equal(r.status, 201);

  assert.equal(store.inventory.length, 1);
  const s = store.inventory[0];
  // The field this endpoint could not produce. Without it the calculator
  // valued this roll's material at cost/1000 g — a 25% under-quote on a 750 g
  // spool — and cost per kilo had nothing to divide by at all.
  assert.equal(s.spoolWeight, 750, 'the arrival weight was not recorded');
  assert.equal(s.weight, 750);
  assert.equal(s.remaining, 750);
});

test('the temperatures and the product code survive the trip', async () => {
  // The companion has a camera and an NFC session largely to read these off
  // the roll. It sent all three; the write allowlist did not name them, so
  // they were dropped in silence.
  store = freshStore();
  await addSpool(asThePhoneSendsIt());
  const s = store.inventory[0];
  assert.equal(s.printTemp, 215);
  assert.equal(s.bedTemp, 60);
  assert.equal(s.sku, 'PRU-PLA-GB');
});

test('the id is the server\'s, not one the caller made up', async () => {
  // The phone stamps a millisecond timestamp. Two phones on one shelf in the
  // same millisecond is unlikely; a caller that repeats an id is not.
  store = freshStore();
  await addSpool(asThePhoneSendsIt());
  assert.notEqual(store.inventory[0].id, 'spool-1757000000000');
  assert.match(store.inventory[0].id, /^spool-\d+-[0-9a-f]{4}$/);
});

test('a spool with no material is refused rather than shelved', async () => {
  // spool-edit's one refusal, now the API's too: a spool with no material
  // cannot be matched to a job.
  store = freshStore();
  const r = await addSpool({ brand: 'Prusament', weight: 1000 });
  assert.equal(r.status, 400);
  assert.equal(store.inventory.length, 0, 'a nameless spool reached the shelf');
});

test('registering a part-used roll keeps the two weights apart', async () => {
  store = freshStore();
  await addSpool({ material: 'PETG', cost: 90, weightTotal: 1000, weightRemaining: 640 });
  const s = store.inventory[0];
  assert.equal(s.spoolWeight, 1000);
  assert.equal(s.weight, 640);
  assert.equal(s.remaining, 640);
});

test('the shelf is tagged with the branch the desk is showing', async () => {
  store = { ...freshStore(), settings: { activeLocationId: 'loc-2' } };
  await addSpool({ material: 'PLA' });
  assert.equal(store.inventory[0].locationId, 'loc-2');
});

test('the desktop is told what arrived', async () => {
  store = freshStore(); sent = [];
  await addSpool(asThePhoneSendsIt());
  const note = sent.find((m) => m.channel === 'lan-spool-added');
  assert.ok(note, 'the renderer was never told to reload the shelf');
  assert.equal(note.payload.spoolWeight, 750, 'told about a spool it cannot cost');
});

test('the shelf is still shut without the owner PIN', async () => {
  store = freshStore();
  const r = await addSpool(asThePhoneSendsIt(), { noPin: true });
  assert.ok(r.status === 401 || r.status === 403, `expected a refusal, got ${r.status}`);
  assert.equal(store.inventory.length, 0);
});

test('the purchase date is the SHOP\'S calendar day, not UTC\'s', async () => {
  // A spool booked in at 02:00 in Riyadh belongs to that day's shelf, not to
  // yesterday's. `toISOString().slice(0, 10)` says yesterday, and this exact
  // mistake shipped across seven sites once already (test/local-dates.test.js).
  store = freshStore();
  await addSpool({ material: 'PLA' });
  const now = new Date();
  const localToday = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  assert.equal(store.inventory[0].purchasedAt, localToday);
});

test('a colour named at the shelf is one the desk offers next time', async () => {
  // `applyEdit` teaches the shop's colour library any variant it has not seen,
  // and the endpoint has to carry that half of the result home: a variant typed
  // at the shelf and not written to settings is one the desk's dropdown has
  // never heard of, so the same roll gets named twice.
  store = { ...freshStore(), settings: { filamentColours: { PLA: ['Galaxy Black'] } } };
  await addSpool({ material: 'PLA', colourVariant: 'Sunset Orange' });
  assert.equal(store.inventory[0].colourVariant, 'Sunset Orange');
  assert.deepEqual(store.settings.filamentColours.PLA, ['Galaxy Black', 'Sunset Orange']);
});

test('a colour the shop already knows is not learnt twice', async () => {
  store = { ...freshStore(), settings: { filamentColours: { PLA: ['Galaxy Black'] } } };
  await addSpool({ material: 'PLA', colourVariant: 'Galaxy Black' });
  assert.deepEqual(store.settings.filamentColours.PLA, ['Galaxy Black']);
});

/* ── PATCH /api/inventory/:id — weighing a roll at the shelf ──────────────── */

const reweigh = (id, grams) => fetch(`${BASE}/api/inventory/${encodeURIComponent(id)}`, {
  method: 'PATCH',
  headers: { 'content-type': 'application/json', 'x-khayt-pin': PIN },
  body: JSON.stringify({ remaining: grams }),   // exactly what updateSpoolRemaining sends
});

test('a roll weighed at the shelf is lighter to the maths too, not just to the shelf', async () => {
  // `weight` is what every deduction subtracts from (lib/order-deduction.js),
  // what the low-stock alert compares, and what the shelf falls back to.
  // `remaining` was the only field this endpoint wrote, so a correction made at
  // the shelf showed on the shelf and nowhere else: the next print took its
  // grams off the number the shop had just replaced.
  store = { ...freshStore(), inventory: [{ id: 's1', material: 'PLA', weight: 1000, spoolWeight: 1000, remaining: 1000 }] };
  const r = await reweigh('s1', 420);
  assert.equal(r.status, 200);
  const s = store.inventory[0];
  assert.equal(s.weight, 420, 'the figure the deduction maths reads was left stale');
  assert.equal(s.remaining, 420);
  assert.equal(s.weightRemaining, 420);
});

test('weighing a roll does not touch what it weighed when it arrived', async () => {
  store = { ...freshStore(), inventory: [{ id: 's1', material: 'PLA', weight: 1000, spoolWeight: 1000 }] };
  await reweigh('s1', 420);
  assert.equal(store.inventory[0].spoolWeight, 1000, 'cost per kilo lost its divisor');
});

test('an empty roll reads as empty, not as untouched', async () => {
  // Zero is a value here: `weight` must become 0, not fall back to the old one.
  store = { ...freshStore(), inventory: [{ id: 's1', material: 'PLA', weight: 90 }] };
  await reweigh('s1', 0);
  assert.equal(store.inventory[0].weight, 0);
  assert.equal(store.inventory[0].remaining, 0);
});

test('a roll cannot hold more than it ever weighed', async () => {
  // The two weights swapped over. Whatever the caller meant, a spool whose
  // arrival weight is under what is left divides every cost per kilo by too
  // small a number, for the rest of that roll's life.
  store = freshStore();
  await addSpool({ material: 'PLA', weightTotal: 640, weightRemaining: 1000 });
  const s = store.inventory[0];
  assert.equal(s.weight, 1000);
  assert.ok(s.spoolWeight >= s.weight, `arrival weight ${s.spoolWeight} is under the ${s.weight} left`);
});
