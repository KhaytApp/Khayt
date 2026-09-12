'use strict';

/**
 * Khayt Cloud client (main-process). Composes the tested lib/sync-crypto (E2E
 * encryption) + lib/cloud-backend (blob-first sync protocol) over a real HTTPS
 * transport, so main.js can expose register / push / pull / health to the
 * renderer via IPC. Node-only (uses Node crypto + fetch) — never loaded in the
 * renderer.
 *
 * The store is encrypted/decrypted HERE with a Data Encryption Key the caller
 * holds (derived from the sync passphrase via sync-crypto). The server only ever
 * sees opaque ciphertext.
 */
const sc = require('./sync-crypto');
const { createCloudBackend } = require('./cloud-backend');
const { createViewCache } = require('./cloud-view-cache');
const { validateBaseUrl } = require('./base-url.js');

/**
 * Encode one URL path segment. Every id/token/shopId below is interpolated into
 * a REST path; without this an opaque value carrying "/", "..", "?" or "#" —
 * from a synced/imported record or a crafted renderer call — could alter which
 * endpoint the request hits. encodeURIComponent is a no-op for the alphanumeric
 * ids these normally are, and neutralises the rest. (email and the billing query
 * param were already encoded; this makes the whole surface consistent.)
 */
function seg(v) { return encodeURIComponent(String(v == null ? '' : v)); }

/**
 * Validate a cloud server URL before anything is sent to it.
 *
 * The base URL is a user setting (self-hosting is supported) that arrives from
 * the renderer unchecked and is concatenated straight into fetch — and the very
 * first thing sent to it is an email and password. The printer path in this
 * codebase is carefully guarded; this one was not guarded at all.
 *
 * Plain http is allowed ONLY for loopback and RFC1918, where a shop running its
 * own server on the bench is a real case. Over the public internet it would put
 * shop credentials on the wire in clear text, so https is required there.
 *
 * Returns the normalised origin+path, or throws with a reason worth showing.
 */
function validateCloudBaseUrl(raw) {
  // THE RULE IS IN `lib/base-url.js` NOW, because the AI base URL needs the
  // same one and did not have it — it concatenated whatever was typed into a
  // fetch carrying an API key. The wording here is unchanged and asserted by
  // `test/cloud-url-guard.test.js`, which is how this lift is known to have
  // changed nothing: a shop reads these sentences.
  try {
    return validateBaseUrl(raw, { what: 'server address', secret: 'password' });
  } catch (e) {
    // One message this owns: a metadata address is specifically not a KHAYT
    // server, which the shared rule cannot know.
    if (/is not allowed$/.test(e.message)) throw new Error('That address is not a Khayt server');
    throw e;
  }
}

/**
 * How long a health probe may take before we call it dead.
 *
 * The general timeout is 30s, which is right for a sync carrying a whole shop's
 * data and badly wrong for a one-line GET: a user whose network cannot reach the
 * server sat on "Connecting…" for half a minute with nothing on screen, which
 * reads as a frozen app rather than a failure. A server that cannot answer
 * /v1/health in eight seconds is not going to sync either.
 */
const HEALTH_TIMEOUT_MS = 8000;
const DEFAULT_TIMEOUT_MS = 30000;

/**
 * Build a fetch-based transport for {baseUrl, token} matching cloud-backend's contract.
 *
 * `opts.deltaCapable` adds `X-Delta-Capable: 1`, which is how this device tells
 * the server it can fold a `base + deltas` reply. The server will not give a shop
 * a delta chain at all unless every credential that reads its store has said so —
 * absence means blob-only, because an old build sends nothing and "unknown" has to
 * fail closed. See KHAYT-CLOUD-DELTA-SYNC.md §4.
 *
 * It is off by default and set in ONE place (backendFor), from whether the delta
 * engine actually loaded — not from a version constant. A build whose `require`
 * of the engine failed cannot fold a chain, and must not claim it can; claiming
 * it wrongly is what would let a chain exist that this device then flattens.
 */
