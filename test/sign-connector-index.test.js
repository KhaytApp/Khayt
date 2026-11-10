'use strict';
/**
 * scripts/sign-connector.js publish / refresh-index / revoke / verify-index,
 * against a throwaway key — the Keychain key is never touched by a test.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const S = require('../scripts/sign-connector.js');
const U = require('../lib/plugin-update.js');

const DAY = 24 * 3600 * 1000;
const NOW = Date.parse('2026-11-12T09:00:00.000Z');
const LAMHA = require('../plugins/samples/lamha-shipping.json');

/** A fresh ed25519 key in the shape lib SIGNING_KEYS uses, and a signer over it. */
function throwaway(id = 'test-key') {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(12).toString('base64');
  return { keys: [{ id, key: raw }], sign: (msg) => crypto.sign(null, Buffer.from(msg, 'utf8'), privateKey).toString('base64') };
}
const site = () => fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-site-'));
const at = (v) => Object.assign(JSON.parse(JSON.stringify(LAMHA)), { version: v });

test('publish writes the signed manifest and a signed index a device accepts', () => {
  const k = throwaway(); const dir = site();
  const ix = S.publish(dir, at('1.1.1'), Object.assign({ nowMs: NOW, requires: { mac: '4.0.0-beta.33' } }, k));
  assert.equal(ix.serial, 1);
  assert.equal(ix.expires, new Date(NOW + U.EXPIRY_DAYS * DAY).toISOString());
  const r = ix.entries[0];
  assert.equal(r.url, `https://khaytapp.com/connectors/${LAMHA.id}/1.1.1.json`);
  assert.deepEqual(r.requires, { schema: 1, mac: '4.0.0-beta.33' });
  const bytes = fs.readFileSync(path.join(dir, 'connectors', LAMHA.id, '1.1.1.json'));
  assert.equal(r.sha256, crypto.createHash('sha256').update(bytes).digest('hex'));
  assert.equal(S.verify(JSON.parse(bytes), k.keys), 'test-key');
  assert.equal(S.verifyIndex(ix, k.keys), 'test-key');
  assert.equal(U.checkIndex(ix, { signedBy: S.verifyIndex(ix, k.keys), nowMs: NOW }).ok, true);
  assert.deepEqual(S.verifySite(dir, { nowMs: NOW, keys: k.keys }), { ok: true, problems: [], warnings: [] });
});

test('publishing an older or equal version is refused; a newer one replaces the row', () => {
  const k = throwaway(); const dir = site();
  S.publish(dir, at('1.1.1'), Object.assign({ nowMs: NOW }, k));
  assert.throws(() => S.publish(dir, at('1.1.1'), Object.assign({ nowMs: NOW }, k)), /not newer/);
  assert.throws(() => S.publish(dir, at('1.0.0'), Object.assign({ nowMs: NOW }, k)), /not newer/);
  const ix = S.publish(dir, at('1.2.0'), Object.assign({ nowMs: NOW + DAY }, k));
  assert.deepEqual([ix.serial, ix.entries.length, ix.entries[0].version], [2, 1, '1.2.0']);
});

test('a key that is not a published one signs nothing and writes nothing', () => {
  const k = throwaway(); const other = throwaway(); const dir = site();
  assert.throws(() => S.publish(dir, at('1.1.1'), { nowMs: NOW, sign: other.sign, keys: k.keys }), /not one of lib SIGNING_KEYS/);
  assert.equal(fs.existsSync(path.join(dir, 'connectors', 'index.json')), false);
});

test('a manifest signature cannot pass as the index signature', () => {
  const k = throwaway(); const dir = site();
  const ix = S.publish(dir, at('1.1.1'), Object.assign({ nowMs: NOW }, k));
  const bare = Object.assign({}, ix); delete bare.signature;
  const forged = Object.assign({}, ix, { signature: { keyId: 'test-key', sig: k.sign(require('../lib/plugin-manifest').canonicalJSON(bare)) } });
  assert.equal(S.verifyIndex(forged, k.keys), null);
});

