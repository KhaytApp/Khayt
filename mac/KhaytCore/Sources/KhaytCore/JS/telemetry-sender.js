'use strict';

/**
 * Flush the local telemetry queue to the cloud ingest.
 *
 * Khayt has scrubbed and queued opt-in telemetry since 3.2.0 and never sent any
 * of it, because there was no endpoint. There is one now (khayt-cloud#25,
 * `POST /v1/telemetry`), and this is the other half.
 *
 * ── What this file is NOT allowed to do ────────────────────────────────────
 *
 * It never scrubs. Scrubbing happens once, at the single choke point in main.js
 * where an event is ENQUEUED, and this transport only ever sees scrubber output.
 * That is what makes an unscrubbed send impossible by construction rather than
 * by review, and adding "just tidy this field before sending" here would quietly
 * end that guarantee.
 *
 * It never throws into the caller and never blocks anything. Telemetry that can
 * break the app is worse than no telemetry.
 *
 * ── Everything is injected ─────────────────────────────────────────────────
 *
 * `fetch`, the clock and the queue's reader/writer are parameters. Every branch
 * below — the 429, the 422, the network failure, the backoff — is reachable from
 * a test without a server, which is the standard the SDCP socket layer set in
 * this repo after a fix shipped with a test that had invented the payload it was
 * asserting against.
 */

/*
 * An IIFE that publishes `KhaytTelemetrySender` as well as exporting, so the
 * native Mac app runs THIS policy in JavaScriptCore rather than a Swift copy of
 * it (issue #1789). Under JSC there is no `module`, and a top-level `const`
 * would collide with every other bundled module's in the one global scope.
 * The Mac uses the pure parts (`planFlush`, `interpret`); `flushOnce` is
 * Electron's, with its fetch.
 */
