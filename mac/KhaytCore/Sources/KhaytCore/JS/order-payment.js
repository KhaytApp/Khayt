'use strict';

/**
 * What a shop has been paid, and what that makes an order.
 *
 * "Is this paid" is the most consequential sentence in the book: it decides
 * what appears in receivables, who gets chased, and what a period earned. It
 * was answered in THREE places, and they did not agree.
 *
 *   `payStatus`            renderer/app-helpers.js — the full rule. Voided,
 *                          credit notes, gift cards, and the price-zero case.
 *   inline in the modal    renderer/order-flows.js — gift cards, no credit
 *                          notes. So recording a payment on an order that had
 *                          been part-credited WROTE a status that the very next
 *                          read disagreed with.
 *   `paymentStatusFor`     lib/split-order.js — price and paid only, for a
 *                          sub-order that has neither.
 *
 * The full rule lives here now and the other two defer to it, except
 * `paymentStatusFor`, which stays where it is because it answers a narrower
 * question about a record that cannot carry the wider one.
 *
 * PURE: no globals, no clock. `ctx.today` is the local `YYYY-MM-DD` a payment
 * is dated with when the caller does not supply one.
 *
 * ── THE RULES, AND WHY EACH ONE IS HERE ────────────────────────────────────
 * A VOIDED order is not unpaid — it is not an order. So is one credited in
 * full: `generateCreditNote` stamps `creditedAt` at full credit, and an order
 * whose whole price has been credited back must stop appearing as money owed.
 *
 * A costless order keeps whatever status it was given, because the arithmetic
 * cannot say: nothing owed and nothing paid is either "free, and settled" or
 * "not priced yet", and only the shop knows which.
 *
 * CREDIT NOTES REDUCE WHAT IS DUE. GIFT CARDS PAY IT DOWN. They land on
 * opposite sides of the division for a reason — a gift card is a tender, and
 * netting it off the price would make it revenue nowhere at all. This is the
 * same split `lib/order-money.js` makes, and the two must not drift.
 */
(function (global) {

  const numberOf = (v) => (+v || 0);

  /**
   * What this order's payment status IS, whatever it says it is.
   *
   * The stored `paymentStatus` field is an answer that was true when it was
   * written. This is the answer now.
   */
  function statusOf(order) {
    if (!order) return 'unpaid';
    if (order.voidedAt) return 'voided';
    if (order.creditedAt) return 'voided';

    const price = numberOf(order.price);
    if (price === 0) return order.paymentStatus || 'paid';

    const credited = (order.creditNotes || []).reduce((s, cn) => s + numberOf(cn && cn.amount), 0);
    const due = Math.max(0, price - credited);
    const paid = numberOf(order.paidAmount) + numberOf(order.giftCardDiscount);

    if (due <= 0) return 'paid';
    if (paid <= 0) return 'unpaid';
    return paid >= due ? 'paid' : 'partial';
  }

  /** True when there is still money to collect on this order. */
  function isOutstanding(order) {
    const s = statusOf(order);
    return s === 'unpaid' || s === 'partial';
  }

  /**
   * Record what a customer has paid.
   *
   * `payment`: `{ amount, method, paidAt }`. The amount is clamped to the
   * order's price — a shop cannot be paid more for a job than it charged, and
   * an overpayment is a credit note, not a bigger `paidAmount`.
   *
   * `ctx`: `{ today }`.
   *
   * Returns `{ notices, effects }` in the shape the status rules use, so a host
   * that already performs those effects performs these without learning
   * anything new.
   */
  function recordPayment(order, payment, ctx) {
    const p = payment || {};
    const c = ctx || {};
    const price = numberOf(order.price);

    order.paidAmount = Math.min(Math.max(0, numberOf(p.amount)), price);
    order.paymentMethod = p.method || null;
    order.paidAt = p.paidAt || c.today || null;
    // Derived, never taken from the caller: a stored status that disagrees with
    // the arithmetic is how an order sits in receivables after it was settled.
    order.paymentStatus = statusOf(order);

    const effects = [
      { type: 'save' },
      { type: 'render' },
      { type: 'toast_saved' },
      { type: 'webhook', event: 'payment_received' },
    ];
    if (order.paymentStatus === 'paid') effects.push({ type: 'order_webhook', event: 'paid' });
    if (order.paidAmount > 0) effects.push({ type: 'email', status: 'payment_received' });
    effects.push({ type: 'accounting' });

    return { notices: [], effects };
  }

  /**
   * Undo a payment: the money was never received, or was recorded against the
   * wrong job.
   *
   * `unpaid` outright rather than derived, because a gift card or a credit note
   * still on the order would otherwise make "clear the payment" leave it
   * reading as paid — and somebody clearing a payment means the order is owed.
   */
  function clearPayment(order) {
    order.paidAmount = 0;
    order.paymentMethod = null;
    order.paidAt = null;
    order.paymentStatus = 'unpaid';
    return {
      notices: [],
      effects: [{ type: 'save' }, { type: 'render' }, { type: 'toast_cleared' }],
    };
  }

  /**
   * What this move would reach outside the shop's own book.
   *
   * The same promise `lib/order-status.js` makes for a status change, for the
   * events a payment fires. The conditions are the renderer's own — see the
   * table in `outboundFor` there; a guard that changes in integrations.js and
   * not here turns this from a promise into a guess.
   */
  function outboundFor(order, ctx) {
    const c = ctx || {};
    const settings = c.settings || {};
    const clients = Array.isArray(c.clients) ? c.clients : [];
    const out = [];

    if ((settings.webhooks || {}).enabled) out.push({ channel: 'webhooks', why: 'enabled' });

    const events = settings.eventWebhooks || {};
    if (events.enabled && /^https:\/\//i.test(events.url || '') &&
        !(events.events && events.events.paid === false)) {
      out.push({ channel: 'event_webhook', why: 'enabled' });
    }

    const email = settings.emailConfig || {};
    const triggers = Array.isArray(email.triggers) ? email.triggers : [];
    if (email.provider && email.provider !== 'none' &&
        triggers.indexOf('payment_received') !== -1 && order && order.clientId) {
      const client = clients.find(x => x && x.id === order.clientId);
      // WITH THE PROVIDER. `order-status.js` has always carried `via` on its
      // email reach, and this did not — so a host that can carry SOME email
      // providers and not others had no way to ask which one this is. The Mac
      // posts to SendGrid and Mailgun and has no SMTP client, so without this
      // it had to treat every email reach as one it could not carry, and
      // refused to record a payment it could in fact have announced.
      if (client && client.email) {
        out.push({ channel: 'email', why: 'payment_received', via: email.provider });
      }
    }

    return out;
  }

  const api = { statusOf, isOutstanding, recordPayment, clearPayment, outboundFor };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderPayment = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
