'use strict';
/**
 * A WhatsApp update sent for the shop, through the shop's own WhatsApp
 * Business account: the request, and what Meta's answer means.
 *
 * `lib/whatsapp-message.js` decides WHETHER a job owes a customer an update and
 * what goes in it. This builds the one HTTPS request that sends it — Meta's
 * Cloud API, `POST /<phone-number-id>/messages` — and reads the answer. The
 * host performs the request: the Mac with URLSession, the other app with
 * fetch. The same split `lib/sms.js` makes, and the same reason: the request
 * can be tested to the byte here, and neither app grows its own copy.
 *
 * ── A TEMPLATE, NEVER FREE TEXT ──────────────────────────────────────────
 *
 * A business may only write first, or write after the customer has been
 * quiet for 24 hours, with a template Meta has approved. An order update is
 * exactly that: the customer has usually not written in a day. Free text is
 * refused outside the window (error 131047), so a sender that used it worked
 * in testing — where the tester had just messaged the number — and failed for
 * every real customer. So the body is `type: "template"`, and there is no
 * free-text path here at all.
 *
 * ── THE TOKEN ────────────────────────────────────────────────────────────
 *
 * The shop's access token goes in the Authorization header and nowhere else —
 * not the URL, not an error. It is checked for shape before it goes there,
 * because a token with a newline in it is a second header.
 *
 * PURE: no clock, no network, no randomness.
 */
