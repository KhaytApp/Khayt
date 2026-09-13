'use strict';
(function () {
/**
 * Outbound event webhooks — build a normalized JSON payload Khayt POSTs to an
 * owner-configured URL when an order event happens (created / status changed /
 * paid), so other tools can react. Pure (no clock/crypto): the caller supplies
 * the timestamp + resolved names; signing happens in the main process.
 */

const EVENTS = ['created', 'status', 'paid'];

/**
 * @param {string} type   one of EVENTS
 * @param {object} order
 * @param {object} [opts] { at:ISO, shopName, clientName, currency }
 * @returns {object} the webhook body
 */
function buildWebhookEvent(type, order, opts) {
  order = order || {};
  opts = opts || {};
  return {
    id: 'evt_' + String(order.id || '') + '_' + type + '_' + (opts.at || ''),
    event: 'order.' + (EVENTS.includes(type) ? type : 'updated'),
    at: opts.at || '',
    shop: { name: opts.shopName || '' },
    order: {
      id: order.id || '',
      project: order.project || '',
      status: order.status || '',
      paymentStatus: order.paymentStatus || '',
      price: +order.price || 0,
      currency: opts.currency || '',
      client: opts.clientName || '',
      dueDate: order.dueDate || '',
    },
  };
}

const api = { EVENTS, buildWebhookEvent };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytWebhooks = api;
})();