function httpTransport(baseUrl, token, opts = {}) {
  const base = validateCloudBaseUrl(baseUrl);
  const timeoutMs = Number.isFinite(opts.timeoutMs) && opts.timeoutMs > 0
    ? opts.timeoutMs : DEFAULT_TIMEOUT_MS;
  return async ({ method, path, body }) => {
    const res = await fetch(base + path, {
      method,
      // Never let a login POST be bounced to another host — the same rule the
      // printer poller already applies.
      redirect: 'manual',
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: 'Bearer ' + token } : {}),
        ...(opts.deltaCapable ? { 'x-delta-capable': '1' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (res.status >= 300 && res.status < 400) throw new Error('Server redirected the request — refusing to follow');
    let data = null;
    try { data = await res.json(); } catch { /* 204 / non-JSON */ }
    return { status: res.status, body: data };
  };
}

/**
 * GET /v1/health, with WHY it failed.
 *
 * "Server not reachable" was the only thing the app could say, and it covers
 * three different problems the user has to fix in three different places: a
 * network that swallows the request, an address that answers but is not a Khayt
 * server, and an address that is not a URL at all. Naming which one it is turns
 * a support thread into a self-service fix.
 *
 * @returns {{ok: boolean, reason: 'ok'|'timeout'|'unreachable'|'http'|'bad-url',
 *            status?: number, timeoutMs?: number, detail?: string}}
 */
async function healthDetail(baseUrl, opts = {}) {
  const timeoutMs = Number.isFinite(opts.timeoutMs) && opts.timeoutMs > 0
    ? opts.timeoutMs : HEALTH_TIMEOUT_MS;
  let call;
  try {
    call = httpTransport(baseUrl, null, { timeoutMs });
  } catch (e) {
    return { ok: false, reason: 'bad-url', detail: String((e && e.message) || e) };
  }
  try {
    const r = await call({ method: 'GET', path: '/v1/health' });
    if (r.status === 200 && r.body && r.body.ok) return { ok: true, reason: 'ok' };
    return { ok: false, reason: 'http', status: r.status };
  } catch (e) {
    // AbortSignal.timeout rejects with TimeoutError; older runtimes use AbortError.
    const name = (e && e.name) || '';
    if (name === 'TimeoutError' || name === 'AbortError') {
      return { ok: false, reason: 'timeout', timeoutMs };
    }
    return { ok: false, reason: 'unreachable', detail: String((e && e.message) || e) };
  }
}

/** GET /v1/health → boolean. Kept for callers that only need yes/no. */
async function health(baseUrl) {
  return (await healthDetail(baseUrl)).ok;
}

/** POST /v1/register → { shopId, token }. Throws with a useful message on failure. */
async function register(baseUrl, registerSecret) {
  const r = await httpTransport(baseUrl, null)({
    method: 'POST', path: '/v1/register', body: registerSecret ? { registerSecret } : {},
  });
  if (r.status !== 200 || !r.body || !r.body.shopId) {
    const detail = r.body && r.body.error ? `: ${r.body.error}` : '';
    throw new Error(`register failed (HTTP ${r.status})${detail}`);
  }
  return { shopId: r.body.shopId, token: r.body.token };
}

/** POST /v1/signup → { accountId, shopId, token }. Creates an account + its shop. */
async function signup(baseUrl, { email, password, registerSecret } = {}) {
  const body = { email, password };
  if (registerSecret) body.registerSecret = registerSecret;
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/signup', body });
  if (r.status !== 200 || !r.body || !r.body.shopId) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(detail);
  }
  return {
    accountId: r.body.accountId, shopId: r.body.shopId, token: r.body.token,
    // BOTH email facts, because they mean different things and the caller has to
    // tell them apart. emailFailed is "we tried and the provider refused";
    // emailConfigured:false is "this server has no mail set up at all". Only
    // emailFailed was carried, so a self-hosted server with no SMTP reported
    // neither — and the app opened a dialog asking for a code that was never
    // sent and could never arrive. The reset flow already distinguishes them;
    // sign-up could not, because the field was dropped here.
    emailConfigured: r.body.emailConfigured !== false,
    emailFailed: !!(r.body && r.body.emailFailed),
  };
}

/**
 * POST /v1/login → { shopId, token, keyset|null, role, verified }. null on 401.
 *
 * `verified` has to be carried through. The server sends it, this parser used
 * to drop it, and settings.js writes `verified: !!lr.verified` — so every login
 * recorded the account as UNVERIFIED and the cloud panel showed "⚠ Email not
 * verified" to shops that had verified months ago. Chasing that warning leads
 * to the Verify button, which asks the server, is told alreadyVerified, and
 * silently corrects the flag — so the bug looked like it fixed itself and came
 * back on the next device. A field the server sends and the client discards
 * reads as a server bug from the outside; it was never on the wire.
 */
async function login(baseUrl, { email, password } = {}) {
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/login', body: { email, password } });
  if (r.status === 401) return null;
  if (r.status !== 200 || !r.body || !r.body.shopId) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(detail);
  }
  return {
    shopId: r.body.shopId, token: r.body.token, keyset: r.body.keyset || null,
    role: r.body.role || 'owner',
    // Absent means unknown, and unknown must not read as verified: an older
    // server that does not send it should leave the shop with the banner and a
    // button, not with a silent claim it is verified.
    verified: r.body.verified === true,
  };
}

