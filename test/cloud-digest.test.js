'use strict';
/**
 * Khayt Cloud's weekly owner email, as an OPTION beside the desktop's own KPI
 * email (Turki, Nov 5): the Mac's CloudCheckout.digest / setDigest route.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const cc = require('../lib/cloud-client.js');

async function withServer(handler, fn) {
  const seen = [];
  const srv = http.createServer((req, res) => {
    let b = ''; req.on('data', (d) => { b += d; });
    req.on('end', () => { seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, body: b }); handler(req, res, b); });
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  try { return await fn(`http://127.0.0.1:${srv.address().port}`, seen); }
  finally { await new Promise((r) => srv.close(r)); }
}
const json = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };

test('reads the owner\'s choice, the cloud\'s switch and the last week sent', async () => {
  await withServer((req, res) => json(res, 200, { enabled: true, serverEnabled: false, lastSentWeek: '2026-11-01' }), async (url, seen) => {
    assert.deepEqual(await cc.digest(url, 'shop_1', 'tok'), { enabled: true, serverEnabled: false, lastSentWeek: '2026-11-01' });
    assert.equal(seen[0].method, 'GET');
    assert.equal(seen[0].url, '/v1/shops/shop_1/digest');
    assert.equal(seen[0].auth, 'Bearer tok');
  });
});

test('sets it with a PUT of { enabled }', async () => {
  await withServer((req, res, b) => json(res, 200, { enabled: JSON.parse(b).enabled, serverEnabled: true }), async (url, seen) => {
    assert.deepEqual(await cc.setDigest(url, 'shop_1', 'tok', false), { enabled: false, serverEnabled: true, lastSentWeek: null });
    assert.equal(seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(seen[0].body), { enabled: false });
  });
});

test('a refusal or a reply without the choice is an error, not "off"', async () => {
  await withServer((req, res) => json(res, 404, { error: 'Not found' }), async (url) => {
    await assert.rejects(cc.digest(url, 's', 't'), /Not found/);
  });
  await withServer((req, res) => json(res, 200, {}), async (url) => {
    await assert.rejects(cc.digest(url, 's', 't'), /did not say/);
  });
});
