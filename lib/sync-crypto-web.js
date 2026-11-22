'use strict';
(function () {

/**
 * Browser-side DECRYPT path for Khayt Cloud E2E — the foundation for the
 * remote-mobile PWA (read-only first). Byte-compatible with lib/sync-crypto.js:
 *   - AES-256-GCM via WebCrypto `crypto.subtle` (available in browsers + Node 16+).
 *   - The scrypt KDF is INJECTED (`scrypt(secretBytes, saltBytes, kdf) -> bytes`)
 *     so this module stays dependency-free; the PWA passes a JS scrypt
 *     (e.g. scrypt-js), and tests pass Node's scryptSync. Same params + salt ⇒
 *     identical KEK, so it unwraps exactly what the desktop wrapped.
 *
 * Decrypt + encrypt: the mobile client reads the store, and (for limited writes)
 * re-encrypts in a format byte-compatible with lib/sync-crypto.js so the desktop
 * can read what the phone wrote.
 */

const subtle = (globalThis.crypto && globalThis.crypto.subtle) || null;
// The stamp that goes on an encrypted store blob, matching STORE_BLOB_VERSION in
// lib/sync-crypto.js. It used to be called KEYSET_VERSION in both files, which
// was only ever right while the two numbers happened to agree; the desktop
// keyset is now v2 (it can carry an org slot) while the blob format has not
// changed. This file never creates keysets, so the blob stamp is the only one
// it needs.
const STORE_BLOB_VERSION = 1;
// Must match STORE_COMPRESSION in lib/sync-crypto.js — the marker the desktop
// writes and this reads. test/sync-crypto-web.test.js holds the two in step.
const STORE_COMPRESSION = 'gzip';

function unb64(s) {
  if (typeof Buffer !== 'undefined') return new Uint8Array(Buffer.from(String(s), 'base64'));
  const bin = atob(String(s));
  const a = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) a[i] = bin.charCodeAt(i);
  return a;
}
function b64(bytes) {
  const a = toBytes(bytes);
  if (typeof Buffer !== 'undefined') return Buffer.from(a).toString('base64');
  let s = '';
  for (let i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
  return btoa(s);
}
function toBytes(x) {
  if (x instanceof Uint8Array) return x;
  if (typeof Buffer !== 'undefined' && Buffer.isBuffer(x)) return new Uint8Array(x);
  return new Uint8Array(x);
}
const utf8 = (s) => new TextEncoder().encode(String(s));
const fromUtf8 = (bytes) => new TextDecoder().decode(bytes);

/** AES-256-GCM decrypt of a { iv, ct, tag } envelope (all base64). Throws on
 *  wrong key / tamper (GCM auth). WebCrypto wants ct||tag concatenated. */
async function gcmDecrypt(blob, keyBytes) {
  if (!subtle) throw new Error('WebCrypto subtle unavailable');
  const key = await subtle.importKey('raw', toBytes(keyBytes), { name: 'AES-GCM' }, false, ['decrypt']);
  const ct = unb64(blob.ct);
  const tag = unb64(blob.tag);
  const combined = new Uint8Array(ct.length + tag.length);
  combined.set(ct, 0);
  combined.set(tag, ct.length);
  const pt = await subtle.decrypt({ name: 'AES-GCM', iv: unb64(blob.iv), tagLength: 128 }, key, combined);
  return new Uint8Array(pt);
}

/** Unwrap the DEK from a keyset using the sync passphrase. `scrypt` is injected:
 *  async|sync (secretBytes, saltBytes, kdf{N,r,p,keyLen}) -> 32 bytes. */
async function unlockDek(opts) {
  const keyset = opts.keyset || {};
  const w = keyset.wrappedByPassphrase;
  if (!w) throw new Error('keyset missing wrappedByPassphrase');
  const kdf = keyset.kdf || {};
  if (kdf.algo && kdf.algo !== 'scrypt') throw new Error('unsupported KDF: ' + kdf.algo);
  if (typeof opts.scrypt !== 'function') throw new Error('scrypt function required');
  const kek = await opts.scrypt(utf8(opts.passphrase), unb64(w.salt), kdf);
  return gcmDecrypt(w, toBytes(kek)); // throws on wrong passphrase (GCM tag)
}

/**
 * Ungzip in the browser. DecompressionStream is the only gunzip a page gets
 * without shipping a library, and Khayt's remote-mobile page is deliberately
 * dependency-free — so if it is missing, say which capability is absent rather
 * than letting JSON.parse fail on binary and report a syntax error.
 */
async function gunzip(bytes) {
  if (typeof DecompressionStream !== 'function') {
    throw new Error('this browser cannot read a compressed store (no DecompressionStream)');
  }
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

/**
 * Decrypt a store blob. Reads both the uncompressed shape and the gzipped one
 * the desktop will start writing — see the rollout note in lib/sync-crypto.js.
 * The `z` marker is plaintext metadata on the envelope, so this knows how to
 * treat the payload before it has one.
 */
async function decryptStore(blob, dek) {
  const pt = await gcmDecrypt(blob, dek);
  const raw = (blob && blob.z === STORE_COMPRESSION) ? await gunzip(pt) : pt;
  return JSON.parse(fromUtf8(raw));
}

/** AES-256-GCM encrypt → { iv, ct, tag } (base64), matching lib/sync-crypto.js
 *  (ct and tag split; random 12-byte IV). */
async function gcmEncrypt(plaintextBytes, keyBytes) {
  if (!subtle) throw new Error('WebCrypto subtle unavailable');
  const key = await subtle.importKey('raw', toBytes(keyBytes), { name: 'AES-GCM' }, false, ['encrypt']);
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const out = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv: iv, tagLength: 128 }, key, toBytes(plaintextBytes)));
  const ct = out.slice(0, out.length - 16);
  const tag = out.slice(out.length - 16);
  return { iv: b64(iv), ct: b64(ct), tag: b64(tag) };
}

/** Encrypt a store object with the DEK → an opaque blob for upload. */
async function encryptStore(obj, dek) {
  const ct = await gcmEncrypt(new TextEncoder().encode(JSON.stringify(obj)), dek);
  return { v: STORE_BLOB_VERSION, ...ct };
}

const api = { gcmDecrypt, gcmEncrypt, unlockDek, decryptStore, encryptStore, _unb64: unb64 };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytSyncWeb = api;

})();
