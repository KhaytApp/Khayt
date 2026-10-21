const { test } = require('node:test');
const assert = require('node:assert/strict');
const { resolvePrinterTarget } = require('../lib/main/printer-target.js');

const lookupOf = (answers) => async () => answers.map((address) => ({ address, family: address.includes(':') ? 6 : 4 }));
const failing = async () => { throw Object.assign(new Error('ENOTFOUND'), { code: 'ENOTFOUND' }); };

test('a LAN address is used as it is, with no lookup', async () => {
  const r = await resolvePrinterTarget('192.168.1.40', { lookup: failing });
  assert.deepEqual(r, { ok: true, address: '192.168.1.40', urlHost: '192.168.1.40' });
});

test('a public address or loopback is refused before anything is looked up', async () => {
  for (const h of ['8.8.8.8', '127.0.0.1', '2130706433', '169.254.169.254', 'localhost']) {
    assert.equal((await resolvePrinterTarget(h, { lookup: failing })).ok, false, h);
  }
});

test('a name is connected to by the LAN address it resolves to', async () => {
  const r = await resolvePrinterTarget('octopi.local', { lookup: lookupOf(['192.168.1.50']) });
  assert.deepEqual(r, { ok: true, address: '192.168.1.50', urlHost: '192.168.1.50' });
});

test('a name that resolves off the LAN never gets the key', async () => {
  const r = await resolvePrinterTarget('printer.attacker.example', { lookup: lookupOf(['203.0.113.9']) });
  assert.deepEqual(r, { ok: false, error: 'Printer host is not on this network' });
});

test('one public answer among LAN ones refuses the whole name (rebinding)', async () => {
  const r = await resolvePrinterTarget('rebind.example', { lookup: lookupOf(['192.168.1.50', '203.0.113.9']) });
  assert.equal(r.ok, false);
  assert.equal((await resolvePrinterTarget('loop.example', { lookup: lookupOf(['127.0.0.1']) })).ok, false);
  assert.equal((await resolvePrinterTarget('meta.example', { lookup: lookupOf(['169.254.169.254']) })).ok, false);
});

test('a name that does not resolve says so', async () => {
  assert.deepEqual(await resolvePrinterTarget('gone.local', { lookup: failing }), { ok: false, error: 'Printer host not found' });
});

test('link-local IPv6 with a zone is judged without the zone', async () => {
  const r = await resolvePrinterTarget('bambu.local', { lookup: lookupOf(['fe80::1%en0']) });
  assert.equal(r.ok, true);
});

test('a camera gets the printer key only on the printer\'s own host, at a pinned address', async () => {
  const { cameraRequest } = require('../lib/main/webcam-proxy.js');
  const Webcam = require('../lib/webcam.js');
  const api = { type: 'octoprint', host: '192.168.1.40', port: 80, apiKey: 'K' };
  const same = await cameraRequest(Webcam, 'http://192.168.1.40/webcam/?action=snapshot', api);
  assert.equal(same.ok, true);
  assert.equal(same.headers['X-Api-Key'], 'K');
  const other = await cameraRequest(Webcam, 'http://192.168.1.41/snap.jpg', api);
  assert.equal(other.ok, true);
  assert.deepEqual(other.headers, {}, 'another device on the LAN gets no key');

  const named = { ...api, host: 'octopi.local' };
  const pinned = await cameraRequest(Webcam, 'http://octopi.local:8080/?action=snapshot', named, { lookup: lookupOf(['192.168.1.50']) });
  assert.equal(pinned.url, 'http://192.168.1.50:8080/?action=snapshot');
  assert.equal(pinned.headers['X-Api-Key'], 'K');
  const off = await cameraRequest(Webcam, 'http://octopi.local/snap', named, { lookup: lookupOf(['203.0.113.9']) });
  assert.equal(off.ok, false, 'a camera name that resolves off the LAN is not fetched at all');
});

test('no printer path in main.js falls back to the text-only host check', () => {
  // isAllowedPrinterHost accepts any DNS name. A printer call that checks only
  // that and then sends a key is the bug this module exists to close.
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'main.js'), 'utf8');
  assert.doesNotMatch(src, /isAllowedPrinterHost\(printerHost\)/);
  assert.equal((src.match(/await resolvePrinterTarget\(host\)/g) || []).length, 5,
    'upload, history, command, plate and status each resolve and pin');
});
