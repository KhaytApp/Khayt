'use strict';
/**
 * The desktop's send path runs the version lib/plugin-update.js runnable
 * picks: never `entry.manifest` directly. A withdrawn version sends nothing;
 * a build too old for the current manifest sends with the previous one; with
 * no update state it behaves as it always has. Throwaway keys, sample hosts.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const M = require('../lib/plugin-manifest.js');
const H = require('../lib/plugin-host.js');
const S = require('../lib/main/plugin-send.js');

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const KEYS = [{ id: 'test-key', key: publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64') }];
const sign = (m) => Object.assign({}, m, { signature: crypto.sign(null, Buffer.from(M.canonicalJSON(m), 'utf8'), privateKey).toString('base64') });

const base = (version, path) => ({
  khayt: { manifest: 1 }, id: 'app.test.ship', name: { en: 'Sample shipping' }, publisher: 'Test', version,
  domains: ['api.example.com'],
  secrets: [{ name: 'apiKey', label: { en: 'API key' }, kind: 'apiKey' }],
  actions: [{ id: 'ship', label: { en: 'Ship' }, placement: 'order', kind: 'post',
    url: `https://api.example.com/${path}`, send: ['order.id'],
    auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' } }],
});
const V1 = sign(base('1.0.0', 'v1/ship'));
const V2 = sign(base('1.1.0', 'v2/ship'));
const DLV = 'dlv_0b9a7c5e-1f2d-4c3b-9a8e-7d6c5b4a3f21';
const records = { order: { id: 'ORD-1' } };
function fakePost() {
  const calls = [];
  const fn = async (url, opts) => { calls.push({ url, ...opts }); return { ok: true, status: 200, text: '{}' }; };
  fn.calls = calls;
  return fn;
}
const entryOf = (m) => Object.assign(H.consentedEntry(null, m), { secrets: { apiKey: 'sample-key' } });
const go = (entry, settings, post) => S.send({ entry, trigger: { action: 'ship' }, records, delivery: DLV, settings }, { keys: KEYS, postPinned: post });

test('the sample manifests are valid', () => {
  for (const m of [V1, V2]) assert.deepEqual(M.validateManifest(m).errors, []);
});

test('no update state: sends with the installed version, as before', async () => {
  const post = fakePost();
  const r = await go(entryOf(V2), { plugins: [entryOf(V2)] }, post);
  assert.equal(r.ok, true);
  assert.equal(post.calls[0].url, 'https://api.example.com/v2/ship');
  // And with no settings at all.
  const post2 = fakePost();
  assert.equal((await go(entryOf(V2), undefined, post2)).ok, true);
  assert.equal(post2.calls.length, 1);
});

test('a withdrawn version sends nothing, refused with runnable\'s why', async () => {
  const entry = Object.assign(entryOf(V2), { enabled: false });
  const settings = { plugins: [entry], connectorUpdates: { serial: 3, connectors: { [V2.id]: {
    revoked: { version: '1.1.0', reason: 'Sample reason', at: '2026-11-12T09:00:00.000Z', wasEnabled: true } } } } };
  const post = fakePost();
  const r = await go(entry, settings, post);
  assert.deepEqual([r.ok, r.refused], [false, 'revoked']);
  assert.equal(post.calls.length, 0);
});

test('a build too old for the current manifest sends with the previous one', async () => {
  const unreadable = Object.assign({}, V2, { khayt: { manifest: 99 } });
  const entry = Object.assign(entryOf(V2), { manifest: unreadable });
  assert.equal(M.checkEntry(entry).ok, false, 'this build cannot run the current manifest');
  const settings = { plugins: [entry], connectorUpdates: { serial: 3, connectors: { [V2.id]: {
    previous: { version: '1.0.0', manifest: V1, granted: M.grantFor(V1) } } } } };
  const post = fakePost();
  const r = await go(entry, settings, post);
  assert.equal(r.ok, true);
  assert.equal(post.calls[0].url, 'https://api.example.com/v1/ship', 'the previous version\'s request');
  assert.equal(post.calls[0].headers.Authorization, 'Bearer sample-key');
  // Without a previous one, nothing runs.
  const none = await go(entry, { plugins: [entry] }, fakePost());
  assert.deepEqual([none.ok, none.refused], [false, 'invalid']);
});

test('switched off is still refused as off', async () => {
  const entry = Object.assign(entryOf(V2), { enabled: false });
  const r = await go(entry, { plugins: [entry] }, fakePost());
  assert.equal(r.refused, 'off');
});
