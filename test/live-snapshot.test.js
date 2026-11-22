'use strict';
/**
 * The live printer snapshot to Khayt Cloud (`PUT /v1/shops/{id}/live/printers`):
 * lib/live-snapshot.js (the Mac's LivePrinters, rule for rule) and
 * lib/main/live-printer-publisher.js (the Mac's LivePrinterPublisher).
 * The cases mirror mac/KhaytCore/Tests/KhaytAppTests/LivePrintersTests.swift.
 * Fakes only: no request leaves this process.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const Snap = require('../lib/live-snapshot.js');
const SyncCrypto = require('../lib/sync-crypto.js');

const ROOT = path.join(__dirname, '..');
const DEK = Buffer.alloc(32, 7);
const seal = (plain) => SyncCrypto.encryptStore(plain, DEK);

/** The Mac test's row. */
function row(id, { progress = 42, at = '2026-09-25T10:15:02.000Z', filename = 'bracket.3mf' } = {}) {
  return { id, name: id, hasPrinterApi: true, apiType: 'bambu', state: 'Printing', progress, filename,
    timeRemaining: 3600, tempNozzle: 220, tempBed: 60, error: null, lastUpdated: at };
}

// ── the pure rules ────────────────────────────────────────────────────────────

test('the plaintext is { v: 1, at, printers } with lastUpdated in epoch MILLISECONDS (the Mac\'s vector)', () => {
  const snap = Snap.snapshot([row('m1')], '2026-09-25T10:15:02Z');
  assert.equal(snap.v, 1);
  assert.equal(snap.at, '2026-09-25T10:15:02Z');
  assert.equal(snap.printers[0].lastUpdated, 1790331302000);
  assert.equal(snap.printers[0].progress, 42);
  assert.equal(snap.printers[0].state, 'Printing');
});

test('both stamps go as epoch ms; the desktop\'s numeric lastUpdated is kept as it is', () => {
  const r = Object.assign(row('m1'), { lastOkAt: '2026-09-25T10:15:02.000Z' });
  const sent = Snap.cloudRow(r);
  assert.equal(sent.lastOkAt, sent.lastUpdated);
  assert.ok(sent.lastOkAt > 1700000000000);
  assert.equal(Snap.cloudRow(Object.assign(row('m1'), { lastUpdated: 1790331302123 })).lastUpdated, 1790331302123);
  assert.equal(Snap.cloudRow(Object.assign(row('m1'), { lastUpdated: null, lastOkAt: null })).lastOkAt, null);
  assert.equal(Snap.cloudRow(Object.assign(row('m1'), { lastUpdated: 'yesterday' })).lastUpdated, null);
  // The row going to the LAN is not touched.
  assert.equal(r.lastOkAt, '2026-09-25T10:15:02.000Z');
});

test('the body is { ciphertext: <envelope object>, at }, and the shop\'s key opens it', () => {
  const b = Snap.body([row('m1')], '2026-09-25T10:15:02.000Z', seal);
  assert.equal(b.at, '2026-09-25T10:15:02.000Z');
  assert.equal(typeof b.ciphertext, 'object', 'the store\'s envelope as an object, not a string of it');
  assert.equal(b.ciphertext.z, 'gzip');
  assert.equal(typeof b.ciphertext.iv, 'string');
  assert.equal(typeof b.ciphertext.tag, 'string');
  const plain = SyncCrypto.decryptStore(b.ciphertext, DEK);
  assert.equal(plain.v, 1);
  assert.equal(plain.at, b.at);
  assert.equal(plain.printers[0].lastUpdated, 1790331302000);
});

test('over 64 KB, filename and error go before any printer; nothing fits → null', () => {
  const noise = () => crypto.randomBytes(6000).toString('hex');
  const rows = Array.from({ length: 12 }, (_, i) => row('m' + i, { filename: noise() }));
  const b = Snap.body(rows, '2026-09-25T10:15:02Z', seal);
  assert.ok(JSON.stringify(b.ciphertext).length <= Snap.MAX_CIPHERTEXT);
  const plain = SyncCrypto.decryptStore(b.ciphertext, DEK);
  assert.equal(plain.printers.length, 12, 'every printer kept');
  assert.ok(plain.printers.every((p) => p.filename === null && p.error === null));
  const names = Array.from({ length: 12 }, (_, i) => Object.assign(row('m' + i), { name: noise() }));
  assert.equal(Snap.body(names, '2026-09-25T10:15:02Z', seal), null);
});

