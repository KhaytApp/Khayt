'use strict';
(function () {

/**
 * Khayt Vault — the encryption format for files a shop keeps in the cloud and
 * shares by link. docs/vault-format.md is the byte-level spec; this file and
 * mac/KhaytCore/Sources/KhaytCore/VaultCrypto.swift are its two twins, pinned
 * by test/fixtures/vault-crypto-vectors.json.
 *
 * WebCrypto only (`globalThis.crypto.subtle`), so it runs unchanged in a
 * browser page and in Node 20+. It is NOT for JavaScriptCore: JSC has no
 * WebCrypto, which is why the Mac has a native CryptoKit twin instead of
 * running this file.
 *
 * THE ROOT KEY is the shop's DEK — the 32 random bytes that lib/sync-crypto.js
 * wraps under the passphrase, the recovery key and (for an org member) the
 * ODK. It is the only shop key that survives a passphrase change, and every
 * device that can read the shop's store already holds it, so the vault opens
 * wherever the book does. The vault never uses the DEK itself as a cipher key:
 * HKDF with its own salt and label separates the vault key from the store key.
 *
 * Streaming: a file is never needed whole. encryptChunk / decryptChunk take one
 * chunk at a time; the caller keeps the running list of chunk hashes for the
 * manifest. encryptFile / decryptFile are conveniences over the same calls.
 *
 * Every function that draws randomness takes an `opts._nonce` / `opts._dk`
 * style override. Those exist ONLY so the shared vectors can be deterministic;
 * production callers never pass them.
 */

const subtle = (globalThis.crypto && globalThis.crypto.subtle) || null;

const VERSION = 1;
const CHUNK_BYTES = 4194304;     // 4 MiB of plaintext per chunk
const KEY_BYTES = 32;            // AES-256 / HKDF output
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const LINK_SCRYPT = { N: 32768, r: 8, p: 1, keyLen: 32 };

const L = {
  vaultSalt: 'khayt-vault-v1',
  vaultInfo: 'vault',
  dedupeInfo: 'khayt-vault-dedupe-v1',
  chunkAad: 'khayt-vault-v1',
  dkAad: 'khayt-vault-dk',
  metaAad: 'khayt-vault-meta',
  linkInfo: 'khayt-link-v1',
  linkPwSalt: 'khayt-link-pw',
  linkDkAad: 'khayt-link-dk',
};

// ── bytes ────────────────────────────────────────────────────────────────

const utf8 = (s) => new TextEncoder().encode(String(s));
const fromUtf8 = (b) => new TextDecoder('utf-8', { fatal: true }).decode(b);

function toBytes(x) {
  if (x instanceof Uint8Array) return x;
  if (x instanceof ArrayBuffer) return new Uint8Array(x);
  if (ArrayBuffer.isView(x)) return new Uint8Array(x.buffer, x.byteOffset, x.byteLength);
  throw new TypeError('expected bytes (Uint8Array)');
}
function concat(...parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
function hex(bytes) {
  const b = toBytes(bytes);
  let s = '';
  for (let i = 0; i < b.length; i++) s += (b[i] < 16 ? '0' : '') + b[i].toString(16);
  return s;
}
function unhex(s) {
  const str = String(s);
  if (str.length % 2 || /[^0-9a-f]/i.test(str)) throw new Error('bad hex');
  const out = new Uint8Array(str.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
  return out;
}
function b64url(bytes) {
  const b = toBytes(bytes);
  let bin = '';
  for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function unb64url(s) {
  const str = String(s);
  if (/[^A-Za-z0-9_-]/.test(str)) throw new Error('bad base64url');
  const pad = str.length % 4 === 0 ? '' : '='.repeat(4 - (str.length % 4));
  const bin = atob(str.replace(/-/g, '+').replace(/_/g, '/') + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function randomBytes(n) {
  return globalThis.crypto.getRandomValues(new Uint8Array(n));
}

function need() { if (!subtle) throw new Error('WebCrypto subtle unavailable'); }
function key32(k, what) {
  const b = toBytes(k);
  if (b.length !== KEY_BYTES) throw new Error(`${what} must be ${KEY_BYTES} bytes`);
  return b;
}
/**
 * IDs go into `|`-joined AAD strings. An ID containing `|` would let two
 * different (fileId, uploadId) pairs produce the same AAD — "a|b"+"c" and
 * "a"+"b|c" — so such an ID is refused rather than encoded.
 */
function id(v, what) {
  if (typeof v !== 'string' || v.length === 0) throw new Error(`${what} must be a non-empty string`);
  if (v.indexOf('|') !== -1) throw new Error(`${what} must not contain "|"`);
  return v;
}
function index(i) {
  if (!Number.isSafeInteger(i) || i < 0) throw new Error('chunk index must be a non-negative integer');
  return i;
}

// ── primitives ───────────────────────────────────────────────────────────

async function sha256(bytes) {
  need();
  return new Uint8Array(await subtle.digest('SHA-256', toBytes(bytes)));
}

/** HKDF-SHA256 (RFC 5869) → `len` bytes. An empty salt is HashLen zeros. */
async function hkdf(ikm, salt, info, len = KEY_BYTES) {
  need();
  const k = await subtle.importKey('raw', toBytes(ikm), 'HKDF', false, ['deriveBits']);
  const bits = await subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: toBytes(salt), info: toBytes(info) }, k, len * 8);
  return new Uint8Array(bits);
}

async function hmacSha256(keyBytes, data) {
  need();
  const k = await subtle.importKey('raw', toBytes(keyBytes), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await subtle.sign('HMAC', k, toBytes(data)));
}

/** AES-256-GCM seal → ct || tag(16). */
async function gcmSeal(keyBytes, nonce, plaintext, aad) {
  need();
  const k = await subtle.importKey('raw', key32(keyBytes, 'key'), { name: 'AES-GCM' }, false, ['encrypt']);
  return new Uint8Array(await subtle.encrypt(
    { name: 'AES-GCM', iv: toBytes(nonce), additionalData: toBytes(aad), tagLength: 128 }, k, toBytes(plaintext)));
}

/** AES-256-GCM open of ct || tag(16); throws on any mismatch. */
async function gcmOpen(keyBytes, nonce, sealed, aad) {
  need();
  const s = toBytes(sealed);
  if (s.length < TAG_BYTES) throw new Error('vault: sealed data is shorter than its tag');
  const k = await subtle.importKey('raw', key32(keyBytes, 'key'), { name: 'AES-GCM' }, false, ['decrypt']);
  try {
    return new Uint8Array(await subtle.decrypt(
      { name: 'AES-GCM', iv: toBytes(nonce), additionalData: toBytes(aad), tagLength: 128 }, k, s));
  } catch (_) {
    // WebCrypto says only OperationError; a wrong key, a wrong AAD and
    // tampering are indistinguishable by design.
    throw new Error('vault: authentication failed (wrong key, wrong position/ids, or tampered)');
  }
}

// ── keys ─────────────────────────────────────────────────────────────────

/** vaultKey = HKDF(DEK, salt "khayt-vault-v1", info "vault"). */
async function deriveVaultKey(shopDek) {
  return hkdf(key32(shopDek, 'shop DEK'), utf8(L.vaultSalt), utf8(L.vaultInfo));
}

/** A fresh data key. Call once per UPLOAD ATTEMPT, never reuse: chunk nonces
 *  are counters, so they are unique only because the key is. */
function newDataKey() { return randomBytes(KEY_BYTES); }

function newLinkSecret() { return randomBytes(KEY_BYTES); }

/**
 * linkKey for a grant.
 *   no password: HKDF(linkSecret, salt=utf8(grantId), info "khayt-link-v1")
 *   password:    p = scrypt(NFC(password), "khayt-link-pw|"+grantId, 2^15, 8, 1, 32)
 *                HKDF(linkSecret || p, salt=utf8(grantId), info "khayt-link-v1")
 *
 * opts.scrypt (async|sync (pw, salt, {N,r,p,keyLen}) → bytes) may be injected;
 * otherwise lib/scrypt-js.js is used with a WebCrypto PBKDF2. opts._scryptN
 * lowers N for fast tests only — the vectors use the real cost.
 */
async function deriveLinkKey(linkSecret, grantId, password, opts = {}) {
  const secret = key32(linkSecret, 'link secret');
  id(grantId, 'grantId');
  const salt = utf8(grantId);
  if (password == null) return hkdf(secret, salt, utf8(L.linkInfo));
  if (typeof password !== 'string' || password.length === 0) {
    throw new Error('a link password must be a non-empty string (pass null for none)');
  }
  const kdf = { ...LINK_SCRYPT, ...(opts._scryptN ? { N: opts._scryptN } : {}) };
  const scrypt = opts.scrypt || defaultScrypt;
  const p = key32(await scrypt(utf8(password.normalize('NFC')), utf8(L.linkPwSalt + '|' + grantId), kdf),
    'scrypt output');
  return hkdf(concat(secret, p), salt, utf8(L.linkInfo));
}

async function defaultScrypt(pw, salt, kdf) {
  let impl = globalThis.KhaytScrypt;
  if (!impl && typeof require === 'function') impl = require('./scrypt-js.js');
  if (!impl || typeof impl.scrypt !== 'function') throw new Error('scrypt unavailable: load lib/scrypt-js.js');
  const pbkdf2 = async (password, s, iterations, dkLen) => {
    need();
    const k = await subtle.importKey('raw', toBytes(password), 'PBKDF2', false, ['deriveBits']);
    return new Uint8Array(await subtle.deriveBits(
      { name: 'PBKDF2', hash: 'SHA-256', salt: toBytes(s), iterations }, k, dkLen * 8));
  };
  return impl.scrypt(pw, salt, kdf, pbkdf2);
}

// ── dedupe ───────────────────────────────────────────────────────────────

async function deriveDedupeKey(vaultKey) {
  return hkdf(key32(vaultKey, 'vault key'), new Uint8Array(0), utf8(L.dedupeInfo));
}

/** dedupeTag from a precomputed sha256(plaintext) — WebCrypto has no
 *  incremental SHA-256, so a streaming caller hashes with its own. */
async function dedupeTagFromDigest(vaultKey, plaintextSha256) {
  const d = toBytes(plaintextSha256);
  if (d.length !== 32) throw new Error('digest must be 32 bytes');
  return hex(await hmacSha256(await deriveDedupeKey(vaultKey), d));
}

async function dedupeTag(vaultKey, plaintext) {
  return dedupeTagFromDigest(vaultKey, await sha256(plaintext));
}

// ── chunks ───────────────────────────────────────────────────────────────

function chunkNonce(i) {
  const n = new Uint8Array(NONCE_BYTES);
  new DataView(n.buffer).setBigUint64(4, BigInt(index(i)), false);
  return n;
}
function chunkAad(fileId, uploadId, i, last) {
  return utf8(L.chunkAad + '|' + id(fileId, 'fileId') + '|' + id(uploadId, 'uploadId') + '|'
    + index(i) + '|' + (last ? '1' : '0'));
}

/** How many chunks a file of `size` bytes has. An empty file has one. */
function chunkCount(size, chunkBytes = CHUNK_BYTES) {
  if (!Number.isSafeInteger(size) || size < 0) throw new Error('size must be a non-negative integer');
  if (!Number.isSafeInteger(chunkBytes) || chunkBytes < 1) throw new Error('chunkBytes must be positive');
  return size === 0 ? 1 : Math.ceil(size / chunkBytes);
}

/** Seal chunk `i` of a file. Returns ct || tag. `last` is required — it is
 *  what makes a truncated file fail rather than read as a shorter one. */
async function encryptChunk(dk, fileId, uploadId, i, last, plaintext) {
  if (typeof last !== 'boolean') throw new Error('last must be a boolean');
  return gcmSeal(key32(dk, 'data key'), chunkNonce(i), toBytes(plaintext), chunkAad(fileId, uploadId, i, last));
}

/** Open chunk `i`. The caller states the position it expects (index, last);
 *  a chunk from any other position, file or upload fails authentication. */
async function decryptChunk(dk, fileId, uploadId, i, last, sealed) {
  if (typeof last !== 'boolean') throw new Error('last must be a boolean');
  return gcmOpen(key32(dk, 'data key'), chunkNonce(i), sealed, chunkAad(fileId, uploadId, i, last));
}

/** hex sha256 of one sealed chunk (ct || tag), as the manifest lists it. */
async function chunkHash(sealed) { return hex(await sha256(sealed)); }

// ── manifest ─────────────────────────────────────────────────────────────

/** The exact manifest bytes: no spaces, keys in this order. */
function manifestJson(size, chunkHashes, chunkBytes = CHUNK_BYTES) {
  if (!Array.isArray(chunkHashes)) throw new Error('chunkHashes must be an array');
  if (chunkHashes.length !== chunkCount(size, chunkBytes)) throw new Error('chunk count does not match size');
  for (const h of chunkHashes) {
    if (typeof h !== 'string' || !/^[0-9a-f]{64}$/.test(h)) throw new Error('chunk hash must be 64 lowercase hex');
  }
  return '{"v":' + VERSION + ',"chunkBytes":' + chunkBytes + ',"size":' + size
    + ',"chunks":[' + chunkHashes.map((h) => '"' + h + '"').join(',') + ']}';
}

async function manifestHash(size, chunkHashes, chunkBytes = CHUNK_BYTES) {
  return hex(await sha256(utf8(manifestJson(size, chunkHashes, chunkBytes))));
}

// ── whole-file conveniences (same calls, in order) ───────────────────────

async function encryptFile(dk, fileId, uploadId, plaintext, opts = {}) {
  const chunkBytes = opts.chunkBytes || CHUNK_BYTES;
  const pt = toBytes(plaintext);
  const n = chunkCount(pt.length, chunkBytes);
  const chunks = [];
  const hashes = [];
  for (let i = 0; i < n; i++) {
    const sealed = await encryptChunk(dk, fileId, uploadId, i, i === n - 1,
      pt.subarray(i * chunkBytes, Math.min(pt.length, (i + 1) * chunkBytes)));
    chunks.push(sealed);
    hashes.push(await chunkHash(sealed));
  }
  return { chunks, chunkHashes: hashes, size: pt.length,
    manifestHash: await manifestHash(pt.length, hashes, chunkBytes) };
}

/**
 * Open a whole file against its manifest. `manifest` is { size, chunks:[hex] }
 * as the server returned it, and `expectedManifestHash` — from an
 * authenticated place (the encrypted meta record) — pins it. Every check is
 * made before a byte is returned.
 */
async function decryptFile(dk, fileId, uploadId, sealedChunks, manifest, expectedManifestHash, opts = {}) {
  const chunkBytes = opts.chunkBytes || CHUNK_BYTES;
  if (!manifest || !Array.isArray(manifest.chunks)) throw new Error('manifest required');
  const mh = await manifestHash(manifest.size, manifest.chunks, chunkBytes);
  if (typeof expectedManifestHash !== 'string' || mh !== expectedManifestHash) {
    throw new Error('vault: manifest does not match its hash');
  }
  const n = manifest.chunks.length;
  if (!Array.isArray(sealedChunks) || sealedChunks.length !== n) throw new Error('vault: chunk count mismatch');
  const parts = [];
  let total = 0;
  for (let i = 0; i < n; i++) {
    const sealed = toBytes(sealedChunks[i]);
    if ((await chunkHash(sealed)) !== manifest.chunks[i]) throw new Error(`vault: chunk ${i} does not match the manifest`);
    const pt = await decryptChunk(dk, fileId, uploadId, i, i === n - 1, sealed);
    if (i < n - 1 && pt.length !== chunkBytes) throw new Error(`vault: chunk ${i} is not full`);
    total += pt.length;
    parts.push(pt);
  }
  if (total !== manifest.size) throw new Error('vault: size mismatch');
  return concat(...parts);
}

// ── key wraps ────────────────────────────────────────────────────────────

/** nonce(12) || AES-GCM(kek, nonce, key, aad) || tag(16) — 60 bytes for a 32-byte key. */
async function wrapKey(kek, keyBytes, aad, opts = {}) {
  const nonce = opts._nonce ? toBytes(opts._nonce) : randomBytes(NONCE_BYTES);
  if (nonce.length !== NONCE_BYTES) throw new Error('nonce must be 12 bytes');
  return concat(nonce, await gcmSeal(kek, nonce, key32(keyBytes, 'wrapped key'), toBytes(aad)));
}

async function unwrapKey(kek, wrapped, aad) {
  const w = toBytes(wrapped);
  if (w.length !== NONCE_BYTES + KEY_BYTES + TAG_BYTES) throw new Error('vault: wrapped key has the wrong length');
  return gcmOpen(kek, w.subarray(0, NONCE_BYTES), w.subarray(NONCE_BYTES), toBytes(aad));
}

const shopDkAad = (fileId, uploadId) => utf8(L.dkAad + '|' + id(fileId, 'fileId') + '|' + id(uploadId, 'uploadId'));
const grantDkAad = (grantId, fileId) => utf8(L.linkDkAad + '|' + id(grantId, 'grantId') + '|' + id(fileId, 'fileId'));

const wrapDkForShop = async (vaultKey, dk, fileId, uploadId, opts) => wrapKey(vaultKey, dk, shopDkAad(fileId, uploadId), opts);
const unwrapDkForShop = async (vaultKey, wrapped, fileId, uploadId) => unwrapKey(vaultKey, wrapped, shopDkAad(fileId, uploadId));
const wrapDkForGrant = async (linkKey, dk, grantId, fileId, opts) => wrapKey(linkKey, dk, grantDkAad(grantId, fileId), opts);
const unwrapDkForGrant = async (linkKey, wrapped, grantId, fileId) => unwrapKey(linkKey, wrapped, grantDkAad(grantId, fileId));

// ── metadata record ──────────────────────────────────────────────────────

/** nonce(12) || ct || tag(16), aad "khayt-vault-meta|"+fileId. `json` is a
 *  string sealed byte for byte, or a value that is JSON.stringify'd. */
async function encryptMeta(vaultKey, fileId, json, opts = {}) {
  const text = typeof json === 'string' ? json : JSON.stringify(json);
  const nonce = opts._nonce ? toBytes(opts._nonce) : randomBytes(NONCE_BYTES);
  if (nonce.length !== NONCE_BYTES) throw new Error('nonce must be 12 bytes');
  const aad = utf8(L.metaAad + '|' + id(fileId, 'fileId'));
  return concat(nonce, await gcmSeal(vaultKey, nonce, utf8(text), aad));
}

/** The record's JSON text, verified. JSON.parse it if you want the value. */
async function decryptMetaText(vaultKey, fileId, sealed) {
  const s = toBytes(sealed);
  if (s.length < NONCE_BYTES + TAG_BYTES) throw new Error('vault: meta record too short');
  const aad = utf8(L.metaAad + '|' + id(fileId, 'fileId'));
  return fromUtf8(await gcmOpen(vaultKey, s.subarray(0, NONCE_BYTES), s.subarray(NONCE_BYTES), aad));
}

async function decryptMeta(vaultKey, fileId, sealed) {
  return JSON.parse(await decryptMetaText(vaultKey, fileId, sealed));
}

const api = {
  VERSION, CHUNK_BYTES, LABELS: Object.freeze({ ...L }), LINK_SCRYPT: Object.freeze({ ...LINK_SCRYPT }),
  deriveVaultKey, deriveDedupeKey, deriveLinkKey, newDataKey, newLinkSecret,
  dedupeTag, dedupeTagFromDigest,
  chunkCount, chunkNonce, encryptChunk, decryptChunk, chunkHash,
  manifestJson, manifestHash, encryptFile, decryptFile,
  wrapKey, unwrapKey, wrapDkForShop, unwrapDkForShop, wrapDkForGrant, unwrapDkForGrant,
  encryptMeta, decryptMeta, decryptMetaText,
  sha256, hex, unhex, b64url, unb64url,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytVault = api;

})();
