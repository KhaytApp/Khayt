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
const { createLivePrinterPublisher } = require('../lib/main/live-printer-publisher.js');

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

test('liveRows is the LAN route\'s builder: lan-server.js uses it, not a copy', () => {
  const src = fs.readFileSync(path.join(ROOT, 'lib', 'lan-server.js'), 'utf8');
  assert.match(src, /require\('\.\/live-snapshot\.js'\)\.liveRows\(store, printerCache\(\) \|\| \{\}\)/);
  const rows = Snap.liveRows({ machines: [{ id: 'a', name: 'A', printerApi: { type: 'moonraker' } }, { id: 'b', name: 'B' }] },
    { a: { state: 'printing', progress: 41.6, lastUpdated: 1790331302000, type: 'moonraker' } });
  assert.equal(rows.length, 2);
  assert.equal(rows[0].progress, 42);
  assert.equal(rows[0].lastOkAt, new Date(1790331302000).toISOString());
  assert.deepEqual(rows[0].problems, []);
  assert.equal(rows[1].hasPrinterApi, false);
  assert.equal(rows[1].state, null);
});

// ── the publisher, with fakes ────────────────────────────────────────────────

function harness(over = {}) {
  let t = Date.parse('2026-09-25T10:15:02.000Z');
  const calls = [];
  const logs = [];
  let status = 200;
  let answerBody = { ok: true };
  let rows = [row('m1')];
  let throwNext = null;
  const timers = [];
  const deps = Object.assign({
    session: () => ({ url: 'https://cloud.example', shopId: 'shop_1', token: 'fake-token', dek: DEK, role: 'owner', scope: 'cloud.example|shop_1' }),
    // A computer that is hearing from its printers: a row without its own
    // lastOkAt answered just now (the freshness rule, hasFreshPoll).
    rows: () => rows.map((r) => ('lastOkAt' in r ? r : { ...r, lastOkAt: new Date(t).toISOString() })),
    allowed: () => true,
    put: async (s, body) => {
      if (throwNext) { const e = throwNext; throwNext = null; throw e; }
      calls.push({ shopId: s.shopId, body });
      return { status, body: answerBody };
    },
    seal: (plain, dek) => SyncCrypto.encryptStore(plain, dek),
    now: () => t,
    log: (m) => logs.push(m),
    setInterval: (fn) => { timers.push(fn); return { unref() {} }; },
    clearInterval: () => {},
  }, over);
  const p = createLivePrinterPublisher(deps);
  return {
    p, calls, logs, timers,
    advance: (ms) => { t += ms; },
    set: (o) => { if ('status' in o) status = o.status; if ('body' in o) answerBody = o.body; if ('rows' in o) rows = o.rows; if ('throw' in o) throwNext = o.throw; },
  };
}

test('publisher: PUT once, quiet while nothing changes, a heartbeat at 45 s, a change after 2 s', async () => {
  const h = harness();
  await h.p.start();
  assert.equal(h.calls.length, 1);
  const plain = SyncCrypto.decryptStore(h.calls[0].body.ciphertext, DEK);
  assert.equal(plain.printers[0].id, 'm1');
  h.advance(10000);
  assert.equal((await h.p.tick()).why, 'not-due');
  assert.equal(h.calls.length, 1, 'nothing changed and no heartbeat due');
  h.advance(35000);
  assert.equal((await h.p.tick()).sent, true, 'the 45 s heartbeat');
  h.set({ rows: [row('m1', { progress: 43 })] });
  h.advance(2000);
  assert.equal((await h.p.tick()).sent, true, 'a change, 2 s after the last');
  assert.equal(h.calls.length, 3);
});

test('publisher: lastOkAt (and lastUpdated) alone changing does not post', async () => {
  const h = harness();
  const answered = (at) => Object.assign(row('m1', { at }), { lastOkAt: at });
  h.set({ rows: [answered('2026-09-25T10:15:02.000Z')] });
  await h.p.start();
  assert.equal(h.calls.length, 1);
  for (let i = 1; i <= 4; i++) {
    h.advance(10000);
    const at = new Date(Date.parse('2026-09-25T10:15:02.000Z') + i * 10000).toISOString();
    h.set({ rows: [answered(at)] });
    await h.p.tick();
  }
  assert.equal(h.calls.length, 1, 'four answered polls in 40 s: no post');
  h.advance(5000);
  await h.p.tick();
  assert.equal(h.calls.length, 2, 'the heartbeat carries the newer stamps');
  const plain = SyncCrypto.decryptStore(h.calls[1].body.ciphertext, DEK);
  assert.equal(typeof plain.printers[0].lastOkAt, 'number');
});

