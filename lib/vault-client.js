'use strict';

/**
 * Khayt Vault routes of Khayt Cloud, for the Electron main process.
 *
 * The JavaScript twin of the native Mac app's `VaultClient`
 * (mac/KhaytCore/Sources/KhaytCore/VaultClient.swift, and the grant routes in
 * VaultLinks.swift). Here: usage, the delta feed, the grant routes, and the
 * upload routes (lib/vault-upload.js drives them). Downloads are not ported.
 *
 * Bytes never pass through the cloud's Node: an upload's parts are PUT to
 * presigned object-storage URLs with NO Authorization header (a shop token
 * sent to object storage is a token handed to a third party) and exactly the
 * part's length as Content-Length. Presigned URLs must be https too (loopback
 * excepted, for tests).
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
const PUT_TIMEOUT_MS = 300000;        // one part, as VaultClient.put's timeoutInterval
const CHUNK_BYTES = 4194304;          // VaultCrypto.chunkBytes; the upload body names it
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
  'duplicate': 'The vault already holds these bytes.',
  'parts-missing': 'Some parts of the upload did not arrive.',
  'upload-expired': 'The upload expired; it has to start again.',
  'file-too-large': "The file is larger than this plan's vault allows.",
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
  for (const k of ['used', 'limit', 'fileIds', 'error', 'fileId', 'version', 'metaRev', 'indexes']) {
    if (o[k] !== undefined) extra[k] = o[k];
  }
  if (reason) return vaultError(status, reason, extra);
  switch (status) {
    case 404: return vaultError(404, 'no-vault', { ...extra, vaultOff: true, message: 'Khayt Cloud has no vault switched on.' });
    case 401: return vaultError(401, 'not-accepted', extra);
    case 403: return vaultError(403, 'not-allowed', extra);
    case 422: return vaultError(422, 'invalid', extra);
    case 413: return vaultError(413, 'file-too-large', extra); // the Swift maps any 413 so
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

/** A presigned URL: https, or http only to this machine (VaultClient.presigned). */
function checkPresigned(raw) {
  let u;
  try { u = new URL(String(raw == null ? '' : raw)); } catch { throw badReply('presigned url'); }
  const h = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  const loopback = h === 'localhost' || h === '::1' || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h);
  if (u.protocol === 'https:' || (u.protocol === 'http:' && loopback)) return u.href;
  throw badReply('presigned url');
}

function int(v) { return typeof v === 'number' && Number.isSafeInteger(v) ? v : null; }

/** The `parts` of an upload reply: [{index, size, url}] (VaultClient.parts(of:)). */
function partsOf(o) {
  if (!Array.isArray(o.parts)) throw badReply('parts');
  return o.parts.map((p) => {
    if (!p || int(p.index) == null || int(p.size) == null || typeof p.url !== 'string') throw badReply('part');
    return { index: p.index, size: p.size, url: p.url };
  });
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
  const uploadPath = (id) => '/vault/uploads/' + checkId(id, 'uploadId');

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

    // ── uploads (VaultClient.swift "Uploads") ──────────────────────────────

    /**
     * POST /vault/uploads (201). `body` is { sizes, tag, fileId?, baseVersion?,
     * deviceId? }: `sizes` are CIPHERTEXT chunk sizes, `tag` the dedupe tag.
     * `chunkBytes` is added here; deviceId is cut to 64 characters. Returns
     * { uploadId, fileId, version, expiresAt, parts: [{index, size, url}] }.
     * A 409 duplicate throws reason 'duplicate' with `.fileId` and `.version`:
     * the shop has these bytes already, upload nothing.
     */
    async startUpload(body) {
      const b = body || {};
      if (!Array.isArray(b.sizes) || !b.sizes.length || !b.sizes.every((n) => int(n) != null && n >= 16)) {
        throw new Error('startUpload needs the ciphertext chunk sizes');
      }
      if (typeof b.tag !== 'string' || !/^[0-9a-f]{64}$/.test(b.tag)) throw new Error('startUpload needs a dedupe tag');
      const out = { chunkBytes: CHUNK_BYTES, sizes: b.sizes, tag: b.tag };
      if (b.fileId != null) out.fileId = checkId(b.fileId, 'fileId');
      if (b.baseVersion != null) out.baseVersion = b.baseVersion;
      if (b.deviceId != null) out.deviceId = String(b.deviceId).slice(0, 64);
      const o = await call('POST', '/vault/uploads', out, [201]);
      if (typeof o.uploadId !== 'string' || typeof o.fileId !== 'string' || int(o.version) == null) {
        throw badReply('upload start');
      }
      checkId(o.uploadId, 'uploadId');
      checkId(o.fileId, 'fileId');
      return { uploadId: o.uploadId, fileId: o.fileId, version: o.version,
        expiresAt: typeof o.expiresAt === 'string' ? o.expiresAt : '', parts: partsOf(o) };
    },

    /** GET /vault/uploads/{id}/parts?from=i: fresh presigned PUTs from part i (one page, ≤256). */
    async uploadParts(uploadId, from = 0) {
      const i = Math.max(0, Math.floor(Number(from) || 0));
      return partsOf(await call('GET', uploadPath(uploadId) + '/parts?from=' + i, null, [200]));
    },

    /**
     * PUT one part's ciphertext to its presigned URL: exactly `bytes.length`
     * bytes as Content-Length, which must equal `size` when given, and NO
     * Authorization. A refusal throws reason 'transfer' with `.index`.
     */
    async putPart(url, bytes, { index = -1, size } = {}) {
      const href = checkPresigned(url);
      const body = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes || []);
      const transfer = (status) => vaultError(status, 'transfer', { index, method: 'PUT',
        message: `Object storage refused part ${index} (${status}).` });
      if (size != null && body.length !== size) throw transfer(0);
      const init = { method: 'PUT', headers: { 'content-length': String(body.length) }, body, redirect: 'manual' };
      if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
        init.signal = AbortSignal.timeout(PUT_TIMEOUT_MS);
      }
      const res = await doFetch(href, init);
      if (!(res.status >= 200 && res.status < 300)) throw transfer(res.status);
    },

    /**
     * POST /vault/uploads/{id}/complete (201). `body` is { manifestHash,
     * wrappedKey, versionMeta, meta? }, blobs already standard base64.
     * Returns { fileId, version, rev, conflict }. A 409 parts-missing throws
     * with `.indexes`: re-PUT the STORED ciphertext of those parts.
     */
    async completeUpload(uploadId, body) {
      const b = body || {};
      for (const k of ['manifestHash', 'wrappedKey', 'versionMeta']) {
        if (typeof b[k] !== 'string' || !b[k]) throw new Error('completeUpload needs ' + k);
      }
      const out = { manifestHash: b.manifestHash, wrappedKey: b.wrappedKey, versionMeta: b.versionMeta };
      if (b.meta != null) out.meta = b.meta;
      const o = await call('POST', uploadPath(uploadId) + '/complete', out, [201]);
      if (typeof o.fileId !== 'string' || int(o.version) == null || int(o.rev) == null) throw badReply('complete');
      return { fileId: o.fileId, version: o.version, rev: o.rev, conflict: o.conflict === true };
    },

    /** DELETE /vault/uploads/{id}: give the upload up and release its reservation. */
    async abandonUpload(uploadId) {
      await call('DELETE', uploadPath(uploadId), null, [200]);
    },
  };
}

module.exports = { createVaultClient, failure, checkBaseUrl };
