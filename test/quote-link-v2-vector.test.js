/**
 * contracts/quote-link-v2.vector.json: the shared test vector for quote pay
 * links signed with a per-shop Ed25519 key (design approved 14 Nov 2026,
 * ~/Khayt-proposals/pay-link-open-signing.md). The desktop, the Mac, Khayt
 * Cloud and every store connector check themselves against this file.
 *
 * This test re-derives every value from the seeds, so the file cannot drift
 * from what it claims, and carries a minimal reference verifier in the order a
 * connector must follow: alg, kid, revoked, trusted (pinned or endorsed through
 * non-revoked keys of this shop), signature, a retired key's iat, iss, aud.
 * Nothing in the payload is read before the signature has verified.
 */
'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const V = require('../contracts/quote-link-v2.vector.json');

const b64 = (b) => Buffer.from(b).toString('base64url');
const unb64 = (s) => Buffer.from(s, 'base64url');
const PKCS8_ED25519 = Buffer.from('302e020100300506032b657004220420', 'hex');
const privFromSeed = (seed) => crypto.createPrivateKey({ key: Buffer.concat([PKCS8_ED25519, seed]), format: 'der', type: 'pkcs8' });
const pubFromX = (x) => crypto.createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x }, format: 'jwk' });
const thumbprint = (x) => b64(crypto.createHash('sha256').update(`{"crv":"Ed25519","kty":"OKP","x":"${x}"}`).digest());

/** Is `kid` trusted? Pinned, or endorsed (iss = shop, x bound by the thumbprint)
 *  by a trusted key that is not revoked. Revoked endorsers never count. */
function trusted(kid, chain, pins, shop, seen = new Set()) {
  if (seen.has(kid)) return false;
  seen.add(kid);
  const key = chain.keys.find((k) => k.kid === kid);
  if (!key || key.status === 'revoked') return false;
  if (pins.includes(kid)) return true;
  for (const e of key.endorsements || []) {
    const by = chain.keys.find((k) => k.kid === e.by);
    if (!by || by.status === 'revoked') continue;
    const [h, p, sig] = e.jws.split('.');
    let head, body;
    try { head = JSON.parse(unb64(h)); body = JSON.parse(unb64(p)); } catch { continue; }
    if (head.alg !== 'EdDSA' || head.typ !== 'khayt-key-endorsement+jwt' || head.kid !== by.kid) continue;
    if (!crypto.verify(null, Buffer.from(`${h}.${p}`), pubFromX(by.x), unb64(sig))) continue;
    if (body.iss !== shop || body.new_kid !== kid || body.x !== key.x || thumbprint(body.x) !== kid) continue;
    if (trusted(by.kid, chain, pins, shop, seen)) return true;
  }
  return false;
}

/** The reference verifier. Returns { ok, payload } or { ok: false, reason }. */
function verifyLink(token, chain, store) {
  const parts = String(token).split('.');
  if (parts.length !== 3) return { ok: false, reason: 'malformed' };
  let header;
  try { header = JSON.parse(unb64(parts[0]).toString('utf8')); } catch { return { ok: false, reason: 'malformed' }; }
  if (header.alg !== 'EdDSA') return { ok: false, reason: 'bad_alg' };
  const key = chain.keys.find((k) => k.kid === header.kid);
  if (!key || key.crv !== 'Ed25519' || key.kty !== 'OKP') return { ok: false, reason: 'unknown_kid' };
  if (key.status === 'revoked') return { ok: false, reason: 'revoked_key' };
  if (!trusted(key.kid, chain, store.pinned_roots, store.connected_shop)) return { ok: false, reason: 'untrusted_key' };
  const good = crypto.verify(null, Buffer.from(`${parts[0]}.${parts[1]}`), pubFromX(key.x), unb64(parts[2]));
  if (!good) return { ok: false, reason: 'bad_signature' };
  const payload = JSON.parse(unb64(parts[1]).toString('utf8'));
  if (key.status === 'retired' && !(payload.iat < Date.parse(key.retired) / 1000)) return { ok: false, reason: 'retired_key' };
  if (payload.iss !== store.connected_shop) return { ok: false, reason: 'wrong_iss' };
  if (payload.aud !== store.STORE_ORIGIN) return { ok: false, reason: 'wrong_aud' };
  if (payload.v !== 2) return { ok: false, reason: 'invalid_claims' };
  return { ok: true, payload };
}