/** POST /v1/accept-invite → { shopId, token, role, keyset|null }. Joins a team via invite code. */
async function acceptInvite(baseUrl, { email, password, code } = {}) {
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/accept-invite', body: { email, password, code } });
  if (r.status !== 200 || !r.body || !r.body.shopId) {
    throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  }
  return { accountId: r.body.accountId, shopId: r.body.shopId, token: r.body.token, role: r.body.role || 'operator', keyset: r.body.keyset || null };
}

/** Invite a team member by email + role. */
async function inviteMember(baseUrl, shopId, token, email, role) {
  const r = await httpTransport(baseUrl, token)({ method: 'POST', path: `/v1/shops/${seg(shopId)}/members/invite`, body: { email, role } });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true, emailConfigured: !!(r.body && r.body.emailConfigured) };
}

/** List shop members (email, role, verified). */
async function listMembers(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/members` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return (r.body && r.body.members) || [];
}

/**
 * The shop's own name for its public URLs, or null if it has never claimed one.
 *
 * The shop id keeps working either way — a name is an extra address, not a
 * replacement — so nothing already published breaks by setting one.
 */
async function getShopSlug(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/slug` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { slug: (r.body && r.body.slug) || null, graceDays: (r.body && r.body.graceDays) || 90 };
}

/** Claim or change it. The server validates; its message is the one worth showing. */
async function setShopSlug(baseUrl, shopId, token, slug) {
  const r = await httpTransport(baseUrl, token)({ method: 'PUT', path: `/v1/shops/${seg(shopId)}/slug`, body: { slug } });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { slug: r.body && r.body.slug };
}

/** Remove a member by email (owner can't be removed). */
async function removeMember(baseUrl, shopId, token, email) {
  const r = await httpTransport(baseUrl, token)({ method: 'DELETE', path: `/v1/shops/${seg(shopId)}/members/${encodeURIComponent(email)}` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true };
}

/** Publish (or replace) the public storefront catalog. payload=null unpublishes. */
async function putCatalog(baseUrl, shopId, token, payload) {
  const r = await httpTransport(baseUrl, token)({ method: 'PUT', path: `/v1/shops/${seg(shopId)}/catalog`, body: { catalog: payload } });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true, published: !!(r.body && r.body.published) };
}

/** GET the public storefront catalog → { catalog, updatedAt } | null (404). */
async function getCatalog(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/catalog` });
  if (r.status === 404) return null;
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { catalog: (r.body && r.body.catalog) || null, updatedAt: r.body && r.body.updatedAt };
}

/** GET the public review summary → { count, avg, recent } | null. */
async function getReviewSummary(baseUrl, shopId) {
  const r = await httpTransport(baseUrl, null)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/reviews` });
  if (r.status !== 200) return null;
  return r.body || null;
}

/**
 * GET /v1/shops/{id}/reviews/all → the shop's own reviews, with ids.
 *
 * The public summary returns at most ten recent COMMENTS and no ids, so a shop
 * could see an average fall and not what was dragging it down. Owner-only on the
 * server; the token is what proves it.
 */
async function listReviews(baseUrl, shopId, token, limit = 50) {
  const r = await httpTransport(baseUrl, token)({
    method: 'GET', path: `/v1/shops/${seg(shopId)}/reviews/all?limit=${encodeURIComponent(limit)}`,
  });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return (r.body && r.body.reviews) || [];
}

