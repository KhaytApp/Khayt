'use strict';
/**
 * When a customer's invoice falls due — payment terms per customer.
 *
 * Receivables aged from the day of the job, so a company, a school or a
 * government buyer on net-30 read as overdue from the first day: the shop was
 * told to chase money that was not yet owed, and learned to ignore the screen.
 *
 * THE RULE, decided by the shop (Oct 2026):
 *
 * * A customer carries `paymentTermsDays` — a whole number of days. Absent,
 *   zero, negative or unreadable is 0: DUE ON RECEIPT, which is what every
 *   customer was before this existed, so a book that never sets terms ages
 *   exactly as it did.
 * * The due date is the INVOICE DATE plus the terms. The invoice date is the
 *   date the issued invoice prints (`lib/invoice-document.js` prints
 *   `order.date` under "Date"), else the job's timestamp — there is no
 *   separate issue stamp on an order, and inventing a field nobody writes
 *   would be a rule that never fires. Due and invoice date must agree on the
 *   paper: "Date 1 Oct · Net 30 · Due 31 Oct".
 * * Overdue is PAST the due date (not on it) and not settled.
 *
 * Calendar arithmetic is on `YYYY-MM-DD` with `Date.UTC`, so no time zone and
 * no daylight-saving change can move a due date by a day. `today` is the
 * shop's LOCAL day: a `Date` is read in local time, a string is taken as is.
 *
 * PURE: no DOM, no clock beyond the `today` it is handed. Ported to Swift as
 * `KhaytCore.PaymentTerms` and held to this file by `PaymentTermsParityTests`.
 */
(function (global) {

  const DAY_MS = 86400000;
  /** What the pickers offer. Anything else is a custom number of days. */
  const PRESETS = [0, 7, 15, 30, 45, 60, 90];
  /** A year. Beyond it a number is a typo, not an agreement. */
  const MAX_DAYS = 365;
  const DAY = /^(\d{4})-(\d{2})-(\d{2})$/;
  const NUMERIC = /^\s*\d+(\.\d+)?\s*$/;

  /**
   * The customer's terms, in whole days. 0 = due on receipt.
   *
   * A number, or a string of digits (a record typed by hand, or by a form).
   * Not `Number(v)` on anything: `Number(true)` is 1 and `Number('0x1e')` is
   * 30, and neither is a term somebody agreed.
   */
  function termsDays(customer) {
    const v = customer && typeof customer === 'object' ? customer.paymentTermsDays : undefined;
    let n;
    if (typeof v === 'number') n = v;
    else if (typeof v === 'string' && NUMERIC.test(v)) n = Number(v);
    else return 0;
    if (!Number.isFinite(n) || n <= 0) return 0;
    return Math.min(MAX_DAYS, Math.floor(n));
  }

  /** `[y, m, d]` of a `YYYY-MM-DD`, or null. */
  function parts(ymd) {
    const m = DAY.exec(String(ymd == null ? '' : ymd));
    if (!m) return null;
    const y = +m[1], mo = +m[2], d = +m[3];
    // A day that does not exist ("2026-02-30") is not a date, not March 2nd.
    const t = new Date(Date.UTC(y, mo - 1, d));
    if (t.getUTCFullYear() !== y || t.getUTCMonth() !== mo - 1 || t.getUTCDate() !== d) return null;
    return [y, mo, d];
  }

  function ymdOf(t) {
    const pad = (x) => String(x).padStart(2, '0');
    return `${String(t.getUTCFullYear()).padStart(4, '0')}-${pad(t.getUTCMonth() + 1)}-${pad(t.getUTCDate())}`;
  }

  /** `ymd` plus `n` days, as `YYYY-MM-DD`; '' for a day that is not one. */
  function addDays(ymd, n) {
    const p = parts(ymd);
    if (!p) return '';
    return ymdOf(new Date(Date.UTC(p[0], p[1] - 1, p[2] + (n | 0))));
  }

  /** Whole days from `from` to `to` (positive when `to` is later); null if either is not a day. */
  function daysBetween(from, to) {
    const a = parts(from), b = parts(to);
    if (!a || !b) return null;
    return Math.round((Date.UTC(b[0], b[1] - 1, b[2]) - Date.UTC(a[0], a[1] - 1, a[2])) / DAY_MS);
  }

  /** The shop's local day for `today`: a `Date` in local time, a string's first ten characters. */
  function dayOf(today) {
    if (today instanceof Date) {
      if (isNaN(today.getTime())) return '';
      const pad = (x) => String(x).padStart(2, '0');
      return `${today.getFullYear()}-${pad(today.getMonth() + 1)}-${pad(today.getDate())}`;
    }
    if (typeof today === 'number') return dayOf(new Date(today));
    return String(today == null ? '' : today).slice(0, 10);
  }

  /**
   * The date the invoice is dated: `order.date`, else its `timestamp`, as the
   * first ten characters — the same reading receivables has always aged from.
   * '' when neither is a day.
   */
  function invoiceDate(order) {
    if (!order || typeof order !== 'object') return '';
    const s = String(order.date || order.timestamp || '').slice(0, 10);
    return parts(s) ? s : '';
  }

  /** The day this order's invoice falls due for this customer, or ''. */
  function dueDate(order, customer) {
    const from = invoiceDate(order);
    return from ? addDays(from, termsDays(customer)) : '';
  }

  /**
   * Whole days past the due date: positive once overdue, 0 on the day, negative
   * before it. Null when the order carries no date to work from.
   */
  function daysPastDue(order, customer, today) {
    const due = dueDate(order, customer);
    if (!due) return null;
    return daysBetween(due, dayOf(today));
  }

  /** Work that cannot owe: a quote, a cancelled job, a voided or credited invoice. */
  function owesAtAll(order) {
    return !!order && order.status !== 'quote' && order.status !== 'cancelled'
      && !order.voidedAt && !order.creditedAt;
  }

  /**
   * Past due and not paid.
   *
   * `settled` is the caller's answer to "is anything still owed on it" — the
   * caller holds the money rule and the currencies. Left out, the shared
   * payment rule is asked when it is loaded, else the stored `paymentStatus`.
   */
  function overdue(order, customer, today, settled) {
    if (!owesAtAll(order)) return false;
    let done = settled;
    if (typeof done !== 'boolean') {
      const P = global.KhaytOrderPayment;
      done = (P && typeof P.isOutstanding === 'function')
        ? !P.isOutstanding(order, {})
        : order.paymentStatus === 'paid';
    }
    if (done) return false;
    const d = daysPastDue(order, customer, today);
    return d !== null && d > 0;
  }

  /** The customer an order is billed to, by `clientId`, or null. */
  function customerOf(order, clients) {
    if (!order || order.clientId == null || !Array.isArray(clients)) return null;
    return clients.find((c) => c && c.id === order.clientId) || null;
  }

  const api = { PRESETS, MAX_DAYS, termsDays, addDays, daysBetween, invoiceDate, dueDate,
                daysPastDue, overdue, customerOf };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPaymentTerms = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
