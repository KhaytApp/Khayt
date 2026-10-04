'use strict';

/**
 * lib/makerrun-v1.js — the shared transport for MakerRun's /api/v1.
 *
 * What matters most here is that errors are classified by `error.code`, never by status: two 403s
 * (mfa_required vs forbidden vs age_required) and two 503s (maintenance vs unavailable) ask the user
 * for opposite things. And that a 401 is retried exactly once behind a forced, single-flighted refresh.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const V1 = require('../lib/makerrun-v1');
const acct = require('../lib/makerrun-account');

const res = (status, body, headers = {}) => ({
  status,
  ok: status >= 200 && status < 300,
  headers: { get: (h) => (Object.prototype.hasOwnProperty.call(headers, String(h).toLowerCase()) ? headers[String(h).toLowerCase()] : null) },
  json: async () => { if (body === undefined) throw new Error('not json'); return body; },
});
const env = (code, message, details) => ({ error: { code, message, ...(details ? { details } : {}) } });

function withFetch(stub, fn) {
  const real = global.fetch;
  global.fetch = stub;
  return Promise.resolve().then(fn).finally(() => { global.fetch = real; });
}
function tmpDir() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'mr-v1-test-'));
  return d;
}

/* ---- parseV1Error ---------------------------------------------------- */

test('each documented code survives as .code, with the server message and status', () => {
  for (const [status, code] of [
    [401, 'unauthorized'], [403, 'mfa_required'], [403, 'age_required'], [403, 'forbidden'],
    [404, 'not_found'], [409, 'conflict'], [503, 'unavailable'], [400, 'bad_request'],
  ]) {
    const e = V1.parseV1Error(res(status), env(code, 'msg ' + code));
    assert.equal(e.code, code);
    assert.equal(e.status, status);
    assert.equal(e.message, 'msg ' + code);
    assert.ok(!e.maintenance, code + ' is not maintenance');
  }
});

test('three different 403s stay three different codes', () => {
  const codes = ['mfa_required', 'age_required', 'forbidden'].map((c) => V1.parseV1Error(res(403), env(c, 'x')).code);
  assert.deepEqual(codes, ['mfa_required', 'age_required', 'forbidden']);
});

test('503 maintenance is retryable with Retry-After; 503 unavailable is not maintenance', () => {
  const m = V1.parseV1Error(res(503, null, { 'retry-after': '120' }), env('maintenance', 'closed'));
  assert.equal(m.code, 'maintenance');
  assert.equal(m.maintenance, true);
  assert.equal(m.retryAfter, 120);
  const u = V1.parseV1Error(res(503, null, { 'retry-after': '120' }), env('unavailable', 'misconfigured'));
  assert.equal(u.code, 'unavailable');
  assert.equal(u.maintenance, undefined);
  assert.equal(u.retryAfter, undefined, 'a broken server is not told to come back in two minutes');
});

test('rate_limited carries retryAfter from the header, defaulting to a minute', () => {
  assert.equal(V1.parseV1Error(res(429, null, { 'retry-after': '30' }), env('rate_limited', 'slow')).retryAfter, 30);
  assert.equal(V1.parseV1Error(res(429), env('rate_limited', 'slow')).retryAfter, 60);
});

test('invalid keeps well-formed details[] so the form can map them onto fields', () => {
  const e = V1.parseV1Error(res(422), env('invalid', 'Some fields were rejected.', [
    { field: 'title', message: 'too long' }, { nope: true }, 'junk', { field: 'license' },
  ]));
  assert.equal(e.code, 'invalid');
  assert.deepEqual(e.details, [{ field: 'title', message: 'too long' }, { field: 'license', message: '' }]);
});

test('the images route 422 (no envelope, failures[]) is read as invalid with details', () => {
  const e = V1.parseV1Error(res(422), { images: [], coverSet: null, failures: [{ field: 'images', message: 'a.jpg: 5000×4000 exceeds the 2048px longest edge' }] });
  assert.equal(e.code, 'invalid');
  assert.equal(e.details.length, 1);
  assert.match(e.message, /2048px/);
});

test('a body that is not the envelope falls back to the status, never to a generic success', () => {
  assert.equal(V1.parseV1Error(res(404), null).code, 'not_found');
  assert.equal(V1.parseV1Error(res(502), null).code, 'http_502');
  assert.match(V1.parseV1Error(res(502), null).message, /502/);
});

/* ---- request ----------------------------------------------------------- */

test('request sends the Bearer token and JSON body to the injected base, and returns the body', async () => {
  let seen;
  await withFetch(async (url, init) => { seen = { url, init }; return res(201, { design: { slug: 'a-b' } }); }, async () => {
    const out = await V1.request('POST', '/designs', { token: 'TOK', json: { title: 'x' }, baseUrl: 'https://93.184.216.34' });
    assert.deepEqual(out, { design: { slug: 'a-b' } });
  });
  assert.equal(seen.url, 'https://93.184.216.34/api/v1/designs');
  assert.equal(seen.init.method, 'POST');
  assert.equal(seen.init.headers.authorization, 'Bearer TOK');
  assert.equal(seen.init.headers['content-type'], 'application/json');
  assert.equal(seen.init.body, '{"title":"x"}');
  assert.ok(seen.init.signal, 'every request has a timeout');
});

