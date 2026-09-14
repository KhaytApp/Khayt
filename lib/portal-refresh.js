'use strict';
/**
 * What the customer's tracking link should say, and whether to send it.
 *
 * A published job carries a `trackingToken`, and the customer watches a page at
 * that token. Every time the job moves, the page has to be republished or it
 * goes on saying the job is printing after it has been collected.
 *
 * `buildPortalPayload` and `republishPortalIfPublished` lived in
 * `renderer/integrations.js`, so the Mac app — which refuses any move it cannot
 * carry out whole — refused every move on a published job. A shop that had
 * published anything could not run its board on the Mac.
 *
 * The third lift of the same shape, after `lib/telegram-message.js` and
 * `lib/order-email.js`, and the split is the same: the REQUEST is here and the
 * TRANSPORT is not. Electron PUTs it from its main process through
 * `lib/cloud-client.js`; the Mac PUTs the same bytes with URLSession.
 *
 * PURE: no DOM, no network, and no clock of its own — `ctx.now` is the current
 * time in milliseconds, because the trial window is judged against it.
 */
(function (global) {

  const sibling = (name) =>
    (typeof globalThis !== 'undefined' ? globalThis[name] : undefined);

  /**
   * The stage words the portal page prints.
   *
   * English only, and deliberately: they are the renderer's own constant moved
   * across unchanged. The portal page is the customer's, and translating these
   * is a job for whoever translates that page, not a thing to invent here
   * where it would silently disagree with what the page already renders.
   */
  const STATUS_LABELS = {
    quote: 'Quote', pending: 'Pending', on_hold: 'On hold',
    printing: 'Printing', post: 'Post-processing', qc: 'Final checks',
    completed: 'Completed', delivered: 'Delivered',
  };

  /** Where a status sits on the customer's five-step timeline. */
  const STAGE_BY_STATUS = {
    pending: 0, queued: 0, accepted: 0, received: 0, ordered: 0,
    printing: 1, post: 2, qc: 2, completed: 3, delivered: 4,
  };

  /**
   * Is this job's link live, and should a move refresh it?
   *
   * The renderer's guards, in the order it applied them: published at all, a
   * token to publish under, cloud switched on with a shop id, and a portal
   * trial that has not run out.
   *
   * ── THE TRIAL, AND WHY A MISSING CLOCK MEANS YES ──────────────────────────
   *
   * `republishPortalIfPublished` returns early when the trial has lapsed, so
   * nothing is sent. `order-status.outboundFor` never checked the trial at
   * all, which means the two disagreed: a move on a published job was reported
   * as reaching the customer's link when it would have reached nobody. On the
   * Mac that is a move REFUSED for a message that was never going to be sent.
   *
   * Judging the trial needs a clock, and `outboundFor` promises it has none.
   * So `ctx.now` is optional: given one this answers the true thing; without
   * one it assumes the link is live, which is exactly what `outboundFor` did
   * before. It cannot report LESS than the transport will send, which is the
   * direction that matters — over-reporting refuses a move, under-reporting
   * makes one and silently drops the message.
   *
   * While `KhaytCloudPlans.BETA_FREE` is true every shop's trial is `available`
   * anyway, so today this is the same answer either way.
   */
  function wouldRefresh(order, ctx) {
    const c = ctx || {};
    const cloud = (c.settings || {}).cloud || {};
    const o = order || {};
    if (!o.cloudPublished || !o.trackingToken) return false;
    if (!cloud.enabled || !cloud.shopId) return false;

    const trial = trialState(cloud, c.now);
    if (trial && !trial.available) return false;
    return true;
  }

  /** The trial as the renderer computes it, or null when it cannot be judged. */
  function trialState(cloud, now) {
    if (now === undefined || now === null) return null;
    const Trial = sibling('KhaytPortalTrial');
    if (!Trial) return null;
    const Plans = sibling('KhaytCloudPlans');
    return Trial.portalTrialState({
      betaFree: Plans ? Plans.isBetaFree() : true,
      subscribed: cloud.planActive === true,
      startedAt: cloud.portalTrialStartedAt || null,
      now,
    });
  }

  /** The money symbol for the shop's currency, as `renderer/currency.js` picks it. */
  function symbolFor(settings) {
    const table = (sibling('KhaytCurrencies') || {}).CURRENCIES || {};
    const cur = table[(settings || {}).currency] || table.SAR;
    return cur ? cur.symbol : '';
  }

  /** Paid or not, by the one rule both apps already share. */
  function isPaid(order) {
    const Pay = sibling('KhaytOrderPayment');
    if (Pay) return Pay.statusOf(order) === 'paid';
    return (order || {}).paymentStatus === 'paid';
  }

  /**
   * The payload for a job, with NO guards — what the portal page will show.
   *
   * Separate from `requestFor` because the guards belong to the REFRESH, not to
   * the payload. A first publish mints the token and sets `cloudPublished`
   * afterwards, so at the moment it builds its payload the job fails every one
   * of those conditions. One builder, two callers, and the caller that needs
   * the guards asks for them by name.
   *
   * `ctx`: `{ settings, clients, shopName, shopAddress, stages }`.
   *
   *   `shopName` / `shopAddress`  the shop in the language it reads — the
   *                              renderer's `shopField('biz')` and `('addr')`.
   *   `stages`                   the five timeline words, in the customer's
   *                              order: received, printing, finishing, done,
   *                              ready. The renderer reads them from `t()`.
   *
   * Returns `{ kind, payload, customerEmail }`.
   */
  function payloadFor(order, ctx) {
    const c = ctx || {};
    const o = order || {};
    const settings = c.settings || {};
    const isQuote = o.status === 'quote';
    const shopName = String(c.shopName || 'Khayt');

    const payload = {
      shopName,
      ref: o.id,
      status: o.status,
      statusLabel: isQuote ? 'Quote' : (STATUS_LABELS[o.status] || o.status),
      eta: o.dueDate || '',
      // Invoice/receipt fields the portal renders into a printable document.
      issueDate: o.date || '',
      invoiceNo: o.invoiceNumber || o.invoiceNum || o.id,
      seller: {
        name: shopName,
        vat: settings.vat || '',
        // Same dead key as the ZATCA builds: the field is `addr`, per language.
        address: String(c.shopAddress || ''),
      },
      paid: isPaid(o),
    };

    const symbol = symbolFor(settings);
    if (+o.price) {
      payload.amount = (+o.price).toFixed(2);
      if (symbol) payload.currency = symbol;
    }
    // Deposit, stored on the order so it survives a status auto-refresh.
    if (isQuote && +o.cloudDeposit) {
      payload.depositAmount = (+o.cloudDeposit).toFixed(2);
      if (!payload.currency && symbol) payload.currency = symbol;
    }
    if (isQuote && o.cloudPayUrl) payload.payUrl = o.cloudPayUrl;

    // An outstanding balance on an active order — let the customer pay it from
    // the portal, the way the quote deposit works.
    if (!isQuote && o.status !== 'completed' && o.status !== 'delivered') {
      const balance = (+o.price || 0) - (+o.paidAmount || 0);
      if (balance > 0.005) {
        payload.balanceDue = balance.toFixed(2);
        if (!payload.currency && symbol) payload.currency = symbol;
        const payUrl = o.cloudPayUrl || (settings.cloud && settings.cloud.lastPayUrl) || '';
        if (/^https?:\/\//i.test(payUrl)) payload.payUrl = payUrl;
      }
    }

    if (o.status === 'on_hold' && o.holdReason) payload.note = String(o.holdReason);

    // Quotes have no timeline. `on_hold` pauses at the print stage, and the
    // note above is what explains why.
    if (!isQuote) {
      const stages = Array.isArray(c.stages) && c.stages.length === 5
        ? c.stages.map(String)
        : ['Received', 'Printing', 'Finishing', 'Done', 'Ready for pickup'];
      payload.stages = stages;
      payload.stage = o.status === 'on_hold'
        ? 1
        : (STAGE_BY_STATUS[o.status] != null ? STAGE_BY_STATUS[o.status] : 0);
    }

    // The address links the published item to a customer's portal account.
    const clients = Array.isArray(c.clients) ? c.clients : [];
    const client = o.clientId ? clients.find((x) => x && x.id === o.clientId) : null;

    return {
      kind: isQuote ? 'quote' : 'order',
      payload,
      customerEmail: (client && client.email) ? String(client.email) : '',
    };
  }

  /**
   * The publish request a MOVE owes the customer's link, or null when it owes
   * none — the payload plus the token to PUT it under, behind the guards.
   */
  function requestFor(order, ctx) {
    const c = ctx || {};
    if (!wouldRefresh(order, c)) return null;
    const built = payloadFor(order, c);
    return { ...built, pubToken: String((order || {}).trackingToken) };
  }

  /**
   * The path the request is PUT to, under the shop's cloud base URL.
   *
   * Spelled here rather than in each host because it is the one part of the
   * transport both apps have to agree on exactly. `lib/cloud-client.js` builds
   * the same path for Electron.
   */
  function pathFor(shopId, pubToken) {
    // `seg` from lib/cloud-client.js, character for character — including its
    // null handling, so a missing id becomes an empty segment rather than the
    // string "undefined" addressing somebody else's shop.
    const seg = (v) => encodeURIComponent(String(v == null ? '' : v));
    return `/v1/shops/${seg(shopId)}/published/${seg(pubToken)}`;
  }

  const api = { STATUS_LABELS, STAGE_BY_STATUS, wouldRefresh, payloadFor, requestFor, pathFor };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPortalRefresh = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
