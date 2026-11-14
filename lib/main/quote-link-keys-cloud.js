'use strict';
/**
 * Pay link v2: this computer's key and Khayt Cloud (khayt-cloud #215,
 * docs/api-contract.md "Quote pay link keys"). Main process only.
 *
 * Every call takes `call`, the transport `lib/cloud-client.js httpTransport`
 * returns (`({ method, path, body }) => { status, body }`), so tests hand in a
 * fake Cloud. Only public halves and endorsements go to Cloud; a body never
 * carries the seed (Cloud refuses `jwk.d` anyway).
 *
 *   setUp      a computer with no key makes one. If the shop has no live key
 *              it publishes it as the root; otherwise it asks to be approved
 *              (a pending-device request) and signs nothing until then.
 *   approve    a trusted computer vouches for a waiting one (PUT with its
 *              endorsement), or declines it.
 *   rotate     this computer replaces its own key: the old key endorses the
 *              new one, `expect.retires` makes it compare-and-swap, and only
 *              after Cloud answers 200 is the old seed dropped (design §2).
 *   revoke /   owner only, in two steps: no code sends the owner an emailed
 *   reset      code; with the code, it is done.
 *
 * Signing rule (design §2): a computer signs only while Cloud lists its key
 * as `current` — `canSign(chain, record)`.
 */
const Key = require('./quote-link-key.js');

const seg = (v) => encodeURIComponent(String(v == null ? '' : v));
const keysPath = (shopId) => `/v1/shops/${seg(shopId)}/quote-keys`;
const jwkOf = (rec) => ({ kty: 'OKP', crv: 'Ed25519', x: rec.x, kid: rec.kid });
const label = (device) => String(device == null ? '' : device).slice(0, 80);
const nowSec = (now) => Math.floor((now == null ? Date.now() : now) / 1000);

/** What Cloud says about one key: 'current' | 'retired' | 'revoked' | 'unpublished'. */
function statusIn(chain, kid) {
  const k = chain && Array.isArray(chain.keys) ? chain.keys.find((x) => x && x.kid === kid) : null;
  return k ? String(k.status || 'unpublished') : 'unpublished';
}

/** May this computer sign right now? Only with a key Cloud lists as `current`. */
const canSign = (chain, record) => !!(record && Key.seedOk(record.seed) && statusIn(chain, record.kid) === 'current');

/** Does the shop have any key that is not revoked (so a new key needs an endorsement)? */
const hasLiveKey = (chain) => !!(chain && Array.isArray(chain.keys) && chain.keys.some((k) => k && k.status !== 'revoked'));

async function getChain(call, shopId) {
  const r = await call({ method: 'GET', path: keysPath(shopId) });
  if (r.status === 200 && r.body && Array.isArray(r.body.keys)) return { ok: true, chain: r.body };
  return { ok: false, status: r.status, error: (r.body && (r.body.reason || r.body.error)) || 'http' };
}

/**
 * A computer with no key, or a fresh start: make one and either publish it
 * as the root or ask to be approved. Returns `{ ok, record, state }`, where
 * state is 'current' (published as root) or 'pending' (waiting for approval).
 * `record` is to be stored at settings.quoteLinkKey by the caller.
 */
async function setUp(call, shopId, { device, now } = {}) {
  const fresh = Key.generate(now);
  const record = { ...fresh, device: label(device) };
  const got = await getChain(call, shopId);
  if (!got.ok) return { ok: false, error: got.error, status: got.status };
  if (!hasLiveKey(got.chain)) {
    const r = await call({ method: 'PUT', path: keysPath(shopId), body: { jwk: jwkOf(record), device: record.device } });
    if (r.status === 200) return { ok: true, record: { ...record, status: 'current' }, state: 'current', chain: r.body && r.body.chain };
    if (r.status !== 409 || !r.body || r.body.reason !== 'endorsement-required') return fail(r);
    // Another computer published a root first: ask to be approved instead.
  }
  const p = await call({ method: 'POST', path: keysPath(shopId) + '/pending', body: { jwk: jwkOf(record), device: record.device } });
  if (p.status === 200 && p.body && p.body.published) return { ok: true, record: { ...record, status: 'current' }, state: 'current' };
  if (p.status === 200) return { ok: true, record: { ...record, status: 'pending', requestedAt: new Date(now == null ? Date.now() : now).toISOString() }, state: 'pending' };
  return fail(p);
}