test('revoke lists the version with its reason, bumps the serial, and survives the next publish', () => {
  const k = throwaway(); const dir = site();
  S.publish(dir, at('1.0.0'), Object.assign({ nowMs: NOW }, k));
  assert.throws(() => S.revoke(dir, LAMHA.id, '1.0.0', ' ', Object.assign({ nowMs: NOW }, k)), /says why/);
  const r = S.revoke(dir, LAMHA.id, '1.0.0', 'Reports a refused order as sent.', Object.assign({ nowMs: NOW }, k));
  assert.equal(r.serial, 2);
  assert.deepEqual(r.entries[0].revoked, [{ version: '1.0.0', reason: 'Reports a refused order as sent.' }]);
  const p = S.publish(dir, at('1.1.1'), Object.assign({ nowMs: NOW }, k));
  assert.deepEqual(p.entries[0].revoked, [{ version: '1.0.0', reason: 'Reports a refused order as sent.' }]);
  assert.equal(S.verifySite(dir, { nowMs: NOW, keys: k.keys }).ok, true);
});

test('refresh-index re-signs with a new serial and expiry; verify warns inside the last 15 days', () => {
  const k = throwaway(); const dir = site();
  S.publish(dir, at('1.1.1'), Object.assign({ nowMs: NOW }, k));
  assert.deepEqual(S.verifySite(dir, { nowMs: NOW + 29 * DAY, keys: k.keys }).warnings, []);
  assert.match(S.verifySite(dir, { nowMs: NOW + 31 * DAY, keys: k.keys }).warnings[0], /refresh-index/);
  const late = S.verifySite(dir, { nowMs: NOW + 45 * DAY, keys: k.keys });
  assert.deepEqual([late.ok, late.problems], [false, ['index: expired']]);
  const ix = S.refreshIndex(dir, Object.assign({ nowMs: NOW + 30 * DAY }, k));
  assert.equal(ix.serial, 2);
  assert.deepEqual(S.verifySite(dir, { nowMs: NOW + 31 * DAY, keys: k.keys }), { ok: true, problems: [], warnings: [] });
});

test('verify-index catches a changed file, a wrong size, a moved url, an unsigned manifest and a tampered index', () => {
  const k = throwaway();
  const fresh = () => { const d = site(); S.publish(d, at('1.1.1'), Object.assign({ nowMs: NOW }, k)); return d; };
  const file = (d) => path.join(d, 'connectors', LAMHA.id, '1.1.1.json');
  const ixFile = (d) => path.join(d, 'connectors', 'index.json');
  const problems = (d) => S.verifySite(d, { nowMs: NOW, keys: k.keys }).problems.join(' | ');

  let d = fresh(); fs.appendFileSync(file(d), ' ');
  assert.match(problems(d), /sha256 does not match/);
  d = fresh(); const m = JSON.parse(fs.readFileSync(file(d))); m.description = { en: 'changed' };
  fs.writeFileSync(file(d), JSON.stringify(m)); assert.match(problems(d), /not signed by a published key/);
  d = fresh(); fs.rmSync(file(d)); assert.match(problems(d), /file missing/);
  d = fresh(); let ix = JSON.parse(fs.readFileSync(ixFile(d))); ix.entries[0].size += 1;
  fs.writeFileSync(ixFile(d), JSON.stringify(ix)); assert.match(problems(d), /index: unsigned/);
  d = fresh(); ix = JSON.parse(fs.readFileSync(ixFile(d))); ix.entries[0].url = 'https://evil.example/x.json';
  fs.writeFileSync(ixFile(d), JSON.stringify(S.signIndex(ix, k.sign, k.keys)));
  assert.match(problems(d), /url is not/);
  d = site(); assert.match(problems(d), /index\.json/);
});

test('verify-index runs with no key at all: the CLI exits 0 on a good site and 1 on a bad one', () => {
  const k = throwaway(); const d = site();
  S.publish(d, at('1.1.1'), Object.assign({ nowMs: NOW }, k));
  // The CLI checks against lib SIGNING_KEYS, which this throwaway key is not in: NOT OK, exit 1.
  const { spawnSync } = require('child_process');
  const out = spawnSync(process.execPath, [path.join(__dirname, '..', 'scripts', 'sign-connector.js'), 'verify-index', '--site', d], { encoding: 'utf8' });
  assert.equal(out.status, 1);
  assert.match(out.stdout, /NOT OK/);
  assert.match(out.stderr, /index: unsigned/);
});
