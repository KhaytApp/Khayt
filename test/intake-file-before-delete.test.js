/**
 * A quote-form request carries the customer's model file, and deleting the
 * request on Khayt Cloud deletes that file. The desktop must therefore hold the
 * file — downloaded, size and sha256 checked — before it deletes the request,
 * and must leave the request alone when it could not.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const cc = require('../lib/cloud-client.js');

const BYTES = Buffer.from('solid\nfacet normal 0 0 1\nendsolid\n');
const SHA = crypto.createHash('sha256').update(BYTES).digest('hex');

async function withServer(handler, fn) {
  const seen = [];
  const srv = http.createServer((req, res) => { seen.push({ method: req.method, url: req.url, headers: req.headers }); handler(req, res); });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  try { return await fn(`http://127.0.0.1:${srv.address().port}`, seen); }
  finally { await new Promise((r) => srv.close(r)); }
}
const json = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };

test('the kept file comes back as bytes once its size and sha256 match', async () => {
  await withServer((req, res) => { res.writeHead(200, { 'content-type': 'application/octet-stream', 'x-content-sha256': SHA }); res.end(BYTES); },
    async (url, seen) => {
      const r = await cc.downloadIntakeFile(url, 'SHOP', 'tok', 'IN1', { bytes: BYTES.length, sha256: SHA });
      assert.equal(r.gone, false);
      assert.ok(r.bytes.equals(BYTES));
      assert.equal(seen[0].url, '/v1/shops/SHOP/intake/IN1/file');
      assert.equal(seen[0].headers.authorization, 'Bearer tok');
    });
});

test('a file that is not what the customer sent is refused', async () => {
  await withServer((req, res) => { res.writeHead(200); res.end(Buffer.from('something else')); }, async (url) => {
    await assert.rejects(cc.downloadIntakeFile(url, 'S', 't', 'I', { sha256: SHA }), /does not match/);
  });
  await withServer((req, res) => { res.writeHead(200); res.end(BYTES.subarray(0, 5)); }, async (url) => {
    await assert.rejects(cc.downloadIntakeFile(url, 'S', 't', 'I', { bytes: BYTES.length, sha256: SHA }), /incomplete/);
  });
});

test('only a 404 that says the file is gone counts as gone', async () => {
  await withServer((req, res) => json(res, 404, { error: 'This request has no kept file', reason: 'no-file' }), async (url) => {
    assert.deepEqual(await cc.downloadIntakeFile(url, 'S', 't', 'I', { sha256: SHA }), { gone: true });
  });
  // A server where the route is switched off is not evidence the file is gone.
  await withServer((req, res) => json(res, 404, { error: 'Not found', reason: 'no-route' }), async (url) => {
    await assert.rejects(cc.downloadIntakeFile(url, 'S', 't', 'I', { sha256: SHA }), /Not found/);
  });
});

test('deleting a request says this client keeps any file type first (level 2)', async () => {
  await withServer((req, res) => json(res, 200, { ok: true }), async (url, seen) => {
    await cc.deleteIntake(url, 'S', 't', 'I');
    assert.equal(seen[0].method, 'DELETE');
    assert.equal(seen[0].headers['x-intake-file-capable'], '2');
  });
});

// --- the renderer's Import, with the app's globals stubbed -------------------

function stubApp(takeFile) {
  const calls = [];
  global.window = global.window || {};
  global.window.hubAPI = {
    cloudIntakeTakeFile: async (o) => { calls.push(['take', o.id]); return takeFile(o); },
    cloudIntakeDelete: async (o) => { calls.push(['delete', o.id]); return { ok: true }; },
  };
  Object.assign(global, {
    printLog: [], clients: [], settings: {}, saveAll() {}, toast() {}, switchTab() {},
    t: (k) => k, uid: (p) => `${p}-1`, localDateStr: () => '2026-10-29', nextQuoteSeq: () => '0001',
  });
  return calls;
}
const REQ = { id: 'IN1', payload: { title: 'Bracket', name: 'Sara', contact: 'sara@example.com', file: { name: 'bracket.stl', bytes: BYTES.length, sha256: SHA } } };
const CLOUD = { url: 'http://x', shopId: 'S', token: 't' };

test('Import saves the file with the quote, then deletes the request', async () => {
  const calls = stubApp(() => ({ ok: true, gone: false, attached: { filename: 'QUO-2026-0001-a.stl', originalName: 'bracket.stl', size: BYTES.length } }));
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote(REQ, CLOUD), true);
  assert.deepEqual(calls, [['take', 'IN1'], ['delete', 'IN1']]);
  assert.equal(global.printLog.length, 1);
  assert.deepEqual(global.printLog[0].attachedFiles.map((f) => f.originalName), ['bracket.stl']);
});

test('a failed download creates nothing and deletes nothing', async () => {
  const calls = stubApp(() => ({ ok: false, error: 'The model file does not match what the customer sent' }));
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote(REQ, CLOUD), false);
  assert.deepEqual(calls, [['take', 'IN1']]);
  assert.equal(global.printLog.length, 0);
  assert.equal(global.clients.length, 0, 'no customer record is made for a request that stays in the list');
});

test('a file the server no longer holds is noted on the quote', async () => {
  const calls = stubApp(() => ({ ok: true, gone: true }));
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote(REQ, CLOUD), true);
  assert.deepEqual(calls, [['take', 'IN1'], ['delete', 'IN1']]);
  assert.deepEqual(global.printLog[0].attachedFiles, []);
  assert.match(global.printLog[0].notes, /intake\.file_gone_note/);
});

test('the verified instant price the customer saw is noted on the quote, not set as its price', async () => {
  stubApp(() => ({ ok: true, gone: false, attached: { filename: 'f.stl', originalName: 'bracket.stl', size: BYTES.length } }));
  global.t = (k, v) => k + (v ? JSON.stringify(v) : '');
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  const quote = { price: 65.875, currency: 'SAR', qty: 1, grams: 41.6, hours: 3.14, exact: true, reliable: false, fileType: 'stl', verified: true };
  assert.equal(await importIntakeAsQuote({ ...REQ, payload: { ...REQ.payload, quote } }, CLOUD), true);
  const notes = global.printLog[0].notes;
  assert.match(notes, /intake\.instant_quote_note\{"price":"65\.88","currency":"SAR","details":" · 42 g · 3\.1 h"\}intake\.instant_quote_rough/);
  assert.notEqual(global.printLog[0].price, 65.88, 'the customer\'s figure is a note, never the price');
  assert.notEqual(global.printLog[0].price, 65.875);
});

test('an unverified quote is not noted', async () => {
  stubApp(() => ({ ok: true, gone: false, attached: { filename: 'f.stl', originalName: 'bracket.stl', size: BYTES.length } }));
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  assert.equal(await importIntakeAsQuote({ ...REQ, payload: { ...REQ.payload, quote: { price: 1, currency: 'SAR' } } }, CLOUD), true);
  assert.doesNotMatch(global.printLog[0].notes, /instant_quote/);
});

test('a verified quote opens costed at the shop\'s rates from the per-piece grams and hours, priced at cost + default margin', async () => {
  stubApp(() => ({ ok: true, gone: false, attached: { filename: 'f.stl', originalName: 'bracket.stl', size: BYTES.length } }));
  require('../lib/print-rates.js'); require('../lib/calculator-cost.js'); require('../lib/pricing.js');
  Object.assign(global, {
    inventory: [{ id: 'SP1', material: 'PETG', cost: 100, spoolWeight: 1000 }],
    printers: [{ id: 'PR1', wearRate: 1, powerDraw: 0, elecRate: 0, prepTime: 0, postTime: 0, laborRate: 0, failureRate: 0 }],
    settings: { lanApi: { intakeQuote: { filamentId: 'SP1', presetId: 'PR1' } } },
  });
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  const quote = { price: 65.88, currency: 'SAR', qty: 3, grams: 20, hours: 1.5, verified: true };
  assert.equal(await importIntakeAsQuote({ ...REQ, payload: { ...REQ.payload, qty: '3', quote } }, CLOUD), true);
  const o = global.printLog[0];
  assert.equal(o.parts.length, 1);
  const part = o.parts[0];
  assert.equal(part.qty, 3);
  assert.equal(part.printWeight, 20);
  assert.equal(part.printTime, 1.5);
  assert.equal(part.filamentId, 'SP1');
  // per piece: 20 g of a 100/1000 g spool = 2, plus 1.5 h at 1/h wear = 1.5 → 3.5; three pieces → 10.5
  assert.ok(Math.abs(part.baseCost - 10.5) < 1e-9, String(part.baseCost));
  assert.equal(o.material, 'PETG');
  assert.equal(o.printTime, 1.5);
  // Cost + the default 30 % margin, as the Mac prices a quote-form line
  // (PriceRule() with defaultMargin): 10.5 → 13.65. Not the 65.88 shown.
  assert.equal(o.price, 13.65);
  assert.equal(o.quoteSentAt, null);
  assert.equal(o.quoteExpiresAt, null);
});

test('the shop\'s own default margin prices it, and a quote with no part opens at 0', async () => {
  stubApp(() => ({ ok: true, gone: false, attached: { filename: 'f.stl', originalName: 'bracket.stl', size: BYTES.length } }));
  global.settings = { lanApi: { intakeQuote: { filamentId: 'SP1', presetId: 'PR1' } }, defaultMargin: 50 };
  const { importIntakeAsQuote } = require('../renderer/integrations.js');
  const quote = { price: 65.88, currency: 'SAR', qty: 3, grams: 20, hours: 1.5, verified: true };
  assert.equal(await importIntakeAsQuote({ ...REQ, payload: { ...REQ.payload, qty: '3', quote } }, CLOUD), true);
  assert.equal(global.printLog[0].price, 15.75);
  assert.equal(await importIntakeAsQuote({ ...REQ, payload: { ...REQ.payload, quote: { price: 9, grams: 20, hours: 1.5 } } }, CLOUD), true);
  assert.equal(global.printLog[0].price, 0, 'nothing measured, nothing to price');
});

test('an unverified or unmeasured quote adds no part', async () => {
  for (const quote of [{ price: 9, grams: 20, hours: 1.5 }, { price: 9, grams: 0, hours: 1.5, verified: true }, { price: 9, grams: 20, verified: true }]) {
    stubApp(() => ({ ok: true, gone: false, attached: { filename: 'f.stl', originalName: 'bracket.stl', size: BYTES.length } }));
    const { importIntakeAsQuote } = require('../renderer/integrations.js');
    assert.equal(await importIntakeAsQuote({ ...REQ, payload: { ...REQ.payload, quote } }, CLOUD), true);
    assert.deepEqual(global.printLog[0].parts, []);
    assert.equal(global.printLog[0].printTime, 0);
  }
});