const seedOf = (k) => unb64(k.private_seed_b64url);
const signWith = (k, signingInput) => b64(crypto.sign(null, Buffer.from(signingInput), privFromSeed(seedOf(k))));

test('the keys are what their seeds make, and each kid is the RFC 7638 thumbprint', () => {
  for (const k of Object.values(V.keys)) {
    const seed = crypto.createHash('sha256').update(k.seed_label).digest();
    assert.equal(b64(seed), k.private_seed_b64url);
    const x = crypto.createPublicKey(privFromSeed(seed)).export({ format: 'jwk' }).x;
    assert.equal(k.public_jwk.x, x);
    assert.equal(k.thumbprint_input, `{"crv":"Ed25519","kty":"OKP","x":"${x}"}`);
    assert.equal(k.public_jwk.kid, thumbprint(x));
    assert.deepEqual([k.public_jwk.kty, k.public_jwk.crv, k.public_jwk.alg, k.public_jwk.use], ['OKP', 'Ed25519', 'EdDSA', 'sig']);
  }
  assert.match(V.WARNING, /TEST VECTOR ONLY/);
});

test('signing input is base64url(header).base64url(payload), and a device signature over it is the token', () => {
  // lib/ builds the signing input (no secret); the device signs it natively.
  for (const l of V.links) {
    assert.equal(l.signing_input, `${b64(JSON.stringify(l.header))}.${b64(l.payload_json)}`);
    assert.equal(JSON.stringify(l.payload), l.payload_json);
    const signer = Object.values(V.keys).find((k) => k.public_jwk.kid === l.header.kid);
    assert.equal(`${l.signing_input}.${signWith(signer, l.signing_input)}`, l.token, 'Ed25519 is deterministic');
  }
  for (const e of Object.values(V.endorsements)) {
    assert.equal(e.signing_input, `${b64(JSON.stringify(e.header))}.${b64(JSON.stringify(e.payload))}`);
    const by = Object.values(V.keys).find((k) => k.public_jwk.kid === e.by);
    assert.equal(`${e.signing_input}.${signWith(by, e.signing_input)}`, e.jws);
    assert.equal(e.payload.iss, V.store.connected_shop, 'an endorsement names its shop');
    assert.equal(thumbprint(e.payload.x), e.payload.new_kid, 'it binds the key, not only its name');
  }
});

test('the chain keeps the retired root, and the pin response names it', () => {
  const root = V.key_chain.body.keys.find((k) => k.root);
  assert.equal(root.status, 'retired');
  assert.deepEqual(V.pin_response.body.roots, [root.kid]);
  assert.deepEqual(V.store.pinned_roots, [root.kid]);
  for (const kid of V.pin_response.body.current) assert.equal(V.key_chain.body.keys.find((k) => k.kid === kid).status, 'current');
});

test('the reference verifier accepts every link against the published chain', () => {
  for (const l of V.links) {
    const r = verifyLink(l.token, V.key_chain.body, V.store);
    assert.equal(r.ok, true, `${l.what}: ${r.reason}`);
    assert.deepEqual(r.payload, l.payload);
    assert.deepEqual(r.payload.customer, { name: 'Sara Example' }, 'name only, as approved');
  }
});

test('the must-refuse cases are refused, each for its stated reason', () => {
  for (const c of V.must_refuse) {
    const r = verifyLink(c.token, c.key_chain || V.key_chain.body, V.store);
    assert.equal(r.ok, false, c.case);
    assert.equal(r.reason, c.reason, c.case);
  }
});
