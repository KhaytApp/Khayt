'use strict';
const test = require('node:test');
const assert = require('node:assert');
const auth = require('../lib/lan-auth.js');

/**
 * The end-to-end tests in `lan-auth-lockout.test.js` drive a real server and
 * count status codes, and they are what proved the lockout worked. These are
 * the arithmetic underneath, which is worth pinning separately for the reason
 * `bumpFailure`'s own comment gives: the broken version was SELF-CONSISTENT.
 * The counter reset itself on every attempt, sat at 1 forever, and every unit
 * test anyone would have thought to write against it would have passed.
 *
 * So these test the thing that was actually wrong: does it ever LOCK.
 */

test('ten failures lock the caller out, which the inert version never did', () => {
  let rec;
  let now = 1_000_000;
  for (let i = 0; i < 9; i++) {
    rec = auth.bumpFailure(rec, now, { limit: 10, lockoutMs: 60_000 });
    now += 250;                                  // a fast attacker
    assert.equal(auth.isLockedOut(rec, now, 10), false, `locked after ${i + 1}`);
  }
  rec = auth.bumpFailure(rec, now, { limit: 10, lockoutMs: 60_000 });
  assert.equal(rec.count, 10);
  assert.equal(auth.isLockedOut(rec, now, 10), true);
});

test('the window opens on the FIRST failure, not the last', () => {
  // This is the bug: `resetAt` starting at 0 meant `now >= resetAt` was always
  // true, so the count reset to 0 on every attempt and never reached the limit.
  const first = auth.bumpFailure(undefined, 1_000_000, { lockoutMs: 60_000 });
  assert.equal(first.count, 1);
  assert.equal(first.resetAt, 1_060_000, 'the clock did not start');
});

test('reaching the limit restarts the clock, so a lockout is a full cooldown', () => {
  let rec = { count: 9, resetAt: 1_000_500 };
  rec = auth.bumpFailure(rec, 1_000_400, { limit: 10, lockoutMs: 60_000 });
  assert.equal(rec.count, 10);
  assert.equal(rec.resetAt, 1_060_400, 'it served out the remaining 100ms instead');
});

test('the lockout expires, and the next failure starts a fresh window', () => {
  const locked = { count: 10, resetAt: 1_060_000 };
  assert.equal(auth.isLockedOut(locked, 1_059_999, 10), true);
  assert.equal(auth.isLockedOut(locked, 1_060_000, 10), false);
  const after = auth.bumpFailure(locked, 1_060_000, { limit: 10, lockoutMs: 60_000 });
  assert.equal(after.count, 1);
});

/// The key is a header the caller controls behind a tunnel, so the table would
/// otherwise grow without bound.
test('the failed-attempt table is swept of expired keys and then capped', () => {
  const map = new Map();
  map.set('a', { count: 3, resetAt: 500 });        // expired
  map.set('b', { count: 3, resetAt: 5_000 });      // live
  map.set('c', null);                              // junk
  assert.equal(auth.sweepFailedAttempts(map, 1_000, 5000), 1);
  assert.deepEqual([...map.keys()], ['b']);

  const many = new Map();
  for (let i = 0; i < 20; i++) many.set('ip' + i, { count: 1, resetAt: 9_999 });
  assert.equal(auth.sweepFailedAttempts(many, 1_000, 5), 5);
  // Oldest-inserted go first, so the newest attackers are the ones still tracked.
  assert.equal(many.has('ip19'), true);
  assert.equal(many.has('ip0'), false);
});

/**
 * The per-IP bucket is keyed on a value the remote caller controls behind a
 * tunnel, so rotating it hands them a fresh bucket every request. This gate is
 * keyed on nothing, which is precisely why a spoofed key cannot move it.
 */
