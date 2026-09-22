/**
 * An online order for something already printed comes OFF THE SHELF.
 *
 * `settings.storefront.stockQty` is the count of finished items the storefront
 * publishes and sells against. Until this, one screen in the whole app wrote
 * it — a person typing a number — and nothing anywhere took one off. So a shop
 * that printed twelve, listed twelve and sold four went on publishing twelve,
 * and the next publish put the four that were gone back on sale.
 *
 * The arithmetic is `lib/shelf-sale.js` and is tested there. This is about the
 * WIRING: a real Salla webhook, signed, over HTTP, into the real handler, and
 * then the shop's book read back off the other side. Delete the
 * `takeOnlineOrderOffTheShelf` call in `lib/lan-server.js` and every assertion
 * below about a count still fails.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3998;   // 3991-3997 are taken by the other LAN suites
const BASE = `http://127.0.0.1:${PORT}`;
const SECRET = 'salla-secret';
const handlers = new Map();
const noop = () => {};

const baseStore = () => ({
  inventory: [], printers: [], printLog: [], machines: [], clients: [],
  waitingList: [], tombstones: [],
  products: [
    { id: 'PRD-A', nameEn: 'Flexi Dragon', nameAr: 'تنين مرن' },
    { id: 'PRD-B', nameEn: 'Falcon hood', nameAr: 'غطاء الصقر' },
  ],
  settings: {
    currency: 'SAR',
    lanApi: { intakeToken: 'tok', sallaWebhookSecret: SECRET, zidWebhookSecret: SECRET },
    storefront: {
      stockQty: { 'PRD-A': 12, 'PRD-B': 4 },
      stockCountedAt: { 'PRD-A': '2026-09-01T00:00:00Z', 'PRD-B': '2026-09-01T00:00:00Z' },
    },
  },
});

let store = baseStore();
/** Nil until the last test, which is the one that watches what the shop is told. */
let mainWindow = null;
const sentToTheApp = [];

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
    getMainWindow: () => mainWindow,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
  });
  const r = await handlers.get('hub:start-lan-server')(
    null, { port: PORT, pin: '4321', bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
});

/** A Salla order, signed the way Salla signs one. */
async function sallaOrder(ref, items, nonce) {
  const body = JSON.stringify({
    event: 'order.created',
    data: {
      reference_id: ref,
      customer: { first_name: 'Nora', last_name: 'A' },
      amounts: { total: { amount: 380, currency: 'SAR' } },
      items,
      ...(nonce ? { source_details: nonce } : {}),
    },
  });
  const sig = 'sha256=' + crypto.createHmac('sha256', SECRET).update(Buffer.from(body, 'utf8')).digest('hex');
  const r = await fetch(`${BASE}/api/webhook/salla`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-salla-signature': sig },
    body,
  });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}

const shelf = () => store.settings.storefront.stockQty;
const counted = () => store.settings.storefront.stockCountedAt;
const newest = () => store.printLog[0];

test('a sale the shelf answers in full takes the items off it and is already done', async () => {
  const r = await sallaOrder('SL-1', [{ name: 'Flexi Dragon', quantity: 2 }]);
  assert.equal(r.status, 200);
  assert.equal(shelf()['PRD-A'], 10, 'twelve dragons were sold two and the shop still publishes twelve');
  assert.equal(newest().fromStock, true);
  assert.equal(newest().status, 'completed',
    'a shelf sale under Pending is a job somebody goes looking for a printer to start');
  assert.equal(newest().shelfTaken, 2);
  assert.notEqual(counted()['PRD-A'], '2026-09-01T00:00:00Z',
    'the count moved and the date it was taken did not');
});

test('a sale the shelf answers in part still corrects the count, and still has work in it', async () => {
  const before = shelf()['PRD-B'];
  assert.equal(before, 4);
  const r = await sallaOrder('SL-2', [{ name: 'Falcon hood', quantity: 6 }]);
  assert.equal(r.status, 200);
  assert.equal(shelf()['PRD-B'], 0);
  assert.equal(newest().shelfTaken, 4);
  assert.equal(newest().status, 'pending', 'two still have to be printed');
  assert.ok(!newest().fromStock, 'an order with printing left in it is not a shelf sale');
  assert.match(newest().notes, /4 off the shelf, 2 to print/);
});

test('an order for something the shop does not stock leaves every shelf alone', async () => {
  const was = { ...shelf() };
  const r = await sallaOrder('SL-3', [{ name: 'A Benchy', quantity: 1 }]);
  assert.equal(r.status, 200);
  assert.deepEqual(shelf(), was, 'an unrecognised line took something off a shelf');
  assert.equal(newest().status, 'pending');
  assert.equal(newest().shelfTaken, undefined);
});

/*
 * Providers RETRY, and a retry is byte-identical. The duplicate check already
 * stopped a second ORDER being written; a deduction made outside it would have
 * taken the same items off the shelf again on every delivery — a number a
 * customer can see, moving on its own.
 */
test('a retried delivery does not take the same items off the shelf twice', async () => {
  store.settings.storefront.stockQty['PRD-A'] = 5;
  const items = [{ name: 'Flexi Dragon', quantity: 3 }];
  await sallaOrder('SL-9', items);
  assert.equal(shelf()['PRD-A'], 2);

  // Byte-identical, which is how a provider actually retries. The signature
  // cache answers this one.
  await sallaOrder('SL-9', items);
  assert.equal(shelf()['PRD-A'], 2, 'the retry sold three more dragons off a shelf holding two');

  // And the case the signature cache CANNOT answer: the same order, delivered
  // again after a restart, an eviction or ten minutes — a different body, so a
  // different signature, and only the platform's own reference says it is the
  // same order. That check lives inside the write chain, which is where the
  // shelf is now read and written too.
  const again = await sallaOrder('SL-9', items, 'retry-after-restart');
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(shelf()['PRD-A'], 2, 'a re-signed retry emptied the shelf a second time');
});

test('the shop is told what was actually written, not what was drafted', async () => {
  // `lan-order-updated` carried `newOrder` — the draft built before the write
  // chain ran — so the desktop's queue would be told 'pending' about an order
  // the book records as completed off the shelf.
  mainWindow = { isDestroyed: () => false,
                 webContents: { send: (_c, o) => sentToTheApp.push(o) } };
  store.settings.storefront.stockQty['PRD-A'] = 4;
  await sallaOrder('SL-11', [{ name: 'Flexi Dragon', quantity: 1 }]);
  assert.equal(sentToTheApp.length, 1);
  assert.equal(sentToTheApp[0].status, 'completed');
  assert.equal(sentToTheApp[0].fromStock, true);
  assert.equal(sentToTheApp[0].shelfTaken, 1);
});
