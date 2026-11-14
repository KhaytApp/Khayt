'use strict';
/**
 * Pay link v2, this computer and Khayt Cloud (lib/main/quote-link-keys-cloud.js),
 * against a fake Cloud that follows docs/api-contract.md "Quote pay link keys":
 * it checks every endorsement it is sent, the way #215 does. Sample shop only.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const C = require('../lib/main/quote-link-keys-cloud.js');
const K = require('../lib/main/quote-link-key.js');

const SHOP = 'shop_0000example';
const unb64 = (s) => Buffer.from(s, 'base64url');

/** A small fake of #215: keys, pending requests, CAS on retires, endorsement checks. */
function fakeCloud() {
  const keys = []; const pending = []; const calls = [];
  const verify = (jws, endorserX, kid, x) => {
    const [h, p, s] = jws.split('.');
    const head = JSON.parse(unb64(h)); const body = JSON.parse(unb64(p));
    const pub = crypto.createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: endorserX }, format: 'jwk' });
    return head.typ === 'khayt-key-endorsement+jwt' && body.iss === SHOP && body.new_kid === kid && body.x === x
      && crypto.verify(null, Buffer.from(h + '.' + p), pub, unb64(s));
  };
  const call = async ({ method, path, body }) => {
    calls.push({ method, path, body });
    assert.ok(!JSON.stringify(body || {}).includes('"d"'), 'no private part is ever sent');
    const base = `/v1/shops/${SHOP}/quote-keys`;
    if (method === 'GET' && path === base) return { status: 200, body: { shop: SHOP, epoch: 1, keys } };
    if (method === 'GET' && path === base + '/pending') return { status: 200, body: { pending } };
    if (method === 'POST' && path === base + '/pending') { pending.push({ kid: body.jwk.kid, x: body.jwk.x, device: body.device }); return { status: 200, body: { ok: true, kid: body.jwk.kid } }; }
    if (method === 'DELETE' && path.startsWith(base + '/pending/')) { const i = pending.findIndex((q) => q.kid === decodeURIComponent(path.split('/').pop())); if (i < 0) return { status: 404, body: {} }; pending.splice(i, 1); return { status: 200, body: { ok: true } }; }
    if (method === 'PUT' && path === base) {
      const { jwk, endorsement, expect } = body;
      if (K.kidOf(jwk.x) !== jwk.kid) return { status: 400, body: { reason: 'kid' } };
      const live = keys.filter((k) => k.status !== 'revoked');
      if (!endorsement) {
        if (live.length) return { status: 409, body: { reason: 'endorsement-required' } };
        keys.push({ kid: jwk.kid, x: jwk.x, status: 'current', root: true }); return { status: 200, body: { ok: true, kid: jwk.kid, chain: { keys } } };
      }
      const by = keys.find((k) => k.kid === JSON.parse(unb64(endorsement.split('.')[0])).kid);
      if (!by) return { status: 409, body: { reason: 'unknown-endorser' } };
      if (by.status === 'revoked') return { status: 409, body: { reason: 'endorser-revoked' } };
      if (!verify(endorsement, by.x, jwk.kid, jwk.x)) return { status: 400, body: { reason: 'bad_signature' } };
      if (expect && expect.retires) {
        const old = keys.find((k) => k.kid === expect.retires);
        if (!old || old.status !== 'current') return { status: 409, body: { reason: 'retires-not-current' } };
        old.status = 'retired';
      }
      keys.push({ kid: jwk.kid, x: jwk.x, status: 'current' });
      const i = pending.findIndex((q) => q.kid === jwk.kid); if (i >= 0) pending.splice(i, 1);
      return { status: 200, body: { ok: true, kid: jwk.kid, chain: { keys } } };
    }
    if (method === 'POST' && /\/revoke$/.test(path)) {
      if (!body.code) return { status: 202, body: { ok: true, codeSent: true } };
      if (body.code !== 'TESTCODE') return { status: 401, body: { reason: 'bad-code' } };
      const k = keys.find((x) => x.kid === decodeURIComponent(path.split('/').slice(-2)[0])); k.status = 'revoked';
      return { status: 200, body: { ok: true, chain: { keys } } };
    }
    return { status: 404, body: {} };
  };
  return { call, keys, pending, calls };
}

