const { test } = require('node:test');
const assert = require('node:assert/strict');
const B = require('../lib/webhook-bus.js');

test('migrateLegacyWebhooks: one subscription per distinct URL, events collapsed', () => {
  const subs = B.migrateLegacyWebhooks({
    enabled: true, secret: 's3cret',
    events: {
      order_created: 'https://a.example/hook',
      status_changed: 'https://a.example/hook',
      payment_received: 'https://b.example/hook',
      quote_approved: '',
    },
  });
  assert.equal(subs.length, 2, 'two distinct URLs');
  const a = subs.find(s => s.url === 'https://a.example/hook');
  assert.deepEqual(a.events.sort(), ['order_created', 'status_changed']);
  assert.equal(a.secret, 's3cret', 'legacy secret carried over');
  assert.equal(a.enabled, true);
  const b = subs.find(s => s.url === 'https://b.example/hook');
  assert.deepEqual(b.events, ['payment_received']);
});

test('migrateLegacyWebhooks: already-migrated config is left alone', () => {
  const existing = [{ id: 'x', url: 'https://k.example', events: ['order_created'], enabled: true }];
  assert.equal(B.migrateLegacyWebhooks({ subscriptions: existing }), existing);
});

test('migrateLegacyWebhooks: empty/absent legacy config → no subscriptions', () => {
  assert.deepEqual(B.migrateLegacyWebhooks({}), []);
  assert.deepEqual(B.migrateLegacyWebhooks(null), []);
  assert.deepEqual(B.migrateLegacyWebhooks({ events: { order_created: '  ' } }), []);
});

test('matchSubscriptions: fan-out to every enabled listener, skipping disabled', () => {
  const subs = [
    { id: '1', url: 'https://a', events: ['order_created', 'order_shipped'], enabled: true },
    { id: '2', url: 'https://b', events: ['order_created'], enabled: true },
    { id: '3', url: 'https://c', events: ['order_created'], enabled: false },
    { id: '4', url: 'https://d', events: ['payment_received'], enabled: true },
    { id: '5', url: '', events: ['order_created'], enabled: true },
  ];
  assert.deepEqual(B.matchSubscriptions(subs, 'order_created').map(s => s.id), ['1', '2'],
    'one event fans out to N urls; disabled and url-less skipped');
  assert.deepEqual(B.matchSubscriptions(subs, 'order_shipped').map(s => s.id), ['1']);
  assert.deepEqual(B.matchSubscriptions(subs, 'nope'), []);
  assert.deepEqual(B.matchSubscriptions(null, 'order_created'), []);
});

test('buildDeliveryBody carries id/event/version/timestamp/payload', () => {
  const body = B.buildDeliveryBody('order_shipped', { orderId: 'O1' }, 'dlv_1', '2026-07-20T00:00:00Z');
  assert.deepEqual(body, {
    id: 'dlv_1', event: 'order_shipped', version: 1,
    timestamp: '2026-07-20T00:00:00Z', payload: { orderId: 'O1' },
  });
  assert.ok(B.buildDeliveryBody('x').id.startsWith('dlv_'), 'auto id when omitted');
});

test('backoffDelayMs follows the ladder and clamps', () => {
  assert.equal(B.backoffDelayMs(1), 0);
  assert.equal(B.backoffDelayMs(2), 30_000);
  assert.equal(B.backoffDelayMs(3), 120_000);
  assert.equal(B.backoffDelayMs(4), 600_000);
  assert.equal(B.backoffDelayMs(5), 3_600_000);
  assert.equal(B.backoffDelayMs(99), 3_600_000, 'clamped at the last rung');
  assert.equal(B.backoffDelayMs(0), 0);
});

test('shouldRetry: 2xx done, 410 never, others retry until the cap', () => {
  assert.equal(B.shouldRetry(200, 1), false, '2xx is success');
  assert.equal(B.shouldRetry(204, 1), false);
  assert.equal(B.shouldRetry(410, 1), false, '410 Gone is permanent');
  assert.equal(B.shouldRetry(500, 1), true);
  assert.equal(B.shouldRetry(429, 2), true);
  assert.equal(B.shouldRetry(undefined, 1), true, 'network error retries');
  assert.equal(B.shouldRetry(500, B.MAX_ATTEMPTS), false, 'stops at the attempt cap');
  assert.equal(B.isGone(410), true);
  assert.equal(B.isGone(500), false);
});

test('appendDelivery bounds the log to the cap, keeping the newest', () => {
  let log = [];
  for (let i = 0; i < 250; i++) log = B.appendDelivery(log, { id: i, subscriptionId: 's1' });
  assert.equal(log.length, B.DELIVERY_LOG_CAP, 'bounded');
  assert.equal(log[log.length - 1].id, 249, 'newest kept');
  assert.equal(log[0].id, 250 - B.DELIVERY_LOG_CAP, 'oldest dropped');
  assert.equal(B.appendDelivery(null, { id: 'a' }).length, 1, 'tolerates a missing log');
});

test('deliveriesFor filters by subscription, newest first', () => {
  const log = [
    { id: 1, subscriptionId: 's1' }, { id: 2, subscriptionId: 's2' }, { id: 3, subscriptionId: 's1' },
  ];
  assert.deepEqual(B.deliveriesFor(log, 's1').map(d => d.id), [3, 1]);
  assert.deepEqual(B.deliveriesFor(log, 'nope'), []);
});

