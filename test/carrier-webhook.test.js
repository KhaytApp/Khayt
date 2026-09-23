/**
 * `lib/carrier-webhook.js` — what a signed SMSA, Aramex or SPL status update
 * does to the book — and the Node route that runs it, over real HTTP.
 *
 * The rule was lifted out of `lib/lan-server.js` so the Mac's LAN server can
 * run it. Nothing had ever sent that route a request: the only coverage was the
 * payload parser in `carriers.test.js`. So the second half of this file drives
 * a signed delivery into the real handler and reads the book back, which is
 * what proves the lift changed nothing a carrier can see.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const W = require('../lib/carrier-webhook.js');

const AT = '2026-09-23T09:00:00.000Z';

const book = () => ({
  printLog: [
    { id: 'J-1', status: 'completed', trackingNumber: 'SM123', shippingStatus: 'label_created',
      shippingHistory: [{ status: 'label_created', at: '2026-09-22T10:00:00.000Z', source: 'manual', note: '' }], rev: 3 },
    { id: 'J-2', status: 'completed', trackingNumber: 'SM999', shippingStatus: 'delivered', deliveredAt: '2026-09-20T00:00:00.000Z' },
    { id: 'J-3', status: 'printing' },
  ],
});

/* ── the rule ───────────────────────────────────────────────────────────── */

test('an event is read from what the carrier sends, or not at all', () => {
  const evt = W.read('smsa', { awb: 'SM123', status: 'in transit' });
  assert.equal(evt.trackingNumber, 'SM123');
  assert.equal(evt.shippingStatus, 'in_transit');
  assert.equal(W.read('smsa', { awb: 'SM123' }), null, 'no status is no event');
  assert.equal(W.read('smsa', { status: 'delivered' }), null, 'no tracking number is no event');
  assert.equal(W.read('manual', { awb: 'SM123', status: 'delivered' }), null, 'the manual carrier sends nothing');
  assert.equal(W.read('fedex', { awb: 'SM123', status: 'delivered' }), null, 'a carrier this does not know is not guessed at');
});

test('a parcel that moved forward gains a line of trail, and a finished job is stamped', () => {
  const cur = book();
  const r = W.apply(cur, { trackingNumber: 'SM123', shippingStatus: 'delivered' }, AT);
  assert.equal(r.outcome, 'advanced');
  assert.equal(r.store.printLog[0], r.order);
  assert.equal(r.order.shippingStatus, 'delivered');
  assert.deepEqual(r.order.shippingHistory.at(-1), { status: 'delivered', at: AT, source: 'webhook', note: '' });
  assert.equal(r.order.shippingHistory.length, 2, 'the manual line was lost');
  assert.equal(r.order.deliveredAt, AT);
  // A parcel delivered was a parcel sent: `stampFromShipping` counts delivered
  // as in the post, so a job whose shipment was never marked gets both dates.
  assert.equal(r.order.shippedAt, AT);
  assert.equal(r.order.status, 'completed', 'delivered is a date stamp on a job that stays completed');
  assert.equal(cur.printLog[0].shippingStatus, 'label_created', 'the book it was handed was changed in place');
});

test('an event that arrived out of order changes nothing', () => {
  const cur = book();
  const r = W.apply(cur, { trackingNumber: 'SM999', shippingStatus: 'in_transit' }, AT);
  assert.equal(r.outcome, 'unchanged');
  assert.equal(r.store, cur);
  assert.equal(r.order, null);
});

test('a tracking number the shop does not hold changes nothing', () => {
  const cur = book();
  const r = W.apply(cur, { trackingNumber: 'NOPE', shippingStatus: 'delivered' }, AT);
  assert.equal(r.outcome, 'unknown');
  assert.equal(r.store, cur);
});

test('a number stored as a number is still found', () => {
  const cur = { printLog: [{ id: 'J', status: 'completed', trackingNumber: 12345, shippingStatus: 'label_created' }] };
  assert.equal(W.apply(cur, { trackingNumber: '12345', shippingStatus: 'in_transit' }, AT).outcome, 'advanced');
});

test('the module reaches its dependencies without require, as JavaScriptCore loads it', () => {
  const vm = require('node:vm');
  const ctx = { console };
  vm.createContext(ctx);
  // order-status reads assembly and the lead-time helpers when present; the
  // Mac loads it after them, but stampFromShipping needs none of them.
  for (const m of ['carriers', 'order-status', 'carrier-webhook']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', `${m}.js`), 'utf8'), ctx);
  }
  const r = vm.runInContext(
    `KhaytCarrierWebhook.apply(${JSON.stringify(book())},
       KhaytCarrierWebhook.read('smsa', { awb: 'SM123', status: 'delivered' }), ${JSON.stringify(AT)})`, ctx);
  assert.equal(r.outcome, 'advanced');
  assert.equal(r.order.deliveredAt, AT);
});

/* ── the Node route, over HTTP ─────────────────────────────────────────── */

const ROOT = path.join(__dirname, '..');
const PORT = 3989;
const BASE = `http://127.0.0.1:${PORT}`;
const SECRET = 'smsa-secret';
const handlers = new Map();
const noop = () => {};
let store = null;
let writes = 0;

before(async () => {
  store = { ...book(), inventory: [], printers: [], machines: [], clients: [], waitingList: [], tombstones: [],
            settings: { currency: 'SAR', lanApi: {}, shipping: { smsa: { enabled: true, webhookSecret: SECRET } } } };
  const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));
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
    updateStoreOnDisk: async (fn) => { writes += 1; store = fn(store); return store; },
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

async function send(body, secret = SECRET) {
  const raw = JSON.stringify(body);
  const sig = 'sha256=' + crypto.createHmac('sha256', secret).update(Buffer.from(raw, 'utf8')).digest('hex');
  const r = await fetch(`${BASE}/api/webhook/smsa`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-khayt-signature': sig }, body: raw,
  });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}
const job = (id) => store.printLog.find((o) => o.id === id);

test('the route: a signed event moves the parcel on, once', async () => {
  const before = writes;
  const r = await send({ awb: 'SM123', status: 'out for delivery' });
  assert.equal(r.status, 200);
  assert.equal(job('J-1').shippingStatus, 'out_for_delivery');
  assert.equal(job('J-1').shippingHistory.at(-1).source, 'webhook');
  assert.equal(writes, before + 1);
});

test('the route: nothing to change is not written', async () => {
  const before = writes;
  assert.equal((await send({ awb: 'SM999', status: 'in transit', n: 1 })).status, 200, 'out of order');
  assert.equal((await send({ awb: 'NOPE', status: 'delivered' })).status, 200, 'unknown parcel keeps its 200');
  assert.equal(writes, before, 'an event that changed nothing still wrote the whole book');
});

test('the route: an unreadable payload is 422, a bad signature 401', async () => {
  const unreadable = await send({ hello: 'world' });
  assert.equal(unreadable.status, 422);
  assert.equal(unreadable.body.carrier, 'smsa');
  assert.equal((await send({ awb: 'SM123', status: 'delivered' }, 'wrong')).status, 401);
});
