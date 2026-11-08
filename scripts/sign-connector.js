#!/usr/bin/env node
'use strict';
/**
 * Sign a reviewed connector manifest: `node scripts/sign-connector.js path/to/manifest.json`.
 *
 * The private key is read from the login Keychain ("Khayt connector signing
 * key") straight into this process — it is never printed, logged or written
 * to disk. The manifest must validate first; the signature goes into
 * `signature` and is checked against lib SIGNING_KEYS before the file is
 * rewritten, so a key that does not match the published one signs nothing.
 *
 * `--verify` only checks an existing signature.
 */
const fs = require('fs');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const M = require('../lib/plugin-manifest');

const SERVICE = 'Khayt connector signing key';
// DER prefixes that wrap a raw ed25519 key for node:crypto.
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function publicKeyOf(b64) {
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_PREFIX, Buffer.from(b64, 'base64')]), format: 'der', type: 'spki' });
}

/** Which published key, if any, this manifest's signature verifies against. */
function verify(manifest) {
  if (typeof manifest.signature !== 'string') return null;
  const msg = Buffer.from(M.canonicalJSON(manifest), 'utf8');
  const sig = Buffer.from(manifest.signature, 'base64');
  const hit = M.SIGNING_KEYS.find(k => crypto.verify(null, msg, publicKeyOf(k.key), sig));
  return hit ? hit.id : null;
}

function main() {
  const args = process.argv.slice(2);
  const verifyOnly = args.includes('--verify');
  const file = args.find(a => !a.startsWith('--'));
  if (!file) { console.error('usage: sign-connector.js [--verify] manifest.json'); process.exit(2); }
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  const v = M.validateManifest(manifest);
  if (!v.ok) { console.error('manifest does not validate:\n  ' + v.errors.join('\n  ')); process.exit(1); }
  if (verifyOnly) {
    const id = verify(manifest);
    console.log(id ? `signed by ${id}` : 'NOT signed by a published key');
    process.exit(id ? 0 : 1);
  }
  const seed = Buffer.from(execFileSync('security', ['find-generic-password', '-s', SERVICE, '-w'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(), 'base64');
  const priv = crypto.createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: 'der', type: 'pkcs8' });
  seed.fill(0);
  const unsigned = Object.assign({}, manifest); delete unsigned.signature;
  const signature = crypto.sign(null, Buffer.from(M.canonicalJSON(unsigned), 'utf8'), priv).toString('base64');
  const signed = Object.assign({}, unsigned, { signature });
  const id = verify(signed);
  if (!id) { console.error('the Keychain key is not one of lib SIGNING_KEYS; nothing written'); process.exit(1); }
  fs.writeFileSync(file, JSON.stringify(signed, null, 2) + '\n');
  console.log(`signed ${manifest.id} ${manifest.version} with ${id}`);
}

if (require.main === module) main();
module.exports = { verify, publicKeyOf };
