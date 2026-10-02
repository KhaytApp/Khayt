'use strict';
/**
 * Sending an outgoing webhook: how it is signed, and where it is allowed to go.
 *
 * Main process only (Node's `https`, `dns` and `crypto`). The Mac sends the
 * same deliveries from Swift (#1712); the header bytes below are pinned to its
 * test vector so a receiver cannot tell which app sent a delivery.
 *
 * ── SIGNING ────────────────────────────────────────────────────────────────
 *
 * `X-Khayt-Signature` is the HMAC-SHA256 of the raw body. It is kept exactly as
 * each transport has always sent it, because receivers already verify it: the
 * event webhook (`hub:webhook-post`) sends `sha256=<hex>`, the per-event bus
 * (`hub:fire-webhook`) bare hex. Changing either would break every receiver
 * that works today.
 *
 * That signature never expires, so a captured delivery could be replayed for
 * ever. Every signed delivery now also carries:
 *
 *   X-Khayt-Timestamp     Unix seconds at send time
 *   X-Khayt-Signature-V2  bare hex HMAC-SHA256 of "<timestamp>.<body>"
 *
 * with the same secret, the scheme Stripe and Slack use. A receiver that checks
 * V2 and refuses an old timestamp cannot be replayed.
 *
 * ── WHERE IT GOES ──────────────────────────────────────────────────────────
 *
 * The old code checked the host's DNS answers and then let fetch() resolve the
 * name AGAIN to connect. A name that answers with a public address for the
 * check and a private one for the connection (DNS rebinding) got through.
 * postPinned resolves once, refuses if ANY answer is private or loopback, and
 * connects to the address it checked. TLS still verifies the certificate
 * against the hostname the shop typed (SNI and the Host header carry it), so
 * pinning the address does not weaken HTTPS. Redirects are never followed.
 */
const https = require('https');
const http = require('http');
const dns = require('dns');
const crypto = require('crypto');
const net = require('net');
const { isBlockedHost } = require('./host-ranges.js');

const hmacHex = (secret, data) => crypto.createHmac('sha256', String(secret)).update(data).digest('hex');

/**
 * The signature headers for one delivery, or {} with no secret.
 * @param {string} secret
 * @param {string} body the exact bytes that will be sent
 * @param {number} nowMs
 * @param {{ v1Prefix?: boolean }} [opts] v1Prefix: send V1 as `sha256=<hex>`
 */
function signatureHeaders(secret, body, nowMs, opts) {
  if (!secret) return {};
  const ts = String(Math.floor(Number(nowMs) / 1000));
  const v1 = hmacHex(secret, body);
  return {
    'X-Khayt-Signature': (opts && opts.v1Prefix ? 'sha256=' : '') + v1,
    'X-Khayt-Timestamp': ts,
    'X-Khayt-Signature-V2': hmacHex(secret, `${ts}.${body}`),
  };
}

const defaultLookupAll = (host) => dns.promises.lookup(host, { all: true });

/**
 * POST `body` to an https URL, connecting only to an address that was checked.
 *
 * @returns {Promise<{ ok: boolean, status?: number, text?: string, error?: string }>}
 *   `error` is set for a refusal or a transport failure, never for an HTTP status.
 */
async function postPinned(url, { headers = {}, body = '', timeoutMs = 10000, allowHttp = false } = {}, deps = {}) {
  const lookupAll = deps.lookupAll || defaultLookupAll;

  let u;
  try { u = new URL(String(url)); } catch { return { ok: false, error: 'Invalid webhook URL' }; }
  const isHttps = u.protocol === 'https:';
  if (!isHttps && !(allowHttp && u.protocol === 'http:')) return { ok: false, error: 'Webhook needs an https:// URL' };
  const request = deps.request || (isHttps ? https.request : http.request);
  const host = u.hostname.replace(/^\[|\]$/g, '');
  if (isBlockedHost(host)) return { ok: false, error: 'Blocked URL — cannot send webhooks to private/loopback addresses' };

  let target;
  if (net.isIP(host)) {
    target = { address: host, family: net.isIP(host) };
  } else {
    let addrs;
    try { addrs = await lookupAll(host); } catch { addrs = null; }
    // Fail closed: an answer that cannot be checked is not sent to.
    if (!Array.isArray(addrs) || !addrs.length) return { ok: false, error: 'Blocked URL — hostname could not be resolved' };
    if (addrs.some((a) => isBlockedHost(a.address))) {
      return { ok: false, error: 'Blocked URL — hostname resolves to a private/loopback address' };
    }
    target = { address: addrs[0].address, family: addrs[0].family || net.isIP(addrs[0].address) };
  }

  const payload = Buffer.from(String(body), 'utf8');
  return new Promise((resolve) => {
    let settled = false;
    const done = (r) => { if (!settled) { settled = true; resolve(r); } };
    let req;
    try {
      req = request({
        protocol: u.protocol,
        hostname: host,
        port: u.port || (isHttps ? 443 : 80),
        path: (u.pathname || '/') + (u.search || ''),
        method: 'POST',
        headers: { ...headers, 'Content-Length': payload.length },
        // The pin: whatever name Node asks to resolve, it gets the checked address.
        lookup: (_name, options, cb) => {
          if (options && options.all) cb(null, [{ address: target.address, family: target.family }]);
          else cb(null, target.address, target.family);
        },
        // SNI must be a name, never an IP literal.
        ...(isHttps && !net.isIP(host) ? { servername: host } : {}),
        timeout: timeoutMs,
      }, (res) => {
        const status = res.statusCode || 0;
        const chunks = [];
        let size = 0;
        res.on('data', (c) => { if (size < 4096) { chunks.push(c); size += c.length; } });
        res.on('end', () => {
          if (status >= 300 && status < 400) return done({ ok: false, status, error: 'Webhook redirects are not allowed' });
          done({ ok: status >= 200 && status < 300, status, text: Buffer.concat(chunks).toString('utf8').slice(0, 4096) });
        });
        res.on('error', (e) => done({ ok: false, error: String((e && e.message) || e) }));
      });
    } catch (e) { return done({ ok: false, error: String((e && e.message) || e) }); }
    req.on('timeout', () => { req.destroy(new Error('Webhook timed out')); });
    req.on('error', (e) => done({ ok: false, error: String((e && e.message) || e) }));
    req.end(payload);
  });
}

module.exports = { signatureHeaders, postPinned };
