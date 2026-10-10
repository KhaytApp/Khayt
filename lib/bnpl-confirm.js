'use strict';
/**
 * Finishing a buy-now-pay-later payment the shop sent a link for (KhaytBnplConfirm).
 *
 * ── WHY ───────────────────────────────────────────────────────────────────
 *
 * Khayt made Tabby and Tamara checkout links and stopped there. Both providers
 * need the MERCHANT to act once the customer has paid, and nothing in Khayt did:
 *
 *   - Tamara: an order the customer approved has to be AUTHORISED by the
 *     merchant (POST /orders/{id}/authorise). "Order was not authorised within
 *     72 hours" → expired: the customer paid their first instalment and the
 *     shop has no sale. (docs.tamara.co, Online Order Status Flow.) Capture is
 *     a later step, at shipment; Tamara captures by itself 21 days after
 *     authorisation.
 *   - Tabby: an AUTHORIZED payment has to be CAPTURED
 *     (POST /api/v2/payments/{id}/captures). "Only captured payments are settled
 *     to you"; Tabby captures by itself only after 21 days.
 *
 * Tamara was told to notify https://khaytapp.com/notify — a static website that
 * cannot receive a POST — and Khayt has no public server of its own. So instead
 * of waiting to be told, the app ASKS: while it is open it checks each link it
 * made, takes the step the provider is waiting for, and records the payment on
 * the job the way the Record Payment dialog does.
 *
 * Pure: no network, no store. The host fetches the provider's status, asks
 * `nextStep` what to do, performs it, and records the result with `settle`.
 *
 * ── THE LINK ON THE JOB ───────────────────────────────────────────────────
 *
 * `order.bnplLinks = [{ provider, id, amount, currency, createdAt, state, remoteStatus, checkedAt }]`
 *   provider  'tabby' | 'tamara'
 *   id        Tabby's payment.id / Tamara's order_id — what every later call takes
 *   state     'open' (still being watched) | 'paid' (recorded on the job) | 'closed' (expired, declined…)
 */
(function (global) {
  const PROVIDERS = ['tabby', 'tamara'];
  // Tamara: a checkout not completed within 30 minutes expires, an approved order not
  // authorised within 72 hours expires. Tabby captures by itself after 21 days. Past
  // 30 days there is nothing left for Khayt to do, so a link stops being checked.
  const WATCH_DAYS = 30;

  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
  const money = (v) => Math.round(num(v) * 100) / 100;

  /** The record a new link leaves on its job, or null when the provider gave no id to follow. */
  function linkRecord(provider, created, opts) {
    const o = opts || {};
    if (PROVIDERS.indexOf(provider) < 0 || !created) return null;
    const id = provider === 'tamara' ? created.orderId : created.paymentId;
    if (!id || typeof id !== 'string') return null;
    return {
      provider, id,
      amount: money(o.amount),
      currency: String(o.currency || 'SAR').toUpperCase(),
      createdAt: o.at || new Date().toISOString(),
      state: 'open',
    };
  }

  /** Add (or refresh) a link on an order; the same provider id is never listed twice. */
  function addLink(order, link) {
    if (!order || !link) return order;
    const list = Array.isArray(order.bnplLinks) ? order.bnplLinks.filter((l) => l && !(l.provider === link.provider && l.id === link.id)) : [];
    list.push(link);
    order.bnplLinks = list;
    return order;
  }

  /** Links still worth asking about: open, and younger than the watch window. */
  function linksToCheck(orders, now) {
    const t = now ? Date.parse(now) : Date.now();
    const out = [];
    for (const order of Array.isArray(orders) ? orders : []) {
      if (!order || !Array.isArray(order.bnplLinks)) continue;
      for (const link of order.bnplLinks) {
        if (!link || link.state !== 'open' || PROVIDERS.indexOf(link.provider) < 0) continue;
        const age = t - Date.parse(link.createdAt || '');
        if (!(age >= 0) || age > WATCH_DAYS * 86400000) continue;
        out.push({ orderId: order.id, link });
      }
    }
    return out;
  }

  /**
   * What to do about a link, from the provider's own status.
   *   'wait'      the customer has not finished (or the provider is mid-way)
   *   'authorise' Tamara approved: the merchant must authorise (within 72 h)
   *   'capture'   Tabby authorised: the merchant must capture to be settled
   *   'paid'      nothing left to do; record the payment
   *   'closed'    it will never be paid (expired, declined, rejected, cancelled)
   *
   * Statuses compared case-blind: Tabby's API answers "AUTHORIZED", its webhooks "authorized".
   */
  function nextStep(provider, status) {
    const s = String(status || '').toLowerCase();
    if (provider === 'tamara') {
      if (s === 'approved') return 'authorise';
      if (s === 'authorised' || s === 'authorized' || s === 'partially_captured' || s === 'fully_captured') return 'paid';
      if (s === 'expired' || s === 'declined' || s === 'canceled' || s === 'cancelled'
        || s === 'fully_refunded' || s === 'refunded') return 'closed';
      return 'wait';                                        // new, or anything Tamara adds later
    }
    if (provider === 'tabby') {
      if (s === 'authorized') return 'capture';
      if (s === 'closed') return 'paid';
      if (s === 'rejected' || s === 'expired') return 'closed';
      return 'wait';                                        // created
    }
    return 'wait';
  }

  /**
   * The payment to record when a link is paid: what was already paid on the job plus the
   * link's amount — recordPayment takes the TOTAL paid, and clamps it to what was billed.
   */
  function paymentFor(order, link, today) {
    const name = link.provider === 'tamara' ? 'Tamara' : 'Tabby';
    return {
      amount: money(num(order && order.paidAmount) + num(link.amount)),
      method: name,
      paidAt: today || null,
    };
  }

  /** Mark a link after a check. Returns the link (mutated) for convenience. */
  function settle(link, state, remoteStatus, at) {
    if (!link) return link;
    if (state === 'paid' || state === 'closed') link.state = state;
    if (remoteStatus != null) link.remoteStatus = String(remoteStatus);
    link.checkedAt = at || new Date().toISOString();
    return link;
  }

  const api = { WATCH_DAYS, linkRecord, addLink, linksToCheck, nextStep, paymentFor, settle };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytBnplConfirm = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
