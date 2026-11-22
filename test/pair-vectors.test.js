'use strict';
/**
 * Pairing by number: the connector's vectors and the phone's (C1).
 *
 * docs/connector-pair.vectors.json is the Mac's (LanConnectorPairingTests).
 * scripts/write-pair-vectors.js must reproduce it value for value, which is
 * what makes docs/phone-pair.vectors.json, written by the same code with the
 * phone's prefixes, the reviewed math and not a second copy of it. The iPhone
 * (PhonePairingTests, #2630) and the Mac's phone route are to run the phone
 * file; neither does yet.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const G = require('../scripts/write-pair-vectors.js');

const conn = JSON.parse(fs.readFileSync(G.CONNECTOR_FILE, 'utf8'));
const phone = JSON.parse(fs.readFileSync(G.PHONE_FILE, 'utf8'));
const edPublic = (b64) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(b64, 'base64')]), format: 'der', type: 'spki' });
const verifies = (msg, sig, identity) => crypto.verify(null, Buffer.from(msg, 'utf8'), edPublic(identity), Buffer.from(sig, 'base64'));

test('the generator reproduces every connector vector exactly (the same math the Mac tests)', () => {
  assert.equal(conn.cases.length, 8);
  for (const c of conn.cases) assert.deepEqual(G.computeCase(G.VARIANTS.connector, c), c, c.name);
});

test('docs/phone-pair.vectors.json is what the generator writes (run scripts/write-pair-vectors.js)', () => {
  assert.equal(fs.readFileSync(G.PHONE_FILE, 'utf8'), G.render(G.buildPhone()));
  assert.deepEqual(phone.prefixes, { commit: 'khayt-phone-commit-v1', offer: 'khayt-enrol-phone-v1', check: 'khayt-phone-check-v1' });
  assert.deepEqual(phone.cases.map((c) => c.name), [...conn.cases.map((c) => c.name), 'long-nonce'], 'the connector\'s eight, and a nonce over 16 bytes');
  // The connector file's field names, so one decoder reads both, plus the derived key.
  for (const c of phone.cases) assert.deepEqual(Object.keys(c), [...Object.keys(conn.cases[0]), 'derivedKey']);
  assert.equal(G.connectorMismatches().length, 0);
});

test('every phone value checks out on its own', () => {
  for (const c of phone.cases) {
    assert.match(c.deviceId, /^dev_[A-Za-z0-9_-]{12,40}$/, 'the phone\'s isDeviceId rule');
    assert.equal(Buffer.from(c.nonce, 'base64').length, c.name === 'long-nonce' ? 32 : 16);
    assert.ok(c.offerMessage.startsWith('khayt-enrol-phone-v1:' + c.deviceId + ':'));
    assert.ok(verifies(c.offerMessage, c.sig, c.identityPublic), c.name + ': the identity signed this offer');
    assert.match(c.check, /^\d{6}$/);
  }
  const lead = Object.fromEntries(phone.cases.map((c) => [c.name, c.check]));
  assert.match(lead['leading-zero-a'], /^0[1-9]/);
  assert.match(lead['leading-zero-b'], /^00[1-9]/);
  // Every input moves the number.
  assert.equal(new Set(phone.cases.map((c) => c.check)).size, phone.cases.length);
});

test('no offer passes as the other kind: the same inputs give a different commit, offer, signature and number', () => {
  const same = ['first', 'other-identity', 'other-keys', 'swapped-keys', 'other-nonce'];
  for (const name of same) {
    const p = phone.cases.find((c) => c.name === name);
    const asConnector = G.computeCase(G.VARIANTS.connector, Object.assign({}, p));
    for (const k of ['identityPublic', 'serverPublic', 'pluginPublic', 'nonce']) assert.equal(p[k], asConnector[k], `${name}.${k} is an input`);
    for (const k of ['commit', 'offerMessage', 'sig', 'check']) assert.notEqual(p[k], asConnector[k], `${name}.${k}`);
    // A connector offer's signature does not verify as a phone offer, nor the other way round.
    assert.equal(verifies(p.offerMessage, asConnector.sig, p.identityPublic), false);
    assert.equal(verifies(asConnector.offerMessage, p.sig, p.identityPublic), false);
  }
  // Separation rests on the first field: every prefix the identity key or the
  // hashes use is distinct, and none holds a separator, so the first ':' or
  // '\n' decides the kind (security review: the comparisons above cannot see
  // a prefix shared between the two kinds, these can).
  const all = [...Object.values(G.VARIANTS.connector), ...Object.values(G.VARIANTS.phone),
    'khayt-enrol', 'khayt-proof'];   // the identity key's other messages (lib/lan-identity.js, LanIdentity.swift)
  assert.equal(require('../lib/lan-devices.js').ENROL_PREFIX.replace(/:$/, ''), 'khayt-enrol', 'the PIN enrolment prefix is the one listed');
  assert.equal(new Set(all).size, all.length, 'every prefix distinct');
  for (const a of all) assert.doesNotMatch(a, /[:\n]/, a);
});

test('the derived key: both sides get the same one, and it depends on the device id', () => {
  for (const c of phone.cases) {
    // The Mac's side: its private key with the phone's public key.
    const pub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(c.pluginPublic, 'base64')]), format: 'der', type: 'spki' });
    const mac = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(c.serverPrivateHex, 'hex')]), format: 'der', type: 'pkcs8' });
    const shared = crypto.diffieHellman({ privateKey: mac, publicKey: pub });
    assert.equal(Buffer.from(crypto.hkdfSync('sha256', shared, 'khayt-device-v1', c.deviceId, 32)).toString('base64'), c.derivedKey, c.name);
  }
  const byName = Object.fromEntries(phone.cases.map((c) => [c.name, c.derivedKey]));
  assert.notEqual(byName.first, byName['second-device-id']);
  // The same as lib/lan-devices.js derives for a PIN-enrolled phone.
  const LD = require('../lib/lan-devices.js');
  {
    const c = phone.cases[0];
    const mac = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(c.serverPrivateHex, 'hex')]), format: 'der', type: 'pkcs8' });
    const pub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(c.pluginPublic, 'base64')]), format: 'der', type: 'spki' });
    const k = LD.deriveDeviceKey(crypto.diffieHellman({ privateKey: mac, publicKey: pub }), c.deviceId);
    assert.equal(Buffer.from(k).toString('base64'), c.derivedKey);
  }
});

test('refusals: every one fails exactly the check it names', () => {
  const first = phone.cases[0];
  const isDeviceId = (id) => /^dev_[A-Za-z0-9_-]{12,40}$/.test(id);
  const zeroSecret = (pubB64) => {
    try {
      const pub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(pubB64, 'base64')]), format: 'der', type: 'spki' });
      const mine = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(first.pluginPrivateHex, 'hex')]), format: 'der', type: 'pkcs8' });
      return crypto.diffieHellman({ privateKey: mine, publicKey: pub }).every((b) => b === 0);
    } catch (_) { return true; }   // a key that cannot be used is refused all the same
  };
  // What the phone checks before it shows a number (PhonePairing.swift CodePairing.accept).
  const phoneAccepts = (r) => isDeviceId(r.deviceId) && !zeroSecret(r.serverPublic)
    && r.commit === first.commit
    && verifies(G.offerMessageOf(G.VARIANTS.phone, r.deviceId, r.serverPublic, first.commit), r.sig, r.identityPublic);
  // What the Mac checks at the reveal (docs/LAN_API.md step 3).
  const macAccepts = (r) => Buffer.from(r.revealNonce, 'base64').length >= 16 && !zeroSecret(r.revealPublic)
    && G.commitOf(G.VARIANTS.phone, r.revealPublic, r.revealNonce) === r.commit;
  // The honest exchange passes both, so the refusals below are not refused for another reason.
  assert.equal(phoneAccepts({ deviceId: first.deviceId, serverPublic: first.serverPublic, commit: first.commit, sig: first.sig, identityPublic: first.identityPublic }), true);
  assert.equal(macAccepts({ commit: first.commit, revealPublic: first.pluginPublic, revealNonce: first.nonce }), true);
  assert.ok(phone.refuse.length >= 9);
  for (const r of phone.refuse) {
    assert.ok(['phone', 'mac'].includes(r.refusedBy) && r.why, r.name);
    assert.equal(r.refusedBy === 'phone' ? phoneAccepts(r) : macAccepts(r), false, r.name);
  }
});

test('the check is the first four bytes big-endian mod 1 000 000, zero-padded (worked by hand, every case)', () => {
  let high = 0;
  for (const c of phone.cases) {
  const text = ['khayt-phone-check-v1', c.deviceId, c.identityPublic, c.serverPublic, c.pluginPublic, c.nonce].join('\n');
  const d = crypto.createHash('sha256').update(text, 'utf8').digest();
  const n = ((d[0] << 24) >>> 0) + (d[1] << 16) + (d[2] << 8) + d[3];
  assert.equal(String(n % 1000000).padStart(6, '0'), c.check, c.name);
  assert.equal(crypto.createHash('sha256').update(`khayt-phone-commit-v1\n${c.pluginPublic}\n${c.nonce}`, 'utf8').digest('base64'), c.commit);
  if (d[0] >= 0x80) high += 1;
  }
  assert.ok(high > 0, 'a case whose first byte is 0x80 or more, where a signed read goes wrong');
});

test('the vectors are plain data: no seed or key that is not a sample pattern', () => {
  for (const c of [...conn.cases, ...phone.cases]) {
    for (const k of ['identitySeedHex', 'serverPrivateHex', 'pluginPrivateHex', 'nonceHex']) {
      assert.match(c[k], /^([0-9a-f]{2})\1+$/, `${c.name}.${k} is one repeated byte`);
    }
  }
});
