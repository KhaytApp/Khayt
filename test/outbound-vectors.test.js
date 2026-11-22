'use strict';
/**
 * lib/outbound.js, the "make no internet calls" switch (P8; decided Nov 22,
 * D1–D6 as recommended). The vectors are shared with the Mac and iPhone,
 * which run the same file in JavaScriptCore.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const O = require('../lib/outbound.js');
const V = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'outbound-vectors.json'), 'utf8'));

for (const c of V.cases) {
  test(c.why, () => {
    const r = O.allowed(c.settings, c.purpose, c.ctx);
    // `once` is part of the contract: present (true) only when a person's
    // answer let the call through, and the host must spend the token then.
    const got = { allowed: r.allowed, reason: r.reason };
    if (r.once !== undefined) got.once = r.once;
    assert.deepEqual(got, c.want);
    assert.equal(r.purpose, c.purpose);
  });
}

test('the purposes and reasons are the closed sets the vectors name, in order', () => {
  assert.deepEqual([...O.PURPOSES], V.purposes);
  for (const c of V.cases) assert.ok(O.REASONS.includes(c.want.reason), c.want.reason);
  for (const p of O.PURPOSES) assert.ok(O.INFO[p], p);
  assert.deepEqual(Object.keys(O.INFO), [...O.PURPOSES]);
});

test('describe: one row per purpose, in order, with kept and the reason', () => {
  const rows = O.describe({ network: { offline: true, keep: ['storage', 'lan', 'nope'] }, telemetry: { crashOptIn: true } });
  assert.deepEqual(rows.map((r) => r.purpose), [...O.PURPOSES]);
  const by = Object.fromEntries(rows.map((r) => [r.purpose, r]));
  assert.deepEqual([by.storage.allowed, by.storage.reason, by.storage.kept], [true, 'kept', true]);
  assert.deepEqual([by.updates.allowed, by.updates.reason], [false, 'offline']);
  assert.deepEqual([by.lan.allowed, by.lan.reason, by.lan.kept], [true, 'lan', false], 'lan is never kept, never blocked');
  assert.deepEqual([by.updates.automatic, by.ai.automatic, by.storage.owner, by.updates.owner], [true, false, 'shop', 'khayt']);
  assert.equal(O.describe(null).filter((r) => r.purpose !== 'lan').every((r) => r.reason === 'settings-unknown'), true);
});

test('isOffline is the shop\'s switch or this computer\'s, never looser', () => {
  assert.equal(O.isOffline({}, {}), false);
  assert.equal(O.isOffline({ network: { offline: true } }, { local: { offline: false } }), true);
  assert.equal(O.isOffline({}, { local: { offline: true } }), true);
  assert.deepEqual(O.keptOf({ network: { keep: ['ai', 'ai', 'lan', 5, 'x'] } }), ['ai']);
});

test('junk never throws and never allows more', () => {
  for (const s of [undefined, null, 0, 'x', [], { network: null }, { network: [] }, { network: { keep: 'updates' } }]) {
    for (const p of [...O.PURPOSES, '', null, '__proto__', 'constructor']) {
      for (const ctx of [undefined, null, 'x', { local: null }, { host: { toString: () => '10.0.0.1' } }]) {
        const r = O.allowed(s, p, ctx);
        assert.equal(typeof r.allowed, 'boolean');
        assert.ok(O.REASONS.includes(r.reason), r.reason);
      }
    }
  }
  assert.equal(O.allowed({}, '__proto__').reason, 'unknown-purpose');
  // And never allows more: with no book, nothing but a LAN address goes out;
  // a purpose outside the closed set never does.
  for (const s of [undefined, null, 0, 'x', []]) {
    for (const p of O.PURPOSES) if (p !== 'lan') assert.equal(O.allowed(s, p).allowed, false, `${p} with ${JSON.stringify(s)}`);
    assert.equal(O.allowed(s, 'lan', { host: 'example.com' }).allowed, false);
  }
  for (const p of ['', 'telemetry', 'LAN', 'Updates', '__proto__', 'toString']) assert.equal(O.allowed({}, p).allowed, false, p);
  assert.equal(O.allowed({ network: { offline: true, keep: ['__proto__'] } }, 'updates').allowed, false);
});

test('loads in JavaScriptCore\'s shape, alone', () => {
  const ctx = {}; vm.createContext(ctx);
  // Self-contained: it loads alone, whatever the Mac's module order.
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'outbound.js'), 'utf8'), ctx);
  assert.equal(vm.runInContext("KhaytOutbound.allowed({network:{offline:true}}, 'lan', {host:'10.1.2.3'}).allowed", ctx), true);
  assert.equal(vm.runInContext("KhaytOutbound.allowed({network:{offline:true}}, 'lan', {host:'2130706433'}).reason", ctx), 'lan', 'numeric IPv4 loopback');
  assert.equal(vm.runInContext("KhaytOutbound.allowed({network:{offline:true}}, 'lan', {host:'example.com'}).reason", ctx), 'lan-host-public');
});

test('switch-sync (Turki, Nov 22): kept only through Khayt Cloud, shown kept in the list, untickable', () => {
  const via = { network: { offline: true, via: 'cloud', keep: ['updates', 'switch-sync'] } };
  assert.deepEqual(O.keptOf(via), ['updates', 'switch-sync'], 'the keep entry is ignored; the via rule adds it once');
  assert.equal(O.switchSyncKept(via), true);
  const row = O.describe(via).find((r) => r.purpose === 'switch-sync');
  assert.deepEqual([row.allowed, row.reason, row.kept, row.automatic], [true, 'kept', true, true]);
  const dropped = { network: { offline: true, via: 'cloud', dropSwitchSync: true } };
  assert.equal(O.describe(dropped).find((r) => r.purpose === 'switch-sync').kept, false);
  assert.deepEqual(O.keptOf({ network: { offline: true, keep: ['switch-sync'] } }), []);
  assert.equal(O.INFO['switch-sync'].every, '15m');
  // Through Khayt Cloud keeps nothing else: every other purpose but lan is still blocked.
  for (const p of O.PURPOSES) if (p !== 'lan' && p !== 'switch-sync') assert.equal(O.allowed({ network: { offline: true, via: 'cloud' } }, p).allowed, false, p);
});

test('a person\'s answer: one switch-sync call, then spent; once:true only then', () => {
  const T = 1795000000000;
  const off = { network: { offline: true } };
  let tok = O.answerToken(T);
  assert.equal(O.ANSWER_MS, 20000);
  assert.deepEqual({ ...tok }, { purpose: 'switch-sync', at: T, until: T + 20000, spent: false });
  assert.ok(Object.isFrozen(tok), 'the host cannot stretch it in place');
  const r = O.allowed(off, 'switch-sync', { answer: tok, now: T + 10 });
  assert.deepEqual(r, { allowed: true, reason: 'kept', purpose: 'switch-sync', once: true });
  tok = O.spend(tok);
  assert.equal(O.allowed(off, 'switch-sync', { answer: tok, now: T + 20 }).allowed, false, 'used once');
  assert.equal(O.answerLive(tok, T + 20), false);
  // Kept by its own rule already: no `once`, nothing to spend.
  const kept = O.allowed({ network: { offline: true, via: 'cloud' } }, 'switch-sync', { answer: O.answerToken(T), now: T + 10 });
  assert.equal(kept.once, undefined);
  // Junk never makes a live token.
  for (const bad of [null, {}, 'x', O.answerToken(NaN), O.answerToken('1'), { purpose: 'switch-sync', at: T, until: T + 1, spent: 0 }]) {
    assert.equal(O.answerLive(bad, T), false, JSON.stringify(bad));
  }
});