test('the first computer publishes its key as the root and may sign', async () => {
  const cloud = fakeCloud();
  const r = await C.setUp(cloud.call, SHOP, { device: 'Workshop PC' });
  assert.equal(r.ok, true); assert.equal(r.state, 'current');
  const chain = (await C.getChain(cloud.call, SHOP)).chain;
  assert.equal(C.canSign(chain, r.record), true);
  assert.ok(K.seedOk(r.record.seed));
  assert.ok(!cloud.calls.some((c) => JSON.stringify(c.body || {}).includes(r.record.seed)), 'the seed never goes to Cloud');
});

test('a second computer waits for approval, and signs only once approved', async () => {
  const cloud = fakeCloud();
  const first = (await C.setUp(cloud.call, SHOP, { device: 'Mac Studio' })).record;
  const second = await C.setUp(cloud.call, SHOP, { device: 'Workshop PC' });
  assert.equal(second.state, 'pending');
  let chain = (await C.getChain(cloud.call, SHOP)).chain;
  assert.equal(C.canSign(chain, second.record), false, 'waiting: no signing');

  const waiting = (await C.listPending(cloud.call, SHOP)).pending;
  assert.equal(waiting.length, 1);
  const ok = await C.approve(cloud.call, SHOP, first, waiting[0]);
  assert.equal(ok.ok, true);
  chain = (await C.getChain(cloud.call, SHOP)).chain;
  assert.equal(C.canSign(chain, second.record), true);
  assert.equal(cloud.pending.length, 0, 'approving clears the request');
});

test('approve refuses a waiting key whose kid is not its thumbprint', async () => {
  const cloud = fakeCloud();
  const first = (await C.setUp(cloud.call, SHOP)).record;
  const other = K.generate();
  const r = await C.approve(cloud.call, SHOP, first, { kid: other.kid, x: K.generate().x });
  assert.deepEqual(r, { ok: false, error: 'kid-mismatch' });
});

test('decline turns a waiting computer away', async () => {
  const cloud = fakeCloud();
  await C.setUp(cloud.call, SHOP);
  const w = await C.setUp(cloud.call, SHOP);
  assert.equal((await C.decline(cloud.call, SHOP, w.record.kid)).ok, true);
  assert.equal(cloud.pending.length, 0);
});

test('rotate: the old key endorses the new, Cloud retires the old, and the old seed is gone', async () => {
  const cloud = fakeCloud();
  const old = (await C.setUp(cloud.call, SHOP, { device: 'Workshop PC' })).record;
  const r = await C.rotate(cloud.call, SHOP, old);
  assert.equal(r.ok, true);
  assert.notEqual(r.record.kid, old.kid);
  assert.equal(r.record.replaced, old.kid);
  assert.ok(!JSON.stringify(r.record).includes(old.seed), 'the retired private key is not kept');
  const chain = (await C.getChain(cloud.call, SHOP)).chain;
  assert.equal(C.statusIn(chain, old.kid), 'retired');
  assert.equal(C.canSign(chain, r.record), true);
  assert.equal(C.canSign(chain, old), false);
});

test('two computers rotating the same key: the second loses (compare-and-swap), and keeps its old key', async () => {
  const cloud = fakeCloud();
  const old = (await C.setUp(cloud.call, SHOP)).record;
  assert.equal((await C.rotate(cloud.call, SHOP, old)).ok, true);
  const lost = await C.rotate(cloud.call, SHOP, old);
  assert.deepEqual([lost.ok, lost.status, lost.error], [false, 409, 'retires-not-current']);
  assert.equal(lost.record, undefined, 'nothing to store: the caller keeps what it had');
});

test('revoke takes two steps: a code is emailed, then the code revokes', async () => {
  const cloud = fakeCloud();
  const rec = (await C.setUp(cloud.call, SHOP)).record;
  assert.deepEqual(await C.revoke(cloud.call, SHOP, rec.kid), { ok: true, codeSent: true });
  assert.equal((await C.revoke(cloud.call, SHOP, rec.kid, 'WRONG')).error, 'bad-code');
  assert.equal((await C.revoke(cloud.call, SHOP, rec.kid, 'TESTCODE')).ok, true);
  const chain = (await C.getChain(cloud.call, SHOP)).chain;
  assert.equal(C.canSign(chain, rec), false);
});

test('a key Cloud has never heard of does not sign', () => {
  const rec = K.generate();
  assert.equal(C.canSign({ keys: [] }, rec), false);
  assert.equal(C.statusIn(null, rec.kid), 'unpublished');
});