/** DELETE /v1/shops/{id}/reviews/{reviewId}. Owner-only on the server. */
async function deleteReview(baseUrl, shopId, token, reviewId) {
  const r = await httpTransport(baseUrl, token)({
    method: 'DELETE', path: `/v1/shops/${seg(shopId)}/reviews/${seg(String(reviewId))}`,
  });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return true;
}

/** POST /v1/request-reset → { ok, emailConfigured }. Always resolves (no leak). */
async function requestReset(baseUrl, { email } = {}) {
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/request-reset', body: { email } });
  if (r.status !== 200) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(detail);
  }
  return {
    ok: true,
    emailConfigured: !!(r.body && r.body.emailConfigured),
    emailFailed: !!(r.body && r.body.emailFailed),
  };
}

/** POST /v1/reset-password → { ok } | throws with the server message (e.g. bad code). */
async function resetPassword(baseUrl, { email, code, newPassword } = {}) {
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/reset-password', body: { email, code, newPassword } });
  if (r.status !== 200) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(detail);
  }
  return { ok: true };
}

/** POST /v1/request-verify → { ok, alreadyVerified, emailConfigured }. */
async function requestVerify(baseUrl, { email } = {}) {
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/request-verify', body: { email } });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  // `sender` is passed through when the server names the address it sends from,
  // so the modal can tell the user what to look for in a spam folder. Servers
  // that do not report it simply leave the hint generic.
  // `emailFailed` is the server saying it tried and the provider turned the
  // message away — NOT "was it sent", which /v1/request-reset deliberately will
  // not answer for an address it has not confirmed exists. Absent on an older
  // server, which reads as false: no worse than before it was reported.
  return {
    ok: true,
    alreadyVerified: !!(r.body && r.body.alreadyVerified),
    emailConfigured: !!(r.body && r.body.emailConfigured),
    emailFailed: !!(r.body && r.body.emailFailed),
    sender: (r.body && (r.body.sender || r.body.fromEmail)) || null,
  };
}

/** POST /v1/verify-email → { ok, verified } | throws (bad/expired code). */
async function verifyEmail(baseUrl, { email, code } = {}) {
  const r = await httpTransport(baseUrl, null)({ method: 'POST', path: '/v1/verify-email', body: { email, code } });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true, verified: true };
}

/** PUT the (encrypted) keyset for a shop. */
async function putKeyset(baseUrl, shopId, token, keyset) {
  const r = await httpTransport(baseUrl, token)({
    method: 'PUT', path: `/v1/shops/${seg(shopId)}/keyset`, body: { keyset },
  });
  if (r.status !== 200) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`save keyset failed: ${detail}`);
  }
  return { ok: true };
}

/** GET the (encrypted) keyset for a shop → keyset | null (204). */
async function getKeyset(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/keyset` });
  if (r.status === 204) return null;
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`get keyset failed: ${detail}`);
  }
  return r.body.keyset || null;
}

/* ── Organisations (multi-shop) ───────────────────────────────────────────────
 *
 * See docs/KHAYT-3.0-ORG-DATA-KEY.md. Every call authenticates AS A SHOP, using
 * that shop's own token, and reaches the org from there — so no token for another
 * shop ever leaves this device. What travels is the org key already wrapped by
 * the org passphrase and an org recovery key; the server cannot open it.
 */

/** The org this shop belongs to → { orgId, keyset } | null (204). */
async function getOrg(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/org` });
  if (r.status === 204) return null;
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`get organisation failed: ${detail}`);
  }
  return { orgId: r.body.orgId, keyset: r.body.keyset || null };
}

/** Create the org, or re-wrap its key after an org passphrase change. */
async function putOrg(baseUrl, shopId, token, orgId, keyset) {
  const r = await httpTransport(baseUrl, token)({
    method: 'PUT', path: `/v1/shops/${seg(shopId)}/org`, body: { orgId, keyset },
  });
  if (r.status !== 200) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`save organisation failed: ${detail}`);
  }
  return { ok: true, orgId: r.body && r.body.orgId };
}

/** Leave the org. Membership only — this shop's own keyset and store are untouched. */
async function leaveOrgRemote(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'DELETE', path: `/v1/shops/${seg(shopId)}/org` });
  if (r.status !== 200) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`leave organisation failed: ${detail}`);
  }
  return { ok: true };
}