test('the global auth gate counts only failures, and then blocks everything', () => {
  const state = { count: 0, windowStart: 0, blockedUntil: 0 };
  let now = 1_000_000;
  for (let i = 0; i < 49; i++) {
    assert.equal(auth.globalAuthThrottle(state, now, true), false);
  }
  assert.equal(auth.globalAuthThrottle(state, now, true), true, 'the 50th did not trip it');
  // And now even a SUCCESSFUL attempt is refused, for the cooldown.
  assert.equal(auth.globalAuthThrottle(state, now + 1, false), true);
  assert.equal(auth.globalAuthThrottle(state, now + 60_001, false), false);
});

test('a successful attempt never advances the global auth gate', () => {
  const state = { count: 0, windowStart: 0, blockedUntil: 0 };
  for (let i = 0; i < 500; i++) auth.globalAuthThrottle(state, 1_000_000, false);
  assert.equal(state.count, 0);
});

/**
 * An estimate is not an auth attempt and always succeeds, so it never touches
 * the gate above — yet it is the most expensive thing an anonymous caller can
 * ask for. This one counts EVERY call.
 */
test('the global window gate counts every call and has no cooldown', () => {
  const state = { count: 0, windowStart: 1_000_000 };
  for (let i = 0; i < 120; i++) {
    assert.equal(auth.globalWindowGate(state, 1_000_000, { limit: 120 }), false);
  }
  assert.equal(auth.globalWindowGate(state, 1_000_000, { limit: 120 }), true);
  // No punishment: it simply stops accepting until the window rolls.
  assert.equal(auth.globalWindowGate(state, 1_000_000 + 3_600_001, { limit: 120 }), false);
});

test('a weak PIN is refused for the tunnel and tolerated on the LAN', () => {
  assert.equal(auth.weakTunnelPinWarning('1234', false), null, 'LAN-only must not be gated');
  assert.ok(auth.weakTunnelPinWarning('1234', true));
  assert.ok(auth.weakTunnelPinWarning('1234567', true), 'seven digits is still guessable');
  assert.equal(auth.weakTunnelPinWarning('12345678', true), null);
  assert.equal(auth.weakTunnelPinWarning('hunter2x', true), null);
  assert.ok(auth.weakTunnelPinWarning('abcde', true), 'five characters is short whatever they are');
});

/**
 * Behind the tunnel every request arrives from loopback, which would collapse
 * all remote callers into one bucket.
 */
test('the client IP comes from the tunnel hop only when the socket is loopback', () => {
  assert.equal(auth.tunnelClientIp('::1', '203.0.113.9, 10.0.0.1', true), '203.0.113.9');
  assert.equal(auth.tunnelClientIp('127.0.0.1', '203.0.113.9', true), '203.0.113.9');
  assert.equal(auth.tunnelClientIp('::ffff:127.0.0.1', '203.0.113.9', true), '203.0.113.9');
  // Not loopback: the header is the caller's and must not be believed.
  assert.equal(auth.tunnelClientIp('192.168.1.4', '203.0.113.9', true), '192.168.1.4');
  // No tunnel: never believed at all.
  assert.equal(auth.tunnelClientIp('::1', '203.0.113.9', false), '::1');
  // Header absent or empty falls back to the socket.
  assert.equal(auth.tunnelClientIp('::1', '', true), '::1');
});

test('only http and https survive URL sanitising', () => {
  assert.equal(auth.sanitizeLanHttpUrl('https://example.com/x'), 'https://example.com/x');
  assert.equal(auth.sanitizeLanHttpUrl('javascript:alert(1)'), undefined);
  assert.equal(auth.sanitizeLanHttpUrl('file:///etc/passwd'), undefined);
  assert.equal(auth.sanitizeLanHttpUrl('data:text/html,<script>'), undefined);
  assert.equal(auth.sanitizeLanHttpUrl('not a url'), undefined);
  assert.equal(auth.sanitizeLanHttpUrl(42), undefined);
  assert.equal(auth.sanitizeLanHttpUrl('  '), undefined);
});

test('HTML that reaches a page is escaped', () => {
  assert.equal(auth.lanEscapeHtml('<script>"x"&y'), '&lt;script&gt;&quot;x&quot;&amp;y');
  assert.equal(auth.lanEscapeHtml(null), '');
});
