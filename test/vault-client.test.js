'use strict';
// lib/vault-client.js against a fake fetch: routes, methods, headers, bodies,
// and the error `reason` mapping of VaultClient.swift `failure(_:_:)`.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createVaultClient } = require('../lib/vault-client.js');

function fakeFetch(handler) {
  const calls = [];
  const fn = async (url, init) => {
    const call = { url, method: init.method, headers: init.headers, redirect: init.redirect,
      body: init.body === undefined ? undefined : JSON.parse(init.body) };
    calls.push(call);
    const [status, body] = await handler(call);
    return { status, json: async () => { if (body === undefined) throw new Error('no body'); return body; } };
  };
  fn.calls = calls;
  return fn;
}

const BASE = 'https://cloud.example.com';
const client = (fetch) => createVaultClient({ baseUrl: BASE + '/', shopId: 'shop_1', token: 'tok', fetch });

test('every route: path under /v1/shops/{shopId}, method, auth + delta headers', async () => {
  const grant = { grantId: 'g'.repeat(22), state: 'ok' };
  const f = fakeFetch(({ url, method }) => {
    if (url.endsWith('/vault/usage')) return [200, { limits: { maxVaultBytes: 10 }, used: { total: 1 } }];
    if (url.endsWith('/vault/grants') && method === 'GET') return [200, { grants: [grant] }];
    if (url.endsWith('/vault/grants') && method === 'POST') return [201, { createdAt: '2026-11-05T00:00:00Z' }];
    if (url.endsWith('/events')) return [200, { events: [{ at: 'x', kind: 'open' }] }];
    return [200, grant];
  });
  const c = client(f);
  await c.usage();
  await c.listGrants();
  const created = await c.createGrant({ grantId: grant.grantId, items: [] });
  assert.equal(created.createdAt, '2026-11-05T00:00:00Z');
  await c.patchGrant(grant.grantId, { revoke: true });
  await c.getGrant(grant.grantId);
  assert.deepEqual(await c.grantEvents(grant.grantId), [{ at: 'x', kind: 'open' }]);

  const p = BASE + '/v1/shops/shop_1';
  assert.deepEqual(f.calls.map((x) => [x.method, x.url]), [
    ['GET', p + '/vault/usage'],
    ['GET', p + '/vault/grants'],
    ['POST', p + '/vault/grants'],
    ['PATCH', p + '/vault/grants/' + grant.grantId],
    ['GET', p + '/vault/grants/' + grant.grantId],
    ['GET', p + '/vault/grants/' + grant.grantId + '/events'],
  ]);
  for (const x of f.calls) {
    assert.equal(x.headers.authorization, 'Bearer tok');
    assert.equal(x.headers['x-delta-capable'], '1');
    assert.equal(x.redirect, 'manual');
    assert.equal(!!x.headers['content-type'], x.body !== undefined);
  }
  assert.deepEqual(f.calls[2].body, { grantId: grant.grantId, items: [] });
  assert.deepEqual(f.calls[3].body, { revoke: true });
});

test('files() follows `more`, passing each page\'s rev as the next since', async () => {
  const f = fakeFetch(({ url }) => {
    const since = Number(new URL(url).searchParams.get('since'));
    assert.equal(new URL(url).searchParams.get('limit'), '1000');
    if (since === 0) return [200, { rev: 5, more: true, files: [{ fileId: 'a', metaRev: 1 }, { fileId: 'b' }] }];
    if (since === 5) return [200, { rev: 9, more: false, files: [{ fileId: 'a', metaRev: 2 }] }];
    throw new Error('unexpected since ' + since);
  });
  const feed = await client(f).files({ since: 0 });
  assert.equal(feed.rev, 9);
  assert.deepEqual(feed.files.map((x) => [x.fileId, x.metaRev]), [['b', undefined], ['a', 2]]);
  assert.equal(f.calls.length, 2);
  assert.match(f.calls[0].url, /\/vault\/files\?since=0&limit=1000$/);
});

test('error reasons: the server\'s own first, then by status', async () => {
  const cases = [
    [402, { reason: 'no-vault' }, 'no-vault'],
    [402, { reason: 'vault-full', used: 9, limit: 10 }, 'vault-full'],
    [402, { reason: 'read-only' }, 'read-only'],
    [402, { reason: 'vault-over' }, 'vault-over'],
    [402, { reason: 'no-links' }, 'no-links'],
    [402, { reason: 'links-full', limit: 3 }, 'links-full'],
    [403, { reason: 'links-disabled' }, 'links-disabled'],
    [409, { reason: 'grant-exists' }, 'grant-exists'],
    [422, { reason: 'unknown-items', fileIds: ['x'] }, 'unknown-items'],
    [422, { reason: 'downloads-cap', limit: 50 }, 'downloads-cap'],
    [409, { reason: 'disabled' }, 'disabled'],
    [404, {}, 'no-vault'],
    [404, undefined, 'no-vault'],
    [401, {}, 'not-accepted'],
    [403, {}, 'not-allowed'],
    [422, { error: 'bad' }, 'invalid'],
    [429, {}, 'rate-limited'],
    [500, {}, 'http'],
  ];
  for (const [status, body, reason] of cases) {
    const c = client(fakeFetch(() => [status, body]));
    const e = await c.patchGrant('g'.repeat(22), { revoke: true }).then(() => null, (x) => x);
    assert.ok(e, `${status} should throw`);
    assert.equal(e.status, status);
    assert.equal(e.reason, reason, `${status} ${JSON.stringify(body)}`);
    assert.ok(e.message && typeof e.message === 'string');
  }
  const c = client(fakeFetch(() => [422, { reason: 'unknown-items', fileIds: ['a', 'b'] }]));
  const e = await c.createGrant({ grantId: 'g'.repeat(22), items: [] }).catch((x) => x);
  assert.deepEqual(e.fileIds, ['a', 'b']);
  const off = await client(fakeFetch(() => [404, {}])).usage().catch((x) => x);
  assert.equal(off.vaultOff, true);
  const vf = await client(fakeFetch(() => [402, { reason: 'vault-full', used: 9, limit: 10 }])).usage().catch((x) => x);
  assert.equal(vf.used, 9); assert.equal(vf.limit, 10);
});

test('https only, except loopback; ids are checked before anything is sent', async () => {
  const f = fakeFetch(() => [200, {}]);
  assert.throws(() => createVaultClient({ baseUrl: 'http://cloud.example.com', shopId: 's', token: 't', fetch: f }), /https/);
  assert.throws(() => createVaultClient({ baseUrl: 'http://192.168.1.5', shopId: 's', token: 't', fetch: f }), /https/);
  for (const ok of ['http://127.0.0.1:8787', 'http://localhost:3000', 'https://x.example']) {
    assert.doesNotThrow(() => createVaultClient({ baseUrl: ok, shopId: 's', token: 't', fetch: f }));
  }
  const c = client(f);
  await assert.rejects(async () => c.getGrant('../x'), /grantId/);
  await assert.rejects(c.createGrant({ grantId: 'short', items: [] }), /22/);
  assert.equal(f.calls.length, 0);
});

test('a redirect is refused, not followed', async () => {
  const e = await client(fakeFetch(() => [302, {}])).usage().catch((x) => x);
  assert.equal(e.reason, 'redirect');
});
