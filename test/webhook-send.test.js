'use strict';

/**
 * Outgoing webhooks: the signature headers (byte-identical to the Mac, #1712)
 * and the connection, which goes to the address that was checked.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { signatureHeaders, postPinned } = require('../lib/webhook-send.js');

const hex = (k, d) => crypto.createHmac('sha256', k).update(d).digest('hex');

test('V1 is unchanged per transport; V2 signs "<ts>.<body>" in bare hex, as the Mac does', () => {
  // The Mac's own test vector (WebhookSigningTests in #1712).
  const body = '{"event":"order.status","payload":{},"timestamp":1}';
  const h = signatureHeaders('s3cret', body, 1790000000 * 1000 + 999);
  assert.equal(h['X-Khayt-Timestamp'], '1790000000');
  assert.equal(h['X-Khayt-Signature'], hex('s3cret', body), 'the event bus has always sent bare hex');
  assert.equal(h['X-Khayt-Signature-V2'], hex('s3cret', '1790000000.' + body));
  const prefixed = signatureHeaders('s3cret', body, 1790000000 * 1000, { v1Prefix: true });
  assert.equal(prefixed['X-Khayt-Signature'], 'sha256=' + hex('s3cret', body), 'the event webhook has always sent sha256=');
  assert.equal(prefixed['X-Khayt-Signature-V2'], h['X-Khayt-Signature-V2'], 'V2 is the same on both');
  assert.deepEqual(signatureHeaders('', body, 0), {}, 'no secret, no signature headers at all');
});

/** A stand-in for https.request that records what it was asked and answers `status`. */
function fakeRequest(status, seen) {
  return (opts, onRes) => {
    seen.opts = opts;
    const req = new EventEmitter();
    req.destroy = () => {};
    req.end = (payload) => {
      seen.body = payload.toString();
      opts.lookup(opts.hostname, {}, (err, address) => { seen.connectedTo = address; });
      opts.lookup(opts.hostname, { all: true }, (err, list) => { seen.connectedToAll = list; });
      const res = new EventEmitter();
      res.statusCode = status;
      onRes(res);
      res.emit('data', Buffer.from('ok'));
      res.emit('end');
    };
    return req;
  };
}

test('it connects to the address it checked, with the typed name for TLS', async () => {
  const seen = {};
  const r = await postPinned('https://hooks.example.com/x?y=1', { headers: { a: '1' }, body: '{}' }, {
    lookupAll: async () => [{ address: '93.184.216.34', family: 4 }],
    request: fakeRequest(200, seen),
  });
  assert.equal(r.ok, true);
  assert.equal(seen.connectedTo, '93.184.216.34');
  assert.equal(seen.connectedToAll[0].address, '93.184.216.34');
  assert.equal(seen.opts.servername, 'hooks.example.com', 'the certificate is checked against the typed name');
  assert.equal(seen.opts.hostname, 'hooks.example.com', 'and so is the Host header');
  assert.equal(seen.opts.path, '/x?y=1');
  assert.equal(seen.body, '{}');
});

test('a name with any private answer is refused before connecting (DNS rebinding)', async () => {
  const seen = {};
  const r = await postPinned('https://rebind.example.com/', { body: '{}' }, {
    lookupAll: async () => [{ address: '93.184.216.34', family: 4 }, { address: '10.0.0.5', family: 4 }],
    request: fakeRequest(200, seen),
  });
  assert.equal(r.ok, false);
  assert.match(r.error, /private\/loopback/);
  assert.equal(seen.opts, undefined, 'nothing was opened');
  const unresolved = await postPinned('https://nowhere.example/', {}, { lookupAll: async () => { throw new Error('ENOTFOUND'); }, request: fakeRequest(200, {}) });
  assert.equal(unresolved.ok, false, 'an answer that cannot be checked is not sent to');
  const literal = await postPinned('https://127.0.0.1/', {}, { request: fakeRequest(200, {}) });
  assert.match(literal.error, /private\/loopback/);
});

test('a redirect is refused, and plain http never sent to', async () => {
  const r = await postPinned('https://hooks.example.com/', {}, { lookupAll: async () => [{ address: '93.184.216.34', family: 4 }], request: fakeRequest(302, {}) });
  assert.equal(r.ok, false);
  assert.equal(r.error, 'Webhook redirects are not allowed');
  const seen = {};
  const plain = await postPinned('http://hooks.example.com/', {}, { lookupAll: async () => [{ address: '93.184.216.34', family: 4 }], request: fakeRequest(200, seen) });
  assert.equal(plain.ok, false);
  assert.equal(seen.opts, undefined, 'nothing was opened');
});

test('accounting sync is https only: its secret travels in a header', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'main.js'), 'utf8');
  const at = src.indexOf("ipcMain.handle('hub:accounting-push'");
  const body = src.slice(at, src.indexOf('\n});\n', at));
  assert.match(body, /\^https:/);
  assert.doesNotMatch(body, /allowHttp|https\?/);
});

test('every outgoing webhook in main.js goes through the pinned sender', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'main.js'), 'utf8');
  for (const h of ["'hub:webhook-post'", "'hub:fire-webhook'", "'hub:accounting-push'"]) {
    const at = src.indexOf(`ipcMain.handle(${h}`);
    const body = src.slice(at, src.indexOf('\n});\n', at));
    assert.match(body, /webhookSend\.postPinned\(/, h);
    assert.doesNotMatch(body, /\bfetch\(/, `${h} must not resolve the name again`);
  }
});
