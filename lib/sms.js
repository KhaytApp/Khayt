'use strict';

/**
 * Outbound SMS / WhatsApp sender (main-process, Node-only) — the automated
 * counterpart to the manual `shareWhatsApp` (wa.me) link. Mirrors the email
 * provider approach in main.js: a pluggable provider with hand-built HTTP
 * requests (no SDKs).
 *
 * Providers: twilio (SMS + WhatsApp), unifonic (popular SMS gateway in the Gulf),
 * and a generic webhook. The shop's WhatsApp Business account (whatsapp_cloud)
 * is configured here but sends through lib/whatsapp-send.js.
 *
 * buildSmsRequest() is pure (no I/O) and unit-tested; sendSms() performs the
 * fetch and normalizes the result.
 */

/** Normalize a phone to digits, preserving a single leading "+". */
function normalizePhone(p, { plus = true } = {}) {
  const digits = String(p || '').replace(/[^\d]/g, '');
  return plus ? '+' + digits : digits;
}

/**
 * Build the HTTP request for a provider. Returns
 * { url, method, headers, body, contentType } or throws if mis-configured.
 *   msg = { to, message, channel('sms'|'whatsapp') }
 */
function buildSmsRequest(provider, cfg, msg) {
  cfg = cfg || {};
  const to = String(msg.to || '').trim();
  const body = String(msg.message || '').slice(0, 4096);
  const channel = msg.channel === 'whatsapp' ? 'whatsapp' : 'sms';
  if (!to) throw new Error('Missing recipient phone');

  if (provider === 'twilio') {
    if (!cfg.accountSid || !cfg.authToken) throw new Error('Twilio needs Account SID + Auth Token');
    const pre = channel === 'whatsapp' ? 'whatsapp:' : '';
    const form = new URLSearchParams({
      From: pre + (channel === 'whatsapp' ? normalizePhone(cfg.from) : (cfg.from || '')),
      To: pre + normalizePhone(to),
      Body: body,
    });
    return {
      url: `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(cfg.accountSid)}/Messages.json`,
      method: 'POST',
      headers: { Authorization: 'Basic ' + Buffer.from(`${cfg.accountSid}:${cfg.authToken}`).toString('base64') },
      body: form.toString(),
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
    const form = new URLSearchParams({
      AppSid: cfg.appSid,
      SenderID: cfg.senderId || '',
      Body: body,
      Recipient: normalizePhone(to, { plus: false }),
    });
    return {
      url: 'https://api.unifonic.com/rest/SMS/messages',
      method: 'POST',
      headers: {},
      body: form.toString(),
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

/** Perform the send. Returns { ok, status } | { ok:false, error }. */
async function sendSms(provider, cfg, msg, { fetchImpl } = {}) {
  const f = fetchImpl || fetch;
  let req;
  try { req = buildSmsRequest(provider, cfg, msg); }
  catch (e) { return { ok: false, error: String(e && e.message || e) }; }
  try {
    const res = await f(req.url, {
      method: req.method,
      headers: { 'Content-Type': req.contentType, ...req.headers },
      body: req.body,
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) {
      let detail = `HTTP ${res.status}`;
      try { const txt = await res.text(); if (txt) detail += ` — ${txt.slice(0, 200)}`; } catch { /* ignore */ }
      return { ok: false, status: res.status, error: detail };
    }
    return { ok: true, status: res.status };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
}

const WaSend = require('./whatsapp-send.js');

/** Read a Graph answer as JSON, or null when it is not JSON. */
async function graphJson(res) {
  try { return JSON.parse(await res.text()); } catch { return null; }
}

/**
 * Send one approved template through the shop's WhatsApp Business account.
 * `cfg` is smsConfig (`phoneNumberId`, `token`); `msg` is `{ to, template:
 * { name, language }, params }` with `to` digits only. Returns lib/whatsapp-
 * send.js's reading: `{ ok, messageId }` or `{ ok:false, reason, code, title,
 * retryable }` — never the token.
 */
async function sendWhatsappTemplate(cfg, msg, { fetchImpl } = {}) {
  const f = fetchImpl || fetch;
  const c = cfg || {};
  const m = msg || {};
  const req = WaSend.buildRequest({ phoneNumberId: c.phoneNumberId, token: c.token,
    to: m.to, template: m.template, params: m.params });
  if (!req.ok) return { ok: false, reason: req.reason, code: null, title: '', retryable: false };
  try {
    const res = await f(req.url, { method: req.method, headers: req.headers, body: req.body,
      signal: AbortSignal.timeout(15000) });
    return WaSend.readResponse(res.status, await graphJson(res));
  } catch {
    return { ok: false, reason: 'unavailable', code: null, title: '', retryable: true };
  }
}

/**
 * Check the account's number id and token together without messaging anyone.
 * `{ ok, number, name }` — the number and verified business name, so the shop
 * sees it is the account it meant — or the failure shape above.
 */
async function checkWhatsapp(cfg, { fetchImpl } = {}) {
  const f = fetchImpl || fetch;
  const req = WaSend.buildCheckRequest(cfg || {});
  if (!req.ok) return { ok: false, reason: req.reason, code: null, title: '', retryable: false };
  try {
    const res = await f(req.url, { method: req.method, headers: req.headers,
      signal: AbortSignal.timeout(15000) });
    return WaSend.readCheck(res.status, await graphJson(res));
  } catch {
    return { ok: false, reason: 'unavailable', code: null, title: '', retryable: true };
  }
}

module.exports = { normalizePhone, buildSmsRequest, sendSms, sendWhatsappTemplate, checkWhatsapp };
