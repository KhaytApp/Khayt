'use strict';

/**
 * Khayt Vault routes of Khayt Cloud, for the Electron main process.
 *
 * The JavaScript twin of the native Mac app's `VaultClient`
 * (mac/KhaytCore/Sources/KhaytCore/VaultClient.swift, and the grant routes in
 * VaultLinks.swift). Only the routes share links need are here: usage, the
 * delta feed, and the grant routes. Uploads and downloads are not ported.
 *
 * Every request is `{baseUrl}/v1/shops/{shopId}{tail}` with
 * `Authorization: Bearer {token}` and `x-delta-capable: 1`, exactly as
 * `CloudReader.request` builds it: one call site without the delta header
 * closes delta sync for the whole shop.
 *
 * The base URL must be https. The token travels in a header, so plain http
 * would put a shop-wide credential on the wire in clear text. The only
 * exception is loopback (127.0.0.0/8, localhost, ::1), for a server on this
 * machine and for tests.
 *
 * Wire encoding (as the Swift): blobs (`wrappedKey`, `meta`, `versionMeta`,
 * `linkMeta`, `ownerNote`) are standard base64 with padding; ids are
 * base64url without padding. This module passes bodies through as given; the
 * caller (lib/vault-links.js) does the encoding.
 *
 * Errors: every refusal throws an Error with `.status` (the HTTP code) and
 * `.reason` — the server's own `reason` when it gave one (no-vault,
 * vault-full, read-only, vault-over, no-links, links-full, links-disabled,
 * grant-exists, unknown-items, downloads-cap, disabled, …). Without one:
 * 404 → 'no-vault' (`.vaultOff = true`: the vault is not switched on for this
 * cloud), 401 → 'not-accepted', 403 → 'not-allowed', 422 → 'invalid',
 * 429 → 'rate-limited', anything else → 'http'. A reply that cannot be read
 * is 'bad-reply'. The reply's `used`, `limit`, `fileIds` and `error` ride
 * along on the Error when present.
 */

const DEFAULT_TIMEOUT_MS = 30000;
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

/** What each refusal says, by reason (VaultClient.swift Failure.description). */
const MESSAGES = {
  'vault-full': 'The vault is full.',
  'no-vault': "This shop's plan has no vault.",
  'read-only': 'The vault is read-only: the plan lapsed or no longer includes it.',
  'vault-over': 'The vault holds more than this plan allows.',
  'no-links': "This shop's plan has no share links.",
  'links-full': "This plan's share links are all in use.",
  'links-disabled': 'Khayt has turned off share links for this shop.',
  'grant-exists': 'That link id is taken already.',
  'unknown-items': 'Some files are no longer in the vault.',
  'downloads-cap': 'This plan caps the downloads a link may allow.',
  'disabled': 'Khayt turned this link off; it can only be revoked.',
  'not-yet': 'Khayt Cloud does not offer that yet.',
  'bad-email-lock': "Khayt Cloud did not accept the link's email addresses.",
  'mail-off': 'Khayt Cloud cannot send email, so it cannot lock a link to email addresses.',
  'not-accepted': "Khayt Cloud did not accept this shop's token. It may have been reset.",
  'not-allowed': 'This sign-in may not do that.',
  'rate-limited': 'Khayt Cloud asked to slow down; try again shortly.',
};

function vaultError(status, reason, extra) {
  const e = new Error(MESSAGES[reason] || `Khayt Cloud answered ${status}${reason ? ': ' + reason : ''}.`);
  e.name = 'VaultError';
  e.status = status;
  e.reason = reason;
  if (extra) Object.assign(e, extra);
  return e;
}

/** The cloud's answer as an Error, by its `reason` first (VaultClient.failure). */
function failure(status, body) {
  const o = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  const reason = typeof o.reason === 'string' ? o.reason : '';
  const extra = {};
  for (const k of ['used', 'limit', 'fileIds', 'error', 'fileId', 'version', 'metaRev']) {
    if (o[k] !== undefined) extra[k] = o[k];
  }
  if (reason) return vaultError(status, reason, extra);
  switch (status) {
    case 404: return vaultError(404, 'no-vault', { ...extra, vaultOff: true, message: 'Khayt Cloud has no vault switched on.' });
    case 401: return vaultError(401, 'not-accepted', extra);
    case 403: return vaultError(403, 'not-allowed', extra);
    case 422: return vaultError(422, 'invalid', extra);
    case 429: return vaultError(429, 'rate-limited', extra);
    default: return vaultError(status, 'http', extra);
  }
}

function badReply(what) { return vaultError(0, 'bad-reply', { message: `Khayt Cloud's reply could not be read (${what}).` }); }

/** https, or http only to this machine. Returns the base with no trailing slash. */
function checkBaseUrl(raw) {
  let u;
  try { u = new URL(String(raw == null ? '' : raw)); } catch { throw new Error('Not a valid server address'); }
  if (u.username || u.password) throw new Error('Server address must not contain a username or password');
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  const loopback = h === 'localhost' || h === '::1' || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h);
  if (u.protocol === 'https:' || (u.protocol === 'http:' && loopback)) {
    return (u.origin + u.pathname).replace(/\/+$/, '');
  }
  throw new Error('The vault needs an https:// server address');
}

