#!/usr/bin/env node
'use strict';
/**
 * Is this Sparkle feed signed, by the key the Mac app holds?
 *
 * The feed for the native Mac app is signed when it is published
 * (`sign_update`, in mac-publish.yml and mac-release.yml). This checks one
 * with the PUBLIC key only, so it can run anywhere: in the publish lane after
 * signing, in tests, and against the live feed.
 *
 *   node scripts/mac-appcast-verify.js --feed appcast.xml
 *   node scripts/mac-appcast-verify.js --url https://khaytapp.com/mac/appcast.xml
 *   … [--public-key <base64>]   default: SUPublicEDKey in mac/make-app.sh
 *
 * HOW SPARKLE SIGNS A FEED (read in Sparkle 2.9.6: common_cli/Signing.swift
 * `signAppcast`, Sparkle/SPUExtractSignedFeed.m, Sparkle/SUAppcastDriver.m).
 * The signature is a comment at the END of the file:
 *
 *     <!-- sparkle-signatures:
 *     edSignature: <base64 Ed25519 signature>
 *     length: <byte count of everything before this comment>
 *     -->
 *
 * and it covers every byte before that comment. `extract` finds it the way
 * Sparkle does (the LAST such comment, then the first `-->` after it), so
 * this and the app agree about which bytes were signed.
 *
 * It only reads. Nothing here signs anything, and no private key is ever
 * given to it.
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PREFIX = Buffer.from('<!-- sparkle-signatures:\n', 'utf8');
const SUFFIX = Buffer.from('-->', 'utf8');
// SubjectPublicKeyInfo for a raw 32-byte Ed25519 key (RFC 8410).
const SPKI = Buffer.from('302a300506032b6570032100', 'hex');

/**
 * @param {Buffer} feed
 * @returns {{ content: Buffer, signature: string|null, length: number }}
 *   `content` is what was signed; the whole file when there is no block.
 */
function extract(feed) {
  const unsigned = { content: feed, signature: null, length: 0 };
  const at = feed.lastIndexOf(PREFIX);
  if (at < 0) return unsigned;
  const end = feed.indexOf(SUFFIX, at + PREFIX.length);
  if (end < 0) return unsigned;
  // A block that is not UTF-8 is no block to Sparkle (it treats the whole
  // file as unsigned), so it is none here.
  let block;
  try { block = new TextDecoder('utf-8', { fatal: true }).decode(feed.subarray(at + PREFIX.length, end)); }
  catch (_) { return unsigned; }
  let signature = null, length = 0;
  for (const line of block.split(/\r\n|\n|\r/)) {
    if (line.startsWith('edSignature:')) signature = line.slice('edSignature:'.length).trim();
    else if (line.startsWith('length:')) length = Number.parseInt(line.slice('length:'.length).trim(), 10) || 0;
  }
  return { content: feed.subarray(0, at), signature, length };
}

/**
 * @param {Buffer} feed
 * @param {string} publicKey  base64 of the raw 32-byte Ed25519 public key (SUPublicEDKey)
 * @returns {{ ok: boolean, reason?: string }}
 */
function verify(feed, publicKey) {
  if (!Buffer.isBuffer(feed) || !feed.length) return { ok: false, reason: 'the feed is empty' };
  const raw = Buffer.from(String(publicKey || ''), 'base64');
  if (raw.length !== 32) return { ok: false, reason: 'the public key is not a 32-byte Ed25519 key' };
  const { content, signature, length } = extract(feed);
  if (!signature) return { ok: false, reason: 'the feed is not signed (no sparkle-signatures block)' };
  // STRICTER THAN SPARKLE, on purpose: the app uses the stated length only to
  // word its error. A block whose length is wrong was not written by
  // sign_update, and that is worth stopping a release for.
  if (length !== content.length) {
    return { ok: false, reason: `the signature says ${length} bytes were signed, the feed has ${content.length} before it` };
  }
  // Strict base64, as the app decodes it (no stray characters): Node's own
  // decoder skips what it does not know and would pass a signature a Mac refuses.
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(signature) || signature.length % 4 !== 0) {
    return { ok: false, reason: 'the signature is not an Ed25519 signature' };
  }
  const sig = Buffer.from(signature, 'base64');
  if (sig.length !== 64) return { ok: false, reason: 'the signature is not an Ed25519 signature' };
  let good = false;
  try {
    const key = crypto.createPublicKey({ key: Buffer.concat([SPKI, raw]), format: 'der', type: 'spki' });
    good = crypto.verify(null, content, key, sig);
  } catch (e) { return { ok: false, reason: `could not verify: ${e.message}` }; }
  if (!good) return { ok: false, reason: 'the signature does not match the feed and this key (edited after signing, or signed with another key)' };
  // A signature over something that is not a feed proves nothing useful, and
  // neither does one over a feed no Mac can parse: both sign and verify.
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(content); }
  catch (_) { return { ok: false, reason: 'what was signed is not UTF-8' }; }
  if (!/<rss[\s>]/.test(text) || !/<enclosure\s/.test(text) || !/<\/rss>\s*$/.test(text)) {
    return { ok: false, reason: 'what was signed is not an update feed' };
  }
  const bad = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/.exec(text);
  if (bad) {
    return { ok: false, reason: `the feed holds a character XML does not allow (U+${bad[0].charCodeAt(0).toString(16).toUpperCase().padStart(4, '0')}): no Mac could parse it` };
  }
  return { ok: true };
}

/** SUPublicEDKey as mac/make-app.sh writes it into the app. */
function publicKeyFromMakeApp(script) {
  const m = /<key>SUPublicEDKey<\/key><string>([A-Za-z0-9+/=]+)<\/string>/.exec(String(script || ''));
  return m ? m[1] : null;
}

module.exports = { extract, verify, publicKeyFromMakeApp, PREFIX };

if (require.main === module) {
  (async () => {
    const args = {};
    for (let i = 2; i < process.argv.length; i += 2) args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
    const key = args['public-key']
      || publicKeyFromMakeApp(fs.readFileSync(path.join(__dirname, '..', 'mac', 'make-app.sh'), 'utf8'));
    if (!key) { console.error('no public key: pass --public-key, or run from a checkout with mac/make-app.sh'); process.exit(2); }
    let feed;
    if (args.feed) feed = fs.readFileSync(args.feed);
    else if (/^https:\/\//.test(String(args.url || ''))) {
      const res = await fetch(args.url, { redirect: 'follow', signal: AbortSignal.timeout(15000) });
      if (!res.ok) { console.error(`${args.url}: HTTP ${res.status}`); process.exit(1); }
      feed = Buffer.from(await res.arrayBuffer());
    } else { console.error('pass --feed <file> or --url <https address>'); process.exit(2); }
    const r = verify(feed, key);
    if (!r.ok) { console.error(`NOT VERIFIED: ${r.reason}`); process.exit(1); }
    console.error(`verified: ${extract(feed).content.length} signed bytes, by the key the Mac app holds`);
  })().catch((e) => { console.error(e.message); process.exit(1); });
}