test('sent on a change after 2 s, otherwise only as a 45 s heartbeat, never before notBefore (the Mac\'s timing)', () => {
  const t0 = 1_790_000_000_000;
  assert.ok(Snap.due({ changed: true, now: t0, lastSent: null, notBefore: null }));
  assert.ok(!Snap.due({ changed: true, now: t0 + 1000, lastSent: t0, notBefore: null }));
  assert.ok(Snap.due({ changed: true, now: t0 + 2000, lastSent: t0, notBefore: null }));
  assert.ok(!Snap.due({ changed: false, now: t0 + 30000, lastSent: t0, notBefore: null }));
  assert.ok(Snap.due({ changed: false, now: t0 + 45000, lastSent: t0, notBefore: null }));
  assert.ok(!Snap.due({ changed: true, now: t0 + 5000, lastSent: t0, notBefore: t0 + 10000 }));
  assert.equal(Snap.HEARTBEAT_MS, 45000);
  assert.equal(Snap.MIN_INTERVAL_MS, 2000);
  assert.equal(Snap.MAX_CIPHERTEXT, 65536);
});

test('the signature leaves out lastUpdated and lastOkAt, and nothing else', () => {
  assert.equal(Snap.signature([row('m1', { at: '2026-09-25T10:15:02Z' })]), Snap.signature([row('m1', { at: '2026-09-25T10:15:09Z' })]));
  assert.notEqual(Snap.signature([row('m1', { progress: 42 })]), Snap.signature([row('m1', { progress: 43 })]));
  const answered = (at) => Object.assign(row('m1', { at }), { lastOkAt: at });
  assert.equal(Snap.signature([answered('2026-09-25T10:15:02Z')]), Snap.signature([answered('2026-09-25T10:15:12Z')]),
    'lastOkAt moves on every answered poll: not a change a person can see');
  const refusedRow = Object.assign(answered('2026-09-25T10:15:02Z'), { errorCode: 'access-refused' });
  assert.notEqual(Snap.signature([refusedRow]), Snap.signature([answered('2026-09-25T10:15:02Z')]),
    'a printer that stops answering IS a change');
  const needs = Object.assign(row('m1'), { problems: [{ code: 'filament-runout' }] });
  assert.notEqual(Snap.signature([needs]), Snap.signature([Object.assign(row('m1'), { problems: [] })]));
  // Key order is not a change.
  const r = row('m1');
  const reordered = Object.fromEntries(Object.entries(r).reverse());
  assert.equal(Snap.signature([r]), Snap.signature([reordered]));
});


test('hasFreshPoll: at least one row answered in the last 3 minutes (ISO or epoch ms)', () => {
  const N = Date.parse('2026-09-25T10:15:02.000Z');
  assert.equal(Snap.hasFreshPoll([{ lastOkAt: new Date(N - 60 * 1000).toISOString() }], N), true);
  assert.equal(Snap.hasFreshPoll([{ lastOkAt: N - 1000 }], N), true);
  assert.equal(Snap.hasFreshPoll([{ lastOkAt: new Date(N - 4 * 60 * 1000).toISOString() }, { lastOkAt: null }], N), false);
  assert.equal(Snap.hasFreshPoll([{ lastOkAt: new Date(N + 10 * 60 * 1000).toISOString() }], N), false, 'a stamp from the future is not fresh');
  assert.equal(Snap.hasFreshPoll([], N), false);
  assert.equal(Snap.hasFreshPoll(null, N), false);
});

test('it loads as the Mac loads it: no require, no module, everything from the global (JavaScriptCore)', () => {
  const vm = require('vm');
  const ctx = { console };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  for (const f of ['printer-problems', 'waiting-at-machine', 'printer-needs', 'live-snapshot']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, 'lib', f + '.js'), 'utf8'), ctx, { filename: f + '.js' });
  }
  const L = ctx.KhaytLiveSnapshot;
  assert.ok(L && typeof L.signature === 'function' && typeof L.liveRows === 'function');
  const rows = L.liveRows({ machines: [{ id: 'm1', name: 'U1', printerApi: { type: 'moonraker' } }] }, { m1: { state: 'printing', progress: 42, lastUpdated: 1790331302000 } });
  assert.equal(rows[0].progress, 42);
  assert.equal(L.signature(rows), Snap.signature(rows), 'the same answer in both runtimes');
});