/** Mint a join code for another branch → { code, expiresInSeconds }. */
async function createOrgInvite(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'POST', path: `/v1/shops/${seg(shopId)}/org/invite`, body: {} });
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`create join code failed: ${detail}`);
  }
  return { code: r.body.code, expiresInSeconds: r.body.expiresInSeconds };
}

/** Redeem a join code → { orgId, keyset }. This shop authenticates as itself. */
async function joinOrgRemote(baseUrl, shopId, token, code) {
  const r = await httpTransport(baseUrl, token)({
    method: 'POST', path: `/v1/shops/${seg(shopId)}/org/join`, body: { code },
  });
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`join organisation failed: ${detail}`);
  }
  return { orgId: r.body.orgId, keyset: r.body.keyset || null };
}

/** Every member branch's wrapped keyset → [{ shopId, keyset }]. Owner only.
 *  Opaque without the org passphrase, which never reaches the server. */
async function getOrgKeysets(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/org/keysets` });
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`read branch keys failed: ${detail}`);
  }
  return Array.isArray(r.body.keysets) ? r.body.keysets : [];
}

/**
 * One branch's encrypted store → { rev, ciphertext } | null (204).
 *
 * Reached as THIS shop, not as the branch: a token is bound to one shop, so the
 * ordinary /v1/shops/{branch}/store returns 401 for a sibling. The server checks
 * the branch is in the same org and hands back ciphertext this device then opens
 * with the org key.
 */
async function getBranchStore(baseUrl, shopId, token, branchId) {
  // Capability is announced here for the same reason it is on the sync backend:
  // this route reads a store, so the server records what this device does with
  // one. Omitting it would mark HQ blob-only and — because the gate spans org
  // siblings — quietly deny every branch in the org a delta chain.
  const r = await httpTransport(baseUrl, token, { deltaCapable: !!deltaEngine })({
    method: 'GET', path: `/v1/shops/${seg(shopId)}/org/branches/${seg(branchId)}/store`,
  });
  if (r.status === 204) return null;
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`read branch failed: ${detail}`);
  }
  return { rev: r.body.rev, ciphertext: r.body.ciphertext, deltas: r.body.deltas };
}

/**
 * Open a branch blob from getBranchStore with the org key: decrypt the base, then
 * fold the chain that sits on it.
 *
 * Dropping `deltas` here would not corrupt anything — this route is read-only —
 * but it would show the org roll-up a branch store missing its newest edits, with
 * nothing anywhere saying so. That is the same silent lie the whole delta design
 * is arranged to prevent, just in a quieter place, so this refuses rather than
 * guesses when it cannot fold.
 */
function decryptBranchStore(blob, dek) {
  const store = sc.decryptStore(blob.ciphertext, dek); // throws on wrong key / tamper
  const deltas = blob && blob.deltas;
  if (!Array.isArray(deltas) || !deltas.length) return store;
  if (!deltaEngine || typeof deltaEngine.applyDeltas !== 'function') {
    throw new Error('branch returned deltas but no sync engine is available to fold them');
  }
  for (const d of deltas) {
    deltaEngine.applyDeltas(store, sc.decryptStore(d.ciphertext, dek), { appendOnly: [] });
  }
  return store;
}

/** The branches in this shop's org, by shop id. Names live in each branch's own
 *  encrypted store, which the server cannot read. */
async function listOrgMembers(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/org/members` });
  if (r.status !== 200 || !r.body) {
    const detail = r.body && r.body.error ? r.body.error : `HTTP ${r.status}`;
    throw new Error(`list branches failed: ${detail}`);
  }
  return Array.isArray(r.body.members) ? r.body.members : [];
}

/** Publish an owner-curated (plaintext) portal item under a public token.
 *  customerEmail (optional) links the item to a customer's portal account. */
async function publishPortal(baseUrl, shopId, token, pubToken, kind, payload, customerEmail) {
  const body = { kind, payload };
  if (customerEmail) body.customerEmail = customerEmail;
  const r = await httpTransport(baseUrl, token)({
    method: 'PUT', path: `/v1/shops/${seg(shopId)}/published/${seg(pubToken)}`, body,
  });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true };
}

