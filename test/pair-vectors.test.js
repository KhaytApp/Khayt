'use strict';
/**
 * Pairing by number: the connector's vectors and the phone's (C1).
 *
 * docs/connector-pair.vectors.json is the Mac's (LanConnectorPairingTests).
 * scripts/write-pair-vectors.js must reproduce it value for value, which is
 * what makes docs/phone-pair.vectors.json, written by the same code with the
 * phone's prefixes, the reviewed math and not a second copy of it. The iPhone
 * (PhonePairingTests, #2630) and the Mac's phone route run the phone file.
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
  assert.deepEqual(phone.cases.map((c) => c.name), conn.cases.map((c) => c.name), 'the same eight cases');
  // The same field names as the connector file, so one decoder reads both.
  for (const c of phone.cases) assert.deepEqual(Object.keys(c), Object.keys(conn.cases[0]));
});

test('every phone value checks out on its own', () => {
  for (const c of phone.cases) {
    assert.match(c.deviceId, /^dev_[A-Za-z0-9_-]{12,40}$/, 'the phone\'s isDeviceId rule');
    assert.equal(Buffer.from(c.nonce, 'base64').length, 16);
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
  // No prefix is the start of another, so a joined message cannot be read under the other's.
  const all = [...Object.values(G.VARIANTS.connector), ...Object.values(G.VARIANTS.phone)];
  for (const a of all) for (const b of all) if (a !== b) assert.ok(!(a + ':').startsWith(b + ':') && !(a + '\n').startsWith(b + '\n'), `${a} / ${b}`);
});

test('the check is the first four bytes big-endian mod 1 000 000, zero-padded (worked by hand for one case)', () => {
  const c = phone.cases[0];
  const text = ['khayt-phone-check-v1', c.deviceId, c.identityPublic, c.serverPublic, c.pluginPublic, c.nonce].join('\n');
  const d = crypto.createHash('sha256').update(text, 'utf8').digest();
  const n = ((d[0] << 24) >>> 0) + (d[1] << 16) + (d[2] << 8) + d[3];
  assert.equal(String(n % 1000000).padStart(6, '0'), c.check);
  assert.equal(crypto.createHash('sha256').update(`khayt-phone-commit-v1\n${c.pluginPublic}\n${c.nonce}`, 'utf8').digest('base64'), c.commit);
});

test('the vectors are plain data: no seed or key that is not a sample pattern', () => {
  for (const c of [...conn.cases, ...phone.cases]) {
    for (const k of ['identitySeedHex', 'serverPrivateHex', 'pluginPrivateHex', 'nonceHex']) {
      assert.match(c[k], /^([0-9a-f]{2})\1+$/, `${c.name}.${k} is one repeated byte`);
    }
  }
});
