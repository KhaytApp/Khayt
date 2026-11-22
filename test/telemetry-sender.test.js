const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/telemetry-sender.js');

/**
 * Khayt queued opt-in telemetry for months with nowhere to send it. Now that
 * there is somewhere, the interesting cases are all the ones where the send does
 * NOT happen, or happens and is refused — because those are the ones that decide
 * whether the queue keeps working or wedges.
 *
 * Everything is injected, so each branch runs without a server. The alternative
 * is a test that invents the response it asserts against, which this repo has
 * already shipped once: the Repetier fix whose test asserted against a copy of
 * the adapter written inline in the test, and which therefore could not catch
 * the defect that was still there.
 */

const ev = (kind, i = 0) => ({ kind, payload: { feature: `f${i}`, installId: 'aaaaaaaabbbbbbbb' }, at: '2026-08-27' });
const BOTH = { crash: true, usage: true };

/** A fetch that answers with one status, and records what it was given. */
function fakeFetch(status, headers = {}) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return { status, headers: { get: (k) => headers[k.toLowerCase()] ?? null } };
  };
  fn.calls = calls;
  return fn;
}

function queueDeps(initial) {
  let q = initial.slice();
  return {
    readQueue: () => q,
    writeQueue: (next) => { q = next; },
    current: () => q,
  };
}

// ── planFlush: why nothing was sent ─────────────────────────────────────────

test('no consent sends nothing, whatever is queued', () => {
  const p = S.planFlush({ queue: [ev('crash')], consent: { crash: false, usage: false }, now: 0 });
  assert.deepEqual(p, { send: false, reason: 'no-consent' });
});

test('consent is per stream, and is re-checked at send time', () => {
  // A queue written while usage was ON must not be sent after it was turned off.
  // Checking only at enqueue would send events the shop has since withdrawn.
  const queue = [ev('usage', 1), ev('crash', 2), ev('usage', 3)];
  const p = S.planFlush({ queue, consent: { crash: true, usage: false }, now: 0 });
  assert.equal(p.send, true);
  assert.equal(p.batch.length, 1);
  assert.equal(p.batch[0].kind, 'crash');
});

test('an empty queue is a reason, not a send', () => {
  assert.deepEqual(S.planFlush({ queue: [], consent: BOTH, now: 0 }), { send: false, reason: 'empty' });
});

test('backoff is honoured', () => {
  assert.deepEqual(
    S.planFlush({ queue: [ev('crash')], consent: BOTH, now: 100, nextAttemptAt: 500 }),
    { send: false, reason: 'backoff' });
  assert.equal(S.planFlush({ queue: [ev('crash')], consent: BOTH, now: 900, nextAttemptAt: 500 }).send, true);
});

test('a batch is capped at what the server will read', () => {
  const queue = Array.from({ length: 120 }, (_, i) => ev('usage', i));
  const p = S.planFlush({ queue, consent: BOTH, now: 0 });
  assert.equal(p.batch.length, S.MAX_BATCH);
});

// ── interpret: what a response means for the queue ──────────────────────────

test('200 drops what was sent', () => {
  assert.deepEqual(S.interpret(200), { drop: true, backoffMs: 0, reason: 'accepted' });
});

test('422 DROPS the batch — a poison event must not wedge the queue', () => {
  // The server refused every event for what they ARE, and will refuse them again
  // for the same reason. Keeping them means a permanently unsendable entry at the
  // head of the queue, retrying forever and blocking every good event behind it.
  for (const status of [422, 400, 413]) {
    assert.equal(S.interpret(status).drop, true, `${status} should not be retried forever`);
  }
});

test('404 keeps everything and waits a long time', () => {
  // The ordinary state today: the ingest ships dormant, and a host that has not
  // been updated answers identically. Nothing is wrong, so nothing is lost — and
  // it starts flowing on its own the day the flag flips.
  const v = S.interpret(404);
  assert.equal(v.drop, false);
  assert.equal(v.backoffMs, S.BACKOFF_MAX_MS);
});

test('429 honours Retry-After, but never shortens the wait', () => {
  // A server asking to be called back in one second is not a reason to call back
  // in one second.
  assert.equal(S.interpret(429, { retryAfterSec: 1 }).backoffMs, S.BACKOFF_MIN_MS);
  assert.equal(S.interpret(429, { retryAfterSec: 3600 }).backoffMs, 3600 * 1000);
  assert.equal(S.interpret(429, { retryAfterSec: 999999 }).backoffMs, S.BACKOFF_MAX_MS);
  assert.equal(S.interpret(429, { retryAfterSec: 'soon' }).backoffMs, S.BACKOFF_MIN_MS);
});

