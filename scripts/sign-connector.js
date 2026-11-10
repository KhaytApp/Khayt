#!/usr/bin/env node
'use strict';
/**
 * Sign reviewed connectors, and keep the update index on khaytapp.com.
 *
 *   sign-connector.js manifest.json                 sign a manifest in place (as before)
 *   sign-connector.js --verify manifest.json        check a manifest's signature (as before)
 *   sign-connector.js publish manifest.json --site DIR [--requires mac=4.0.0-beta.33,desktop=4.9.0,ios=202611101200,schema=1]
 *   sign-connector.js refresh-index --site DIR      re-sign with a new serial and expiry (every 30 days)
 *   sign-connector.js revoke ID VERSION "reason" --site DIR
 *   sign-connector.js verify-index --site DIR       check everything; needs no key (website CI)
 *
 * DIR is the folder served as https://khaytapp.com/ — the index is
 * DIR/connectors/index.json and each manifest DIR/connectors/<id>/<version>.json.
 *
 * The private key is read from the login Keychain ("Khayt connector signing
 * key") straight into this process: never printed, logged or written to disk.
 * Every signature is checked against lib SIGNING_KEYS before anything is
 * written, so a key that is not the published one signs nothing.
 *
 * The index is signed over "khayt-index-v1\n" + its canonical JSON
 * (lib/plugin-update.js indexSigningMessage), never the bare JSON a manifest
 * is signed over: neither signature can pass as the other.
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const M = require('../lib/plugin-manifest');
const U = require('../lib/plugin-update');

const SERVICE = 'Khayt connector signing key';
const FEED_BASE = 'https://khaytapp.com/connectors/';
const DAY = 24 * 3600 * 1000;
// DER prefixes that wrap a raw ed25519 key for node:crypto.
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function publicKeyOf(b64) {
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_PREFIX, Buffer.from(b64, 'base64')]), format: 'der', type: 'spki' });
}

/** Which of `keys` (default: the published ones) signed these bytes. */
function signedBy(message, sigB64, keys) {
  if (typeof sigB64 !== 'string') return null;
  const msg = Buffer.from(message, 'utf8');
  const sig = Buffer.from(sigB64, 'base64');
  const hit = (keys || M.SIGNING_KEYS).find((k) => {
    try { return crypto.verify(null, msg, publicKeyOf(k.key), sig); } catch (_) { return false; }
  });
  return hit ? hit.id : null;
}

/** Which published key, if any, this manifest's signature verifies against. */
function verify(manifest, keys) {
  return signedBy(M.canonicalJSON(manifest), manifest && manifest.signature, keys);
}

/** Which key signed this index — `{ keyId, sig }` over the context-prefixed bytes. */
function verifyIndex(index, keys) {
  const s = index && index.signature;
  if (!s || typeof s !== 'object' || typeof s.sig !== 'string') return null;
  const id = signedBy(U.indexSigningMessage(index), s.sig, keys);
  return id && id === s.keyId ? id : null;
}

/** A signer over the Keychain key. Returns base64. */
function keychainSigner() {
  return (message) => {
    const seed = Buffer.from(execFileSync('security', ['find-generic-password', '-s', SERVICE, '-w'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(), 'base64');
    const priv = crypto.createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: 'der', type: 'pkcs8' });
    seed.fill(0);
    return crypto.sign(null, Buffer.from(message, 'utf8'), priv).toString('base64');
  };
}

function signManifest(manifest, sign, keys) {
  const unsigned = Object.assign({}, manifest); delete unsigned.signature;
  const signed = Object.assign({}, unsigned, { signature: sign(M.canonicalJSON(unsigned)) });
  if (!verify(signed, keys)) throw new Error('the signing key is not one of lib SIGNING_KEYS; nothing written');
  return signed;
}

function signIndex(index, sign, keys) {
  const unsigned = Object.assign({}, index); delete unsigned.signature;
  const keyIds = (keys || M.SIGNING_KEYS).map((k) => k.id);
  const sig = sign(U.indexSigningMessage(unsigned));
  for (const keyId of keyIds) {
    const signed = Object.assign({}, unsigned, { signature: { keyId, sig } });
    if (verifyIndex(signed, keys)) return signed;
  }
  throw new Error('the signing key is not one of lib SIGNING_KEYS; nothing written');
}

