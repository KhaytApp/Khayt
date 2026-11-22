#!/usr/bin/env node
'use strict';
/**
 * The pairing-by-number test vectors, for both kinds of device that pair
 * without the PIN (docs/LAN_API.md, "POST /api/connectors/pair"):
 *
 *   docs/connector-pair.vectors.json  the slicer plugin, v2 prefixes (READ here,
 *                                     never written: the Mac's tests own it, and
 *                                     this script must reproduce it exactly)
 *   docs/phone-pair.vectors.json      a phone (C1, ~/Khayt-proposals/phone-pairing-code-design.md),
 *                                     the same math with the phone's own prefixes
 *
 * The math, for a variant {commit, offer, check}:
 *   commit       = base64 SHA-256(commit \n clientPublic \n nonce)
 *   offerMessage = offer ':' deviceId ':' serverPublic ':' commit   (Ed25519-signed by the identity)
 *   check        = first 4 bytes big-endian of SHA-256(check \n deviceId \n identityPublic
 *                  \n serverPublic \n clientPublic \n nonce) mod 1 000 000, zero-padded to 6
 * Keys and the nonce are base64 (standard, padded) of the raw bytes.
 *
 * The phone file keeps the connector file's field names (`pluginPrivateHex`,
 * `pluginPublic` hold the PHONE's key) so one decoder reads both; its
 * `prefixes` say which variant it is.
 *
 * Every seed, private key and nonce is a sample value for tests only.
 *
 *   node scripts/write-pair-vectors.js          write docs/phone-pair.vectors.json
 *   node scripts/write-pair-vectors.js --check  exit 1 if either file is not what this computes
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const CONNECTOR_FILE = path.join(ROOT, 'docs', 'connector-pair.vectors.json');
const PHONE_FILE = path.join(ROOT, 'docs', 'phone-pair.vectors.json');

const VARIANTS = Object.freeze({
  connector: Object.freeze({ commit: 'khayt-connector-commit-v2', offer: 'khayt-enrol-commit-v2', check: 'khayt-connector-check-v2' }),
  phone: Object.freeze({ commit: 'khayt-phone-commit-v1', offer: 'khayt-enrol-phone-v1', check: 'khayt-phone-check-v1' }),
});

// Raw 32-byte private keys as PKCS#8 (RFC 8410): the fixed prefix, then the key.
const X25519_PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex');
const ED25519_PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');
const priv = (prefix, hex) => crypto.createPrivateKey({ key: Buffer.concat([prefix, Buffer.from(hex, 'hex')]), format: 'der', type: 'pkcs8' });
const rawPublic = (key) => crypto.createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
const sha256 = (s) => crypto.createHash('sha256').update(Buffer.from(s, 'utf8')).digest();

function commitOf(v, clientPublic, nonce) { return sha256(`${v.commit}\n${clientPublic}\n${nonce}`).toString('base64'); }
function offerMessageOf(v, deviceId, serverPublic, commit) { return `${v.offer}:${deviceId}:${serverPublic}:${commit}`; }
function checkOf(v, deviceId, identityPublic, serverPublic, clientPublic, nonce) {
  const d = sha256([v.check, deviceId, identityPublic, serverPublic, clientPublic, nonce].join('\n'));
  return String(d.readUInt32BE(0) % 1000000).padStart(6, '0');
}

/** One case from its inputs: every value a test checks. */
function computeCase(v, input) {
  const identity = priv(ED25519_PKCS8, input.identitySeedHex);
  const identityPublic = rawPublic(identity);
  const serverPublic = rawPublic(priv(X25519_PKCS8, input.serverPrivateHex));
  const pluginPublic = rawPublic(priv(X25519_PKCS8, input.pluginPrivateHex));
  const nonce = Buffer.from(input.nonceHex, 'hex').toString('base64');
  const commit = commitOf(v, pluginPublic, nonce);
  const offerMessage = offerMessageOf(v, input.deviceId, serverPublic, commit);
  return {
    name: input.name,
    identitySeedHex: input.identitySeedHex,
    serverPrivateHex: input.serverPrivateHex,
    pluginPrivateHex: input.pluginPrivateHex,
    nonceHex: input.nonceHex,
    deviceId: input.deviceId,
    identityPublic, serverPublic, pluginPublic, nonce, commit, offerMessage,
    sig: crypto.sign(null, Buffer.from(offerMessage, 'utf8'), identity).toString('base64'),   // Ed25519: deterministic
    check: checkOf(v, input.deviceId, identityPublic, serverPublic, pluginPublic, nonce),
  };
}

const rep = (byteHex, n) => byteHex.repeat(n);
const BASE = { identitySeedHex: rep('11', 32), serverPrivateHex: rep('01', 32), pluginPrivateHex: rep('02', 32), nonceHex: rep('30', 16) };

