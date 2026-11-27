'use strict';
// lib/main/phone-network-switch.js: an owner's phone flipping "Make no internet
// calls" (POST /api/network/switch), the Mac's phoneSetOutbound on Windows/Linux.
// The route's signing and role are tested over HTTP in test/lan-phone-pairing.test.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/main/phone-network-switch.js');

function harness(network, extra = {}) {
  const book = { settings: network === undefined ? null : { network } };
  const calls = [];
  const sw = P.createPhoneNetworkSwitch(Object.assign({
    getSettings: () => book.settings,
    updateNetwork: async (fn) => { const b = book.settings.network || {}; const n = fn(b); if (n !== b) book.settings = { ...book.settings, network: n }; },
    publish: async (a) => { calls.push(a); return { ok: true, via: null }; },
    highestSeen: () => null,
    notify: () => {},
    now: () => Date.parse('2026-11-26T12:00:00.000Z'),
  }, extra));
  const ask = (body, deviceName = 'Phone') => sw.handle({ body: Buffer.from(JSON.stringify(body)), deviceName });
  return { book, calls, sw, ask };
}

test('the book not read yet: 503 busy, nothing written', async () => {
  const h = harness(undefined);
  const r = await h.ask({ offline: true });
  assert.deepEqual([r.status, r.body.reason], [503, 'busy']);
});

test('seenKeep: an id this computer does not know is ignored, not "changed"', async () => {
  const h = harness({ offline: false, keep: ['cloud'], changedAt: '2026-11-20T10:00:00.000Z' });
  const r = await h.ask({ offline: false, keep: ['cloud', 'ai'], seenKeep: ['cloud', 'a-newer-purpose'] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
});

test('the stamp is forward-only: never before the book\'s own or the highest heard from Khayt Cloud', async () => {
  const ahead = '2026-11-26T12:05:00.000Z';   // inside the 10-minute window: followed
  const h = harness({ offline: false, changedAt: ahead }, { highestSeen: () => '2026-11-26T12:06:00.000Z' });
  const r = await h.ask({ offline: true });
  assert.equal(r.status, 200);
  assert.equal(r.body.network.changedAt, '2026-11-26T12:06:00.001Z');
});

test('a change that landed between reading and writing is not overwritten: 409 changed', async () => {
  const h = harness({ offline: false, changedAt: '2026-11-20T10:00:00.000Z' });
  const sw = P.createPhoneNetworkSwitch({
    getSettings: () => h.book.settings,
    updateNetwork: async (fn) => {
      // The window turned it on meanwhile.
      const b = { offline: true, changedAt: '2026-11-26T11:59:00.000Z' };
      h.book.settings = { network: b };
      const n = fn(b);
      if (n !== b) h.book.settings = { network: n };
    },
    publish: async () => ({ ok: true }), highestSeen: () => null, notify: () => {}, now: () => Date.parse('2026-11-26T12:00:00.000Z'),
  });
  const r = await sw.handle({ body: Buffer.from('{"offline":true}'), deviceName: 'P' });
  assert.deepEqual([r.status, r.body.reason, r.body.network.offline], [409, 'changed', true]);
  assert.equal(h.book.settings.network.changedAt, '2026-11-26T11:59:00.000Z', 'the window\'s change stands');
});

test('one change at a time: a second request while one is in flight is 409 not-saved', async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const h = harness({ offline: false }, { publish: async () => { await gate; return { ok: true }; } });
  const first = h.ask({ offline: true });
  const second = await h.ask({ offline: true });
  assert.deepEqual([second.status, second.body.reason], [409, 'not-saved']);
  release();
  assert.equal((await first).status, 200);
});

test('a write that fails is 409 not-saved; the window is not told', async () => {
  let told = 0;
  const h = harness({ offline: false }, { updateNetwork: async () => { throw new Error('locked'); }, notify: () => { told++; } });
  const r = await h.ask({ offline: true });
  assert.deepEqual([r.status, r.body.reason], [409, 'not-saved']);
  assert.equal(told, 0);
});

test('the phone\'s name, as other computers will show it: no controls or direction marks, bounded', () => {
  assert.equal(P.cleanName('  Turki‮\'s‏ iPhone\n\u0007 '), "Turki's iPhone");
  assert.equal([...P.cleanName('ж'.repeat(200))].length, 80);
  assert.ok(Buffer.byteLength(P.cleanName('😀'.repeat(80)), 'utf8') <= 240);
  assert.equal(P.cleanName(null), '');
});

test('what a phone may keep: every purpose but lan and switch-sync', () => {
  assert.ok(!P.PHONE_KEEPABLE.includes('lan'));
  assert.ok(!P.PHONE_KEEPABLE.includes('switch-sync'));
  for (const p of ['cloud', 'tunnel', 'updates', 'storefront']) assert.ok(P.PHONE_KEEPABLE.includes(p), p);
});