(function () {
  /** Server's cap. Sending more just means the rest is dropped, unread. */
  const MAX_BATCH = 50;

  /** Backoff after a failure, in ms. Doubling, capped — a shop with no internet
   *  for a week must not spend the week retrying every minute. */
  const BACKOFF_MIN_MS = 5 * 60 * 1000;
  const BACKOFF_MAX_MS = 12 * 60 * 60 * 1000;

  /**
   * The endpoint is deliberately NOT the shop's configured cloud URL.
   *
   * A shop can point cloud sync at its own server, and its data going there is the
   * whole point of that setting. Telemetry is different: the consent the shop gave
   * was to send diagnostics to Khayt, so it goes to Khayt, and a self-hoster who
   * wants it elsewhere says so explicitly rather than having it follow a setting
   * that means something else.
   */
  const DEFAULT_ENDPOINT = 'https://cloud.khaytapp.com/v1/telemetry';

  /**
   * Decide what to do, without doing it.
   *
   * Split out from the send so the policy — consent, backoff, emptiness — is
   * readable and testable on its own, and so "why did nothing send" has one place
   * to look.
   *
   * @returns {{send: false, reason: string} | {send: true, batch: Array}}
   */
  function planFlush({ queue, consent, now, nextAttemptAt }) {
    if (!consent || (!consent.crash && !consent.usage)) return { send: false, reason: 'no-consent' };
    if (nextAttemptAt && now < nextAttemptAt) return { send: false, reason: 'backoff' };
    const q = Array.isArray(queue) ? queue : [];
    // Consent is per stream and can be withdrawn for one and not the other, so it
    // is checked HERE as well as at enqueue: a queue written while usage was on
    // must not be sent after it was turned off.
    const eligible = q.filter((e) => e && (e.kind === 'crash' ? consent.crash : consent.usage));
    if (!eligible.length) return { send: false, reason: 'empty' };
    return { send: true, batch: eligible.slice(0, MAX_BATCH) };
  }

  /**
   * What a response means for the queue.
   *
   * The case worth stating is 422. It means the server refused every event in the
   * batch, and it will refuse them again for the same reason next time — so those
   * events are DROPPED rather than kept. A queue that keeps what can never be
   * accepted is a queue with a poison entry at its head, retrying forever and
   * blocking every good event behind it. Telemetry is the last thing that should
   * be allowed to wedge itself.
   *
   * 404 is the ordinary state today, not an error: the ingest ships dormant, and a
   * host that has not been updated answers the same way. Keep the queue, back off
   * a long way, and it starts flowing the day the flag flips.
   *
   * @returns {{drop: boolean, backoffMs: number, reason: string}}
   */
  function interpret(status, { retryAfterSec, backoffMs } = {}) {
    const grow = () => Math.min(BACKOFF_MAX_MS, Math.max(BACKOFF_MIN_MS, (backoffMs || 0) * 2 || BACKOFF_MIN_MS));
    if (status === 200) return { drop: true, backoffMs: 0, reason: 'accepted' };
    // Refused for what it IS, not for when it arrived. Keeping it changes nothing
    // except that nothing else ever gets sent.
    if (status === 422 || status === 400 || status === 413) return { drop: true, backoffMs: BACKOFF_MIN_MS, reason: 'refused' };
    if (status === 429) {
      const wait = Number(retryAfterSec);
      return {
        drop: false,
        // Honour Retry-After when it is sane, and never let it be shorter than the
        // ordinary backoff — a server asking to be called back in one second is
        // not a reason to call back in one second.
        backoffMs: Number.isFinite(wait) && wait > 0
          ? Math.min(BACKOFF_MAX_MS, Math.max(BACKOFF_MIN_MS, wait * 1000))
          : grow(),
        reason: 'rate-limited',
      };
    }
    if (status === 404) return { drop: false, backoffMs: BACKOFF_MAX_MS, reason: 'not-enabled' };
    return { drop: false, backoffMs: grow(), reason: 'retry' };
  }

  /** Remove exactly the events that were sent, matching by identity. */
  function withoutSent(queue, batch) {
    const sent = new Set(batch);
    return (Array.isArray(queue) ? queue : []).filter((e) => !sent.has(e));
  }

  /**
   * Attempt one flush.
   *
   * @param {object} deps
   * @param {() => Array} deps.readQueue
   * @param {(q: Array) => void} deps.writeQueue
   * @param {object} deps.consent            { crash, usage }
   * @param {Function} deps.fetchImpl        fetch-compatible
   * @param {() => number} [deps.now]
   * @param {string} [deps.endpoint]
   * @param {number} [deps.backoffMs]        current backoff, for growth
   * @param {number} [deps.nextAttemptAt]    epoch ms; before it, nothing is sent
   * @param {string} [deps.appVersion]
   * @returns {Promise<{sent: number, status: number|null, reason: string, backoffMs: number, nextAttemptAt: number}>}
   */
  async function flushOnce(deps) {
    const now = (deps.now || Date.now)();
    const quiet = (reason, backoffMs = deps.backoffMs || 0, nextAttemptAt = deps.nextAttemptAt || 0) =>
      ({ sent: 0, status: null, reason, backoffMs, nextAttemptAt });

    let queue;
    try { queue = deps.readQueue(); } catch { return quiet('unreadable'); }

    const plan = planFlush({ queue, consent: deps.consent, now, nextAttemptAt: deps.nextAttemptAt });
    if (!plan.send) return quiet(plan.reason);

    const body = JSON.stringify({
      events: plan.batch.map((e) => ({ kind: e.kind, payload: e.payload })),
    });

    let status = null;
    let retryAfterSec = null;
    try {
      const res = await deps.fetchImpl(deps.endpoint || DEFAULT_ENDPOINT, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          // Not identity: the server needs no user agent to accept a batch. It is
          // here so an operator reading access logs can tell Khayt's own traffic
          // from whatever else finds an open POST route.
          'user-agent': `Khayt/${deps.appVersion || 'unknown'}`,
        },
        body,
      });
      status = res.status;
      const ra = res.headers && typeof res.headers.get === 'function' ? res.headers.get('retry-after') : null;
      if (ra) retryAfterSec = Number(ra);
    } catch {
      // Offline, DNS, TLS, a captive portal. Indistinguishable from here and all
      // handled the same way: keep everything, wait longer.
      const backoffMs = interpret(0, { backoffMs: deps.backoffMs }).backoffMs;
      return { sent: 0, status: null, reason: 'unreachable', backoffMs, nextAttemptAt: now + backoffMs };
    }

    const verdict = interpret(status, { retryAfterSec, backoffMs: deps.backoffMs });
    if (verdict.drop) {
      try { deps.writeQueue(withoutSent(deps.readQueue(), plan.batch)); } catch { /* next flush retries */ }
    }
    return {
      sent: verdict.drop && verdict.reason === 'accepted' ? plan.batch.length : 0,
      status,
      reason: verdict.reason,
      backoffMs: verdict.backoffMs,
      nextAttemptAt: verdict.backoffMs ? now + verdict.backoffMs : 0,
    };
  }

  const api = {
    DEFAULT_ENDPOINT, MAX_BATCH, BACKOFF_MIN_MS, BACKOFF_MAX_MS,
    planFlush, interpret, withoutSent, flushOnce,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytTelemetrySender = api;
})();