/* ── Durable retry queue ─────────────────────────────────────────── */

test('schedulePending queues a retry with an absolute due time', () => {
  const now = Date.parse('2026-07-20T00:00:00Z');
  const q = B.schedulePending([], { id: 'd1', subscriptionId: 's1', event: 'order_shipped', payload: { a: 1 }, attempt: 2 }, 30_000, now);
  assert.equal(q.length, 1);
  assert.equal(q[0].attempt, 2);
  assert.equal(q[0].nextAttemptAt, '2026-07-20T00:00:30.000Z');
  assert.deepEqual(q[0].payload, { a: 1 });
});

test('schedulePending replaces an existing entry for the same delivery (no duplicates)', () => {
  const now = Date.parse('2026-07-20T00:00:00Z');
  let q = B.schedulePending([], { id: 'd1', subscriptionId: 's1', event: 'e', attempt: 1 }, 0, now);
  q = B.schedulePending(q, { id: 'd1', subscriptionId: 's1', event: 'e', attempt: 2 }, 30_000, now);
  assert.equal(q.length, 1, 'still one entry');
  assert.equal(q[0].attempt, 2, 'updated to the newer attempt');
});

test('duePending returns retries that came due — including while the app was closed', () => {
  const now = Date.parse('2026-07-20T12:00:00Z');
  const pending = [
    { id: 'past', subscriptionId: 's1', nextAttemptAt: '2026-07-20T11:00:00Z' },   // due while closed
    { id: 'now', subscriptionId: 's1', nextAttemptAt: '2026-07-20T12:00:00Z' },
    { id: 'future', subscriptionId: 's1', nextAttemptAt: '2026-07-20T13:00:00Z' },
    { id: 'bad', subscriptionId: 's1', nextAttemptAt: 'not-a-date' },              // malformed → retry now
    { id: 'orphan', nextAttemptAt: '2026-07-20T11:00:00Z' },                        // no subscription → skip
  ];
  assert.deepEqual(B.duePending(pending, now).map(p => p.id).sort(), ['bad', 'now', 'past']);
});

test('futurePending reports the remaining delay so timers can be re-armed', () => {
  const now = Date.parse('2026-07-20T12:00:00Z');
  const out = B.futurePending([
    { id: 'a', subscriptionId: 's', nextAttemptAt: '2026-07-20T12:00:30Z' },
    { id: 'b', subscriptionId: 's', nextAttemptAt: '2026-07-20T11:00:00Z' },
  ], now);
  assert.equal(out.length, 1);
  assert.equal(out[0].id, 'a');
  assert.equal(out[0].inMs, 30_000);
});

test('removePending drops a delivery once it succeeds or gives up', () => {
  const q = [{ id: 'a' }, { id: 'b' }];
  assert.deepEqual(B.removePending(q, 'a').map(p => p.id), ['b']);
  assert.deepEqual(B.removePending(null, 'a'), []);
});

test('pending queue is bounded so a broken endpoint cannot grow it forever', () => {
  let q = [];
  for (let i = 0; i < B.PENDING_CAP + 50; i++) {
    q = B.schedulePending(q, { id: 'd' + i, subscriptionId: 's', event: 'e', attempt: 1 }, 0, 0);
  }
  assert.equal(q.length, B.PENDING_CAP);
  assert.equal(q[q.length - 1].id, 'd' + (B.PENDING_CAP + 49), 'newest kept');
});

/* ── The bytes two apps sign ──────────────────────────────────────────────
 *
 * The Mac app posts these webhooks too, and it builds them from this module.
 * So the payload's field names AND their order are part of the contract: JSON
 * preserves insertion order, the HMAC is over those bytes, and a consumer that
 * verifies a delivery from one app must verify the identical delivery from the
 * other.
 */
test('statusPayload is the exact object the renderer used to build inline', () => {
  const order = { id: 'ORD-1', project: 'Bracket', client: 'Acme' };
  assert.equal(
    JSON.stringify(B.statusPayload('status_changed', order, 'completed')),
    JSON.stringify({ orderId: 'ORD-1', project: 'Bracket', newStatus: 'completed', client: 'Acme' }));
});

test('order_delivered carries no status, because delivered is not one', () => {
  // A handed-over job stays `completed` with a `deliveredAt`; a `newStatus`
  // here would be inventing a state neither app has.
  const order = { id: 'ORD-1', project: 'Bracket', client: 'Acme' };
  assert.equal(
    JSON.stringify(B.statusPayload('order_delivered', order, 'completed')),
    JSON.stringify({ orderId: 'ORD-1', project: 'Bracket', client: 'Acme' }));
});

test('buildWireBody is the envelope main.js has posted since webhooks shipped', () => {
  assert.equal(
    JSON.stringify(B.buildWireBody('status_changed', { id: 'dlv_1' }, 1789)),
    JSON.stringify({ event: 'status_changed', payload: { id: 'dlv_1' }, timestamp: 1789 }));
});

test('the transport builds its body from this module, not from a literal', () => {
  // The envelope is written down once because a second app sends it now. A
  // main.js that went back to building it inline would drift silently — the
  // deliveries would still arrive, and only the Mac's would fail verification.
  const main = require('node:fs').readFileSync(
    require('node:path').join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /webhookBus\.buildWireBody\(webhookEvent, payload\)/,
    'hub:fire-webhook no longer uses the shared envelope');
});
