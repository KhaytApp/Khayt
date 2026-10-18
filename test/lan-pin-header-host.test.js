/**
 * The LAN server's owner gate, caught up with the Mac's (LanServer.swift):
 *
 *  - the PIN is the `x-khayt-pin` header and nothing else on every API route;
 *    `?pin=` is ignored, because it put the PIN in the address of every link,
 *    in clear over plain HTTP;
 *  - the queue page trades a PIN (its old `/?pin=` bookmark, or its form's
 *    body) ONCE for a session cookie and sends the browser to a clean address;
 *  - a Host header that is somebody's domain is refused (421): DNS rebinding;
 *  - a PIN shorter than eight characters opens nothing until the shop sets a
 *    new one.
 *
 * Spoken over HTTP, like the lockout test: a gate is only as good as what the
 * running server answers.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3984;
const PIN = '43218765';
const BASE = `http://127.0.0.1:${PORT}`;
const noop = () => {};

function start(port, pin) {
  const handlers = new Map();
  let store = {
    printLog: [], inventory: [], printers: [], machines: [], waitingList: [], tombstones: [],
    clients: [{ id: 'C1', name: 'Real Customer', phone: '+966500000000' }],
    settings: { currency: 'SAR', lanApi: { intakeToken: 'tok' } },
  };
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
  });
  return handlers;
}

let handlers;
before(async () => {
  handlers = start(PORT, PIN);
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});
after(async () => { await handlers.get('hub:stop-lan-server')?.(null, {}); });

/** fetch() will not send a Host of our choosing; http.request will. */
function raw(pathname, { method = 'GET', headers = {}, body, port = PORT } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: pathname, method, headers }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: data }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

test('the header opens an API route', async () => {
  const res = await fetch(`${BASE}/api/clients`, { headers: { 'x-khayt-pin': PIN } });
  assert.equal(res.status, 200);
});

test('the right PIN in the address opens nothing on an API route, read or write', async () => {
  assert.equal((await fetch(`${BASE}/api/clients?pin=${PIN}`)).status, 401);
  const w = await fetch(`${BASE}/api/orders?pin=${PIN}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
  assert.equal(w.status, 401);
});

test('somebody else\'s domain is refused before the PIN is even read (DNS rebinding)', async () => {
  for (const host of ['evil.example', `evil.example:${PORT}`, '192.168.1.5.evil.example']) {
    const r = await raw('/api/clients', { headers: { host, 'x-khayt-pin': PIN } });
    assert.equal(r.status, 421, host);
  }
  for (const host of [`127.0.0.1:${PORT}`, `localhost:${PORT}`, 'shop-mac.local', `[::1]:${PORT}`]) {
    const r = await raw('/api/clients', { headers: { host, 'x-khayt-pin': PIN } });
    assert.equal(r.status, 200, host);
  }
});

test('the queue page with no PIN asks for one, in a form that posts it', async () => {
  const res = await fetch(`${BASE}/`, { redirect: 'manual' });
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.match(html, /<form method="post" action="\/session">/);
  assert.doesNotMatch(html, /Real Customer/);
});

test('an old /?pin= bookmark is traded once for a cookie and a clean address', async () => {
  const res = await fetch(`${BASE}/?pin=${PIN}`, { redirect: 'manual' });
  assert.equal(res.status, 303);
  assert.equal(res.headers.get('location'), '/');
  const cookie = res.headers.get('set-cookie') || '';
  assert.match(cookie, /^khayt_lan=[0-9a-f]{64}; Path=\/; HttpOnly; SameSite=Strict; Max-Age=43200$/);
  const page = await fetch(`${BASE}/`, { headers: { cookie: cookie.split(';')[0] } });
  assert.equal(page.status, 200);
  assert.doesNotMatch(await page.text(), /action="\/session"/, 'the session should open the queue, not the form');
});

test('a wrong bookmark is refused and sets no cookie', async () => {
  const res = await fetch(`${BASE}/?pin=wrong-pin-1`, { redirect: 'manual' });
  assert.equal(res.status, 401);
  assert.equal(res.headers.get('set-cookie'), null);
});

test('the form: a wrong PIN gets the form back, the right one a session', async () => {
  const form = (pin) => fetch(`${BASE}/session`, {
    method: 'POST', redirect: 'manual',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ pin }).toString(),
  });
  const wrong = await form('nope-nope');
  assert.equal(wrong.status, 401);
  assert.match(await wrong.text(), /border-color:#f87171/);
  const right = await form(PIN);
  assert.equal(right.status, 303);
  assert.match(right.headers.get('set-cookie') || '', /^khayt_lan=/);
});

test('a made-up session cookie opens nothing', async () => {
  const res = await fetch(`${BASE}/`, { headers: { cookie: `khayt_lan=${'0'.repeat(64)}` } });
  assert.match(await res.text(), /action="\/session"/);
});

test('a PIN shorter than eight characters opens nothing, and says why', async () => {
  const port = PORT + 1;
  const h = start(port, '4321');
  const r = await h.get('hub:start-lan-server')(null, { port, pin: '4321', bindLan: 'loopback' });
  assert.ok(r && r.ok);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/clients`, { headers: { 'x-khayt-pin': '4321' } });
    assert.equal(res.status, 401);
    assert.equal((await res.json()).reason, 'pin-too-short');
    const w = await fetch(`http://127.0.0.1:${port}/api/orders`, { method: 'POST', headers: { 'x-khayt-pin': '4321', 'content-type': 'application/json' }, body: '{}' });
    assert.equal(w.status, 401);
  } finally {
    await h.get('hub:stop-lan-server')?.(null, {});
  }
});
