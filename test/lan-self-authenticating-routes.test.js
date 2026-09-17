/**
 * Routes that carry their own auth still answer once the shop sets a PIN.
 *
 * ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
 *
 * Several LAN routes authenticate themselves: `/status/:id` and `/order/:id`
 * take a per-order tracking token, `/calendar.ics` takes a calendar token.
 * They must be listed in the server's `isAlwaysPublic` set, because the owner
 * PIN gate runs FIRST and answers 401 before the route's own check is reached
 * — and a customer holding a tracking link has no PIN to send, nor does a
 * calendar app.
 *
 * `/status/` and `/calendar.ics` were missing from that list. Both returned
 * 401 to a perfectly valid token for any shop with a PIN configured, which is
 * every shop that writes through the API, because writes require one. The tell
 * was that `/order/:id` served the same token happily while `/status/:id`
 * refused it, and that the Mac app served both.
 *
 * ── WHY NOTHING CAUGHT IT ─────────────────────────────────────────────────
 *
 * The calendar had two tests. One drove the feed MODULE; the other asserted
 * that the server's source text contains `LanCalendar.feed(store)`. Both
 * passed throughout. Neither ever asked the running server for the feed.
 *
 * `test/lan-auth-lockout.test.js` says the same thing about its own subject in
 * its header: "What was missing was anybody asking the running server." So
 * these tests speak HTTP, with a PIN configured, which is the condition the
 * bug needs.
 */
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const { registerLanServer } = require(path.join(ROOT, 'lib/lan-server.js'));

const PORT = 3997;   // 3991-3996 are taken by the other LAN suites
const PIN = '4321';
const CAL_TOKEN = 'calendar-token-abcdef';
const TRACK = 'tracking-token-abcdef';
const BASE = `http://127.0.0.1:${PORT}`;
const handlers = new Map();
const noop = () => {};

let store = {
  printLog: [{
    id: 'ORD-1', project: 'Bracket', status: 'printing',
    dueDate: '2026-10-01', trackingToken: TRACK,
  }],
  inventory: [], printers: [], machines: [], waitingList: [], tombstones: [], clients: [],
  settings: { currency: 'SAR', lanApi: { intakeToken: 'tok', calendarToken: CAL_TOKEN } },
};

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
    ensureLanCalendarToken: () => ({ token: CAL_TOKEN, generated: false }),
    writeStoreToDisk: async () => {},
    persistLanStoreUpdate: async (s) => { store = s; },
    updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store,
    setLanServerStore: (s) => { store = s; },
    getMainWindow: () => null,
    // A FUNCTION, as main.js passes it — `statusPagesDir()` is called.
    statusPagesDir: () => path.join(ROOT, 'status-pages'),
    appRoot: ROOT,
    getPrinterStatusCache: () => ({}),
  });
  // WITH A PIN. Without one the gate does not run and none of this is tested.
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, `server did not start: ${JSON.stringify(r)}`);
});

after(async () => {
  const stop = handlers.get('hub:stop-lan-server');
  if (stop) await stop(null, {});
});

test('the calendar subscription link works with only its token', async () => {
  const res = await fetch(`${BASE}/calendar.ics?token=${CAL_TOKEN}`);
  assert.equal(res.status, 200,
    'the link Settings → Online hands out is refused once a PIN is set');
  const body = await res.text();
  assert.match(body, /BEGIN:VCALENDAR/, 'a 200 that is not a calendar');
});

test('the customer tracking page works with only its order token', async () => {
  const res = await fetch(`${BASE}/status/ORD-1?token=${TRACK}`);
  // 404 is a pass here: the generated status page file need not exist in a
  // test checkout. What must NOT happen is 401 — that is the PIN gate
  // answering before the route's own token check ran.
  assert.notEqual(res.status, 401,
    'a valid tracking link is refused for want of a PIN the customer cannot have');
  assert.ok([200, 404].includes(res.status), `unexpected ${res.status}`);
});

test('the older tracking URL still works too, as it always did', async () => {
  const res = await fetch(`${BASE}/order/ORD-1?token=${TRACK}`);
  assert.equal(res.status, 200);
});

