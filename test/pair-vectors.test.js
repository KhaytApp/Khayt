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

// ── The desktop's own code (lib/main/phone-pairing.js, lib/lan-identity.js,
// lib/lan-devices.js admitPhone) reproduces every phone vector ─────────────

test('desktop: the commitment, the offer message and the check number, every case', () => {
  const PP = require('../lib/main/phone-pairing.js');
  assert.deepEqual(PP.FLAVOR, phone.prefixes);
  for (const c of phone.cases) {
    assert.equal(PP.commitment(c.pluginPublic, c.nonce).toString('base64'), c.commit, c.name);
    assert.equal(PP.offerMessage(c.deviceId, c.serverPublic, c.commit), c.offerMessage, c.name);
    assert.equal(PP.checkNumber(c.deviceId, c.identityPublic, c.serverPublic, c.pluginPublic, c.nonce), c.check, c.name);
  }
});

test('desktop: the whole exchange with the vector keys gives the vector offer, number and key', () => {
  const os = require('os');
  const path = require('path');
  const PP = require('../lib/main/phone-pairing.js');
  const { createLanIdentity } = require('../lib/lan-identity.js');
  const LD = require('../lib/lan-devices.js');
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-pair-vec-'));
  const x = (hex) => crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(hex, 'hex')]), format: 'der', type: 'pkcs8' });
  try {
    for (const c of phone.cases) {
      const keyPath = path.join(tmp, `${c.name}.key`);
      const ed = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(c.identitySeedHex, 'hex')]), format: 'der', type: 'pkcs8' });
      fs.writeFileSync(keyPath, ed.export({ type: 'pkcs8', format: 'pem' }));
      const id = createLanIdentity({ fs, keyPath });
      assert.equal(id.identity().publicKey, c.identityPublic);
      assert.equal(id.signPhoneOffer(c.offerMessage), c.sig, `${c.name}: the identity's signature`);
      const serverPrivate = x(c.serverPrivateHex);
      let n = 0;
      const w = PP.createPhonePairing({ clock: () => 0, enabled: () => true, newKeyPair: () => ({ privateKey: serverPrivate, publicKey: crypto.createPublicKey(serverPrivate) }),
        newDeviceId: () => c.deviceId, newSecret: (len) => String(n++).padStart(len, 'a').replace(/[^a-z0-9]/g, 'a') });
      w.open();
      const { offer } = w.request({ commit: c.commit, name: 'p', identity: { publicKey: id.identity().publicKey, sign: (m) => id.signPhoneOffer(m) } });
      assert.deepEqual([offer.deviceId, offer.publicKey, offer.sig, offer.identity], [c.deviceId, c.serverPublic, c.sig, c.identityPublic], c.name);
      assert.equal(w.reveal(offer.pairId, offer.pollSecret, c.pluginPublic, c.nonce), 'accepted', c.name);
      assert.equal(w.snapshot().pending.check, c.check, c.name);
      const devs = LD.createLanDevices({ fs, keyPath: path.join(tmp, `${c.name}-devices.key`) });
      assert.equal(w.approve({ pairId: offer.pairId, check: c.check }, (r) => {
        assert.deepEqual(devs.admitPhone({ serverPrivate: r.serverPrivate, phonePublic: r.phonePublic, deviceId: r.deviceId, name: 'p', role: 'viewer', pin: '12345678' }), { deviceId: c.deviceId });
      }), true);
      // The phone signs with derivedKey, and this computer takes it.
      const t = Math.floor(Date.now() / 1000);
      const nonce = '00112233445566778899aabbccddeeff';
      const mac = LD.requestMac(Buffer.from(c.derivedKey, 'base64'), LD.canonicalRequest('GET', '/api/devices/self', String(t), nonce));
      const v = devs.verify({ headers: { 'x-khayt-device': c.deviceId, 'x-khayt-time': String(t), 'x-khayt-nonce': nonce, 'x-khayt-mac': mac }, method: 'GET', target: '/api/devices/self', pin: '12345678' });
      assert.equal(v.ok, true, `${c.name}: the derived key`);
    }
    // The identity signs a phone offer of that exact shape and nothing else.
    const id = createLanIdentity({ fs, keyPath: path.join(tmp, 'first.key') });
    for (const bad of ['khayt-enrol-phone-v1:anything', 'khayt-proof:00', phone.cases[0].offerMessage + ':x', phone.refuse.find((r) => r.name === 'bad-device-id').offerMessage.replace('dev_SamplePhone0001', 'dev_Sample:Phone0001')]) {
      assert.throws(() => id.signPhoneOffer(bad), bad);
    }
  } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
});

test('desktop: every reveal the vectors say the computer must refuse is refused', () => {
  const PP = require('../lib/main/phone-pairing.js');
  const first = phone.cases[0];
  const serverPrivate = crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(first.serverPrivateHex, 'hex')]), format: 'der', type: 'pkcs8' });
  const ident = { publicKey: first.identityPublic, sign: () => 'sig' };
  const macSide = phone.refuse.filter((r) => r.refusedBy === 'mac');
  assert.ok(macSide.length >= 3);
  for (const r of macSide) {
    const w = PP.createPhonePairing({ clock: () => 0, enabled: () => true, newKeyPair: () => ({ privateKey: serverPrivate, publicKey: crypto.createPublicKey(serverPrivate) }) });
    w.open();
    const { offer } = w.request({ commit: r.commit, identity: ident });
    assert.equal(w.reveal(offer.pairId, offer.pollSecret, r.revealPublic, r.revealNonce), 'refused', r.name);
    assert.equal(w.poll(offer.pairId, offer.pollSecret), 'expired', r.name);
  }
});
