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
  const invoiceDue = od !== null && od >= cfg.graceDays;
  // A milestone proforma past ITS due date is chased even while the job's
  // own due date is still ahead — that is what giving it a date is for.
  if (!invoiceDue && milestonesDue(order, now, cfg).length === 0) return false;
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
    .sort((a, b) => (reminderDaysOverdue(b, now, clientOf(b), settings) || 0)
      - (reminderDaysOverdue(a, now, clientOf(a), settings) || 0));
}

// ── MILESTONE PROFORMAS WITH A DUE DATE ───────────────────────────────────
//
// `order.milestoneInvoices` rows are `{ id, label, percentage, amount,
// issuedAt }` and may now carry a `dueDate` (`YYYY-MM-DD`). Each is a
// PROFORMA — a request for part of the price, never a tax invoice — so being
// due means "this part should have been paid by now", and nothing here
// numbers or issues anything.
//
// PAID IS READ FROM THE JOB'S RUNNING TOTAL. A milestone carries no payment
// of its own (a `paidAt` on one, where some build wrote it, is honoured), so
// milestones are taken in the order they are stored and each counts as paid
// once the job's payments reach the sum of it and every one before it — the
// order a shop asks for them in.

/** The money on the job that pays milestones down: payments and gift cards. */
function paidTowards(order) {
  return (+(order && order.paidAmount) || 0) + (+(order && order.giftCardDiscount) || 0);
}

/**
 * Every milestone with what is still unpaid on it, in stored order:
 * `[{ id, label, amount, dueDate, unpaid }]`, amounts in the job's own
 * currency. Rows with no id are skipped, as both apps skip them.
 */
function milestoneBalances(order) {
  const rows = Array.isArray(order && order.milestoneInvoices) ? order.milestoneInvoices : [];
  const paid = paidTowards(order);
  let before = 0;
  const out = [];
  for (const m of rows) {
    if (!m || typeof m !== 'object' || !m.id) continue;
    const amount = Math.max(0, +m.amount || 0);
    const through = before + amount;
    const unpaid = m.paidAt ? 0 : Math.round(Math.max(0, Math.min(amount, through - paid)) * 100) / 100;
    before = through;
    out.push({
      id: String(m.id), label: String(m.label || ''), amount,
      dueDate: typeof m.dueDate === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(m.dueDate) ? m.dueDate : null,
      unpaid,
    });
  }
  return out;
}

/**
 * The milestones past their due date by at least `graceDays` and not paid,
 * most overdue first: `[{ id, label, amount, dueDate, unpaid, days }]`.
 * `cfg` defaults to the reminder's own tuning.
 */
function milestonesDue(order, now = Date.now(), cfg) {
  const grace = cfg && Number.isFinite(+cfg.graceDays) ? +cfg.graceDays : DEFAULTS.graceDays;
  if (!order || order.status === 'quote' || order.voidedAt) return [];
  const today = startOfDay(now);
  return milestoneBalances(order)
    .filter((m) => m.dueDate && m.unpaid > 0.005)
    .map((m) => Object.assign(m, { days: Math.round((today - dayStartFromYmd(m.dueDate)) / DAY_MS) }))
    .filter((m) => m.days >= grace)
    .sort((a, b) => b.days - a.days);
}

/**
 * Days overdue as the chase list shows it: the invoice's own, or its most
 * overdue milestone's when that is further gone. Null when neither has a date.
 */
function reminderDaysOverdue(order, now, client, settings) {
  const od = daysOverdue(order, now, client);
  const ms = milestonesDue(order, now, reminderConfig(settings));
  const worst = ms.length ? ms[0].days : null;
  if (od === null) return worst;
  return worst === null ? od : Math.max(od, worst);
}

/**
 * What a reminder asks for, in the job's own currency: everything owed when
 * the invoice itself is overdue, else the unpaid part of the milestones that
 * are due. `owed` is the caller's outstanding figure IN THE JOB'S CURRENCY.
 *
 * Returns `{ amount, milestones }` — `milestones` the due ones it covers
 * (empty when the whole balance is asked for).
 */
function reminderAmount(order, owed, settings, now = Date.now(), client) {
  const cfg = reminderConfig(settings);
  const owing = Math.max(0, +owed || 0);
  const od = daysOverdue(order, now, client);
  if (od !== null && od >= cfg.graceDays) return { amount: Math.round(owing * 100) / 100, milestones: [] };
  const ms = milestonesDue(order, now, cfg);
  if (!ms.length) return { amount: Math.round(owing * 100) / 100, milestones: [] };
  const sum = ms.reduce((s, m) => s + m.unpaid, 0);
  return { amount: Math.round(Math.min(owing, sum) * 100) / 100, milestones: ms };
}