function checkId(v, what) {
  if (typeof v !== 'string' || !ID_RE.test(v)) throw new Error(`${what} must be 1-64 of [A-Za-z0-9_-]`);
  return v;
}

/**
 * @param {object} o
 * @param {string} o.baseUrl   the cloud's API address (https)
 * @param {string} o.shopId
 * @param {string} o.token     the shop token, held only by this client
 * @param {Function} [o.fetch] a WHATWG fetch; defaults to globalThis.fetch
 * @param {number} [o.timeoutMs]
 */
function createVaultClient({ baseUrl, shopId, token, fetch: fetchImpl, timeoutMs } = {}) {
  const base = checkBaseUrl(baseUrl);
  if (typeof shopId !== 'string' || !shopId) throw new Error('shopId is required');
  if (typeof token !== 'string' || !token) throw new Error('token is required');
  const doFetch = fetchImpl || globalThis.fetch;
  if (typeof doFetch !== 'function') throw new Error('fetch is unavailable');
  const timeout = Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : DEFAULT_TIMEOUT_MS;
  const prefix = base + '/v1/shops/' + encodeURIComponent(shopId);

  /** One request; the parsed JSON body when the status is expected, else a throw. */
  async function call(method, tail, body, expect) {
    const headers = { authorization: 'Bearer ' + token, 'x-delta-capable': '1' };
    const init = { method, headers, redirect: 'manual' };
    if (body !== undefined && body !== null) {
      headers['content-type'] = 'application/json';
      init.body = JSON.stringify(body);
    }
    if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
      init.signal = AbortSignal.timeout(timeout);
    }
    const res = await doFetch(prefix + tail, init);
    if (res.status >= 300 && res.status < 400) throw vaultError(res.status, 'redirect', { message: 'Khayt Cloud redirected the request; refusing to follow.' });
    let data = null;
    try { data = await res.json(); } catch { /* empty or not JSON */ }
    if (!expect.includes(res.status)) throw failure(res.status, data);
    if (!data || typeof data !== 'object') throw badReply(method + ' ' + tail);
    return data;
  }

  const grantPath = (id) => '/vault/grants/' + checkId(id, 'grantId');

  return {
    baseUrl: base,
    shopId,

    /** GET /vault/usage: { limits, used, lapse? }. */
    usage: () => call('GET', '/vault/usage', null, [200]),

    /** One page of the delta feed: GET /vault/files?since&limit (limit 1..1000). */
    async filesPage({ since = 0, limit = 1000 } = {}) {
      const n = Math.min(1000, Math.max(1, Math.floor(Number(limit) || 1000)));
      const o = await call('GET', `/vault/files?since=${Math.max(0, Math.floor(Number(since) || 0))}&limit=${n}`, null, [200]);
      if (!Array.isArray(o.files) || !Number.isFinite(o.rev)) throw badReply('feed');
      return { rev: o.rev, more: o.more === true, files: o.files };
    },

    /**
     * The whole delta feed since `since`, following `more`. A file seen on
     * two pages keeps its later row. Returns { rev, files }.
     */
    async files({ since = 0, limit = 1000 } = {}) {
      const byId = new Map();
      let rev = since;
      for (let guard = 0; guard < 100000; guard++) {
        const page = await this.filesPage({ since: rev, limit });
        for (const f of page.files) {
          if (f && typeof f.fileId === 'string') { byId.delete(f.fileId); byId.set(f.fileId, f); }
        }
        if (!page.more) return { rev: page.rev, files: [...byId.values()] };
        if (page.rev <= rev) throw badReply('feed did not advance');
        rev = page.rev;
      }
      throw badReply('feed');
    },

    /** POST /vault/grants (201). A taken id throws reason 'grant-exists'. Returns the reply ({createdAt}). */
    async createGrant(body) {
      if (!body || typeof body !== 'object') throw new Error('createGrant needs a body');
      checkId(body.grantId, 'grantId');
      if (body.grantId.length < 22) throw new Error('grantId must be at least 22 characters');
      return call('POST', '/vault/grants', body, [201]);
    },

    /** PATCH /vault/grants/{id}: the grant as it is afterwards. */
    patchGrant: async (grantId, body) => call('PATCH', grantPath(grantId), body || {}, [200]),

    /** GET /vault/grants: every grant, newest first. */
    async listGrants() {
      const o = await call('GET', '/vault/grants', null, [200]);
      if (!Array.isArray(o.grants)) throw badReply('grants');
      return o.grants;
    },

    /** GET /vault/grants/{id}. */
    getGrant: async (grantId) => call('GET', grantPath(grantId), null, [200]),

    /** GET /vault/grants/{id}/events: newest first, the last 500. */
    async grantEvents(grantId) {
      const o = await call('GET', grantPath(grantId) + '/events', null, [200]);
      if (!Array.isArray(o.events)) throw badReply('events');
      return o.events;
    },
  };
}

module.exports = { createVaultClient, failure, checkBaseUrl };
