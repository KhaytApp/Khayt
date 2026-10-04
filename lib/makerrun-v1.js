'use strict';

/**
 * MakerRun /api/v1 transport (main-process). The one place a v1 request is built, sent, and read —
 * shared by lib/makerrun-catalog.js (browse, download) and lib/makerrun-publish.js (create, upload).
 *
 * ── TWO ERROR SHAPES, AND THIS FILE READS ONLY ONE OF THEM ─────────────────────────────────────────
 *
 * /v1 answers `{ error: { code, message, details? } }`. `/api/app-token` answers `{ error: "rate" }` —
 * a short string, not the envelope — and MakerRun's own docs say not to share one parser between them.
 * So token refresh stays in lib/makerrun-account.js with its own reader, and `parseV1Error` never sees
 * an app-token response.
 *
 * ── BRANCH ON error.code, NEVER ON THE STATUS ────────────────────────────────────────────────────
 *
 * Two pairs share a status and mean opposite things:
 *   403  mfa_required (complete a challenge and retry) vs forbidden (you may not) vs age_required
 *   503  maintenance (come back in Retry-After seconds) vs unavailable (misconfigured; retrying won't help)
 * The status is used only as a fallback when a body is not the envelope at all (a CDN error page).
 *
 * The host is lib/makerrun.js's BASE — never an environment variable, because these requests carry the
 * user's Bearer token. Tests pass `baseUrl` as a parameter.
 *
 * Node-only (global fetch, FormData, Blob from Node 22). Never loaded in the renderer.
 */
const MAINT = require('./makerrun-maintenance');
const { BASE } = require('./makerrun');

const READ_TIMEOUT_MS = 30000;
const UPLOAD_TIMEOUT_MS = 120000;

/** Codes the UI knows how to explain. Anything else keeps the server's own message. */
const KNOWN_CODES = new Set([
  'bad_request', 'unauthorized', 'forbidden', 'rejected', 'not_found', 'conflict', 'invalid',
  'mfa_required', 'age_required', 'rate_limited', 'unavailable', 'maintenance', 'query_failed',
]);

/** Plain-English fallbacks, used only when the server sent no message of its own. */
const FALLBACK = {
  unauthorized: 'Your MakerRun session expired — sign in again.',
  forbidden: 'MakerRun refused that request.',
  rejected: 'MakerRun refused that request.',
  not_found: 'MakerRun could not find that design.',
  conflict: 'That listing cannot accept this change in its current state.',
  invalid: 'MakerRun rejected some of the fields.',
  mfa_required: 'This MakerRun account has two-factor authentication on, and this sign-in has not completed it.',
  age_required: 'This design is marked 18+. Confirm your age on makerrun.com, then try again.',
  rate_limited: 'MakerRun is asking for a pause. Wait a minute and try again.',
  unavailable: 'MakerRun is unavailable right now. If it does not clear shortly, this needs reporting.',
  bad_request: 'MakerRun could not read that request.',
};

function statusFallbackCode(status) {
  if (status === 401) return 'unauthorized';
  if (status === 403) return 'forbidden';
  if (status === 404) return 'not_found';
  if (status === 409) return 'conflict';
  if (status === 422) return 'invalid';
  if (status === 429) return 'rate_limited';
  if (status === 503) return 'unavailable';
  return 'http_' + status;
}

/** Keep only well-formed `{field, message}` entries; the UI maps `field` onto a form control. */
function cleanDetails(list) {
  if (!Array.isArray(list)) return [];
  return list
    .filter((d) => d && typeof d === 'object' && typeof d.field === 'string')
    .map((d) => ({ field: d.field, message: typeof d.message === 'string' ? d.message : '' }))
    .slice(0, 50);
}

/**
 * A failing response → an Error carrying `.code`, `.status`, `.details` and (when the server said)
 * `.retryAfter` in seconds.
 *
 * @param {{status:number, headers:{get:(h:string)=>string|null}}} res
 * @param {any} body  the parsed JSON body, or null if it was not JSON
 * @param {number} [now]  injected for Retry-After dates
 */
function parseV1Error(res, body, now) {
  const status = Number(res && res.status) || 0;
  const header = (h) => { try { return res.headers.get(h); } catch { return null; } };

  // Maintenance first: the planned-downtime gate closes every endpoint, and the work the user was
  // doing must survive it rather than be treated as failed.
  if (MAINT.isMaintenance(status, body)) {
    const e = MAINT.maintenanceError(MAINT.retryAfterSeconds(header('retry-after'), now));
    e.code = 'maintenance';
    e.status = status;
    e.details = [];
    return e;
  }

  const env = body && typeof body === 'object' && body.error && typeof body.error === 'object' ? body.error : null;
  let code = env && typeof env.code === 'string' && env.code ? env.code : '';
  let details = cleanDetails(env && env.details);
  // POST /designs/{slug}/images answers 422 WITHOUT the envelope when every image failed — the body
  // is the ordinary success shape with an empty `images` and the reasons in `failures`.
  if (!code && body && Array.isArray(body.failures)) {
    code = 'invalid';
    details = cleanDetails(body.failures);
  }
  if (!code) code = statusFallbackCode(status);

  const serverMsg = env && typeof env.message === 'string' ? env.message.trim() : '';
  const msg = serverMsg
    || (details.length && details[0].message)
    || FALLBACK[code]
    || ('MakerRun request failed (HTTP ' + status + ').');
  const e = new Error(msg);
  e.code = code;
  e.status = status;
  e.details = details;
  if (code === 'rate_limited') e.retryAfter = MAINT.retryAfterSeconds(header('retry-after'), now);
  return e;
}

