'use strict';
/**
 * Publishes this computer's printers to Khayt Cloud, so the phone and the PWA
 * can follow a print away from the shop: `PUT /v1/shops/{id}/live/printers`,
 * sealed with the shop's key. The Mac's LivePrinterPublisher
 * (mac/KhaytCore/Sources/KhaytApp/LivePrinterPublisher.swift), rule for rule;
 * the snapshot, the signature and WHEN to send are lib/live-snapshot.js.
 *
 * OFF unless Khayt Cloud is unlocked on this computer for the book's own shop
 * (`session()`), the role may write (a viewer's snapshot is a 403), and the
 * "make no internet calls" gate allows `cloud` (`allowed()`). It never throws:
 * `tick()` swallows everything, so a poll that nudges it cannot be broken by it.
 *
 * WHEN: checked every 15 s and after every printer poll. Sent on a change once
 * 2 s have passed since the last accepted snapshot, else as a 45 s heartbeat.
 *
 * ANSWERS (the Mac's):
 *   2xx  remembered as sent.
 *   429  waits the server's `retryAfter` (else 2 s).
 *   401  stops; Khayt Cloud has to be signed in to again (`state().signIn`).
 *   403  stops for this session (a viewer, or a token the shop revoked).
 *   else (a deploy, a 5xx, a 413) tried again 45 s later, never in a loop.
 *   A request that never got an answer is tried at the next check.
 * A new unlock (`stop()` then `start()`) forgets all of it.
 */

const Snap = require('../live-snapshot.js');

const CHECK_MS = 15000;

/**
 * @param {object} d
 * @param {() => ({url, shopId, token, dek, role?, scope}|null)} d.session
 * @param {() => object[]} d.rows       the /api/machines/live rows, now
 * @param {() => boolean} d.allowed     the outbound gate's answer for `cloud`
 * @param {(session, body) => Promise<{status:number, body:any}>} d.put
 * @param {(plain, dek) => object} d.seal   lib/sync-crypto.js encryptStore
 * @param {() => number} [d.now]
 * @param {(msg: string) => void} [d.log]   never given a token, key or body
 */
function createLivePrinterPublisher(d) {
  const now = typeof d.now === 'function' ? d.now : () => Date.now();
  const log = typeof d.log === 'function' ? d.log : () => {};
  const every = typeof d.setInterval === 'function' ? d.setInterval : setInterval;
  const clear = typeof d.clearInterval === 'function' ? d.clearInterval : clearInterval;

  let timer = null;
  let scope = null;
  let lastSent = null;
  let lastSignature = null;
  let notBefore = null;
  let inFlight = false;
  let refused = false;   // 403
  let signIn = false;    // 401
  // Bumped by start() and stop(): an answer that lands after them is not this session's.
  let gen = 0;

  function forget() { lastSent = null; lastSignature = null; notBefore = null; refused = false; signIn = false; }

  async function publish() {
    if (!timer || inFlight) return { sent: false, why: 'idle' };
    const s = d.session();
    if (!s || !s.dek || !s.url || !s.shopId) return { sent: false, why: 'signed-out' };
    // Another shop or server unlocked: what was learned about the last one does not carry over.
    if (s.scope !== scope) { forget(); scope = s.scope; }
    if (refused) return { sent: false, why: 'refused' };
    if (signIn) return { sent: false, why: 'signin' };
    if (typeof s.role === 'string' && s.role.toLowerCase() === 'viewer') return { sent: false, why: 'viewer' };
    if (!s.token) return { sent: false, why: 'signed-out' };
    const rows = d.rows();
    if (!Array.isArray(rows) || rows.length === 0) return { sent: false, why: 'no-printers' };
    const t = now();
    // Only a computer that is hearing from the printers speaks for the shop.
    if (!Snap.hasFreshPoll(rows, t)) return { sent: false, why: 'not-polling' };
    const signature = Snap.signature(rows);
    if (!Snap.due({ changed: signature !== lastSignature, now: t, lastSent, notBefore })) return { sent: false, why: 'not-due' };
    // The switch: asked only when a snapshot is due, so a shop that is
    // offline is asked once a heartbeat, not every check.
    if (!d.allowed()) { notBefore = t + Snap.HEARTBEAT_MS; return { sent: false, why: 'blocked' }; }
    inFlight = true;
    const mine = gen;
    try {
      const at = new Date(t).toISOString();
      const body = Snap.body(rows, at, (plain) => d.seal(plain, s.dek));
      // Too large even slimmed: not sealed again until the next heartbeat.
      if (!body) { notBefore = t + Snap.HEARTBEAT_MS; return { sent: false, why: 'too-large' }; }
      let r;
      try { r = await d.put(s, body); } catch (e) {
        // The gate refused at the transport (the switch turned on between the
        // check and the call): wait a heartbeat, as above.
        if (e && e.code === 'outbound.blocked') { notBefore = t + Snap.HEARTBEAT_MS; return { sent: false, why: 'blocked' }; }
        // No answer at all: tried again at the next check, as the Mac does.
        return { sent: false, why: 'network' };
      }
      if (mine !== gen) return { sent: false, why: 'stopped' };
      const status = r && Number.isInteger(r.status) ? r.status : 0;
      if (status >= 200 && status < 300) {
        lastSent = t;
        lastSignature = signature;
        return { sent: true };
      }
      if (status === 429) {
        const ra = r.body && Number(r.body.retryAfter);
        notBefore = t + (Number.isFinite(ra) && ra > 0 ? Math.min(ra * 1000, Snap.MAX_RETRY_AFTER_MS) : Snap.MIN_INTERVAL_MS);
        return { sent: false, why: 'rate' };
      }
      if (status === 401) {
        signIn = true;
        log('[live-printers] Khayt Cloud refused the sign-in (401): stopped until it is signed in again');
        return { sent: false, why: 'signin' };
      }
      if (status === 403) {
        refused = true;
        log('[live-printers] Khayt Cloud refused this computer (403): stopped for this session');
        return { sent: false, why: 'refused' };
      }
      notBefore = t + Snap.HEARTBEAT_MS;
      return { sent: false, why: 'error', status };
    } finally { if (mine === gen) inFlight = false; }
  }

  /** One check. Never throws, never rejects. */
  function tick() {
    let p;
    try { p = publish(); } catch (_) { return Promise.resolve({ sent: false, why: 'error' }); }
    return p.catch(() => ({ sent: false, why: 'error' }));
  }

  function start() {
    if (timer) return Promise.resolve({ sent: false, why: 'running' });
    gen += 1;
    forget();
    scope = null;
    timer = every(() => { tick(); }, CHECK_MS);
    if (timer && typeof timer.unref === 'function') timer.unref();
    return tick();
  }

  function stop() {
    if (timer) clear(timer);
    timer = null;
    gen += 1;
    inFlight = false;
    forget();
    scope = null;
  }

  function state() {
    return { running: !!timer, signIn, refused, lastSent, notBefore };
  }

  return { start, stop, tick, state };
}

module.exports = { createLivePrinterPublisher, CHECK_MS };