function fail(r) {
  const reason = (r.body && (r.body.reason || r.body.error)) || 'http';
  return { ok: false, status: r.status, error: reason };
}

/** The computers waiting to be approved (owner or manager). */
async function listPending(call, shopId) {
  const r = await call({ method: 'GET', path: keysPath(shopId) + '/pending' });
  if (r.status === 200 && r.body && Array.isArray(r.body.pending)) return { ok: true, pending: r.body.pending };
  return fail(r);
}

/**
 * This computer vouches for a waiting one. `waiting` is `{ kid, x, device }`
 * from listPending; its kid must be the thumbprint of its x, or nothing is sent.
 */
async function approve(call, shopId, record, waiting, { now } = {}) {
  if (!record || !Key.seedOk(record.seed)) return { ok: false, error: 'no-key' };
  if (!waiting || Key.kidOf(waiting.x) !== waiting.kid) return { ok: false, error: 'kid-mismatch' };
  const endorsement = Key.endorse({ iss: String(shopId), new_kid: waiting.kid, x: waiting.x, iat: nowSec(now) }, record.seed);
  if (!endorsement) return { ok: false, error: 'endorse-failed' };
  const r = await call({ method: 'PUT', path: keysPath(shopId), body: {
    jwk: { kty: 'OKP', crv: 'Ed25519', x: waiting.x, kid: waiting.kid }, device: label(waiting.device),
    endorsement, expect: { endorser: record.kid },
  } });
  return r.status === 200 ? { ok: true, chain: r.body && r.body.chain } : fail(r);
}

/** Turn a waiting computer away. */
async function decline(call, shopId, kid) {
  const r = await call({ method: 'DELETE', path: `${keysPath(shopId)}/pending/${seg(kid)}` });
  return r.status === 200 ? { ok: true } : fail(r);
}

/**
 * Replace this computer's key. The old key endorses the new one; Cloud
 * retires the old only if it is still current (compare-and-swap). On 200 the
 * caller stores the returned record, which no longer holds the old seed.
 */
async function rotate(call, shopId, record, { now } = {}) {
  if (!record || !Key.seedOk(record.seed)) return { ok: false, error: 'no-key' };
  const next = Key.generate(now);
  const endorsement = Key.endorse({ iss: String(shopId), new_kid: next.kid, x: next.x, iat: nowSec(now) }, record.seed);
  if (!endorsement) return { ok: false, error: 'endorse-failed' };
  const r = await call({ method: 'PUT', path: keysPath(shopId), body: {
    jwk: jwkOf(next), device: label(record.device), endorsement,
    expect: { endorser: record.kid, retires: record.kid },
  } });
  if (r.status !== 200) return fail(r);
  // Design §2: once the rotation is accepted, the retired private key is deleted.
  return { ok: true, record: { ...next, device: record.device, status: 'current', replaced: record.kid }, chain: r.body && r.body.chain };
}

/**
 * Revoke a key (owner only). Without `code` Cloud emails the owner a code
 * (`{ ok, codeSent }`); call again with it to revoke.
 */
async function revoke(call, shopId, kid, code) {
  const r = await call({ method: 'POST', path: `${keysPath(shopId)}/${seg(kid)}/revoke`, body: code ? { code: String(code) } : {} });
  if (r.status === 202) return { ok: true, codeSent: true };
  return r.status === 200 ? { ok: true, chain: r.body && r.body.chain, already: !!(r.body && r.body.already) } : fail(r);
}

/** Reset every key (owner only, lost keys). Same two steps as revoke. Every store must re-pin afterwards. */
async function reset(call, shopId, code) {
  const r = await call({ method: 'POST', path: `${keysPath(shopId)}/reset`, body: code ? { code: String(code) } : {} });
  if (r.status === 202) return { ok: true, codeSent: true };
  return r.status === 200 ? { ok: true, chain: r.body && r.body.chain } : fail(r);
}

module.exports = { statusIn, canSign, hasLiveKey, getChain, setUp, listPending, approve, decline, rotate, revoke, reset };