const json = (v) => JSON.stringify(v, null, 2) + '\n';
const indexPath = (site) => path.join(site, 'connectors', 'index.json');
const manifestPath = (site, id, version) => path.join(site, 'connectors', id, `${version}.json`);
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

function readIndex(site) {
  const p = indexPath(site);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8'))
    : { khaytIndex: U.INDEX_FORMAT, serial: 0, issuedAt: null, expires: null, entries: [] };
}

/** A new serial and a fresh expiry, then signed. */
function stamped(index, nowMs, sign, keys) {
  const next = Object.assign({}, index, {
    khaytIndex: U.INDEX_FORMAT,
    serial: (Number.isInteger(index.serial) ? index.serial : 0) + 1,
    issuedAt: new Date(nowMs).toISOString(),
    expires: new Date(nowMs + U.EXPIRY_DAYS * DAY).toISOString(),
  });
  return signIndex(next, sign, keys);
}

function parseRequires(arg) {
  const out = {};
  for (const part of String(arg || '').split(',').filter(Boolean)) {
    const [k, v] = part.split('=');
    if (!k || v === undefined) throw new Error(`--requires: "${part}" is not key=value`);
    out[k] = k === 'schema' ? Number(v) : v;
  }
  return out;
}

/** Sign `manifest`, put it on the site, list it in the index, sign the index. */
function publish(site, manifest, { requires = {}, nowMs = Date.now(), sign, keys, kind = 'connector' } = {}) {
  const v = M.validateManifest(manifest);
  if (!v.ok) throw new Error('manifest does not validate:\n  ' + v.errors.join('\n  '));
  const signed = signManifest(manifest, sign, keys);
  const bytes = Buffer.from(json(signed), 'utf8');
  const file = manifestPath(site, signed.id, signed.version);
  const index = readIndex(site);
  const rows = (index.entries || []).filter((r) => !(r.kind === kind && r.id === signed.id));
  const old = (index.entries || []).find((r) => r.kind === kind && r.id === signed.id);
  if (old && U.compareVersions(signed.version, old.version) <= 0) {
    throw new Error(`${signed.id} ${signed.version} is not newer than the listed ${old.version}`);
  }
  rows.push({
    kind, id: signed.id, version: signed.version,
    requires: Object.assign({ schema: M.MANIFEST_VERSION }, requires),
    url: `${FEED_BASE}${encodeURIComponent(signed.id)}/${encodeURIComponent(signed.version)}.json`,
    sha256: sha256(bytes), size: bytes.length,
    ...(old && Array.isArray(old.revoked) && old.revoked.length ? { revoked: old.revoked } : {}),
  });
  rows.sort((a, b) => (a.kind + a.id).localeCompare(b.kind + b.id));
  const next = stamped(Object.assign({}, index, { entries: rows }), nowMs, sign, keys);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.writeFileSync(indexPath(site), json(next));
  return next;
}

function refreshIndex(site, { nowMs = Date.now(), sign, keys } = {}) {
  const next = stamped(readIndex(site), nowMs, sign, keys);
  fs.writeFileSync(indexPath(site), json(next));
  return next;
}

function revoke(site, id, version, reason, { nowMs = Date.now(), sign, keys, kind = 'connector' } = {}) {
  if (!String(reason || '').trim()) throw new Error('a revocation says why');
  const index = readIndex(site);
  const row = (index.entries || []).find((r) => r.kind === kind && r.id === id);
  if (!row) throw new Error(`${id} is not in the index`);
  row.revoked = (Array.isArray(row.revoked) ? row.revoked : []).filter((x) => x.version !== version)
    .concat([{ version, reason: String(reason).trim() }]);
  const next = stamped(index, nowMs, sign, keys);
  fs.writeFileSync(indexPath(site), json(next));
  return next;
}

/**
 * Everything a device would check, and the files behind it. Returns `{ ok,
 * problems, warnings }`; a warning is an index that expires within
 * EXPIRY_DAYS − RESIGN_DAYS days (time to run refresh-index).
 */
