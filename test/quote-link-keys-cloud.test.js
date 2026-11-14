'use strict';
/**
 * Pay link v2, this computer and Khayt Cloud (lib/main/quote-link-keys-cloud.js),
 * against a fake Cloud that follows docs/api-contract.md "Quote pay link keys":
 * it checks every endorsement it is sent, the way #215 does. Sample shop only.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../lib/main/quote-link-keys-cloud.js');
const K = require('../lib/main/quote-link-key.js');

const { fakeCloud, SHOP } = require('./helpers/fake-quote-keys-cloud.js');

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