test('request never sets content-type for multipart — fetch writes the boundary', async () => {
  let seen;
  const form = new FormData();
  form.append('file', new Blob(['x']), 'a.stl');
  await withFetch(async (url, init) => { seen = init; return res(201, { ok: 1 }); }, () =>
    V1.request('POST', '/designs/x/files', { token: 'T', form, baseUrl: 'https://93.184.216.34' }));
  assert.equal(seen.body, form);
  assert.equal(Object.keys(seen.headers).some((h) => h.toLowerCase() === 'content-type'), false);
});

test('the default host is makerrun.com', async () => {
  let url;
  await withFetch(async (u) => { url = u; return res(200, { designs: [] }); }, () => V1.request('GET', '/designs'));
  assert.equal(url, 'https://makerrun.com/api/v1/designs');
});

test('a network failure and an unreadable 200 are coded, not thrown raw', async () => {
  await withFetch(async () => { throw new TypeError('fetch failed'); }, () =>
    assert.rejects(() => V1.request('GET', '/designs'), (e) => e.code === 'network'));
  await withFetch(async () => res(200, undefined), () =>
    assert.rejects(() => V1.request('GET', '/designs'), (e) => e.code === 'bad_response'));
});

test('toIpcError keeps code, retryAfter and details and nothing else', () => {
  const e = V1.parseV1Error(res(429, null, { 'retry-after': '9' }), env('rate_limited', 'slow'));
  assert.deepEqual(V1.toIpcError(e), { ok: false, error: 'slow', code: 'rate_limited', retryAfter: 9 });
});

/* ---- withToken ----------------------------------------------------------- */

function fakeAccount(tokens) {
  const calls = [];
  return {
    calls,
    getAccessToken: async (_dir, _now, opts) => { calls.push(opts && opts.force ? 'force' : 'normal'); return tokens.shift(); },
  };
}
const unauthorized = () => V1.parseV1Error(res(401), env('unauthorized', 'expired'));

test('withToken: a 401 is retried once after a FORCED refresh, with the new token', async () => {
  const account = fakeAccount(['A', 'B']);
  const used = [];
  const out = await V1.withToken('/x', async (tok) => { used.push(tok); if (tok === 'A') throw unauthorized(); return 'done'; }, { account });
  assert.equal(out, 'done');
  assert.deepEqual(used, ['A', 'B']);
  assert.deepEqual(account.calls, ['normal', 'force']);
});

test('withToken: a second 401 becomes relink, and is not retried a third time', async () => {
  const account = fakeAccount(['A', 'B', 'C']);
  let n = 0;
  await assert.rejects(
    () => V1.withToken('/x', async () => { n++; throw unauthorized(); }, { account }),
    (e) => e.code === 'relink');
  assert.equal(n, 2);
});

test('withToken: any other error passes straight through without a refresh', async () => {
  const account = fakeAccount(['A', 'B']);
  await assert.rejects(
    () => V1.withToken('/x', async () => { throw V1.parseV1Error(res(403), env('mfa_required', 'mfa')); }, { account }),
    (e) => e.code === 'mfa_required');
  assert.deepEqual(account.calls, ['normal']);
});

test('withToken: not linked is reported as not_linked, before any request', async () => {
  const dir = tmpDir();
  let called = false;
  await assert.rejects(() => V1.withToken(dir, async () => { called = true; }), (e) => e.code === 'not_linked');
  assert.equal(called, false);
});

test('a forced refresh skips the "still fresh" shortcut but stays single-flight', async () => {
  const dir = tmpDir();
  acct.link(dir, { access: 'STILL_VALID', refresh: 'R0', expires: 99_999 });
  let posts = 0;
  const bodies = [];
  await withFetch(async (url, init) => {
    posts++;
    bodies.push(JSON.parse(init.body).refresh_token);
    await new Promise((r) => setTimeout(r, 5));
    return { status: 200, ok: true, headers: { get: () => null }, json: async () => ({ access_token: 'NEW', refresh_token: 'R1', expires_at: 99_999 }) };
  }, async () => {
    // Without force the clock says the token is fine.
    assert.equal(await acct.getAccessToken(dir, 1_000), 'STILL_VALID');
    assert.equal(posts, 0);
    // Two callers that both just got a 401 — one exchange, never a replay of R0.
    const [a, b] = await Promise.all([
      acct.getAccessToken(dir, 1_000, { force: true }),
      acct.getAccessToken(dir, 1_000, { force: true }),
    ]);
    assert.equal(a, 'NEW');
    assert.equal(b, 'NEW');
  });
  assert.equal(posts, 1);
  assert.deepEqual(bodies, ['R0']);
  assert.equal(acct.read(dir).refresh, 'R1', 'the rotated refresh token is stored');
});

test('a dead link during the forced refresh surfaces as relink', async () => {
  const dir = tmpDir();
  acct.link(dir, { access: 'A', refresh: 'R0', expires: 99_999 });
  let first = true;
  await withFetch(async (url) => {
    if (String(url).endsWith('/api/app-token')) return { status: 401, ok: false, headers: { get: () => null }, json: async () => ({ error: 'invalid' }) };
    if (first) { first = false; return res(401, env('unauthorized', 'expired')); }
    return res(200, { ok: true });
  }, async () => {
    await assert.rejects(
      () => V1.withToken(dir, (tok) => V1.request('GET', '/me', { token: tok })),
      (e) => e.code === 'relink');
  });
  assert.equal(acct.isLinked(dir), false, 'the refused refresh token is cleared');
});
