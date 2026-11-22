'use strict';
/**
 * Who is allowed to write a shop's book.
 *
 * The rule these tests exist for: LIVENESS BEATS TIME. A lock is broken because
 * the process that took it is gone, not because a clock says enough seconds have
 * passed. An app paused at a breakpoint, or stopped by the OS, or simply busy
 * through a long import, is still the owner — and taking its lock away on a
 * stopwatch is precisely how two writers end up on one file.
 *
 * The clock is consulted in exactly one case: a record written by a DIFFERENT
 * machine, where there is no pid we can ask about.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const L = require('../lib/store-lock.js');

const HOST = 'shop-mac';
const now = 1_000_000;
const held = (over = {}) => ({ ...L.claim({ app: 'Khayt', pid: 42, host: HOST, now }), ...over });

test('no lock file at all is free to take', () => {
  const v = L.decide(null, { pid: 7, host: HOST, now, alive: null });
  assert.equal(v.action, 'take');
  assert.equal(v.reason, 'no-lock');
});

test('a file that is not a lock record does not hold the store hostage', () => {
  // Anything without a pid: truncated by a crash mid-write, hand-edited, or a
  // stray file. A holder that can never be disproved would wedge the app.
  for (const junk of [{}, { v: 1 }, { pid: 0 }, { pid: 'nonsense' }, 'text', 42]) {
    assert.equal(L.decide(junk, { pid: 7, host: HOST, now, alive: null }).action, 'take',
      `${JSON.stringify(junk)} should not read as a live holder`);
  }
});

test('our own record is ours, not somebody else holding us out', () => {
  const v = L.decide(held({ pid: 7 }), { pid: 7, host: HOST, now, alive: null });
  assert.equal(v.action, 'own');
});

test('same pid on a different machine is a different process', () => {
  // Pids are only unique per host. Without the host check, one shop's laptop
  // would happily adopt another's lock the moment the numbers collided.
  const v = L.decide(held({ pid: 7, host: 'other-mac' }), { pid: 7, host: HOST, now, alive: true });
  assert.notEqual(v.action, 'own');
});

test('a living holder keeps the lock however old its heartbeat', () => {
  const ancient = held({ heartbeat: now - 10 * L.STALE_AFTER_MS });
  const v = L.decide(ancient, { pid: 7, host: HOST, now, alive: true });
  assert.equal(v.action, 'held');
  assert.equal(v.reason, 'holder-alive');
});

test('a holder whose process is gone releases it, however fresh its heartbeat', () => {
  const justNow = held({ heartbeat: now });
  const v = L.decide(justNow, { pid: 7, host: HOST, now, alive: false });
  assert.equal(v.action, 'take');
  assert.equal(v.reason, 'holder-gone');
});

test('another machine is judged on the clock, because there is no pid to ask', () => {
  const fresh = held({ host: 'nas-mac', heartbeat: now - 1000 });
  assert.equal(L.decide(fresh, { pid: 7, host: HOST, now, alive: null }).action, 'held');

  const stale = held({ host: 'nas-mac', heartbeat: now - L.STALE_AFTER_MS - 1 });
  assert.equal(L.decide(stale, { pid: 7, host: HOST, now, alive: null }).action, 'take');
});

test('the same machine spelt in different case is the same machine', () => {
  // Node's os.hostname() says "Turkis-MacBook-Air.local"; Swift's
  // ProcessInfo.hostName says "turkis-macbook-air.local". Compared raw, the Mac
  // app reads Electron's lock as foreign, stops checking whether that pid is
  // alive, and judges a LIVE holder on the clock. Found by running the two
  // against each other, not by reading either.
  const theirs = L.claim({ app: 'Khayt', pid: 9, host: 'Turkis-MacBook-Air.local', now });
  const v = L.decide(theirs, { pid: 7, host: 'turkis-macbook-air.local', now, alive: true });
  assert.equal(v.action, 'held');
  assert.equal(v.reason, 'holder-alive', 'case alone must not make it another host');

  const ours = L.decide(theirs, { pid: 9, host: 'TURKIS-MacBook-Air.LOCAL', now, alive: null });
  assert.equal(ours.action, 'own', 'we must recognise our own record whatever the case');
});

test('a heartbeat from the future is not treated as stale', () => {
  // Clock skew between two machines, or a store on a share. A negative age must
  // not wrap round into "old enough to break".
  const skewed = held({ host: 'nas-mac', heartbeat: now + 60_000 });
  assert.equal(L.decide(skewed, { pid: 7, host: HOST, now, alive: null }).action, 'held');
});

test('an unknowable holder on this machine falls back to the clock', () => {
  const fresh = held({ heartbeat: now - 1000 });
  assert.equal(L.decide(fresh, { pid: 7, host: HOST, now, alive: null }).reason, 'unknown-fresh');
  const old = held({ heartbeat: now - L.STALE_AFTER_MS - 1 });
  assert.equal(L.decide(old, { pid: 7, host: HOST, now, alive: null }).reason, 'unknown-stale');
});

test('the heartbeat interval leaves room for missed beats', () => {
  // If these ever cross, a holder that is merely slow looks dead.
  assert.ok(L.STALE_AFTER_MS >= 3 * L.HEARTBEAT_MS,
    'stale must be at least three heartbeats, or a busy holder loses its lock');
});

test('a beat moves only the heartbeat', () => {
  const first = L.claim({ app: 'Khayt', pid: 42, host: HOST, now });
  const later = L.beat(first, now + 5000);
  assert.equal(later.heartbeat, now + 5000);
  assert.equal(later.takenAt, first.takenAt, 'when it was taken must not move');
  assert.equal(later.pid, first.pid);
});

test('the message names the application, never a pid', () => {
  const v = L.decide(held({ app: 'Khayt for Mac' }), { pid: 7, host: HOST, now, alive: true });
  const said = L.describe({ ...v, selfHost: HOST });
  assert.match(said, /Khayt for Mac/);
  assert.doesNotMatch(said, /\b42\b/, 'a pid means nothing to a shop');
  assert.match(said, /read-only/);
});

test('a holder elsewhere says where', () => {
  const v = L.decide(held({ host: 'front-desk', heartbeat: now }), { pid: 7, host: HOST, now, alive: null });
  assert.match(L.describe({ ...v, selfHost: HOST }), /front-desk/);
});

test('nothing is said when we hold it ourselves', () => {
  assert.equal(L.describe({ action: 'take' }), '');
  assert.equal(L.describe({ action: 'own' }), '');
});