test('publisher: off when signed out, locked, another shop, a viewer, or the gate refuses cloud', async () => {
  for (const [why, over] of [
    ['signed-out', { session: () => null }],
    ['signed-out', { session: () => ({ url: 'https://cloud.example', shopId: 'shop_1', token: 'fake-token', dek: null, scope: 's' }) }],
    ['viewer', { session: () => ({ url: 'https://cloud.example', shopId: 'shop_1', token: 'fake-token', dek: DEK, role: 'viewer', scope: 's' }) }],
    ['blocked', { allowed: () => false }],
  ]) {
    const h = harness(over);
    const r = await h.p.start();
    assert.equal(r.why, why);
    assert.equal(h.calls.length, 0, why + ': never');
  }
  // Not started (never unlocked here): a poll's nudge does nothing.
  const idle = harness();
  assert.equal((await idle.p.tick()).why, 'idle');
  assert.equal(idle.calls.length, 0);
});

test('publisher: the switch turned on stops it; asked once a heartbeat while refused; resumes when allowed', async () => {
  let allowed = true;
  let asked = 0;
  const h = harness({ allowed: () => { asked += 1; return allowed; } });
  await h.p.start();
  assert.equal(h.calls.length, 1);
  allowed = false;
  h.set({ rows: [row('m1', { progress: 50 })] });
  h.advance(3000);
  assert.equal((await h.p.tick()).why, 'blocked');
  const askedThen = asked;
  h.advance(15000);
  await h.p.tick();
  h.advance(15000);
  await h.p.tick();
  assert.equal(asked, askedThen, 'not asked again before a heartbeat has passed');
  assert.equal(h.calls.length, 1);
  allowed = true;
  h.advance(15000);
  assert.equal((await h.p.tick()).sent, true);
  // A refusal at the transport (the switch turned on mid-way) waits too.
  h.set({ rows: [row('m1', { progress: 51 })], throw: Object.assign(new Error('blocked'), { code: 'outbound.blocked' }) });
  h.advance(3000);
  assert.equal((await h.p.tick()).why, 'blocked');
  h.advance(3000);
  assert.equal((await h.p.tick()).why, 'not-due');
});

test('publisher: 401 stops and needs sign-in; only a new unlock starts it again', async () => {
  const h = harness();
  h.set({ status: 401 });
  await h.p.start();
  assert.equal(h.p.state().signIn, true);
  assert.equal(h.calls.length, 1);
  h.set({ status: 200, rows: [row('m1', { progress: 99 })] });
  h.advance(60000);
  assert.equal((await h.p.tick()).why, 'signin');
  assert.equal(h.calls.length, 1, 'not asked again every check');
  assert.ok(h.logs.some((m) => /401/.test(m)));
  assert.ok(h.logs.every((m) => !/fake-token/.test(m)), 'the token is never logged');
  h.p.stop();
  await h.p.start();
  assert.equal(h.calls.length, 2, 'a new unlock forgets the 401');
  assert.equal(h.p.state().signIn, false);
});

test('publisher: 403 stops for the session', async () => {
  const h = harness();
  h.set({ status: 403 });
  await h.p.start();
  h.set({ rows: [row('m1', { progress: 99 })] });
  h.advance(60000);
  await h.p.tick();
  assert.equal(h.calls.length, 1, 'a 403 is not asked again every check');
  assert.equal(h.p.state().refused, true);
});

test('publisher: backs off — 429 by its retryAfter, 5xx and 413 by a heartbeat, no answer at the next check', async () => {
  const h = harness();
  h.set({ status: 429, body: { error: 'slow down', retryAfter: 7 } });
  await h.p.start();
  assert.equal(h.calls.length, 1);
  h.set({ status: 200, rows: [row('m1', { progress: 60 })] });
  h.advance(6000);
  assert.equal((await h.p.tick()).why, 'not-due', 'inside the 7 s');
  h.advance(1000);
  assert.equal((await h.p.tick()).sent, true, 'after it');

  for (const status of [500, 503, 413]) {
    const e = harness();
    e.set({ status });
    await e.p.start();
    e.set({ status: 200, rows: [row('m1', { progress: 61 })] });
    e.advance(44000);
    assert.equal((await e.p.tick()).why, 'not-due', status + ': waits a heartbeat');
    e.advance(1000);
    assert.equal((await e.p.tick()).sent, true, status + ': then tries again');
  }

  const n = harness();
  n.set({ throw: new Error('ECONNRESET') });
  assert.equal((await n.p.start()).why, 'network');
  n.advance(15000);
  assert.equal((await n.p.tick()).sent, true, 'no answer: tried at the next check, as the Mac does');
});

