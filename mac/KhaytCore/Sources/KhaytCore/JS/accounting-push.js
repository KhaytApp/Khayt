'use strict';
/**
 * Sending a paid invoice to the shop's accounting system — when, what, and
 * what the order records afterwards.
 *
 * The desktop has pushed since accounting sync shipped (renderer/expenses.js
 * `maybePushAccounting`), with the rules written inline: switched on, "push
 * when paid" not switched off, the order paid and not pushed before, an
 * address to push to. The Mac pushes too now, so the rules are here and both
 * apps ask them. The transport stays each host's own (the desktop's main
 * process, the Mac's pinned client); the request they send is built here, so a
 * receiver cannot tell which app sent it.
 *
 * `settings.accountingSync` is the shape the desktop writes:
 *   { enabled, format, webhookUrl, secret, pushOnPaid, salesAccount, taxCode }
 * `secret` is a registered secret (`lib/store-secret-paths.js`), opened by the
 * host at the point of use. On the order: `accountingPushedAt` once the system
 * took it, or `accountingPushFailedAt` + `accountingPushError` when it did not
 * — which is what the retry sweep looks for.
 */
(function (global) {

  const exportApi = () => global.KhaytAccountingExport
    || (typeof require === 'function' ? require('./accounting-export.js') : null);

  /** The shop's accounting settings, or an empty object. */
  function configOf(settings) {
    const c = (settings || {}).accountingSync;
    return c && typeof c === 'object' ? c : {};
  }

  /**
   * Is this order owed a push right now? `{ push, reason }`, `reason` one of
   * `off`, `not_on_paid`, `not_paid`, `already_pushed`, `no_url`.
   *
   * The address test is the desktop's (`^https?://`) rather than https only:
   * the transports refuse plain http themselves and record that on the order,
   * which is how a shop still set up with http:// finds out — a rule that
   * skipped it here would leave the invoice silently unsent.
   */
  function wouldPush(order, settings) {
    const cfg = configOf(settings);
    if (!cfg.enabled) return { push: false, reason: 'off' };
    if (cfg.pushOnPaid === false) return { push: false, reason: 'not_on_paid' };
    const o = order || {};
    if (o.paymentStatus !== 'paid') return { push: false, reason: 'not_paid' };
    if (o.accountingPushedAt) return { push: false, reason: 'already_pushed' };
    if (!/^https?:\/\//i.test(String(cfg.webhookUrl || ''))) return { push: false, reason: 'no_url' };
    return { push: true, reason: '' };
  }

  /**
   * The orders a retry sweep sends again: paid, never pushed, and a failure on
   * record. ONLY those — an order paid before the shop switched sync on has no
   * failure on it and is not swept up, so turning the switch on does not push
   * the whole history. Off entirely while sync is off.
   */
  function retryable(orders, settings) {
    const cfg = configOf(settings);
    if (!cfg.enabled) return [];
    return (Array.isArray(orders) ? orders : []).filter((o) =>
      o && o.paymentStatus === 'paid' && !o.accountingPushedAt && o.accountingPushFailedAt &&
      wouldPush(o, settings).push);
  }

  /**
   * The JSON the system is sent for one invoice. `row` is the order as an
   * invoice row (`lib/accounting-rows.js`, or the desktop's
   * `orderToInvoiceRow`); its date is the day it was PAID where the order says,
   * as the desktop has always sent.
   */
  function payloadFor(row, order, settings) {
    const E = exportApi();
    if (!E) throw new Error('accounting-push: lib/accounting-export.js is not loaded');
    const cfg = configOf(settings);
    const o = order || {};
    const r = Object.assign({}, row || {});
    if (o.paidAt) r.date = o.paidAt;
    return E.buildInvoicePayload(r, {
      format: cfg.format, salesAccount: cfg.salesAccount, taxCode: cfg.taxCode,
    });
  }

  /** The test the settings' "Send test" button sends — the desktop's own. */
  function testPayload(settings, nowMs) {
    const cfg = configOf(settings);
    return { type: 'test', format: cfg.format || 'generic',
      idempotencyKey: 'test:' + Number(nowMs || 0), note: 'Khayt accounting sync test' };
  }

  /**
   * The headers and body a push goes out with — `hub:accounting-push`'s: the
   * shop's secret as `X-Khayt-Secret` when there is one, and the payload's
   * idempotency key so a receiver that sees the same invoice twice keeps one.
   */
  function request(payload, secret) {
    const headers = { 'content-type': 'application/json' };
    if (secret) headers['X-Khayt-Secret'] = String(secret);
    if (payload && payload.idempotencyKey) headers['Idempotency-Key'] = String(payload.idempotencyKey);
    return { headers, body: JSON.stringify(payload || {}) };
  }

  /**
   * What the order records after an attempt. `{ set, clear }`: the fields to
   * write and the fields to remove. A success clears an earlier failure, so a
   * retried invoice stops reading as stuck.
   */
  function outcome(ok, nowIso, error) {
    if (ok) {
      return { set: { accountingPushedAt: String(nowIso || '') },
               clear: ['accountingPushFailedAt', 'accountingPushError'] };
    }
    return { set: { accountingPushFailedAt: String(nowIso || ''),
                    accountingPushError: String(error || 'unknown error').slice(0, 300) },
             clear: [] };
  }

  const api = { configOf, wouldPush, retryable, payloadFor, testPayload, request, outcome };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytAccountingPush = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