test('backoff doubles and then stops', () => {
  let ms = 0;
  const seen = [];
  for (let i = 0; i < 12; i++) { ms = S.interpret(500, { backoffMs: ms }).backoffMs; seen.push(ms); }
  assert.equal(seen[0], S.BACKOFF_MIN_MS);
  assert.ok(seen[1] > seen[0]);
  assert.equal(seen[seen.length - 1], S.BACKOFF_MAX_MS, 'a shop offline for a week must not retry all week');
  // Monotonic: never goes backwards, which would be a retry storm on a flapping link.
  for (let i = 1; i < seen.length; i++) assert.ok(seen[i] >= seen[i - 1]);
});

// ── flushOnce: the whole thing ──────────────────────────────────────────────

test('a successful flush sends the scrubber output verbatim and clears it', async () => {
  const q = queueDeps([ev('crash', 1), ev('usage', 2)]);
  const fetchImpl = fakeFetch(200);
  const r = await S.flushOnce({ ...q, consent: BOTH, fetchImpl, now: () => 1000, appVersion: '3.7.0-beta.10' });
  assert.equal(r.sent, 2);
  assert.equal(r.reason, 'accepted');
  assert.deepEqual(q.current(), []);
  // The transport must not reshape a payload: scrubbing happened once, at
  // enqueue, and anything done here would quietly end that guarantee.
  assert.deepEqual(fetchImpl.calls[0].body.events[0].payload, ev('crash', 1).payload);
  assert.match(fetchImpl.calls[0].init.headers['user-agent'], /^Khayt\/3\.7\.0-beta\.10$/);
});

test('only the events that were sent are removed', async () => {
  const queue = Array.from({ length: 60 }, (_, i) => ev('usage', i));
  const q = queueDeps(queue);
  const r = await S.flushOnce({ ...q, consent: BOTH, fetchImpl: fakeFetch(200), now: () => 1 });
  assert.equal(r.sent, S.MAX_BATCH);
  assert.equal(q.current().length, 60 - S.MAX_BATCH);
  assert.equal(q.current()[0].payload.feature, `f${S.MAX_BATCH}`);
});

test('a 404 leaves the queue exactly as it was', async () => {
  const q = queueDeps([ev('crash', 1)]);
  const r = await S.flushOnce({ ...q, consent: BOTH, fetchImpl: fakeFetch(404), now: () => 1 });
  assert.equal(r.sent, 0);
  assert.equal(r.reason, 'not-enabled');
  assert.equal(q.current().length, 1);
  assert.equal(r.nextAttemptAt, 1 + S.BACKOFF_MAX_MS);
});

test('a refused batch is dropped, and the rest of the queue survives it', async () => {
  const queue = [ev('crash', 1), ev('usage', 2)];
  const q = queueDeps(queue);
  const r = await S.flushOnce({ ...q, consent: BOTH, fetchImpl: fakeFetch(422), now: () => 1 });
  assert.equal(r.sent, 0, 'nothing was stored, so nothing was sent');
  assert.equal(r.reason, 'refused');
  assert.deepEqual(q.current(), [], 'both were in the batch, so both go');
});

test('an unreachable network never throws and never loses an event', async () => {
  const q = queueDeps([ev('crash', 1)]);
  const boom = async () => { throw new Error('EAI_AGAIN'); };
  const r = await S.flushOnce({ ...q, consent: BOTH, fetchImpl: boom, now: () => 1 });
  assert.equal(r.reason, 'unreachable');
  assert.equal(r.status, null);
  assert.equal(q.current().length, 1);
});

test('an unreadable queue file is a quiet no-op', async () => {
  // Telemetry that can break the app is worse than no telemetry.
  const r = await S.flushOnce({
    readQueue: () => { throw new Error('ENOENT'); },
    writeQueue: () => {},
    consent: BOTH,
    fetchImpl: fakeFetch(200),
  });
  assert.equal(r.reason, 'unreadable');
  assert.equal(r.sent, 0);
});

test('nothing is sent without consent — the request is never made', async () => {
  const fetchImpl = fakeFetch(200);
  const q = queueDeps([ev('crash', 1)]);
  const r = await S.flushOnce({ ...q, consent: { crash: false, usage: false }, fetchImpl });
  assert.equal(r.reason, 'no-consent');
  assert.equal(fetchImpl.calls.length, 0, 'consent must be checked before the network, not after');
  assert.equal(q.current().length, 1);
});

test('the endpoint is Khayt, not whatever the shop syncs with', () => {
  // A shop can point cloud sync at its own server. The consent it gave was to
  // send diagnostics to Khayt, so following that setting would send them
  // somewhere the shop never agreed to and nobody reads.
  assert.equal(S.DEFAULT_ENDPOINT, 'https://cloud.khaytapp.com/v1/telemetry');
});
