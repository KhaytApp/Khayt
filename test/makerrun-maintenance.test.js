/**
 * MakerRun's planned-downtime gate.
 *
 * While a migration is applied by hand to the live database, every makerrun.com
 * endpoint answers 503 with `error.code === "maintenance"` and a `Retry-After`
 * header — reads included, /auth included.
 *
 * Khayt reported that as "Library fetch failed (HTTP 503)": a shop told its sync
 * is broken, during a window in which nothing is broken and nothing was
 * half-written.
 *
 * The distinction that has to hold: 503 is ALSO `unavailable`, which means a
 * misconfigured server that retrying will not fix. Same status, opposite advice
 * — so the branch is on `error.code`, exactly as `mfa_required` must be branched
 * against a plain `forbidden`.
 *
 * The second half of this file drives the real client functions against a real
 * local HTTP server, because "does it read the header off the response" is not
 * something a unit test of a pure function can answer.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { isMaintenance, retryAfterSeconds, maintenanceError } = require('../lib/makerrun-maintenance.js');

// ─────────────────────────────────────────────────────────── the decision

test('maintenance and unavailable share a status and mean opposite things', () => {
  const body = (code) => ({ error: { code, message: 'x' } });
  assert.equal(isMaintenance(503, body('maintenance')), true);
  assert.equal(isMaintenance(503, body('unavailable')), false,
    'a misconfigured server was treated as planned downtime — it will never come back on its own');
});

test('only a 503 is the gate', () => {
  const m = { error: { code: 'maintenance' } };
  for (const s of [200, 401, 403, 429, 500, 502, 504]) {
    assert.equal(isMaintenance(s, m), false, String(s));
  }
});

test('a 503 with no readable body is not assumed to be maintenance', () => {
  // A proxy's own 503 has no JSON at all. Guessing would tell the shop to wait
  // for a migration that is not happening.
  for (const b of [null, undefined, {}, { error: null }, { error: {} }, 'nope', 0]) {
    assert.equal(isMaintenance(503, b), false, JSON.stringify(b));
  }
});

// ───────────────────────────────────────────────────────────── the wait

test('Retry-After in seconds is honoured', () => {
  assert.equal(retryAfterSeconds('120', 0), 120);
  assert.equal(retryAfterSeconds('1', 0), 1);
});

test('an HTTP-date Retry-After is turned into seconds', () => {
  const now = Date.parse('2026-08-09T12:00:00Z');
  assert.equal(retryAfterSeconds('Sun, 09 Aug 2026 12:05:00 GMT', now), 300);
});

test('a missing, junk or absurd Retry-After falls back to a minute', () => {
  // The server knows how long its migration takes; we do not. But "wait a day"
  // is not a wait anyone sits through, and a negative one is nonsense.
  for (const v of ['', null, undefined, 'soon', '-5', '0', '999999', 'Mon, 01 Jan 1990 00:00:00 GMT']) {
    assert.equal(retryAfterSeconds(v, Date.parse('2026-08-09T12:00:00Z')), 60, JSON.stringify(v));
  }
});

test('the error carries what a caller needs to retry rather than discard', () => {
  const e = maintenanceError(300);
  assert.equal(e.maintenance, true, 'a caller cannot tell this from a real failure');
  assert.equal(e.retryAfter, 300);
  assert.match(e.message, /maintenance/i);
  assert.match(e.message, /5 minutes/, 'the wait is not stated in the message');
  assert.match(maintenanceError(60).message, /1 minute\b/, 'pluralised wrongly at one minute');
});

// ──────────────────────────────────────── against a real server, real headers

/** Serve one canned response, run fn(base), always close. */
async function withServer(handler, fn) {
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { return await fn(base); } finally { await new Promise((r) => server.close(r)); }
}

const gate = (retryAfter) => (req, res) => {
  res.writeHead(503, { 'content-type': 'application/json', ...(retryAfter ? { 'retry-after': retryAfter } : {}) });
  res.end(JSON.stringify({ error: { code: 'maintenance', message: 'Back shortly.' } }));
};

test('fetchLibrary reports maintenance, not a failed fetch', async () => {
  // The bug, end to end: a shop is told its library sync is broken during a
  // planned migration.
  const lib = require('../lib/makerrun-library.js');
  await withServer(gate('180'), async (base) => {
    {
      const err = await lib.fetchLibrary('a-token', { baseUrl: base }).then(() => null, (e) => e);
      assert.ok(err, 'a closed gate resolved as if it had returned a library');
      assert.equal(err.maintenance, true, `reported as a plain failure: ${err.message}`);
      assert.equal(err.retryAfter, 180, 'the Retry-After header was not read off the response');
      assert.doesNotMatch(err.message, /HTTP 503/, 'the raw status leaked into a user-facing message');
    }
  });
});

test('a real 503 that is NOT the gate still reports as a failure', async () => {
  const lib = require('../lib/makerrun-library.js');
  const broken = (req, res) => {
    res.writeHead(503, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'unavailable', message: 'not configured' } }));
  };
  await withServer(broken, async (base) => {
    {
      const err = await lib.fetchLibrary('a-token', { baseUrl: base }).then(() => null, (e) => e);
      assert.ok(err);
      assert.ok(!err.maintenance, 'a misconfigured server was reported as planned downtime');
      assert.match(err.message, /HTTP 503/);
    }
  });
});

test('the token refresh reports maintenance without clearing the link', () => {
  // The stored refresh token is cleared ONLY on 401. A 503 during a migration
  // must not look like an expired link, or a shop is signed out by a planned
  // window and has to reconnect from the website for no reason.
  const fs2 = require('fs');
  const src = fs2.readFileSync(require('path').join(__dirname, '..', 'lib', 'makerrun-account.js'), 'utf8');
  const at = src.indexOf('async function doRefresh(');
  const body = src.slice(at, src.indexOf('\n}', at));
  assert.match(body, /MAINT\.isMaintenance\(res\.status, j\)/,
    'a closed gate is reported as "could not refresh your session"');
  // The maintenance branch must come BEFORE the generic !res.ok, or it is dead.
  assert.ok(body.indexOf('MAINT.isMaintenance') < body.indexOf('if (!res.ok)'),
    'the generic failure branch runs first, so the maintenance one is unreachable');
  // And clearing stays pinned to 401.
  const clearAt = body.indexOf('clear(userDataDir)');
  assert.ok(clearAt > -1 && body.lastIndexOf('res.status === 401', clearAt) > -1,
    'the link is cleared outside the 401 branch — a maintenance window would sign the shop out');
});
