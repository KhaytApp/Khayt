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

// The request builder is shared with the Mac app (`lib/sms-request.js`, pure,
// no Node): both apps send byte-identical requests. Re-exported here unchanged.
const { normalizePhone, buildSmsRequest, readSmsResponse } = require('./sms-request.js');

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
      let txt = '';
      try { txt = await res.text(); } catch { /* ignore */ }
      return readSmsResponse(res.status, txt);
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
