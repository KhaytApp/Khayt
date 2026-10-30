'use strict';
(function () {

/**
 * Overdue-invoice payment reminders — pure selector logic (sibling of
 * lib/quote-followup.js). Unpaid invoices past their due date quietly age into
 * bad debt; this decides which invoices are "due" for a gentle payment nudge.
 * Side-effect free → unit-testable + reusable by the dashboard and the optional
 * auto-reminder timer.
 *
 * An invoice is due for a payment reminder when ALL hold:
 *   (a) it is a real order (not a quote) and not voided
 *   (b) it still owes money — owed(order) > 0 (caller supplies the owed amount)
 *   (c) it has a due date that is at least `graceDays` in the past — the
 *       customer's PAYMENT TERMS due date (invoice date + terms,
 *       lib/payment-terms.js) when the customer has terms, else the order's
 *       own `dueDate` as before. A net-30 company is not nudged on day one.
 *   (d) it hasn't been reminded "recently" — dedupe by `payRemindedAt`
 *       (cooldown) and capped by `payReminderMaxCount`.
 */

const DAY_MS = 86400000;

const DEFAULTS = {
  graceDays: 3,       // start nudging this many days AFTER the due date
  cooldownDays: 3,    // min days between two reminders for the same invoice
  maxCount: 3,        // never send more than this many reminders per invoice
};

/** Read reminder tuning from settings.paymentReminder, falling back to DEFAULTS. */
function reminderConfig(settings) {
  const f = (settings && settings.paymentReminder) || {};
  const pick = (v, d) => (Number.isFinite(+v) && +v >= 0 ? +v : d);
  return {
    enabled: !!f.enabled,
    graceDays: pick(f.graceDays, DEFAULTS.graceDays),
    cooldownDays: pick(f.cooldownDays, DEFAULTS.cooldownDays),
    maxCount: pick(f.maxCount, DEFAULTS.maxCount),
  };
}

function dayStartFromYmd(ymd) {
  if (!ymd || typeof ymd !== 'string') return null;
  const d = new Date(ymd + 'T00:00:00');
  return Number.isNaN(d.getTime()) ? null : d;
}
function startOfDay(now) { const d = new Date(now); d.setHours(0, 0, 0, 0); return d; }

/** The payment-terms rule, however this file happens to be loaded. */
function terms() {
  if (typeof globalThis !== 'undefined' && globalThis.KhaytPaymentTerms) return globalThis.KhaytPaymentTerms;
  try { return require('./payment-terms.js'); } catch (e) { return null; }
}

/**
 * The day payment is due: invoice date + the customer's terms when the
 * customer has terms, else the order's own `dueDate` (unchanged behaviour for
 * every customer without terms).
 */
function paymentDueDate(order, client) {
  const T = terms();
  if (T && client && T.termsDays(client) > 0) return T.dueDate(order, client) || null;
  return (order && order.dueDate) || null;
}

/** Whole-day count the invoice is PAST due (0 = due today, negative = future). */
function daysOverdue(order, now, client) {
  const due = dayStartFromYmd(paymentDueDate(order, client));
  if (!due) return null;
  return Math.round((startOfDay(now) - due) / DAY_MS);
}

/** Eligible at all: a non-void order that still owes money. `owed` is the
 *  caller-computed outstanding balance (so currency logic stays in the app). */
function isReminderEligible(order, owed) {
  if (!order || order.status === 'quote') return false;
  if (order.voidedAt) return false;
  return (+owed || 0) > 0.005;
}

function cooldownElapsed(order, now, cooldownDays) {
  if (!order.payRemindedAt) return true;
  const last = new Date(order.payRemindedAt);
  if (Number.isNaN(last.getTime())) return true;
  return (new Date(now) - last) >= cooldownDays * DAY_MS;
}

/**
 * Decide whether a single invoice is due for a payment reminder now.
 * @param {object} order
 * @param {number} owed  outstanding balance (caller-computed)
 * @param {object} cfg   resolved config (see reminderConfig)
 * @param {Date|number} now
 */
function isDueForReminder(order, owed, cfg, now, client) {
  if (!isReminderEligible(order, owed)) return false;
  const od = daysOverdue(order, now, client);
  if (od === null) return false;
  if (od < cfg.graceDays) return false; // not overdue enough yet
  if ((+order.payReminderCount || 0) >= cfg.maxCount) return false;
  if (!cooldownElapsed(order, now, cfg.cooldownDays)) return false;
  return true;
}

/**
 * Select invoices due for a payment reminder. `owedOf(order)` returns the
 * outstanding balance for an order (injected so currency conversion stays in
 * the renderer). Sorted by most-overdue first. Pure.
 *
 * `clients` (optional) is the customer list, for each customer's payment
 * terms; without it every order is read by its own `dueDate`, as before.
 */
function selectInvoicesDueForReminder(orders, settings, owedOf, now = Date.now(), clients = []) {
  const cfg = reminderConfig(settings);
  const list = Array.isArray(orders) ? orders : [];
  const owed = typeof owedOf === 'function' ? owedOf : () => 0;
  const clientOf = (o) => {
    if (!o || o.clientId == null || !Array.isArray(clients)) return null;
    return clients.find((c) => c && c.id === o.clientId) || null;
  };
  return list
    .filter((o) => isDueForReminder(o, owed(o), cfg, now, clientOf(o)))
    .sort((a, b) => (daysOverdue(b, now, clientOf(b)) || 0) - (daysOverdue(a, now, clientOf(a)) || 0));
}

/** Patch to apply after a reminder is sent. */
function markReminderPatch(order, now = Date.now()) {
  return {
    payRemindedAt: new Date(now).toISOString(),
    payReminderCount: (+(order && order.payReminderCount) || 0) + 1,
  };
}

const api = {
  DEFAULTS,
  reminderConfig,
  daysOverdue,
  paymentDueDate,
  isReminderEligible,
  cooldownElapsed,
  isDueForReminder,
  selectInvoicesDueForReminder,
  markReminderPatch,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPaymentReminder = api;

})();
