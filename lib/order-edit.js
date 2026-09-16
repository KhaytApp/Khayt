'use strict';

/**
 * Changing a job's own details, and remembering that it changed.
 *
 * The order editor writes thirty fields; five of them are RECORDED — the due
 * date, the discount, the shipping, and the two that carry the priority. Those
 * five are the ones a customer can be told a different answer about later, so
 * `editHistory` exists to say who moved the goalposts and when.
 *
 * The rule lived inside the editor's save handler, which meant anything else
 * that changed a due date changed it silently. The Mac app is about to be one
 * of those things.
 *
 * PURE: no globals, and no clock — `ctx.now` is the current time in
 * milliseconds. `ctx.id` supplies the entry's identifier, because a random
 * source is what a pure module does not have.
 *
 * ── THE PRIORITY IS TWO FIELDS AND THEY MOVE TOGETHER ──────────────────────
 * `priorityLevel` is the answer ('normal' | 'high' | 'urgent') and `priority`
 * is the older boolean that the kanban card, the Mac app's card and every
 * older record still carry. Setting one without the other leaves a job that is
 * urgent on one screen and ordinary on another, which is exactly what
 * `getPriorityLevel` was written to paper over. They are set as a pair here.
 */
(function (global) {

  /** A job remembers its last hundred edits and no more. */
  const EDIT_HISTORY_CAP = 100;

  /** The fields whose changes are written down. */
  // `price` joined on 2026-09-16: a job's total can be adjusted after it is
  // taken — "we agreed 1,800 in the end" — and that is the change a customer
  // is most likely to be told a different answer about later.
  const TRACKED_FIELDS = ['dueDate', 'discountPct', 'shippingCost', 'priority', 'priorityLevel', 'price'];

  /** In the order a shop escalates. */
  const PRIORITY_LEVELS = ['normal', 'high', 'urgent'];

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});

  /**
   * The priority as BOTH fields.
   *
   * An unknown level is 'normal': a job whose urgency nobody can read is not
   * urgent, and guessing upward would put it at the top of every queue.
   */
  function priorityFrom(level) {
    const wanted = PRIORITY_LEVELS.indexOf(level) === -1 ? 'normal' : level;
    return { priorityLevel: wanted, priority: wanted !== 'normal' };
  }

  /** The level a job is at, however old the record is. */
  function priorityOf(order) {
    if (!order) return 'normal';
    if (PRIORITY_LEVELS.indexOf(order.priorityLevel) > 0) return order.priorityLevel;
    if (order.priorityLevel === 'normal') return 'normal';
    return order.priority ? 'high' : 'normal';
  }

  /**
   * What changed, among the fields that are written down.
   *
   * Compared as STRINGS, the way the editor always has: a due date arrives from
   * a date input and a discount from a number input, and `5` and `'5'` are the
   * same answer typed twice. Null and undefined and '' are all "not set".
   */
  function changesBetween(order, next) {
    const changes = {};
    for (const key of TRACKED_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(next, key)) continue;
      const from = order[key];
      const to = next[key];
      if (String(from == null ? '' : from) !== String(to == null ? '' : to)) {
        changes[key] = { from, to };
      }
    }
    return changes;
  }

  /**
   * Write an edit into the job's history.
   *
   * Nothing is recorded for an empty change set — an editor opened and closed
   * again is not an edit, and a history full of those hides the real ones.
   */
  function recordEdit(order, changes, ctx) {
    if (!changes || Object.keys(changes).length === 0) return false;
    const c = ctxOf(ctx);
    order.editHistory = order.editHistory || [];
    order.editHistory.push({
      id: c.id || null,
      at: new Date(typeof c.now === 'number' ? c.now : Date.now()).toISOString(),
      fields: changes,
    });
    if (order.editHistory.length > EDIT_HISTORY_CAP) {
      order.editHistory = order.editHistory.slice(-EDIT_HISTORY_CAP);
    }
    return true;
  }

  /**
   * Apply a set of tracked changes to a job, in place, and record them.
   *
   * `next` names only the fields being changed. `dueDate` set to '' or null
   * clears it — a job with no due date is a real answer, and the field has to
   * be able to say it.
   *
   * Returns `{ changes, effects }`; `effects` is empty when nothing changed, so
   * a caller that saves on a non-empty list cannot write a revision for an
   * editor somebody opened and closed.
   */
  /** null, undefined and '' are ABSENT — an empty price box is not a free job. */
  function optional(v) {
    if (v === null || v === undefined || v === '') return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  function applyEdit(order, next, ctx) {
    const wanted = Object.assign({}, next || {});
    // The priority is a pair. A caller naming only the level gets both.
    if (Object.prototype.hasOwnProperty.call(wanted, 'priorityLevel')) {
      Object.assign(wanted, priorityFrom(wanted.priorityLevel));
    }
    // A price is a typed total: a number, never negative, money's two
    // decimals. Anything else is "leave the price alone", not "zero".
    if (Object.prototype.hasOwnProperty.call(wanted, 'price')) {
      const typed = optional(wanted.price);
      if (typed === null || typed < 0) delete wanted.price;
      else wanted.price = Math.round(typed * 100) / 100;
    }
    const changes = changesBetween(order, wanted);
    if (Object.keys(changes).length === 0) return { changes: {}, effects: [] };

    for (const key of TRACKED_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(wanted, key)) continue;
      const value = wanted[key];
      if (key === 'dueDate' && (value === '' || value == null)) order.dueDate = null;
      else order[key] = value;
    }
    if (changes.price) adjustPrice(order, changes.price);
    recordEdit(order, changes, ctx);

    return {
      changes,
      effects: [
        { type: 'save' },
        { type: 'render', dashboard: true },
        { type: 'toast_saved' },
      ],
    };
  }

  /**
   * What follows a typed price.
   *
   * The record says how its price was reached (`lib/order-new.js` writes
   * `computedPrice` / `priceSource` when rounding or a typed figure did):
   * an adjustment keeps the arithmetic's figure — the one already there, or
   * the price this edit replaced when nothing had been written down — marks
   * the source as `override`, and keeps the typed figure beside it.
   *
   * And the money follows the price. What has been paid can never exceed
   * what is owed, and the payment status is the payment rule's answer, not a
   * stored word that now disagrees with the arithmetic — see
   * `lib/order-payment.js` for why that word is derived.
   */
  function adjustPrice(order, change) {
    if (order.priceSource !== 'override') {
      const had = optional(order.computedPrice);
      const was = optional(change.from);
      if (had !== null) order.computedPrice = had;
      else if (was !== null) order.computedPrice = was;
    }
    order.priceSource = 'override';
    order.priceOverride = order.price;
    const paid = optional(order.paidAmount) || 0;
    if (paid > order.price) order.paidAmount = order.price;
    const Pay = typeof globalThis !== 'undefined' ? globalThis.KhaytOrderPayment : undefined;
    if (Pay && typeof Pay.statusOf === 'function') {
      order.paymentStatus = Pay.statusOf(order);
    } else {
      const p = optional(order.paidAmount) || 0;
      order.paymentStatus = p <= 0 ? 'unpaid' : (p + 0.005 >= order.price ? 'paid' : 'partial');
    }
  }

  const api = {
    EDIT_HISTORY_CAP, TRACKED_FIELDS, PRIORITY_LEVELS,
    priorityFrom, priorityOf, changesBetween, recordEdit, applyEdit, adjustPrice,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderEdit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
