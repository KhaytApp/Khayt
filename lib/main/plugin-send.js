'use strict';
/**
 * The desktop's connector transport (main process only).
 *
 * The window decides WHEN a connector runs — a button pressed, an event on a
 * job — and hands this the entry's id, the trigger and the records. Everything
 * that decides WHETHER and WHERE runs here, where the secrets are:
 *
 *   - REVIEWED: the manifest's ed25519 signature must verify against
 *     lib/plugin-manifest.js SIGNING_KEYS, over canonicalJSON. Every time;
 *     the book holds no "reviewed" flag to trust (dev mode is the Mac's only).
 *   - the entry must pass checkEntry, not be paused and be switched on.
 *   - the request is lib/plugin-payload.js payloadFor's, byte for byte: its
 *     `body` string is sent and signed as it is, never re-encoded or wrapped.
 *     payloadFor refusing means no request at all.
 *   - the finished URL's host must be EXACTLY one the shop granted and the
 *     manifest declares (lib/secret-destination.js pluginDestinationAllowed),
 *     re-checked here at send time.
 *   - the POST goes through lib/webhook-send.js postPinned: DNS pinned and
 *     checked, never a private address, no redirect followed. 15 s, and a
 *     reply over 64 KB is not read as JSON.
 *
 * Headers, the same on every device (Mac Connectors.swift): Content-Type,
 * X-Khayt-Event (the event name or the action id), X-Khayt-Delivery (the id
 * minted once per press or event), the trigger's auth header when it names
 * one, and — only with `signWith` — X-Khayt-Signature (bare hex HMAC of the
 * body), X-Khayt-Timestamp and X-Khayt-Signature-V2.
 */
const crypto = require('crypto');
const M = require('../plugin-manifest.js');
const P = require('../plugin-payload.js');
const SecretDestination = require('../secret-destination.js');
const webhookSend = require('../webhook-send.js');

const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');
const DELIVERY_RE = /^dlv_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// An HTTP header name (RFC 7230 token). A manifest passed validation, but the
// value is about to become a header, so it is held to the wire's own rule.
const HEADER_NAME_RE = /^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}$/;
const TIMEOUT_MS = 15000;
const REPLY_MAX = 64 * 1024;

const keyCache = new Map();
function publicKeyOf(b64) {
  if (!keyCache.has(b64)) {
    keyCache.set(b64, crypto.createPublicKey({ key: Buffer.concat([SPKI_PREFIX, Buffer.from(b64, 'base64')]), format: 'der', type: 'spki' }));
  }
  return keyCache.get(b64);
}

/** The id of the Khayt key this manifest's signature verifies against, or null. */
function reviewedBy(manifest, keys) {
  if (!manifest || typeof manifest.signature !== 'string') return null;
  let msg, sig;
  try {
    msg = Buffer.from(M.canonicalJSON(manifest), 'utf8');
    sig = Buffer.from(manifest.signature, 'base64');
  } catch (_) { return null; }
  if (sig.length !== 64) return null;
  for (const k of (keys || M.SIGNING_KEYS)) {
    try { if (crypto.verify(null, msg, publicKeyOf(k.key), sig)) return k.id; } catch (_) { /* a bad key verifies nothing */ }
  }
  return null;
}

/** Can this manifest be installed here? Valid AND reviewed. */
function checkInstall(manifest, keys) {
  const v = M.validateManifest(manifest);
  if (!v.ok) return { ok: false, error: 'invalid', errors: v.errors };
  const by = reviewedBy(manifest, keys);
  if (!by) return { ok: false, error: 'unreviewed' };
  return { ok: true, reviewedBy: by };
}

/**
 * Send one trigger. `entry` is the stored entry from DISK (secrets in the
 * clear, never the window's masked copy); `records` is { order, customer }
 * from the window. Returns
 *   { ok:true, method:'OPEN', url }                    an "open" button
 *   { ok, status, reply|null, error? }                 a POST
 *   { ok:false, refused:'…' }                          nothing was sent
 */
async function send({ entry, trigger, records, delivery }, deps = {}) {
  const keys = deps.keys;
  const post = deps.postPinned || webhookSend.postPinned;
  const now = deps.now || Date.now;
  if (!entry || !entry.manifest) return { ok: false, refused: 'not installed' };
  const check = M.checkEntry(entry);
  if (!check.ok) return { ok: false, refused: 'invalid' };
  if (!reviewedBy(entry.manifest, keys)) return { ok: false, refused: 'unreviewed' };
  if (check.paused) return { ok: false, refused: 'paused' };
  if (entry.enabled === false) return { ok: false, refused: 'off' };

  const ctx = {
    order: records && records.order ? records.order : undefined,
    customer: records && records.customer ? records.customer : undefined,
    secrets: entry.secrets && typeof entry.secrets === 'object' ? entry.secrets : {},
  };
  const p = P.payloadFor(entry.manifest, trigger, ctx);
  if (!p.ok) return { ok: false, refused: p.error || 'payload' };

  let u;
  try { u = new URL(p.url); } catch (_) { return { ok: false, refused: 'url' }; }
  const host = u.hostname.toLowerCase();
  if (!(entry.manifest.domains || []).includes(host) || !SecretDestination.pluginDestinationAllowed(entry, p.url)) {
    return { ok: false, refused: 'host' };
  }
  if (p.method === 'OPEN') return { ok: true, method: 'OPEN', url: p.url };

  if (!DELIVERY_RE.test(String(delivery || ''))) return { ok: false, refused: 'delivery id' };
  const eventName = trigger.action ? String(trigger.action) : String(trigger.event);
  const headers = { 'Content-Type': p.contentType || 'application/json', 'X-Khayt-Event': eventName, 'X-Khayt-Delivery': delivery };
  if (p.auth) {
    const value = ctx.secrets[p.auth.secret];
    if (typeof value !== 'string' || !value) return { ok: false, refused: `secret "${p.auth.secret}" is not set` };
    if (!HEADER_NAME_RE.test(String(p.auth.header || '')) || /[\r\n]/.test(value) || /[\r\n]/.test(p.auth.scheme || '')) {
      return { ok: false, refused: 'auth header' };
    }
    headers[p.auth.header] = p.auth.scheme ? `${p.auth.scheme} ${value}` : value;
  }
  if (p.signWith) {
    const key = ctx.secrets[p.signWith];
    if (typeof key !== 'string' || !key) return { ok: false, refused: `secret "${p.signWith}" is not set` };
    Object.assign(headers, webhookSend.signatureHeaders(key, p.body, now()));
  }

  const r = await post(p.url, { headers, body: p.body, timeoutMs: TIMEOUT_MS, maxBytes: REPLY_MAX });
  let reply = null;
  if (r && r.ok && !r.truncated && typeof r.text === 'string' && r.text) {
    try { const j = JSON.parse(r.text); if (j && typeof j === 'object' && !Array.isArray(j)) reply = j; } catch (_) { /* not JSON: no reply */ }
  }
  return { ok: !!(r && r.ok), status: r && r.status, reply, error: r && r.error };
}

module.exports = { reviewedBy, checkInstall, send, DELIVERY_RE, TIMEOUT_MS, REPLY_MAX };
