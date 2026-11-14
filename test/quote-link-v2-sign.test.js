'use strict';
/**
 * Pay link v2, the signing side: lib/quote-pay-link.js builds the bytes and
 * lib/main/quote-link-key.js signs them. Both are checked byte for byte
 * against the shared vector (contracts/quote-link-v2.vector.json); Ed25519 is
 * deterministic, so the same seed and input give the vector's very token.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const V = require('../contracts/quote-link-v2.vector.json');
const L = require('../lib/quote-pay-link.js');
const K = require('../lib/main/quote-link-key.js');

const seedOfKid = (kid) => Object.values(V.keys).find((k) => k.public_jwk.kid === kid).private_seed_b64url;

test('each vector key: the seed gives its public x and its kid (RFC 7638)', () => {
  for (const [name, k] of Object.entries(V.keys)) {
    const pub = K.publicOf(k.private_seed_b64url);
    assert.equal(pub.x, k.public_jwk.x, name);
    assert.equal(pub.kid, k.public_jwk.kid, name);
    assert.equal(L.thumbprintInput(k.public_jwk.x), k.thumbprint_input, name);
  }
});

test('every vector link: the signing input and the token are byte for byte the vector\'s', () => {
  for (const link of V.links) {
    const input = L.signingInputV2(link.payload, link.header.kid);
    assert.equal(input, link.signing_input, link.what);
    assert.equal(K.signLink(link.payload, seedOfKid(link.header.kid)), link.token, link.what);
  }
});

test('every vector endorsement: the input and the JWS are the vector\'s', () => {
  for (const [name, e] of Object.entries(V.endorsements)) {
    const input = L.endorsementInput(e.payload, e.by);
    assert.equal(input, e.signing_input, name);
    assert.equal(K.endorse(e.payload, seedOfKid(e.by)), e.jws, name);
  }
});

test('claimsForV2 leads with v, iss, aud, in the vector\'s key order', () => {
  // The same approved job the v1 tests use: two dragons and a design fee.
  const order = {
    id: 'QUO-2026-0142-ab3k', jobNumber: 'QUO-2026-0142', status: 'pending',
    quoteAcceptedAt: '2026-11-12', project: 'Dragon', price: 340, paidAmount: 0,
    parts: [{ name: 'dragon-v2.stl', material: 'PLA', color: 'red', qty: 2, printWeight: 450, baseCost: 80 }],
    extraLines: [{ label: 'Design fee', amount: 50 }],
  };
  const ctx = {
    shopId: 'shop_0000example', config: { storeUrl: 'https://Store.example/sa/ar', hasSecret: true },
    nowSeconds: 1794470400, settings: { currency: 'SAR', enableVat: false }, clients: [],
    customerName: 'Sara Example', leadDays: { min: 5, max: 7 },
  };
  const v1 = L.claimsFor(order, ctx);
  const v2 = L.claimsForV2(order, ctx);
  assert.ok(v1 && v2, 'the fixture is a job v1 signs');
  assert.deepEqual(Object.keys(v2), Object.keys(V.links[0].payload), 'every key, in the vector\'s order');
  for (const k of Object.keys(v1)) if (k !== 'v') assert.deepEqual(v2[k], v1[k], k);
  const want = Object.keys(V.links[0].payload).filter((k) => k in v2);
  assert.deepEqual(Object.keys(v2), want);
  assert.equal(v2.v, 2);
  assert.equal(v2.iss, 'shop_0000example');
  assert.equal(v2.aud, 'https://store.example', 'aud is the origin, lower-cased, no path');
});

test('claimsForV2 refuses without a shop id or an https store', () => {
  const ctx = { config: { storeUrl: 'https://store.example', hasSecret: true }, nowSeconds: 1794470400 };
  assert.equal(L.claimsForV2({}, { ...ctx }), null);
  assert.equal(L.claimsForV2({}, { ...ctx, shopId: 's', config: { storeUrl: 'http://store.example' } }), null);
});

test('a fresh key signs links the store can verify; the seed never appears in what leaves', () => {
  const key = K.generate(Date.UTC(2026, 10, 14));
  assert.ok(K.seedOk(key.seed));
  assert.equal(key.kid, K.kidOf(key.x));
  const claims = { ...V.links[0].payload };
  const token = K.signLink(claims, key.seed);
  const [h, p, s] = token.split('.');
  const pub = crypto.createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: key.x }, format: 'jwk' });
  assert.ok(crypto.verify(null, Buffer.from(h + '.' + p), pub, Buffer.from(s, 'base64url')));
  assert.equal(JSON.parse(Buffer.from(h, 'base64url')).kid, key.kid);
  assert.ok(!token.includes(key.seed));
  assert.ok(!JSON.stringify(K.publicOf(key.seed)).includes(key.seed));
});

test('bad inputs give empty results, never a token', () => {
  assert.equal(K.signLink(V.links[0].payload, 'short'), '');
  assert.equal(L.signingInputV2({ ...V.links[0].payload, v: 1 }, V.keys.K1.public_jwk.kid), '', 'a v1 payload is not signed as v2');
  assert.equal(L.signingInputV2(V.links[0].payload, 'not-a-kid'), '');
  assert.equal(L.tokenFromV2(V.links[0].signing_input, new Uint8Array(32)), '', 'an HMAC-sized signature is refused');
  assert.equal(L.endorsementInput({ iss: '', new_kid: V.keys.K2.public_jwk.kid, x: V.keys.K2.public_jwk.x, iat: 1 }, V.keys.K1.public_jwk.kid), '');
});

test('no function in lib/quote-pay-link.js takes a key or a seed', () => {
  const src = require('node:fs').readFileSync(require.resolve('../lib/quote-pay-link.js'), 'utf8');
  assert.doesNotMatch(src, /function\s+\w+\s*\([^)]*\b(seed|privateKey|private_key)\b/);
});