function verifySite(site, { nowMs = Date.now(), keys } = {}) {
  const problems = []; const warnings = [];
  let index;
  try { index = JSON.parse(fs.readFileSync(indexPath(site), 'utf8')); } catch (e) {
    return { ok: false, problems: [`connectors/index.json: ${e.message}`], warnings };
  }
  const by = verifyIndex(index, keys);
  const verdict = U.checkIndex(index, { signedBy: by, nowMs });
  if (!verdict.ok) problems.push(`index: ${verdict.reason}`);
  const left = Date.parse(index.expires) - nowMs;
  if (verdict.ok && left < (U.EXPIRY_DAYS - U.RESIGN_DAYS) * DAY) {
    warnings.push(`index expires in ${Math.floor(left / DAY)} days: run refresh-index`);
  }
  for (const r of Array.isArray(index.entries) ? index.entries : []) {
    if (!r || !U.KINDS.includes(r.kind)) continue;
    const where = `${r.kind} ${r.id} ${r.version}`;
    const prefix = `${FEED_BASE}${encodeURIComponent(r.id)}/`;
    if (r.url !== `${prefix}${encodeURIComponent(r.version)}.json`) { problems.push(`${where}: url is not ${prefix}<version>.json`); continue; }
    let bytes;
    try { bytes = fs.readFileSync(manifestPath(site, r.id, r.version)); } catch (_) { problems.push(`${where}: file missing`); continue; }
    if (sha256(bytes) !== r.sha256) problems.push(`${where}: sha256 does not match the file`);
    if (r.size !== undefined && r.size !== bytes.length) problems.push(`${where}: size does not match the file`);
    let m;
    try { m = JSON.parse(bytes.toString('utf8')); } catch (_) { problems.push(`${where}: not JSON`); continue; }
    if (m.id !== r.id || m.version !== r.version) problems.push(`${where}: the file is ${m.id} ${m.version}`);
    if (r.kind === 'connector') {
      const v = M.validateManifest(m);
      if (!v.ok) problems.push(`${where}: does not validate: ${v.errors[0]}`);
    }
    if (!verify(m, keys)) problems.push(`${where}: not signed by a published key`);
  }
  return { ok: problems.length === 0, problems, warnings };
}

function siteArg(args) {
  const i = args.indexOf('--site');
  if (i < 0 || !args[i + 1]) throw new Error('--site DIR is required');
  return args[i + 1];
}

function main() {
  const args = process.argv.slice(2);
  const cmd = args[0];
  try {
    if (cmd === 'verify-index') {
      const r = verifySite(siteArg(args));
      r.warnings.forEach((w) => console.log('warning: ' + w));
      r.problems.forEach((p) => console.error('problem: ' + p));
      console.log(r.ok ? 'connector index OK' : 'connector index NOT OK');
      process.exit(r.ok ? 0 : 1);
    }
    if (cmd === 'publish') {
      const file = args[1];
      const ri = args.indexOf('--requires');
      const next = publish(siteArg(args), JSON.parse(fs.readFileSync(file, 'utf8')),
        { requires: ri >= 0 ? parseRequires(args[ri + 1]) : {}, sign: keychainSigner() });
      console.log(`published; index serial ${next.serial}, expires ${next.expires}`);
      return;
    }
    if (cmd === 'refresh-index') {
      const next = refreshIndex(siteArg(args), { sign: keychainSigner() });
      console.log(`index serial ${next.serial}, expires ${next.expires}`);
      return;
    }
    if (cmd === 'revoke') {
      const next = revoke(siteArg(args), args[1], args[2], args[3], { sign: keychainSigner() });
      console.log(`revoked ${args[1]} ${args[2]}; index serial ${next.serial}`);
      return;
    }
    // The original single-manifest commands.
    const verifyOnly = args.includes('--verify');
    const file = args.find((a) => !a.startsWith('--'));
    if (!file) { console.error('usage: see the header of scripts/sign-connector.js'); process.exit(2); }
    const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
    const v = M.validateManifest(manifest);
    if (!v.ok) { console.error('manifest does not validate:\n  ' + v.errors.join('\n  ')); process.exit(1); }
    if (verifyOnly) {
      const id = verify(manifest);
      console.log(id ? `signed by ${id}` : 'NOT signed by a published key');
      process.exit(id ? 0 : 1);
    }
    const signed = signManifest(manifest, keychainSigner());
    fs.writeFileSync(file, json(signed));
    console.log(`signed ${manifest.id} ${manifest.version} with ${verify(signed)}`);
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}

if (require.main === module) main();
module.exports = { verify, verifyIndex, publicKeyOf, signManifest, signIndex, publish, refreshIndex, revoke, verifySite, parseRequires };
