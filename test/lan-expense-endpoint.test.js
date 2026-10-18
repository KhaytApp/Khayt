/**
 * POST /api/expense — capturing a receipt with the phone camera.
 *
 * A receipt is a photograph and the phone is the camera; the desktop's expense
 * form expects a file already sitting on that machine, which a phone photo never
 * is. So this is the first endpoint in the app that accepts BINARY, and most of
 * these tests are about what it refuses rather than what it stores.
 *
 * It writes into a directory the desktop will later hand to shell.openPath, over
 * a server that can be exposed to the internet through the tunnel. A declared
 * content-type or filename is a CLAIM; the first bytes of the file are evidence.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer, sniffReceiptType, receiptFilename } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3993;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

const RECEIPTS = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-receipts-'));
let store;

const JPEG = Buffer.concat([Buffer.from([0xFF, 0xD8, 0xFF, 0xE0]), Buffer.alloc(64, 7)]);
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), Buffer.alloc(64, 7)]);
const PDF = Buffer.concat([Buffer.from('%PDF-1.4'), Buffer.alloc(64, 7)]);

const freshStore = () => ({
  expenses: [], inventory: [], settings: {}, printLog: [], machines: [],
  clients: [], waitingList: [], wasteLog: [], tombstones: [],
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
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    statusPagesDir: path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
    receiptsDir: () => RECEIPTS,
  });
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
  fs.rmSync(RECEIPTS, { recursive: true, force: true });
});

const post = (payload, opts = {}) => fetch(`${BASE}/api/expense`, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(opts.noPin ? {} : { 'x-khayt-pin': PIN }) },
  body: opts.raw !== undefined ? opts.raw : JSON.stringify(payload),
});

const receiptsOnDisk = () => fs.readdirSync(RECEIPTS);

test('an expense with a photographed receipt is stored, and the file lands on disk', async () => {
  store = freshStore();
  const r = await post({ amount: 149.5, category: 'filament', note: 'spool run', receiptBase64: JPEG.toString('base64') });
  assert.equal(r.status, 201);
  const body = await r.json();

  assert.equal(store.expenses.length, 1);
  const e = store.expenses[0];
  assert.equal(e.amount, 149.5);
  assert.equal(e.category, 'filament');
  assert.ok(e.receiptPath, 'the expense points at its receipt');
  assert.ok(fs.existsSync(e.receiptPath), 'and that file exists');
  assert.deepEqual(fs.readFileSync(e.receiptPath), JPEG, 'stored byte for byte');
  assert.equal(body.entry.id, e.id);
});

test('an expense without a receipt is still recorded', async () => {
  store = freshStore();
  const r = await post({ amount: 20, category: 'other' });
  assert.equal(r.status, 201);
  assert.equal(store.expenses[0].receiptPath, null);
});

test('PNG and PDF receipts are accepted too', async () => {
  for (const [name, buf, ext] of [['png', PNG, '.png'], ['pdf', PDF, '.pdf']]) {
    store = freshStore();
    const r = await post({ amount: 10, receiptBase64: buf.toString('base64') });
    assert.equal(r.status, 201, `${name} should be accepted`);
    assert.ok(store.expenses[0].receiptPath.endsWith(ext), `${name} keeps its own extension`);
  }
});

// MARK: - what it refuses

test('a file that is not an image or PDF is refused by its BYTES, not its name', async () => {
  // The whole point. A caller can say anything; the header cannot lie as easily.
  store = freshStore();
  const before = receiptsOnDisk().length;
  const evil = Buffer.from('#!/bin/sh\nrm -rf /\n');
  const r = await post({ amount: 10, receiptBase64: evil.toString('base64'), filename: 'receipt.jpg', contentType: 'image/jpeg' });
  assert.equal(r.status, 415, 'a shell script called receipt.jpg is not a receipt');
  assert.equal(store.expenses.length, 0, 'and no expense was created');
  assert.equal(receiptsOnDisk().length, before, 'and nothing was written to disk');
});

test('an expense with no amount is refused', async () => {
  store = freshStore();
  for (const payload of [{}, { amount: 0 }, { amount: -5 }, { amount: 'abc' }, { category: 'filament' }]) {
    assert.equal((await post(payload)).status, 400, `${JSON.stringify(payload)} should be refused`);
  }
  assert.equal(store.expenses.length, 0);
});

test('recording an expense needs the owner PIN', async () => {
  store = freshStore();
  const before = receiptsOnDisk().length;
  const r = await post({ amount: 10, receiptBase64: JPEG.toString('base64') }, { noPin: true });
  assert.equal(r.status, 401);
  assert.equal(store.expenses.length, 0);
  assert.equal(receiptsOnDisk().length, before, 'an unauthenticated caller cannot write files either');
});

test('an oversized receipt is refused rather than filling the disk', async () => {
  store = freshStore();
  const before = receiptsOnDisk().length;
  const huge = Buffer.concat([Buffer.from([0xFF, 0xD8, 0xFF]), Buffer.alloc(7 * 1024 * 1024, 1)]);

  // Two correct outcomes, and which one happens is a race the client does not
  // control. The server answers 413 and destroys the socket — so depending on
  // timing, either the response arrives, or the remaining megabytes hit a closed
  // pipe and fetch rejects with EPIPE. An earlier version of this test asserted
  // only the first and failed roughly one run in five.
  //
  // The guarantee being tested is not "the client always sees a 413". It is that
  // the upload is refused and NOTHING persists — which holds either way, and is
  // what a shop would care about.
  let status = null;
  try {
    status = (await post({ amount: 10, receiptBase64: huge.toString('base64') })).status;
  } catch (err) {
    assert.match(String(err?.cause?.code || err?.message || err), /EPIPE|ECONNRESET|fetch failed/,
      `expected a torn-down connection, got ${err}`);
  }
  if (status !== null) {
    assert.ok(status === 413 || status === 400, `expected a refusal, got ${status}`);
  }
  assert.equal(store.expenses.length, 0, 'no expense was recorded');
  assert.equal(receiptsOnDisk().length, before, 'and nothing reached the disk');
});

test('a failed receipt write leaves no expense behind', async () => {
  // Otherwise the ledger holds a row pointing at a file that does not exist,
  // and the shop finds out when they click it months later at tax time.
  store = freshStore();
  const r = await post({ amount: 10, receiptBase64: 'not base64 at all !!!' });
  assert.notEqual(r.status, 201);
  assert.equal(store.expenses.length, 0);
});

// MARK: - the filename

test('the stored filename is generated, never taken from the caller', async () => {
  store = freshStore();
  const r = await post({
    amount: 10,
    receiptBase64: JPEG.toString('base64'),
    filename: '../../../../etc/passwd',
  });
  assert.equal(r.status, 201);
  const p = store.expenses[0].receiptPath;
  assert.ok(p.startsWith(RECEIPTS + path.sep), `receipt escaped its directory: ${p}`);
  assert.ok(!p.includes('passwd'), 'the caller-supplied name was not used');
  assert.match(path.basename(p), /^receipt-[a-z0-9]+-[0-9a-f]{8}\.jpg$/);
});

test('two receipts in the same millisecond do not collide', async () => {
  store = freshStore();
  const names = new Set(Array.from({ length: 500 }, () => receiptFilename('jpg')));
  assert.equal(names.size, 500, 'a collision would overwrite someone else\'s receipt');
});

test('the type sniffer reads headers, and rejects everything else', () => {
  assert.equal(sniffReceiptType(JPEG), 'jpg');
  assert.equal(sniffReceiptType(PNG), 'png');
  assert.equal(sniffReceiptType(PDF), 'pdf');
  assert.equal(sniffReceiptType(Buffer.from('GIF89a-not-accepted')), null);
  assert.equal(sniffReceiptType(Buffer.from('<?xml version="1.0"?><svg/>')), null, 'SVG is script-capable');
  assert.equal(sniffReceiptType(Buffer.alloc(0)), null);
  assert.equal(sniffReceiptType(Buffer.from([0xFF, 0xD8])), null, 'a truncated header is not a match');
  assert.equal(sniffReceiptType(null), null);
  assert.equal(sniffReceiptType('a string'), null);
});