test('a self-authenticating route still refuses a WRONG token', async () => {
  // Being exempt from the PIN gate must not mean being open. Each of these
  // has to turn its own key.
  assert.equal((await fetch(`${BASE}/calendar.ics?token=nope`)).status, 401);
  assert.equal((await fetch(`${BASE}/status/ORD-1?token=nope`)).status, 403);
  assert.equal((await fetch(`${BASE}/order/ORD-1?token=nope`)).status, 403);
  assert.equal((await fetch(`${BASE}/calendar.ics`)).status, 401, 'no token at all');
});

test('guessing the PIN through the calendar feed locks out like anywhere else', async () => {
  // The route accepts the owner PIN as well as its token, and it is now exempt
  // from the gate that used to do the counting. Exempt from the gate must not
  // mean exempt from the lockout: the PIN is four digits in the field's own
  // placeholder, and an unthrottled endpoint that accepts it is a guessing
  // oracle for the credential that opens every other route.
  let sawLock = false;
  for (let i = 0; i < 20; i++) {
    const res = await fetch(`${BASE}/calendar.ics?pin=wrong${i}`);
    if (res.status === 429) { sawLock = true; break; }
  }
  assert.ok(sawLock, 'the calendar feed answers wrong PINs for ever');
});

// ── A REQUEST THAT CANNOT BE UNDERSTOOD IS STILL ANSWERED ──────────────────
//
// Node's request listener has no error handling of its own: a throw inside it
// escapes to `uncaughtException` and the socket is never answered at all. The
// client hangs until its own timeout, and this app's process-level handler
// files the throw as a crash report — so one malformed request produced a dead
// connection and a bogus crash together.
//
// `GET /status/%` did it. The route decodes the order id with
// `decodeURIComponent`, a lone percent is a `URIError`, and the route is
// public: no PIN, no token, anyone on the shop's Wi-Fi. Seven other routes
// decode a path segment the same way, and the cookie parser decodes a header
// the customer's own browser sends.

test('a malformed percent-escape is answered, not hung', async () => {
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), 5000);
  let status;
  try {
    status = (await fetch(`${BASE}/status/%`, { signal: stop.signal })).status;
  } catch (e) {
    assert.fail(`no response at all to GET /status/% — ${e.name}`);
  } finally { clearTimeout(timer); }
  assert.equal(status, 400);
});

test('a malformed cookie on the public intake path is answered too', async () => {
  // The customer's browser sends this, on the one page a shop hands out.
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), 5000);
  let status;
  try {
    status = (await fetch(`${BASE}/api/intake`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie: 'khayt_intake=%' },
      body: JSON.stringify({ name: 'x' }),
      signal: stop.signal,
    })).status;
  } catch (e) {
    assert.fail(`no response at all to a malformed cookie — ${e.name}`);
  } finally { clearTimeout(timer); }
  assert.ok(status >= 400 && status < 500, `expected a 4xx, got ${status}`);
});

test('the server is still serving afterwards', async () => {
  assert.equal((await fetch(`${BASE}/api/status`)).status, 200);
});

test('being exempt from the PIN does not mean being open to every origin', async () => {
  // `isAlwaysPublic` grants `Access-Control-Allow-Origin: *`. These two routes
  // are exempt from the PIN gate through a SEPARATE list precisely so they do
  // not inherit that: `/calendar.ics` accepts the owner PIN as an alternative
  // to its token, and a wildcard would let any web page in the world guess the
  // shop's PIN through the shop's own browser.
  const cal = await fetch(`${BASE}/calendar.ics?token=${CAL_TOKEN}`, {
    headers: { origin: 'https://evil.example' },
  });
  assert.equal(cal.headers.get('access-control-allow-origin'), null,
    'the calendar feed is readable cross-origin by any site');

  const status = await fetch(`${BASE}/status/ORD-1?token=${TRACK}`, {
    headers: { origin: 'https://evil.example' },
  });
  assert.equal(status.headers.get('access-control-allow-origin'), null,
    'the tracking page is readable cross-origin by any site');
});