/** An Error with a code, for failures that never reached the server's error envelope. */
function codedError(code, message, extra) {
  const e = new Error(message);
  e.code = code;
  if (extra) Object.assign(e, extra);
  return e;
}

const apiBase = (baseUrl) => String(baseUrl || BASE).replace(/\/+$/, '') + '/api/v1';

/**
 * One v1 request. Resolves to the parsed JSON body of a 2xx; throws a coded Error otherwise.
 *
 * @param {string} method
 * @param {string} pathAndQuery  already-encoded, starting with '/'
 * @param {{token?:string, json?:object, form?:FormData, timeoutMs?:number, baseUrl?:string}} [opts]
 */
async function request(method, pathAndQuery, opts) {
  const o = opts || {};
  const headers = { accept: 'application/json' };
  if (o.token) headers.authorization = 'Bearer ' + String(o.token);
  let body;
  if (o.form) {
    // NEVER set content-type for multipart: fetch writes it, boundary included. A hand-written
    // `multipart/form-data` without the boundary is unreadable to the server.
    body = o.form;
  } else if (o.json !== undefined) {
    headers['content-type'] = 'application/json';
    body = JSON.stringify(o.json);
  }
  const timeoutMs = o.timeoutMs || (o.form ? UPLOAD_TIMEOUT_MS : READ_TIMEOUT_MS);
  let res;
  try {
    res = await fetch(apiBase(o.baseUrl) + pathAndQuery, {
      method, headers, body, signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    const name = err && err.name;
    if (name === 'TimeoutError' || name === 'AbortError') {
      throw codedError('timeout', 'MakerRun took too long to answer. Check your connection and try again.');
    }
    throw codedError('network', 'Could not reach MakerRun. Check your connection and try again.');
  }
  const data = await res.json().catch(() => null);
  if (!res.ok) throw parseV1Error(res, data, Date.now());
  if (data === null || typeof data !== 'object') {
    throw codedError('bad_response', 'MakerRun replied, but not in a shape Bed Ready recognises. Try again shortly.');
  }
  return data;
}

/**
 * Run `fn(token)` with a valid access token, retrying ONCE after a forced refresh if MakerRun says 401.
 *
 * A 401 with a token our clock still considers fresh means the session was revoked server-side (or
 * the clock is off). One forced refresh fixes the clock case; a second 401 cannot be fixed by retrying
 * and becomes code `relink` — the user has to connect the app again.
 *
 * The forced refresh goes through makerrun-account's single-flight, so two calls that 401 together
 * share one refresh and the rotated refresh token is never replayed (which would revoke the session).
 *
 * @param {string} userDataDir
 * @param {(token:string)=>Promise<any>} fn
 * @param {{account?: {getAccessToken: Function}}} [opts]  test seam for the account module
 */
async function withToken(userDataDir, fn, opts) {
  const account = (opts && opts.account) || require('./makerrun-account');
  const token = await account.getAccessToken(userDataDir).catch(authError);
  try {
    return await fn(token);
  } catch (e) {
    if (!e || e.code !== 'unauthorized') throw e;
  }
  const fresh = await account.getAccessToken(userDataDir, undefined, { force: true }).catch(authError);
  try {
    return await fn(fresh);
  } catch (e) {
    if (e && e.code === 'unauthorized') {
      throw codedError('relink', 'MakerRun no longer accepts this sign-in. Connect the app to your MakerRun account again.');
    }
    throw e;
  }
}

/** Errors from getAccessToken, given a code the UI can branch on. Never swallowed. */
function authError(e) {
  if (e && e.maintenance) { e.code = 'maintenance'; throw e; }
  if (e && !e.code) e.code = 'auth';
  throw e;
}

/** What an IPC handler returns for a thrown error: the code, never the stack. */
function toIpcError(e) {
  const out = { ok: false, error: String((e && e.message) || e || 'MakerRun request failed.') };
  if (e && e.code) out.code = String(e.code);
  if (e && Number.isFinite(e.retryAfter)) out.retryAfter = e.retryAfter;
  if (e && Array.isArray(e.details) && e.details.length) out.details = e.details;
  return out;
}

module.exports = {
  request, parseV1Error, withToken, toIpcError, codedError, apiBase,
  READ_TIMEOUT_MS, UPLOAD_TIMEOUT_MS, KNOWN_CODES,
};