test('publisher: never throws into the poll', async () => {
  const h = harness({ rows: () => { throw new Error('boom'); } });
  const r = await h.p.start();
  assert.equal(r.sent, false);
  const s = harness({ session: () => { throw new Error('boom'); } });
  assert.equal((await s.p.start()).sent, false);
});

test('publisher: an answer that lands after stop() is not this session\'s', async () => {
  let release;
  const h = harness({ put: () => new Promise((resolve) => { release = () => resolve({ status: 401, body: null }); }) });
  const pending = h.p.start();
  h.p.stop();
  release();
  await pending;
  assert.equal(h.p.state().signIn, false);
});

test('main wires it: started at unlock, stopped at lock and quit, nudged after each poll, gate purpose cloud', () => {
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  assert.match(main, /createLivePrinterPublisher\(/);
  assert.match(main, /allowed: \(\) => outboundGate\.check\('cloud'\)\.allowed === true/);
  assert.match(main, /put: \(s, body\) => cloudClient\.putLivePrinters\(/);
  assert.match(main, /livePrinterPublisher\.stop\(\);\n    livePrinterPublisher\.start\(\);\n[^\n]*\n    networkSwitchSync\.start\(\);\n    return \{ ok: true \};/);
  assert.match(main, /ipcMain\.handle\('hub:cloud-lock', \(\) => \{ networkSwitchSync\.stop\(\); livePrinterPublisher\.stop\(\);/);
  assert.match(main, /app\.on\('will-quit', \(\) => \{ try \{ livePrinterPublisher\.stop\(\); \}/);
  assert.match(main, /diagnoseMovedPrinters\(machineList\)[^\n]*\n[\s\S]{0,200}livePrinterPublisher\.tick\(\);/);
  const client = fs.readFileSync(path.join(ROOT, 'lib', 'cloud-client.js'), 'utf8');
  assert.match(client, /method: 'PUT', path: `\/v1\/shops\/\$\{seg\(shopId\)\}\/live\/printers`/);
});


// ── The security review (Nov 22) ─────────────────────────────────────────────

test('only a computer hearing from its printers publishes: the laptop at home, or a stopped poll, sends nothing', async () => {
  const h = harness();
  // Every printer unreachable from here: no row answered in the last 3 minutes.
  h.set({ rows: [Object.assign(row('m1'), { state: null, lastOkAt: null, errorCode: 'unreachable' })] });
  const r = await h.p.start();
  assert.deepEqual([r.sent, r.why], [false, 'not-polling']);
  assert.equal(h.calls.length, 0);
  // A frozen cache: the last answer was 4 minutes ago.
  h.set({ rows: [Object.assign(row('m1'), { lastOkAt: new Date(Date.parse('2026-09-25T10:15:02.000Z') - 4 * 60 * 1000).toISOString() })] });
  assert.equal((await h.p.tick()).why, 'not-polling');
  // One printer answering is enough to speak for the shop.
  h.set({ rows: [Object.assign(row('m1'), { lastOkAt: null }), row('m2')] });
  assert.equal((await h.p.tick()).sent, true);
  assert.equal(Snap.hasFreshPoll([{ lastOkAt: Date.parse('2026-09-25T10:15:02.000Z') - 1000 }], Date.parse('2026-09-25T10:15:02.000Z')), true, 'epoch ms too');
  assert.equal(Snap.hasFreshPoll([], Date.now()), false);
});

test('too large is not sealed again before the next heartbeat; a huge retryAfter is capped at 5 minutes', async () => {
  let seals = 0;
  // A seal whose envelope is always over 64 KB, slimmed or not.
  const h = harness({ seal: () => { seals++; return { v: 1, ct: 'x'.repeat(70000) }; } });
  const first = await h.p.start();
  assert.equal(first.why, 'too-large');
  const n = seals;
  h.advance(15000); await h.p.tick(); h.advance(15000); await h.p.tick();
  assert.equal(seals, n, 'not sealed again inside the heartbeat');
  h.advance(20000); await h.p.tick();
  assert.ok(seals > n, 'tried again at the heartbeat');
  const k = harness();
  k.set({ status: 429, body: { retryAfter: 86400 } });
  await k.p.start();
  k.set({ status: 200, body: { ok: true }, rows: [row('m1', { progress: 77 })] });
  k.advance(5 * 60 * 1000 + 1000);
  assert.equal((await k.p.tick()).sent, true, 'a day-long retryAfter waits 5 minutes, not a day');
});
