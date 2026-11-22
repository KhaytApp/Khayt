'use strict';
/**
 * The request an SMS provider is sent, and what its answer means — with no
 * network, no Node and no browser in it.
 *
 * This was the top half of `lib/sms.js`, which only the desktop's main process
 * could load: it built the Twilio form with `URLSearchParams` and the Basic
 * header with `Buffer`, neither of which JavaScriptCore has. The Mac sends the
 * same messages through the same providers now, so the builder lives here and
 * `lib/sms.js` re-exports it unchanged. Both apps send byte-identical requests,
 * which is what a provider's support desk will ask for first.
 *
 * `settings.smsConfig` is the account, the shape the desktop's SMS settings
 * write: `{ provider, channel, accountSid, authToken, from, phoneNumberId,
 * token, appSid, senderId, url, secret }`. `authToken`, `token`, `appSid` and
 * `secret` are registered secrets (`lib/store-secret-paths.js`) and arrive here
 * already opened by the host; nothing in this file stores or logs one.
 */
(function (global) {

  /** The providers that send free text. `whatsapp_cloud` sends templates only. */
  const TEXT_PROVIDERS = ['twilio', 'unifonic', 'webhook'];
  const PROVIDERS = ['none', 'twilio', 'whatsapp_cloud', 'unifonic', 'webhook'];

  /** Normalize a phone to digits, preserving a single leading "+". */
  function normalizePhone(p, opts) {
    const plus = !opts || opts.plus !== false;
    const digits = String(p || '').replace(/[^\d]/g, '');
    return plus ? '+' + digits : digits;
  }

  /**
   * `application/x-www-form-urlencoded`, exactly as `URLSearchParams` writes
   * it (the WHATWG serializer): UTF-8 bytes, `*-._` and alphanumerics kept,
   * a space as `+`, everything else `%XX` upper-case. Pinned against
   * `URLSearchParams` in test/sms-request.test.js.
   */
  function formEncode(pairs) {
    const enc = (s) => encodeURIComponent(String(s))
      .replace(/[!'()~]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase())
      .replace(/%20/g, '+');
    return Object.keys(pairs).map((k) => enc(k) + '=' + enc(pairs[k])).join('&');
  }

  /** Standard base64 of a string's UTF-8 bytes (what `Buffer.toString('base64')` writes). */
  function base64(text) {
    const bytes = unescape(encodeURIComponent(String(text)));
    const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let out = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2);
      const n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out += A[(n >> 18) & 63] + A[(n >> 12) & 63]
        + (i + 1 < bytes.length ? A[(n >> 6) & 63] : '=')
        + (i + 2 < bytes.length ? A[n & 63] : '=');
    }
    return out;
  }

  /**
   * Build the HTTP request for a provider. Returns
   * { url, method, headers, body, contentType } or throws if mis-configured.
   *   msg = { to, message, channel('sms'|'whatsapp') }
   */
  function buildSmsRequest(provider, cfg, msg) {
    cfg = cfg || {};
    msg = msg || {};
    const to = String(msg.to || '').trim();
    const body = String(msg.message || '').slice(0, 4096);
    const channel = msg.channel === 'whatsapp' ? 'whatsapp' : 'sms';
    if (!to) throw new Error('Missing recipient phone');

    if (provider === 'twilio') {
      if (!cfg.accountSid || !cfg.authToken) throw new Error('Twilio needs Account SID + Auth Token');
      const pre = channel === 'whatsapp' ? 'whatsapp:' : '';
      const form = formEncode({
        From: pre + (channel === 'whatsapp' ? normalizePhone(cfg.from) : (cfg.from || '')),
        To: pre + normalizePhone(to),
        Body: body,
      });
      return {
        url: `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(cfg.accountSid)}/Messages.json`,
        method: 'POST',
        headers: { Authorization: 'Basic ' + base64(`${cfg.accountSid}:${cfg.authToken}`) },
        body: form,
        contentType: 'application/x-www-form-urlencoded',
      };
    }

    if (provider === 'whatsapp_cloud') {
      // The shop's WhatsApp Business account writes first, and Meta takes only an
      // approved template for that: free text is refused outside the 24 hours
      // after the customer last wrote (error 131047) — so it worked for a tester
      // who had just messaged the number and failed for nearly every customer.
      // Those sends go through lib/whatsapp-send.js; there is no free-text path.
      throw new Error('WhatsApp Business sends approved templates only');
    }

    if (provider === 'unifonic') {
      if (!cfg.appSid) throw new Error('Unifonic needs an AppSid');
      const form = formEncode({
        AppSid: cfg.appSid,
        SenderID: cfg.senderId || '',
        Body: body,
        Recipient: normalizePhone(to, { plus: false }),
      });
      return {
        url: 'https://api.unifonic.com/rest/SMS/messages',
        method: 'POST',
        headers: {},
        body: form,
        contentType: 'application/x-www-form-urlencoded',
      };
    }

    if (provider === 'webhook') {
      if (!/^https?:\/\//i.test(String(cfg.url || ''))) throw new Error('Webhook needs an http(s) URL');
      const headers = { };
      if (cfg.secret) headers['X-Khayt-Secret'] = String(cfg.secret);
      return {
        url: cfg.url,
        method: 'POST',
        headers,
        body: JSON.stringify({ to: normalizePhone(to), message: body, channel }),
        contentType: 'application/json',
      };
    }

    throw new Error(`Unknown SMS provider: ${provider || 'none'}`);
  }

  /**
   * Whether the stored account can send a text, before anything is opened.
   * `{ ok, provider, channel, reason }`; `reason` one of `not_set_up` (no
   * provider, or WhatsApp Business, which sends templates), `no_account_sid`,
   * `no_auth_token`, `no_app_sid`, `no_url`. Secrets are checked only for
   * PRESENCE — a sealed one is still a non-empty string.
   */
  function textAccount(settings) {
    const cfg = ((settings || {}).smsConfig) || {};
    const provider = String(cfg.provider || 'none');
    const channel = cfg.channel === 'sms' ? 'sms' : 'whatsapp';
    const out = { ok: false, provider, channel, reason: '' };
    if (TEXT_PROVIDERS.indexOf(provider) === -1) return Object.assign(out, { reason: 'not_set_up' });
    const filled = (k) => !!String(cfg[k] == null ? '' : cfg[k]).trim();
    if (provider === 'twilio') {
      if (!filled('accountSid')) return Object.assign(out, { reason: 'no_account_sid' });
      if (!filled('authToken')) return Object.assign(out, { reason: 'no_auth_token' });
    }
    if (provider === 'unifonic' && !filled('appSid')) return Object.assign(out, { reason: 'no_app_sid' });
    if (provider === 'webhook' && !/^https?:\/\//i.test(String(cfg.url || ''))) {
      return Object.assign(out, { reason: 'no_url' });
    }
    out.ok = true;
    return out;
  }

  /**
   * What a provider's answer means: `{ ok, status, error }`, the shape
   * `sendSms` has always returned. `text` is the answer's body, kept to 200
   * characters so a provider that echoes the request cannot spill it.
   */
  function readSmsResponse(status, text) {
    const s = Number(status) || 0;
    if (s >= 200 && s < 300) return { ok: true, status: s };
    let detail = `HTTP ${s}`;
    const t = String(text == null ? '' : text);
    if (t) detail += ` — ${t.slice(0, 200)}`;
    return { ok: false, status: s, error: detail };
  }

  /**
   * The line a text writes to the customer's communications log — the shape
   * every log line has (`{ id, type, note, at }`), `type: 'sms'`, which the
   * desktop's customer editor already offers, plus the job and milestone it
   * was for when it was an order update.
   */
  function commEntry(opts) {
    const o = opts || {};
    const out = { id: String(o.id || ''), type: 'sms', note: String(o.text || ''), at: String(o.at || '') };
    if (o.orderId) out.orderId = String(o.orderId);
    if (['received', 'ready', 'shipped', 'delivered'].indexOf(o.milestone) !== -1) out.milestone = o.milestone;
    if (o.provider) out.via = String(o.provider);
    return out;
  }

  /** When this job's update for this milestone was last texted, or null. */
  function sentAt(commLog, orderId, milestone) {
    let best = null;
    for (const e of Array.isArray(commLog) ? commLog : []) {
      if (!e || e.type !== 'sms' || e.orderId !== orderId || e.milestone !== milestone) continue;
      const at = String(e.at || '');
      if (!best || at > best) best = at;
    }
    return best;
  }

  const api = {
    PROVIDERS, TEXT_PROVIDERS, normalizePhone, formEncode, base64,
    buildSmsRequest, textAccount, readSmsResponse, commEntry, sentAt,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSmsRequest = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