/** Remove a published portal item. */
async function unpublishPortal(baseUrl, shopId, token, pubToken) {
  const r = await httpTransport(baseUrl, token)({ method: 'DELETE', path: `/v1/shops/${seg(shopId)}/published/${seg(pubToken)}` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true };
}

/** List this shop's published items (+ any customer actions). */
async function listPublished(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/published` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return (r.body && r.body.items) || [];
}

/** List inbound customer order requests for this shop. */
async function listIntake(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/intake` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return (r.body && r.body.items) || [];
}

/** Delete an inbound request (after importing it). */
async function deleteIntake(baseUrl, shopId, token, id) {
  const r = await httpTransport(baseUrl, token)({ method: 'DELETE', path: `/v1/shops/${seg(shopId)}/intake/${seg(id)}` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return { ok: true };
}

/**
 * GET a portal message thread for the owner's own screen (token = the order's
 * tracking token).
 *
 * This used to read the customer's own public route, `GET /v1/p/{token}/messages`,
 * with no credentials at all — which meant that route had to stay open to anyone
 * holding the portal link, because closing it would blank the owner's Messages
 * button. khayt-cloud #10 added the owner-authenticated equivalent below: same
 * thread, Bearer shop token, 404 if the token is not this shop's. Reading it here
 * is what lets the public route be gated on the customer's portal session, the
 * way its POST half already is.
 *
 * There is NO fallback to the public route any more. There was one, for the gap
 * between a desktop update and a cloud deploy, and it is gone because it undid
 * the point: a 404 meaning "not this shop's token" fell through to the public
 * read and returned the thread anyway. The desktop now has no path to
 * /v1/p/{token}/messages at all, which is what lets that route be closed.
 *
 * The Server URL is user-editable, so this can still meet a khayt-cloud too old
 * to have the route. That answers 404, and 404 is now reported — but reported as
 * the thing it actually is, because "HTTP 404" on a message thread reads as
 * "this order is gone" and sends someone looking in the wrong place entirely.
 */
async function portalMessages(baseUrl, shopId, token, authToken) {
  const r = await httpTransport(baseUrl, authToken)({
    method: 'GET', path: `/v1/shops/${seg(shopId)}/published/${seg(token)}/messages`,
  });
  if (r.status === 200) return (r.body && r.body.messages) || [];
  if (r.status === 404) {
    throw new Error('Could not read this conversation. Either the order is not on this '
      + 'Khayt Cloud server, or the server is older than this version of Khayt — update it and try again.');
  }
  throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
}

/** Owner reply to a portal thread (authenticated). */
async function portalReply(baseUrl, shopId, token, authToken, text) {
  const r = await httpTransport(baseUrl, authToken)({ method: 'POST', path: `/v1/shops/${seg(shopId)}/published/${seg(token)}/message`, body: { text } });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return r.body || {};
}

/** GET storefront analytics (views/carts/orders + top items) for this shop. */
async function storefrontStats(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/shops/${seg(shopId)}/sfstats` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return r.body || { views: 0, carts: 0, orders: 0, items: [] };
}

/**
 * PUT /v1/shops/{id}/lead-time — publish when this shop could have a new order
 * ready, for a storefront to quote from. `null` withdraws it.
 *
 * Withdrawal matters as much as publishing: a shop that turns the setting off
 * must stop answering, not leave a frozen date on a public URL for ever.
 */
async function putLeadTime(baseUrl, shopId, token, leadTime) {
  const r = await httpTransport(baseUrl, token)({
    method: 'PUT', path: `/v1/shops/${seg(shopId)}/lead-time`, body: { leadTime: leadTime || null },
  });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return r.body || { ok: true };
}

/** GET /v1/billing/me → the shop's plan + limits (or { billingEnabled:false }). */
async function billingMe(baseUrl, shopId, token) {
  const r = await httpTransport(baseUrl, token)({ method: 'GET', path: `/v1/billing/me?shopId=${encodeURIComponent(shopId)}` });
  if (r.status !== 200) throw new Error((r.body && r.body.error) || `HTTP ${r.status}`);
  return r.body || {};
}

/** A cloud-backend bound to {baseUrl, shopId, token, dek}. */
/**
 * The Phase 0 delta engine, loaded into the MAIN process.
 *
 * It lives under renderer/ for historical reasons but is pure logic with no DOM
 * — `lib/lan-server.js` already reaches across the same way for
 * calculator-cost.js. It is needed here so a pull can FOLD a `base + deltas`
 * response; without it the backend refuses such a response outright, which is
 * safe but means the shop simply cannot read a delta store.
 *
 * Loading it here does not interact with the renderer's own copy, because the
 * main process is a different realm and gets its own module instance.
 *
 * This used to say "and applyDeltas touches no module-level index", which is
 * FALSE — `applyDeltas` calls `noteSynced`, which writes `syncedRev` into the
 * index. The conclusion above still holds, for the realm reason rather than
 * the purity one, and the difference matters to any host with a SINGLE
 * JavaScript context: `test/cloud-inbox.test.js` compared two implementations
 * in one process and got a spurious difference out of exactly this.
 */
let deltaEngine = null;
try { deltaEngine = require('../lib/sync.js'); } catch (e) { deltaEngine = null; }

/**
 * @param {object} [opts]
 * @param {string} [opts.cacheDir]        where to keep the retained server view across
 *                                        restarts. Omit and every launch is cold, exactly
 *                                        as before — the cache is an optimisation.
 * @param {function} [opts.getLocalSnapshot]  the local store, for the safety check in
 *                                        cloud-backend's `viewSafeForLocal`. Without it a
 *                                        cached view is never adopted, by design.
 */
function backendFor(baseUrl, shopId, token, dek, opts = {}) {
  const { cacheDir, getLocalSnapshot } = opts;
  let viewCache = null;
  if (cacheDir) {
    // A cache that cannot even be constructed must not stop a shop syncing.
    try {
      viewCache = createViewCache({ dir: cacheDir, shopId, crypto: sc, getDek: () => dek });
    } catch (e) { viewCache = null; }
  }
  return createCloudBackend({
    // Announce delta capability from the SAME fact the backend folds with. If the
    // engine failed to load, this backend refuses a `base + deltas` reply — so it
    // must not tell the server it can read one, or the server may hand a chain to
    // a shop this device will then be unable to sync (and, worse, would flatten
    // on a full push).
    transport: httpTransport(baseUrl, token, { deltaCapable: !!deltaEngine }),
    crypto: sc,
    shopId,
    getDek: () => dek,
    sync: deltaEngine,
    viewCache,
    getLocalSnapshot,
  });
}

module.exports = {
  validateCloudBaseUrl,
  httpTransport,
  health,
  register,
  signup,
  login,
  acceptInvite,
  inviteMember,
  listMembers,
  getShopSlug,
  setShopSlug,
  removeMember,
  putCatalog,
  putLeadTime,
  getCatalog,
  getReviewSummary,
  listReviews,
  deleteReview,
  requestReset,
  resetPassword,
  requestVerify,
  verifyEmail,
  healthDetail,
  HEALTH_TIMEOUT_MS,
  publishPortal,
  unpublishPortal,
  listPublished,
  listIntake,
  deleteIntake,
  storefrontStats,
  portalMessages,
  portalReply,
  billingMe,
  putKeyset,
  getKeyset,
  backendFor,
  // re-exported crypto helpers (keyset creation + unlock) for the IPC layer
  createKeyset: sc.createKeyset,
  unlockWithPassphrase: sc.unlockWithPassphrase,
  unlockWithRecovery: sc.unlockWithRecovery,
  changePassphrase: sc.changePassphrase,
  decryptStore: sc.decryptStore,
  // organisations — HTTP
  getOrg,
  putOrg,
  leaveOrgRemote,
  createOrgInvite,
  joinOrgRemote,
  listOrgMembers,
  getOrgKeysets,
  getBranchStore,
  decryptBranchStore,
  // organisations — crypto (docs/KHAYT-3.0-ORG-DATA-KEY.md)
  createOrgKeyset: sc.createOrgKeyset,
  unlockOrgWithPassphrase: sc.unlockOrgWithPassphrase,
  unlockOrgWithRecovery: sc.unlockOrgWithRecovery,
  changeOrgPassphrase: sc.changeOrgPassphrase,
  joinOrg: sc.joinOrg,
  leaveOrg: sc.leaveOrg,
  unlockWithOrg: sc.unlockWithOrg,
};