// ── THE SHOP'S OWN PAY LINK ───────────────────────────────────────────────
//
// `settings.paymentProviders[id].payLink` was saved by both apps' Settings
// ("use {amount}") and read by nothing. A reminder is the message that most
// wants a way to pay in it.

/**
 * The first switched-on provider's pay link with the amount put in, or ''.
 * `{amount}` and `{total}` (the storefront's spelling) both take the figure,
 * as plain digits with two decimals. Only an http(s) address is used.
 */
function payLinkFor(settings, amount) {
  const providers = (settings && settings.paymentProviders) || {};
  const figure = (Math.round(Math.max(0, +amount || 0) * 100) / 100).toFixed(2);
  for (const id of Object.keys(providers)) {
    const p = providers[id];
    if (!p || !p.enabled) continue;
    const link = String(p.payLink || '').trim();
    if (!/^https?:\/\/\S+$/i.test(link)) continue;
    return link.replace(/\{amount\}|\{total\}/g, figure);
  }
  return '';
}

/** The placeholder rule, however this file is loaded. */
function waTemplate() {
  if (typeof globalThis !== 'undefined' && globalThis.KhaytWaTemplate) return globalThis.KhaytWaTemplate;
  try { return require('./wa-template.js'); } catch (e) { return null; }
}

/**
 * The reminder's words: the shop's template (`tpl-payment`) or the caller's
 * default, with this job's values put in, and the pay link on a line of its
 * own when the shop has one.
 *
 * `values` are already-formatted text (`lib/wa-template.js`): `price` should
 * be the AMOUNT ASKED FOR (`reminderAmount`) and `currency` the job's own.
 * `payLabel` is the words before the link ("Pay here:"), in the shop's
 * language; the link goes alone when it is empty.
 */
function reminderText({ body, values, payLink, payLabel } = {}) {
  // `values` null: the text is already filled (the desktop fills its own), and
  // is only given the link — a customer named `{{price}}` stays a name.
  const W = waTemplate();
  const raw = String(body == null ? '' : body);
  const filled = values == null || !W ? raw : W.fillTemplate(raw, values);
  const link = String(payLink || '').trim();
  if (!link || filled.indexOf(link) !== -1) return filled;
  const label = String(payLabel || '').trim();
  return filled.replace(/\s+$/, '') + '\n' + (label ? label + ' ' : '') + link;
}

/**
 * How this reminder goes out: 'whatsapp', 'email' or 'none'.
 *
 * `settings.paymentReminder.channel` when the shop has chosen one and it can
 * be used for this customer; otherwise WhatsApp when the customer has a
 * number (every shop can open WhatsApp), else email when the shop has an
 * email provider and the customer an address.
 */
function reminderChannel(settings, client) {
  const pref = String(((settings && settings.paymentReminder) || {}).channel || '');
  const phone = String((client && client.phone) || '').replace(/\D/g, '');
  const provider = String(((settings && settings.emailConfig) || {}).provider || '');
  const canEmail = !!(client && client.email) && !!provider && provider !== 'none';
  if (pref === 'email' && canEmail) return 'email';
  if (phone) return 'whatsapp';
  return canEmail ? 'email' : 'none';
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[c]);
}

/**
 * The reminder as an email, in the shape `lib/order-email.js` hands a
 * transport: `{ to, subject, html, provider }`, or null when the shop has no
 * provider or the customer no address. The words come from the caller —
 * `text` from `reminderText`, `subject` in the shop's language.
 */
function reminderEmail({ settings, client, text, subject, shopName } = {}) {
  const provider = String(((settings && settings.emailConfig) || {}).provider || '');
  const to = String((client && client.email) || '').trim();
  if (!provider || provider === 'none' || !to) return null;
  const body = esc(text).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1">$1</a>').replace(/\n/g, '<br>');
  const html = `<div style="font-family:sans-serif;max-width:500px;margin:0 auto;padding:20px;">
    <h2 style="color:#5E2E14;">${esc(shopName || 'Khayt')}</h2>
    <p>${body}</p>
  </div>`;
  return { to, subject: String(subject || ''), html, provider };
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
  milestoneBalances,
  milestonesDue,
  reminderDaysOverdue,
  reminderAmount,
  payLinkFor,
  reminderText,
  reminderChannel,
  reminderEmail,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPaymentReminder = api;

})();