/** The first repeated-byte nonce whose check starts with `lead` (and not one more zero). */
function nonceFor(v, input, lead) {
  for (let b = 0; b < 256; b++) {
    const nonceHex = rep(b.toString(16).padStart(2, '0'), 16);
    const c = computeCase(v, Object.assign({}, input, { nonceHex })).check;
    if (c.startsWith(lead) && c[lead.length] !== '0') return nonceHex;
  }
  throw new Error('no nonce gives a check starting ' + lead);
}

/** The phone's cases: the connector's eight, the same inputs where they are inputs. */
function phoneInputs() {
  const v = VARIANTS.phone;
  const otherKeys = { serverPrivateHex: rep('a0', 32), pluginPrivateHex: rep('5f', 32) };
  const a = Object.assign({}, BASE, { name: 'leading-zero-a', deviceId: 'dev_SamplePhone0003' });
  const b = Object.assign({}, BASE, otherKeys, { name: 'leading-zero-b', deviceId: 'dev_SamplePhone0004' });
  return [
    Object.assign({}, BASE, { name: 'first', deviceId: 'dev_SamplePhone0001' }),
    Object.assign({}, BASE, { name: 'second-device-id', deviceId: 'dev_SamplePhone0002' }),
    Object.assign({}, BASE, { name: 'other-identity', deviceId: 'dev_SamplePhone0001', identitySeedHex: rep('22', 32) }),
    Object.assign({}, BASE, otherKeys, { name: 'other-keys', deviceId: 'dev_SamplePhone0001' }),
    Object.assign({}, BASE, { name: 'swapped-keys', deviceId: 'dev_SamplePhone0001', serverPrivateHex: rep('02', 32), pluginPrivateHex: rep('01', 32) }),
    Object.assign({}, BASE, { name: 'other-nonce', deviceId: 'dev_SamplePhone0001', nonceHex: rep('40', 16) }),
    Object.assign(a, { nonceHex: nonceFor(v, a, '0') }),     // one leading zero
    Object.assign(b, { nonceHex: nonceFor(v, b, '00') }),    // two
  ];
}

function buildPhone() {
  const v = VARIANTS.phone;
  return {
    about: 'Phone pairing by number, v1 (POST /api/devices/pair; ~/Khayt-proposals/phone-pairing-code-design.md, C1). '
      + 'The same math as docs/connector-pair.vectors.json with the phone\'s own prefixes, so neither kind of offer can be replayed as the other. '
      + `commit = base64 SHA-256('${v.commit}' \\n phonePublic \\n nonce). `
      + `offerMessage = '${v.offer}:' + deviceId + ':' + serverPublic + ':' + commit, signed by the Mac's Ed25519 identity (sig, deterministic). `
      + `check = first 4 bytes big-endian of SHA-256('${v.check}' \\n deviceId \\n identityPublic \\n serverPublic \\n phonePublic \\n nonce) mod 1000000, zero-padded to 6. `
      + 'pluginPrivateHex / pluginPublic hold the PHONE\'s X25519 key: the connector file\'s field names, so one decoder reads both. '
      + 'Generated by scripts/write-pair-vectors.js. The nonce is 16 random bytes in real use. Seeds, private keys and nonces here are sample values for tests only.',
    prefixes: Object.assign({}, v),
    cases: phoneInputs().map((i) => computeCase(v, i)),
  };
}

const render = (obj) => JSON.stringify(obj, null, 2) + '\n';

module.exports = { VARIANTS, computeCase, commitOf, offerMessageOf, checkOf, buildPhone, render, CONNECTOR_FILE, PHONE_FILE };

if (require.main === module) {
  const want = render(buildPhone());
  if (process.argv.includes('--check')) {
    const conn = JSON.parse(fs.readFileSync(CONNECTOR_FILE, 'utf8'));
    const bad = conn.cases.filter((c) => JSON.stringify(computeCase(VARIANTS.connector, c)) !== JSON.stringify(c)).map((c) => c.name);
    const phoneOk = fs.existsSync(PHONE_FILE) && fs.readFileSync(PHONE_FILE, 'utf8') === want;
    if (bad.length || !phoneOk) {
      console.error(`pair vectors: connector cases not reproduced: [${bad.join(', ')}]; phone file ${phoneOk ? 'ok' : 'stale (run node scripts/write-pair-vectors.js)'}`);
      process.exit(1);
    }
    console.log('pair vectors ok');
  } else {
    fs.writeFileSync(PHONE_FILE, want);
    console.log('wrote', path.relative(ROOT, PHONE_FILE));
  }
}
