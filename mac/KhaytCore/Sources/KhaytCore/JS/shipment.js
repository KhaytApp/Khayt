'use strict';
/**
 * Sending a job out with a carrier, and moving the parcel along by hand.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * It lived inside the Electron Ship dialog (`renderer/order-flows.js`), so the
 * Mac could mark a job shipped and could not say who took it or under what
 * tracking number. Every screen downstream of that number — the customer's
 * tracking page, the carrier's own status webhooks, the portal — had nothing
 * to go on for a Mac shop. The fields a shipment writes, and how a status moves
 * without going backwards, are the same wherever the button is, so they are
 * one rule here and both apps call it.
 *
 * What stays with each app: the carrier's API call (proxied through Electron's
 * main process, and not made from the Mac yet), the toasts, the redraw.
 *
 * Pure: the moment is the caller's. Mutates the order it is handed, the way
 * `order-status.js` does, and returns what changed.
 */
(function (global) {
  const Carriers = global.KhaytCarriers
    || (typeof require === 'function' ? require('./carriers.js') : null);
  const OrderStatus = global.KhaytOrderStatus
    || (typeof require === 'function' ? require('./order-status.js') : null);

  /** How long a parcel's trail may grow. A carrier that sends every scan
   *  would otherwise grow one job's record without bound. */
  const HISTORY_MAX = 100;

  /** The statuses a person may pick for a parcel already on its way. */
  const MANUAL_STATUSES = ['label_created', 'in_transit', 'out_for_delivery', 'delivered', 'exception'];

  function pushHistory(order, status, source, at, note) {
    if (!Array.isArray(order.shippingHistory)) order.shippingHistory = [];
    order.shippingHistory.push({ status, at, source: source || 'manual', note: note || '' });
    if (order.shippingHistory.length > HISTORY_MAX) {
      order.shippingHistory = order.shippingHistory.slice(-HISTORY_MAX);
    }
  }

  /**
   * Hand a job to a carrier.
   *
   * `input` is `{ carrier, service, trackingNumber, source, labelUrl, meta }`;
   * only `carrier` is needed, and `manual` is always a carrier. A tracking
   * number is not required — a shop may post a parcel before the courier's
   * receipt is in hand — and is written `null` rather than `''` when absent,
   * which is what the dialog has always written.
   */
  function create(order, input, at) {
    const i = input || {};
    const carrierId = i.carrier || 'manual';
    const carrier = Carriers ? Carriers.getCarrier(carrierId) : null;
    order.carrier = carrierId;
    order.trackingNumber = (i.trackingNumber && String(i.trackingNumber).trim()) || null;
    order.shippingService = i.service || null;
    order.labelUrl = i.labelUrl || null;
    order.shipmentMeta = i.meta || null;
    order.shippedAt = at;
    order.shippingStatus = 'label_created';
    // Back-compat: the order editor's free-text courier and its Track button
    // read `courierName`.
    order.courierName = carrier ? ((carrier.label && carrier.label.en) || carrierId) : carrierId;
    pushHistory(order, 'label_created', i.source || 'manual', at);
    return order;
  }

  /**
   * Move a parcel's status, never backwards, and stamp the job shipped or
   * delivered by `order-status`'s rule. Returns whether anything moved.
   *
   * 'exception' may always be set; a delivered parcel ignores a later
   * 'in transit' — the rule is `carriers.advanceShippingStatus`.
   */
  function advance(order, next, source, at) {
    const step = Carriers ? Carriers.advanceShippingStatus(order.shippingStatus, next) : next;
    if (step === order.shippingStatus) return false;
    order.shippingStatus = step;
    pushHistory(order, step, source, at);
    // `shippedAt` and `deliveredAt` both, from one rule. This stamped only the
    // delivery once, so a job tracked by a carrier jumped from Completed to
    // Delivered and was never once seen in the post.
    OrderStatus.stampFromShipping(order, step, at);
    return true;
  }

  /**
   * The dialog's save for a parcel already sent: a corrected tracking number,
   * and a status picked by hand. Returns whether anything changed.
   */
  function update(order, input, at) {
    const i = input || {};
    let changed = false;
    const typed = i.trackingNumber == null ? '' : String(i.trackingNumber).trim();
    if (typed && typed !== order.trackingNumber) { order.trackingNumber = typed; changed = true; }
    if (i.status && advance(order, i.status, 'manual', at)) changed = true;
    return changed;
  }

  const api = { HISTORY_MAX, MANUAL_STATUSES, pushHistory, create, advance, update };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytShipment = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
