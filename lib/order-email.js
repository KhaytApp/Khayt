'use strict';
/**
 * What a shop's email to a customer says when a job moves.
 *
 * The subject and the body were built inline in
 * `renderer/integrations.js:autoSendEmailNotification`, so the Mac app — which
 * refuses any move that would reach outside the shop precisely because it
 * could not send one — had no way to say the same thing. A shop whose
 * customers are told by email could not finish a job on the Mac at all: the
 * move was refused whole, which is right, and there was nothing it could do
 * about it, which is not.
 *
 * The same lift as `lib/telegram-message.js`, for the same reason and with the
 * same split: the WORDS are here and the TRANSPORT is not. Electron posts them
 * from its main process, the Mac from `URLSession`, and both send exactly
 * these bytes.
 *
 * PURE: no DOM, no network, no clock. The shop's name, the customer's name and
 * the status label come in through `ctx` — how a shop writes its own name in
 * two languages is the app's business and not this module's.
 *
 * ── WHY THE GUARD IS HERE TOO ──────────────────────────────────────────────
 *
 * `order-status.js:outboundFor` used to carry its own copy of the conditions
 * under which an email is sent, with a comment warning that a guard which
 * changes in the renderer and not there "turns this from a promise into a
 * guess". Two copies of a condition is the bug that comment describes, so
 * `outboundFor` now asks `wouldSend()` and there is one copy. The renderer
 * asks it as well, rather than opening with the conditions again.
 */
(function (global) {

  /**
   * The providers an app can carry over plain HTTPS.
   *
   * This matters to a host, not to a shop: `sendgrid` and `mailgun` are one
   * POST each and anything that can make an HTTPS request can make them.
   * `custom` is SMTP — a socket, a dialogue, STARTTLS — which Electron's main
   * process implements and the Mac app does not. A host that cannot carry a
   * provider must refuse the move rather than make it and skip the email, so
   * it has to be able to ask WHICH provider before the move happens. That is
   * what `via` on an `outboundFor` entry is for.
   */
  const HTTP_PROVIDERS = ['sendgrid', 'mailgun'];

  /** Escape for HTML text. Same five characters as `renderer/util.js`. */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;',
    })[c]);
  }

  /**
   * Would this move email this customer, and through what?
   *
   * The conditions are exactly the ones `autoSendEmailNotification` opened
   * with: a provider configured, this status among the triggers, a customer on
   * the job, and an address on that customer.
   *
   * `ctx`: `{ settings, clients }`.
   * Returns `{ send, provider, to }` — `send` false and the rest empty when it
   * would not. A caller deciding whether it CAN send reads `provider`; one
   * building the message reads `to`.
   */
  function wouldSend(order, newStatus, ctx) {
    const c = ctx || {};
    const cfg = (c.settings || {}).emailConfig || {};
    const none = { send: false, provider: '', to: '' };
    const provider = String(cfg.provider || '');
    if (!provider || provider === 'none') return none;

    const triggers = Array.isArray(cfg.triggers) ? cfg.triggers : [];
    if (triggers.indexOf(newStatus) === -1) return none;

    const o = order || {};
    if (!o.clientId) return none;
    const clients = Array.isArray(c.clients) ? c.clients : [];
    const client = clients.find((x) => x && x.id === o.clientId);
    // No address on file is NOT a reason to refuse a move: nothing is sent and
    // nothing is missed. The renderer says so with a toast; this says so by
    // answering no.
    if (!client || !client.email) return none;

    return { send: true, provider, to: String(client.email) };
  }

  /** Can a host that speaks only HTTPS deliver through this provider? */
  function isHttpProvider(provider) {
    return HTTP_PROVIDERS.indexOf(String(provider || '')) !== -1;
  }

  /**
   * The email for a status change, or null when the shop has not asked for one.
   *
   * `ctx`: `{ settings, clients, shopName, clientName, statusLabel }`.
   *
   *   `shopName`    what the shop calls itself, in the language it reads.
   *   `clientName`  the customer's name in that language; the address is used
   *                 in the greeting when there is no name, which is what the
   *                 renderer did.
   *   `statusLabel` the stage in words — `t('queue.' + status)` in the
   *                 renderer, `Words` on the Mac. The raw status is the
   *                 fallback in both.
   *
   * Returns `{ to, subject, html, provider }`.
   *
   * The template is the renderer's, moved across character for character
   * including its colour: this is a lift, and a shop that has been sending
   * this email for a year should not find it redesigned because it moved
   * house. What IS new is that the escaping is the module's own — the renderer
   * borrowed `escapeHtml` from its own globals, which the Mac does not have.
   */
  function messageFor(order, newStatus, ctx) {
    const c = ctx || {};
    const decision = wouldSend(order, newStatus, c);
    if (!decision.send) return null;

    const o = order || {};
    const shopName = String(c.shopName || 'Khayt');
    const statusLabel = String(c.statusLabel || newStatus);
    const greeting = String(c.clientName || decision.to);
    const subject = `${shopName} — Order ${o.id} Update: ${statusLabel}`;
    const html = `<div style="font-family:sans-serif;max-width:500px;margin:0 auto;padding:20px;">
    <h2 style="color:#5E2E14;">${esc(shopName)}</h2>
    <p>Dear ${esc(greeting)},</p>
    <p>Your order <strong>${esc(o.id)}</strong> (${esc(o.project || '')}) has been updated:</p>
    <p style="font-size:18px;font-weight:bold;color:#5E2E14;">${esc(statusLabel)}</p>
    ${o.dueDate ? `<p>Due date: ${esc(o.dueDate)}</p>` : ''}
    <p>Thank you for your business!</p>
    <p style="font-size:12px;color:#888;">— ${esc(shopName)}</p>
  </div>`;

    return { to: decision.to, subject, html, provider: decision.provider };
  }

  const api = { HTTP_PROVIDERS, wouldSend, isHttpProvider, messageFor };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderEmail = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
