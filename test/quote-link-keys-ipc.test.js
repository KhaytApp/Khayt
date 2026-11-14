'use strict';
/**
 * Pay link v2, the window's view of the keys (lib/main/quote-link-keys-ipc.js):
 * off unless KHAYT_PAYLINK_V2=1, the Cloud token read from the book (never
 * the window), and the seed never in anything handed back. Fake Cloud only.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { registerQuoteLinkKeys } = require('../lib/main/quote-link-keys-ipc.js');
const { fakeCloud, SHOP } = require('./helpers/fake-quote-keys-cloud.js');

function rig({ enabled = true, cloud = fakeCloud(), withCloud = true } = {}) {
  const handlers = {};
  let book = { settings: withCloud ? { cloud: { url: 'https://cloud.example', shopId: SHOP, token: 'test-token-not-real', role: 'owner' } } : {} };
  const seen = [];
  registerQuoteLinkKeys({
    ipcMain: { handle: (name, fn) => { handlers[name] = fn; } },
    readBook: () => JSON.parse(JSON.stringify(book)),
    updateStoreOnDisk: async (mutate) => { book = mutate(book); },
    transportFor: (url, token) => { seen.push({ url, token }); return cloud.call; },
    deviceName: () => 'Workshop PC',
    enabled: () => enabled,
  });
  const call = (name, args) => handlers[name](null, args);
  return { call, cloud, seen, book: () => book, setBook: (b) => { book = b; } };
}

test('switched off: every handler answers enabled:false and nothing is called', async () => {
  const r = rig({ enabled: false });
  for (const h of ['hub:qlk-status', 'hub:qlk-setup', 'hub:qlk-rotate', 'hub:qlk-revoke', 'hub:qlk-reset', 'hub:qlk-approve']) {
    assert.deepEqual(await r.call(h, {}), { ok: true, enabled: false }, h);
  }
  assert.equal(r.cloud.calls.length, 0);
  assert.equal(r.seen.length, 0);
});

test('no Khayt Cloud sign-in: status says so and sends nothing', async () => {
  const r = rig({ withCloud: false });
  assert.deepEqual(await r.call('hub:qlk-status'), { ok: true, enabled: true, cloud: false });
  assert.equal(r.cloud.calls.length, 0);
});

test('set up: the key is stored by main, the token comes from the book, and the window never sees the seed', async () => {
  const r = rig();
  const res = await r.call('hub:qlk-setup');
  assert.deepEqual(res, { ok: true, state: 'current' });
  const rec = r.book().settings.quoteLinkKey;
  assert.ok(rec && rec.seed && rec.kid);
  assert.deepEqual(r.seen[0], { url: 'https://cloud.example', token: 'test-token-not-real' });
  const st = await r.call('hub:qlk-status');
  assert.equal(st.state, 'current');
  assert.equal(st.keys.length, 1);
  assert.equal(st.keys[0].mine, true);
  assert.equal(JSON.stringify(st).includes(rec.seed), false, 'no seed in the status');
  assert.equal(JSON.stringify(res).includes(rec.seed), false);
});

test('a second computer waits; the first sees it and approves it', async () => {
  const cloud = fakeCloud();
  const first = rig({ cloud });
  await first.call('hub:qlk-setup');
  const second = rig({ cloud });
  assert.equal((await second.call('hub:qlk-setup')).state, 'pending');
  assert.equal((await second.call('hub:qlk-status')).state, 'pending');

  const st = await first.call('hub:qlk-status');
  assert.equal(st.pending.length, 1);
  assert.equal((await first.call('hub:qlk-approve', { kid: st.pending[0].kid })).ok, true);
  assert.equal((await second.call('hub:qlk-status')).state, 'current');
});

test('rotate stores the new key and drops the old seed', async () => {
  const r = rig();
  await r.call('hub:qlk-setup');
  const old = r.book().settings.quoteLinkKey;
  assert.equal((await r.call('hub:qlk-rotate')).ok, true);
  const now = r.book().settings.quoteLinkKey;
  assert.notEqual(now.kid, old.kid);
  assert.equal(JSON.stringify(r.book()).includes(old.seed), false);
});

test('revoking this computer\'s own key: a code first, then the key is gone from the book', async () => {
  const r = rig();
  await r.call('hub:qlk-setup');
  const kid = r.book().settings.quoteLinkKey.kid;
  assert.deepEqual(await r.call('hub:qlk-revoke', { kid }), { ok: true, codeSent: true });
  assert.ok(r.book().settings.quoteLinkKey, 'nothing removed before the code');
  assert.equal((await r.call('hub:qlk-revoke', { kid, code: 'TESTCODE' })).ok, true);
  assert.equal(r.book().settings.quoteLinkKey, undefined);
});

test('a waiting computer can cancel its own request', async () => {
  const cloud = fakeCloud();
  await rig({ cloud }).call('hub:qlk-setup');
  const second = rig({ cloud });
  await second.call('hub:qlk-setup');
  assert.equal((await second.call('hub:qlk-cancel')).ok, true);
  assert.equal(second.book().settings.quoteLinkKey, undefined);
  assert.equal(cloud.pending.length, 0);
});
