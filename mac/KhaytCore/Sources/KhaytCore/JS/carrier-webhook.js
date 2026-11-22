'use strict';
/**
 * What a signed carrier webhook — SMSA, Aramex, Saudi Post — does to the book.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * It lived inline in `lib/lan-server.js`, which cannot run on the Mac, so the
 * Mac answered a carrier's status update 404 and a parcel's trail stopped at
 * whatever the shop typed by hand. What is a RULE moved here: reading the
 * carrier's payload, finding the job by its tracking number, and moving its
 * shipping status forward. What is PLUMBING stayed with each server: the body,
 * the HMAC, the replay cache, the lockout and the write chain. The same split
 * as `lib/storefront-webhook.js`.
 *
 * ── CALLED INSIDE THE WRITE ───────────────────────────────────────────────
 *
 * `apply` is run on the book as it is inside the write. Two carrier events
 * arriving together would otherwise each build the job's history from the same
 * base, and the one that landed last would drop the other's entry — losing a
 * step of the trail rather than ordering it. A server may ALSO call it on the
 * book it last read, to answer an event that changes nothing without writing.
 *
 * Pure: the moment is the caller's, and nothing here touches a clock or a disk.
 */
(function (global) {
  const Carriers = global.KhaytCarriers
    || (typeof require === 'function' ? require('./carriers.js') : null);
  const OrderStatus = global.KhaytOrderStatus
    || (typeof require === 'function' ? require('./order-status.js') : null);

  /** The carriers that send a webhook. Manual never does. */
  const CARRIERS = ['smsa', 'aramex', 'spl'];

  /**
   * The event in a carrier's payload, or null when there is none Khayt can
   * read — no tracking number, or no status it recognises.
   *
   * Null is not "ignore". The signature already matched, so this genuinely is
   * the carrier sending something unmapped, and the servers answer it 422 so it
   * shows in the carrier's own delivery dashboard — where a broken integration
   * belongs — rather than being acknowledged and silently dropped.
   */
  function read(carrierId, payload, headers, config) {
    if (CARRIERS.indexOf(carrierId) === -1) return null;
    const carrier = Carriers && Carriers.getCarrier(carrierId);
    const evt = carrier ? carrier.parseWebhook(payload, headers || {}, config || {}) : null;
    if (!evt || !evt.trackingNumber || !evt.shippingStatus) return null;
    return evt;
  }

  const holds = (tn) => (o) => o && o.trackingNumber && String(o.trackingNumber) === String(tn);

  /**
   * The book with this event on it.
   *
   * `at` is when the event happened — the carrier's own time when it sent one,
   * else the caller's now. Returns `{ store, order, outcome }`:
   *
   *   - `unknown`   no job holds this tracking number. The book is untouched,
   *                 and the servers still answer 200: a different answer would
   *                 tell whoever holds the secret which parcels this shop has.
   *   - `unchanged` the job is already at or past this status (an event that
   *                 arrived out of order). Untouched.
   *   - `advanced`  the job moved forward, its trail gained a line, and a
   *                 finished job was stamped shipped or delivered.
   */
  function apply(cur, evt, at) {
    const log = [...((cur && cur.printLog) || [])];
    const i = log.findIndex(holds(evt.trackingNumber));
    if (i === -1) return { store: cur, order: null, outcome: 'unknown' };
    const was = log[i];
    const step = Carriers.advanceShippingStatus(was.shippingStatus, evt.shippingStatus);
    if (step === was.shippingStatus) return { store: cur, order: null, outcome: 'unchanged' };
    const next = {
      ...was,
      shippingStatus: step,
      shippingHistory: [...(was.shippingHistory || []), { status: step, at, source: 'webhook', note: '' }],
    };
    // `shippedAt` and `deliveredAt`, by the rule the shipping dialog uses — so
    // the webhook and the dialog cannot disagree about when a parcel left.
    OrderStatus.stampFromShipping(next, step, at);
    log[i] = next;
    return { store: { ...cur, printLog: log }, order: next, outcome: 'advanced' };
  }

  const api = { CARRIERS, read, apply };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCarrierWebhook = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
