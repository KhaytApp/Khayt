'use strict';
/**
 * A small fake of Khayt Cloud's quote-keys endpoints (khayt-cloud #215,
 * docs/api-contract.md "Quote pay link keys"): keys, pending requests, CAS on
 * `expect.retires`, endorsement checks and the two-step revoke (code TESTCODE).
 * Sample shop only; never the real Cloud.
 */
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const K = require('../../lib/main/quote-link-key.js');

const SHOP = 'shop_0000example';
const unb64 = (s) => Buffer.from(s, 'base64url');

/** A small fake of #215: keys, pending requests, CAS on retires, endorsement checks. */
function fakeCloud() {
  const keys = []; const pending = []; const calls = [];
  const verify = (jws, endorserX, kid, x) => {
    const [h, p, s] = jws.split('.');
    const head = JSON.parse(unb64(h)); const body = JSON.parse(unb64(p));
    const pub = crypto.createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: endorserX }, format: 'jwk' });
    return head.typ === 'khayt-key-endorsement+jwt' && body.iss === SHOP && body.new_kid === kid && body.x === x
      && crypto.verify(null, Buffer.from(h + '.' + p), pub, unb64(s));
  };
  const call = async ({ method, path, body }) => {
    calls.push({ method, path, body });
    assert.ok(!JSON.stringify(body || {}).includes('"d"'), 'no private part is ever sent');
    const base = `/v1/shops/${SHOP}/quote-keys`;
    if (method === 'GET' && path === base) return { status: 200, body: { shop: SHOP, epoch: 1, keys } };
    if (method === 'GET' && path === base + '/pending') return { status: 200, body: { pending } };
    if (method === 'POST' && path === base + '/pending') { pending.push({ kid: body.jwk.kid, x: body.jwk.x, device: body.device }); return { status: 200, body: { ok: true, kid: body.jwk.kid } }; }
    if (method === 'DELETE' && path.startsWith(base + '/pending/')) { const i = pending.findIndex((q) => q.kid === decodeURIComponent(path.split('/').pop())); if (i < 0) return { status: 404, body: {} }; pending.splice(i, 1); return { status: 200, body: { ok: true } }; }
    if (method === 'PUT' && path === base) {
      const { jwk, endorsement, expect } = body;
      if (K.kidOf(jwk.x) !== jwk.kid) return { status: 400, body: { reason: 'kid' } };
      const live = keys.filter((k) => k.status !== 'revoked');
      if (!endorsement) {
        if (live.length) return { status: 409, body: { reason: 'endorsement-required' } };
        keys.push({ kid: jwk.kid, x: jwk.x, status: 'current', root: true }); return { status: 200, body: { ok: true, kid: jwk.kid, chain: { keys } } };
      }
      const by = keys.find((k) => k.kid === JSON.parse(unb64(endorsement.split('.')[0])).kid);
      if (!by) return { status: 409, body: { reason: 'unknown-endorser' } };
      if (by.status === 'revoked') return { status: 409, body: { reason: 'endorser-revoked' } };
      if (!verify(endorsement, by.x, jwk.kid, jwk.x)) return { status: 400, body: { reason: 'bad_signature' } };
      if (expect && expect.retires) {
        const old = keys.find((k) => k.kid === expect.retires);
        if (!old || old.status !== 'current') return { status: 409, body: { reason: 'retires-not-current' } };
        old.status = 'retired';
      }
      keys.push({ kid: jwk.kid, x: jwk.x, status: 'current' });
      const i = pending.findIndex((q) => q.kid === jwk.kid); if (i >= 0) pending.splice(i, 1);
      return { status: 200, body: { ok: true, kid: jwk.kid, chain: { keys } } };
    }
    if (method === 'POST' && /\/revoke$/.test(path)) {
      if (!body.code) return { status: 202, body: { ok: true, codeSent: true } };
      if (body.code !== 'TESTCODE') return { status: 401, body: { reason: 'bad-code' } };
      const k = keys.find((x) => x.kid === decodeURIComponent(path.split('/').slice(-2)[0])); k.status = 'revoked';
      return { status: 200, body: { ok: true, chain: { keys } } };
    }
    return { status: 404, body: {} };
  };
  return { call, keys, pending, calls };
}

module.exports = { fakeCloud, SHOP };