(function (global) {

  /** The Graph API version both apps speak. One place to move it. */
  const GRAPH_VERSION = 'v21.0';
  const GRAPH = 'https://graph.facebook.com/' + GRAPH_VERSION + '/';

  // ── WHAT IS ACCEPTED ──────────────────────────────────────────────────────

  /** Meta's phone number id: digits only, as WhatsApp Manager shows it. */
  function isPhoneNumberId(v) { return /^\d{6,20}$/.test(String(v || '')); }

  /**
   * An access token: one line of the characters Meta's tokens are made of.
   * Anything else — a space, a newline, a quote — is a paste gone wrong, and
   * in a header it would be worse than wrong.
   */
  function isToken(v) { return /^[A-Za-z0-9_\-.|]{20,4096}$/.test(String(v || '')); }

  /** A template's name as WhatsApp Manager allows it: lowercase, digits, `_`. */
  function isTemplateName(v) { return /^[a-z0-9_]{1,512}$/.test(String(v || '')); }

  /** A template language code: `ar`, `en`, `en_US`. */
  function isLanguage(v) { return /^[a-z]{2,3}(_[A-Z]{2})?$/.test(String(v || '')); }

  /**
   * One template parameter as Meta will take it.
   *
   * A body parameter may not hold a newline, a tab or more than four spaces
   * in a row (Meta refuses the whole message, 132018), and may not be empty
   * (132000). A customer's name typed on two lines is not a reason for the
   * customer to hear nothing, so it is made one line rather than refused.
   */
  const PARAM_MAX = 200;
  function cleanParam(v) {
    const s = String(v == null ? '' : v)
      .replace(/[\r\n\t]+/g, ' ')
      .replace(/ {4,}/g, ' ')
      .trim()
      .slice(0, PARAM_MAX)
      .trim();
    return s || '-';
  }

  // ── THE REQUEST ───────────────────────────────────────────────────────────

  function refuse(reason) { return { ok: false, reason }; }

  /**
   * The request that sends one template message.
   *
   * `msg`: `{ phoneNumberId, token, to, template: { name, language }, params }`
   * where `to` is the international number, digits only
   * (`KhaytWhatsappMessage.normalizePhone(...).digits`) and `params` the
   * template's body values in order (`KhaytWhatsappMessage.templateParams`).
   *
   * Returns `{ ok: true, url, method, headers, body }` or `{ ok: false,
   * reason }` with one of `bad_phone_number_id`, `bad_token`, `bad_recipient`,
   * `bad_template`, `bad_language`. The token is in `headers` only.
   */
  function buildRequest(msg) {
    const m = msg || {};
    const t = m.template || {};
    if (!isPhoneNumberId(m.phoneNumberId)) return refuse('bad_phone_number_id');
    if (!isToken(m.token)) return refuse('bad_token');
    if (!/^\d{8,15}$/.test(String(m.to || ''))) return refuse('bad_recipient');
    if (!isTemplateName(t.name)) return refuse('bad_template');
    if (!isLanguage(t.language)) return refuse('bad_language');
    const params = (Array.isArray(m.params) ? m.params : []).map(cleanParam);
    const template = { name: t.name, language: { code: t.language } };
    if (params.length) {
      template.components = [{
        type: 'body',
        parameters: params.map((text) => ({ type: 'text', text })),
      }];
    }
    return {
      ok: true,
      url: GRAPH + m.phoneNumberId + '/messages',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + m.token, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        recipient_type: 'individual',
        to: String(m.to),
        type: 'template',
        template,
      }),
    };
  }

  /**
   * The request a settings screen sends to check the number id and token
   * together WITHOUT writing to anybody: Graph's own record of the number.
   * Same refusals as `buildRequest` for the two fields it takes.
   */
  function buildCheckRequest(cfg) {
    const c = cfg || {};
    if (!isPhoneNumberId(c.phoneNumberId)) return refuse('bad_phone_number_id');
    if (!isToken(c.token)) return refuse('bad_token');
    return {
      ok: true,
      url: GRAPH + c.phoneNumberId + '?fields=display_phone_number,verified_name',
      method: 'GET',
      headers: { Authorization: 'Bearer ' + c.token },
      body: '',
    };
  }

  // ── THE ANSWER ────────────────────────────────────────────────────────────

  /**
   * Meta's error codes, as the shop has to act on them. Several codes, one
   * thing to do: a token that expired and one that never worked both mean
   * "paste a new token".
   *
   * https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes
   */
  const REASONS = {
    0: 'bad_token', 190: 'bad_token', 102: 'bad_token',
    3: 'no_permission', 10: 'no_permission',
    100: 'bad_request',
    4: 'rate_limited', 80007: 'rate_limited', 130429: 'rate_limited', 131056: 'rate_limited',
    368: 'account_restricted', 131031: 'account_restricted',
    131042: 'payment_problem',
    131026: 'not_on_whatsapp',
    131030: 'recipient_not_allowed',
    131047: 'outside_window',
    132000: 'template_params', 132005: 'template_params', 132012: 'template_params', 132018: 'template_params',
    132001: 'template_missing',
    132007: 'template_rejected',
    132015: 'template_paused',
    132016: 'template_disabled',
    133010: 'number_not_registered',
    1: 'unavailable', 2: 'unavailable', 131000: 'unavailable', 131016: 'unavailable',
  };

  /** Reasons worth trying again later without the shop changing anything. */
  const RETRYABLE = ['rate_limited', 'unavailable'];

  function reasonFor(code, status) {
    if (code !== null && Object.prototype.hasOwnProperty.call(REASONS, code)) return REASONS[code];
    if (code !== null && code >= 200 && code <= 299) return 'no_permission';
    if (status === 401) return 'bad_token';
    if (status === 429) return 'rate_limited';
    if (status >= 500) return 'unavailable';
    return 'failed';
  }

  const TITLE_MAX = 200;

  /**
   * What an answer to `buildRequest` means.
   *
   * `status` is the HTTP status, `body` the parsed JSON (or null when it was
   * not JSON). Returns `{ ok: true, messageId, waId }` — `messageId` the
   * `wamid…` the delivery reports name — or `{ ok: false, reason, code,
   * title, retryable }`. A 200 with no message id is NOT a send: nothing
   * could ever report on it, so it is treated as the failure it is.
   */
  function readResponse(status, body) {
    const b = body && typeof body === 'object' ? body : {};
    const err = b.error && typeof b.error === 'object' ? b.error : null;
    if (status >= 200 && status < 300 && !err) {
      const m = Array.isArray(b.messages) ? b.messages[0] : null;
      const id = m && typeof m.id === 'string' ? m.id.trim() : '';
      if (id && id.length <= 256) {
        const c = Array.isArray(b.contacts) ? b.contacts[0] : null;
        return { ok: true, messageId: id, waId: c && typeof c.wa_id === 'string' ? c.wa_id : '' };
      }
      return { ok: false, reason: 'no_message_id', code: null, title: '', retryable: false };
    }
    // `0` is one of Meta's codes (an auth failure), so "no code" is null.
    const code = err && Number.isFinite(err.code) ? err.code : null;
    const reason = reasonFor(code, status);
    const raw = err ? String(err.error_user_title || err.message || '') : '';
    return {
      ok: false, reason, code,
      title: raw.replace(/\s+/g, ' ').trim().slice(0, TITLE_MAX),
      retryable: RETRYABLE.indexOf(reason) !== -1,
    };
  }

  /**
   * What an answer to `buildCheckRequest` means: `{ ok, number, name }` on
   * success — the number as WhatsApp shows it and the business's verified
   * name, so the shop sees it is the account it meant — or the same failure
   * shape as `readResponse`.
   */
  function readCheck(status, body) {
    const b = body && typeof body === 'object' ? body : {};
    if (status >= 200 && status < 300 && !b.error && b.display_phone_number) {
      return {
        ok: true,
        number: String(b.display_phone_number).slice(0, 40),
        name: String(b.verified_name || '').slice(0, TITLE_MAX),
      };
    }
    const r = readResponse(status >= 200 && status < 300 && !b.error ? 404 : status, b);
    return Object.assign(r, { ok: false });
  }

  const api = {
    GRAPH_VERSION, REASONS, RETRYABLE, PARAM_MAX,
    isPhoneNumberId, isToken, isTemplateName, isLanguage, cleanParam,
    buildRequest, buildCheckRequest, readResponse, readCheck,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWhatsappSend = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
