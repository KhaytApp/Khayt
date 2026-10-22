'use strict';
(function () {

/**
 * Khayt Vault — the encryption format for files a shop keeps in the cloud and
 * shares by link. docs/vault-format.md is the byte-level spec; this file and
 * mac/KhaytCore/Sources/KhaytCore/VaultCrypto.swift are its two twins, pinned
 * by test/fixtures/vault-crypto-vectors.json (written from node:crypto alone
 * by scripts/gen-vault-crypto-vectors.js).
 *
 * WebCrypto only (`globalThis.crypto.subtle`), so it runs unchanged in a
 * browser page and in Node 20+. It is NOT for JavaScriptCore: JSC has no
 * WebCrypto, which is why the Mac has a native CryptoKit twin instead of
 * running this file.
 *
 * THE ROOT KEY is the shop's DEK — the 32 random bytes that lib/sync-crypto.js
 * wraps under the passphrase, the recovery key and (for an org member) the
 * ODK. vaultKey and dedupeKey are both derived from it directly, under
 * separate labels, and the DEK itself is never a vault cipher key.
 *
 * Streaming: a file is never needed whole. encryptChunk / decryptChunk take one
 * chunk at a time, and createReader() opens a download chunk by chunk and
 * reports success only once the last chunk has opened.
 *
 * Every function that draws randomness takes an `opts._nonce` override. It
 * exists ONLY so the shared vectors can be deterministic; production callers
 * never pass it.
 */

const subtle = (globalThis.crypto && globalThis.crypto.subtle) || null;

const VERSION = 1;
const CHUNK_BYTES = 4194304;     // 4 MiB of plaintext per chunk
const MAX_SIZE = 2 ** 53 - 1;    // the largest size either twin accepts (Number.MAX_SAFE_INTEGER)
const KEY_BYTES = 32;            // AES-256 / HKDF output
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const LINK_SCRYPT = Object.freeze({ N: 32768, r: 8, p: 1, keyLen: 32 });
const LINK_PASSWORD_MIN = 10;    // Unicode scalars, after NFC
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const HEX64_RE = /^[0-9a-f]{64}$/;

const L = {
  vaultSalt: 'khayt-vault-v1',
  vaultInfo: 'vault',
  dedupeInfo: 'dedupe',
  chunkInfo: 'khayt-vault-chunk-v1',
  chunkAad: 'khayt-vault-v1',
  dkAad: 'khayt-vault-dk',
  metaAad: 'khayt-vault-meta',
  vmetaAad: 'khayt-vault-vmeta',
  linkInfo: 'khayt-link-v1',
  linkPwSalt: 'khayt-link-pw',
  linkDkAad: 'khayt-link-dk',
  linkMetaAad: 'khayt-link-meta',
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
 * IDs go into `|`-joined AAD strings and an HKDF salt. Only [A-Za-z0-9_-],
 * 1–64 of them, is accepted: an allow-list, because a deny-list ("no |")
 * misses look-alikes and Unicode the two twins would not see the same way.
 */
function id(v, what) {
  if (typeof v !== 'string' || !ID_RE.test(v)) throw new Error(`${what} must be 1-64 of [A-Za-z0-9_-]`);
  return v;
}
function index(i) {
  if (!Number.isSafeInteger(i) || i < 0) throw new Error('chunk index must be a non-negative integer');
  return i;
}
function sizeOk(size) {
  if (typeof size !== 'number' || !Number.isInteger(size) || size < 0 || size > MAX_SIZE) {
    throw new Error('size must be an integer from 0 to 2^53-1');
  }
  return size;
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

/** nonce(12) || GCM(key, nonce, pt, aad) || tag(16). */
async function sealWithNonce(key, pt, aad, opts = {}) {
  const nonce = opts._nonce ? toBytes(opts._nonce) : randomBytes(NONCE_BYTES);
  if (nonce.length !== NONCE_BYTES) throw new Error('nonce must be 12 bytes');
  return concat(nonce, await gcmSeal(key, nonce, pt, aad));
}
async function openWithNonce(key, sealed, aad) {
  const s = toBytes(sealed);
  if (s.length < NONCE_BYTES + TAG_BYTES) throw new Error('vault: sealed record too short');
  return gcmOpen(key, s.subarray(0, NONCE_BYTES), s.subarray(NONCE_BYTES), aad);
}

// ── keys ─────────────────────────────────────────────────────────────────

/** vaultKey = HKDF(DEK, salt "khayt-vault-v1", info "vault"). */
async function deriveVaultKey(shopDek) {
  return hkdf(key32(shopDek, 'shop DEK'), utf8(L.vaultSalt), utf8(L.vaultInfo));
}

/** dedupeKey = HKDF(DEK, salt "khayt-vault-v1", info "dedupe") — a sibling of
 *  vaultKey, not derived from it. */
async function deriveDedupeKey(shopDek) {
  return hkdf(key32(shopDek, 'shop DEK'), utf8(L.vaultSalt), utf8(L.dedupeInfo));
}

/** chunkKey = HKDF(DK, salt utf8(uploadId), info "khayt-vault-chunk-v1"). */
async function deriveChunkKey(dk, uploadId) {
  return hkdf(key32(dk, 'data key'), utf8(id(uploadId, 'uploadId')), utf8(L.chunkInfo));
}

/** A fresh data key. Call once per UPLOAD ATTEMPT, never reuse: chunk nonces
 *  are counters, so they are unique only because the key is. */
function newDataKey() { return randomBytes(KEY_BYTES); }

function newLinkSecret() { return randomBytes(KEY_BYTES); }

/** A fresh grant id: base64url of 16 random bytes, no padding — 22 characters,
 *  all inside the ID alphabet. */
function newGrantId() { return b64url(randomBytes(16)); }

/**
 * Whether a link password is long enough for the UI to accept: at least 10
 * Unicode scalars after NFC. A leaked link with a short password falls to an
 * offline guess at scrypt 2^15; length is the only defence the format has.
 */
function linkPasswordOk(pw) {
  if (typeof pw !== 'string') return false;
  return [...pw.normalize('NFC')].length >= LINK_PASSWORD_MIN;
}

/**
 * linkKey for a grant. `password` must be given explicitly: null for a link
 * with none, or a non-empty string. `undefined` is refused, so forgetting the
 * argument can never quietly produce a password-less link.
 *   no password: HKDF(linkSecret, salt=utf8(grantId), info "khayt-link-v1")
 *   password:    p = scrypt(NFC(password), "khayt-link-pw|"+grantId, 2^15, 8, 1, 32)
 *                HKDF(linkSecret || p, salt=utf8(grantId), info "khayt-link-v1")
 *
 * opts.scrypt (async|sync (pw, salt, {N,r,p,keyLen}) → bytes) may be injected;
 * it is always called with the format's fixed cost. Otherwise lib/scrypt-js.js
 * runs over a WebCrypto PBKDF2.
 */
async function deriveLinkKey(linkSecret, grantId, password, opts = {}) {
  const secret = key32(linkSecret, 'link secret');
  id(grantId, 'grantId');
  const salt = utf8(grantId);
  if (password === null) return hkdf(secret, salt, utf8(L.linkInfo));
  if (typeof password !== 'string' || password.length === 0) {
    throw new Error('password must be null (no password) or a non-empty string');
  }
  const scrypt = opts.scrypt || defaultScrypt;
  const p = key32(await scrypt(utf8(password.normalize('NFC')), utf8(L.linkPwSalt + '|' + grantId),
    { ...LINK_SCRYPT }), 'scrypt output');
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

/** dedupeTag from a precomputed sha256(plaintext) — WebCrypto has no
 *  incremental SHA-256, so a streaming caller hashes with its own. */
async function dedupeTagFromDigest(shopDek, plaintextSha256) {
  const d = toBytes(plaintextSha256);
  if (d.length !== 32) throw new Error('digest must be 32 bytes');
  return hex(await hmacSha256(await deriveDedupeKey(shopDek), d));
}

async function dedupeTag(shopDek, plaintext) {
  return dedupeTagFromDigest(shopDek, await sha256(plaintext));
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
  sizeOk(size);
  if (!Number.isSafeInteger(chunkBytes) || chunkBytes < 1) throw new Error('chunkBytes must be positive');
  if (size === 0) return 1;
  return Math.floor(size / chunkBytes) + (size % chunkBytes === 0 ? 0 : 1);
}

/** Seal chunk `i` of a file, under the upload's chunk key. Returns ct || tag.
 *  `last` is required — it is what makes a truncated file fail rather than
 *  read as a shorter one. */
async function encryptChunk(dk, fileId, uploadId, i, last, plaintext) {
  if (typeof last !== 'boolean') throw new Error('last must be a boolean');
  const aad = chunkAad(fileId, uploadId, i, last);
  return gcmSeal(await deriveChunkKey(dk, uploadId), chunkNonce(i), toBytes(plaintext), aad);
}

/** Open chunk `i`. The caller states the position it expects (index, last);
 *  a chunk from any other position, file or upload fails authentication. */
async function decryptChunk(dk, fileId, uploadId, i, last, sealed) {
  if (typeof last !== 'boolean') throw new Error('last must be a boolean');
  const aad = chunkAad(fileId, uploadId, i, last);
  return gcmOpen(await deriveChunkKey(dk, uploadId), chunkNonce(i), sealed, aad);
}

/** hex sha256 of one sealed chunk (ct || tag), as the manifest lists it. */
async function chunkHash(sealed) { return hex(await sha256(sealed)); }

// ── manifest ─────────────────────────────────────────────────────────────

/** The exact manifest bytes: no spaces, keys in this order. */
function manifestJson(size, chunkHashes, chunkBytes = CHUNK_BYTES) {
  const n = chunkCount(size, chunkBytes); // size is checked before anything else
  if (!Array.isArray(chunkHashes)) throw new Error('chunkHashes must be an array');
  if (chunkHashes.length !== n) throw new Error('chunk count does not match size');
  for (const h of chunkHashes) {
    if (typeof h !== 'string' || !HEX64_RE.test(h)) throw new Error('chunk hash must be 64 lowercase hex');
  }
  return '{"v":' + VERSION + ',"chunkBytes":' + chunkBytes + ',"size":' + size
    + ',"chunks":[' + chunkHashes.map((h) => '"' + h + '"').join(',') + ']}';
}

async function manifestHash(size, chunkHashes, chunkBytes = CHUNK_BYTES) {
  return hex(await sha256(utf8(manifestJson(size, chunkHashes, chunkBytes))));
}

// ── streaming reader ─────────────────────────────────────────────────────

/**
 * Open a download chunk by chunk. The manifest is checked against
 * `expectedManifestHash` (from an authenticated meta record) up front; each
 * `push(sealed)` then checks the chunk's hash, opens it at its position and
 * returns its plaintext. `finish()` succeeds only once the chunk sealed with
 * last=1 has opened and the total equals `size`; a stream that ends early
 * fails there, and a chunk pushed after the last is refused.
 */
async function createReader(dk, fileId, uploadId, manifest, expectedManifestHash, opts = {}) {
  const chunkBytes = opts.chunkBytes || CHUNK_BYTES;
  if (!manifest || typeof manifest !== 'object') throw new Error('manifest required');
  sizeOk(manifest.size);
  const mh = await manifestHash(manifest.size, manifest.chunks, chunkBytes);
  if (typeof expectedManifestHash !== 'string' || mh !== expectedManifestHash) {
    throw new Error('vault: manifest does not match its hash');
  }
  key32(dk, 'data key'); id(fileId, 'fileId'); id(uploadId, 'uploadId');
  const hashes = manifest.chunks.slice();
  const n = hashes.length;
  let next = 0;
  let total = 0;
  let sawLast = false;
  let failed = false;
  // push is async; a second push before the first settles would read `next`
  // twice. That is a caller bug, so it is refused and the reader is spent.
  let busy = false;
  return {
    get done() { return sawLast && !failed && !busy; },
    async push(sealedIn) {
      if (busy) { failed = true; throw new Error('vault: concurrent push (await each push before the next)'); }
      if (failed) throw new Error('vault: reader already failed');
      if (sawLast) { failed = true; throw new Error('vault: chunk after the last chunk'); }
      busy = true;
      try {
        const sealed = toBytes(sealedIn);
        const i = next;
        if ((await chunkHash(sealed)) !== hashes[i]) throw new Error(`vault: chunk ${i} does not match the manifest`);
        const last = i === n - 1;
        const pt = await decryptChunk(dk, fileId, uploadId, i, last, sealed);
        if (!last && pt.length !== chunkBytes) throw new Error(`vault: chunk ${i} is not full`);
        total += pt.length;
        if (last && total !== manifest.size) throw new Error('vault: size mismatch');
        next = i + 1;
        sawLast = last;
        return pt;
      } catch (e) { failed = true; throw e; } finally { busy = false; }
    },
    finish() {
      if (busy) throw new Error('vault: finish while a push is in flight');
      if (failed) throw new Error('vault: reader failed');
      if (!sawLast) throw new Error('vault: stream ended before the last chunk');
      return { size: total, chunks: next };
    },
  };
}

// ── whole-file conveniences (the same calls, in order) ───────────────────

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

/** Open a whole file through createReader. */
async function decryptFile(dk, fileId, uploadId, sealedChunks, manifest, expectedManifestHash, opts = {}) {
  const r = await createReader(dk, fileId, uploadId, manifest, expectedManifestHash, opts);
  if (!Array.isArray(sealedChunks) || sealedChunks.length !== manifest.chunks.length) {
    throw new Error('vault: chunk count mismatch');
  }
  const parts = [];
  for (const c of sealedChunks) parts.push(await r.push(c));
  r.finish();
  return concat(...parts);
}

// ── key wraps ────────────────────────────────────────────────────────────

/** nonce(12) || AES-GCM(kek, nonce, key, aad) || tag(16) — 60 bytes for a 32-byte key. */
async function wrapKey(kek, keyBytes, aad, opts = {}) {
  return sealWithNonce(kek, key32(keyBytes, 'wrapped key'), toBytes(aad), opts);
}

async function unwrapKey(kek, wrapped, aad) {
  const w = toBytes(wrapped);
  if (w.length !== NONCE_BYTES + KEY_BYTES + TAG_BYTES) throw new Error('vault: wrapped key has the wrong length');
  return openWithNonce(kek, w, toBytes(aad));
}

const shopDkAad = (fileId, uploadId) => utf8(L.dkAad + '|' + id(fileId, 'fileId') + '|' + id(uploadId, 'uploadId'));
const grantDkAad = (grantId, fileId, uploadId) => utf8(L.linkDkAad + '|' + id(grantId, 'grantId') + '|'
  + id(fileId, 'fileId') + '|' + id(uploadId, 'uploadId'));

const wrapDkForShop = async (vaultKey, dk, fileId, uploadId, opts) => wrapKey(vaultKey, dk, shopDkAad(fileId, uploadId), opts);
const unwrapDkForShop = async (vaultKey, wrapped, fileId, uploadId) => unwrapKey(vaultKey, wrapped, shopDkAad(fileId, uploadId));
const wrapDkForGrant = async (linkKey, dk, grantId, fileId, uploadId, opts) =>
  wrapKey(linkKey, dk, grantDkAad(grantId, fileId, uploadId), opts);
const unwrapDkForGrant = async (linkKey, wrapped, grantId, fileId, uploadId) =>
  unwrapKey(linkKey, wrapped, grantDkAad(grantId, fileId, uploadId));

// ── shop metadata record ─────────────────────────────────────────────────

const metaAad = (fileId, uploadId) => utf8(L.metaAad + '|' + id(fileId, 'fileId') + '|' + id(uploadId, 'uploadId'));
const vmetaAad = (fileId, uploadId) => utf8(L.vmetaAad + '|' + id(fileId, 'fileId') + '|' + id(uploadId, 'uploadId'));

/** 0 ≤ seq ≤ 2^53−1, checked on the value JSON.parse produced, before any
 *  arithmetic. Anything past 2^53−1 has already been rounded by JSON.parse
 *  (2^53+1 reads as 2^53), so it can only be refused, never compared. */
function seqOk(seq) {
  if (!Number.isSafeInteger(seq) || seq < 0) {
    throw new Error('meta seq must be an integer from 0 to 2^53-1');
  }
  return seq;
}

/**
 * Refuse a meta record older than one this reader has already seen. Rollback
 * (the server serving an earlier, validly sealed head) is detected ONLY by a
 * reader that remembers its last-seen seq; a first-time reader cannot tell.
 * `lastSeenSeq` null means "nothing remembered". Returns the seq to remember.
 */
function checkMetaSeq(seq, lastSeenSeq) {
  seqOk(seq);
  if (lastSeenSeq != null && seq < seqOk(lastSeenSeq)) {
    throw new Error(`vault: meta seq ${seq} is older than the last seen ${lastSeenSeq} (rollback)`);
  }
  return seq;
}

function parseMeta(text) {
  let v;
  try { v = JSON.parse(text); } catch (_) { throw new Error('vault: meta record is not JSON'); }
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error('vault: meta record must be a JSON object');
  // Belt and braces beside the version record's own AAD label: a shop
  // record may never look like one, so `manifest` is reserved for it.
  if (Object.prototype.hasOwnProperty.call(v, 'manifest')) throw new Error('vault: a shop meta record has no manifest');
  seqOk(v.seq);
  return v;
}

/** nonce(12) || ct || tag(16), aad "khayt-vault-meta|"+fileId+"|"+uploadId.
 *  `json` is a string sealed byte for byte, or an object JSON.stringify'd;
 *  either way it must be an object carrying an integer `seq`. */
async function encryptMeta(vaultKey, fileId, uploadId, json, opts = {}) {
  const text = typeof json === 'string' ? json : JSON.stringify(json);
  parseMeta(text);
  return sealWithNonce(vaultKey, utf8(text), metaAad(fileId, uploadId), opts);
}

/** The record's JSON text, authenticated, with its seq checked. */
async function decryptMetaText(vaultKey, fileId, uploadId, sealed, lastSeenSeq = null) {
  const text = fromUtf8(await openWithNonce(vaultKey, sealed, metaAad(fileId, uploadId)));
  checkMetaSeq(parseMeta(text).seq, lastSeenSeq);
  return text;
}

async function decryptMeta(vaultKey, fileId, uploadId, sealed, lastSeenSeq = null) {
  return JSON.parse(await decryptMetaText(vaultKey, fileId, uploadId, sealed, lastSeenSeq));
}

// ── version meta record ──────────────────────────────────────────────────

/** The exact version record bytes: {"manifest":<manifestJson>,"size":N,"seq":S}. */
function versionMetaJson(size, chunkHashes, seq, chunkBytes = CHUNK_BYTES) {
  const m = manifestJson(size, chunkHashes, chunkBytes); // checks size and hashes first
  return '{"manifest":' + m + ',"size":' + size + ',"seq":' + seqOk(seq) + '}';
}

/**
 * One version's own record, sealed under the vault key with its own AAD
 * ("khayt-vault-vmeta|"+fileId+"|"+uploadId): its whole manifest, so a
 * reader has every chunk hash before the first chunk, plus size and seq.
 * `v` is { size, chunkHashes, seq, chunkBytes? }.
 */
async function encryptVersionMeta(vaultKey, fileId, uploadId, v, opts = {}) {
  const text = versionMetaJson(v.size, v.chunkHashes, v.seq, v.chunkBytes ?? CHUNK_BYTES);
  return sealWithNonce(vaultKey, utf8(text), vmetaAad(fileId, uploadId), opts);
}

/**
 * Open a version record. The bytes must be EXACTLY the canonical form. Returns
 * { size, chunkBytes, chunkHashes, seq, manifestJson, manifestHash }.
 */
async function decryptVersionMeta(vaultKey, fileId, uploadId, sealed, lastSeenSeq = null) {
  const text = fromUtf8(await openWithNonce(vaultKey, sealed, vmetaAad(fileId, uploadId)));
  let v;
  try { v = JSON.parse(text); } catch (_) { throw new Error('vault: version meta is not JSON'); }
  const m = v && typeof v === 'object' && !Array.isArray(v) ? v.manifest : null;
  if (!m || typeof m !== 'object' || Array.isArray(m) || m.v !== VERSION || !Number.isSafeInteger(m.chunkBytes)
      || m.chunkBytes <= 0 || m.size !== v.size) {
    throw new Error('vault: version meta must be {manifest, size, seq}');
  }
  seqOk(v.seq);
  let canon;
  try { canon = versionMetaJson(v.size, m.chunks, v.seq, m.chunkBytes); } catch (e) { throw new Error('vault: version meta: ' + e.message); }
  if (canon !== text) throw new Error('vault: version meta is not canonical');
  checkMetaSeq(v.seq, lastSeenSeq);
  const mj = manifestJson(v.size, m.chunks, m.chunkBytes);
  return { size: v.size, chunkBytes: m.chunkBytes, chunkHashes: m.chunks.slice(), seq: v.seq,
    manifestJson: mj, manifestHash: hex(await sha256(utf8(mj))) };
}

// ── link metadata record ─────────────────────────────────────────────────

const linkMetaAad = (grantId, fileId) => utf8(L.linkMetaAad + '|' + id(grantId, 'grantId') + '|' + id(fileId, 'fileId'));

/** Every field checked, and sha256 of the manifest (rebuilt canonically from
 *  its fields) must equal manifestHash. */
async function linkMetaOk(v) {
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error('vault: link meta must be a JSON object');
  id(v.uploadId, 'uploadId');
  if (typeof v.manifestHash !== 'string' || !HEX64_RE.test(v.manifestHash)) throw new Error('vault: link meta manifestHash');
  sizeOk(v.size);
  if (typeof v.name !== 'string') throw new Error('vault: link meta name');
  if (typeof v.kind !== 'string') throw new Error('vault: link meta kind');
  const m = v.manifest;
  if (!m || typeof m !== 'object' || Array.isArray(m) || m.v !== VERSION || !Number.isSafeInteger(m.chunkBytes)
      || m.chunkBytes <= 0 || m.size !== v.size) {
    throw new Error('vault: link meta manifest');
  }
  let mj;
  try { mj = manifestJson(m.size, m.chunks, m.chunkBytes); } catch (e) { throw new Error('vault: link meta manifest: ' + e.message); }
  if (hex(await sha256(utf8(mj))) !== v.manifestHash) throw new Error('vault: link meta manifest does not match manifestHash');
  return v;
}

/**
 * The record a share page opens with the linkKey: which upload to fetch, its
 * whole manifest (so every chunk is checked as it streams) and the
 * AUTHENTICATED manifestHash it must hash to. Sealed with a random nonce,
 * aad "khayt-link-meta|"+grantId+"|"+fileId. An object is written in the
 * fixed key order {uploadId, manifest, manifestHash, name, size, kind}, the
 * manifest as {v, chunkBytes, size, chunks}, which is its canonical JSON.
 */
async function encryptLinkMeta(linkKey, grantId, fileId, meta, opts = {}) {
  let text;
  if (typeof meta === 'string') { text = meta; await linkMetaOk(JSON.parse(text)); } else {
    await linkMetaOk(meta);
    const m = meta.manifest;
    text = JSON.stringify({ uploadId: meta.uploadId,
      manifest: { v: m.v, chunkBytes: m.chunkBytes, size: m.size, chunks: m.chunks },
      manifestHash: meta.manifestHash, name: meta.name, size: meta.size, kind: meta.kind });
  }
  return sealWithNonce(linkKey, utf8(text), linkMetaAad(grantId, fileId), opts);
}

async function decryptLinkMeta(linkKey, grantId, fileId, sealed) {
  const text = fromUtf8(await openWithNonce(linkKey, sealed, linkMetaAad(grantId, fileId)));
  let v;
  try { v = JSON.parse(text); } catch (_) { throw new Error('vault: link meta is not JSON'); }
  return linkMetaOk(v);
}

const api = {
  VERSION, CHUNK_BYTES, MAX_SIZE, LINK_PASSWORD_MIN,
  LABELS: Object.freeze({ ...L }), LINK_SCRYPT,
  deriveVaultKey, deriveDedupeKey, deriveChunkKey, deriveLinkKey, newDataKey, newLinkSecret, newGrantId, linkPasswordOk,
  dedupeTag, dedupeTagFromDigest,
  chunkCount, chunkNonce, encryptChunk, decryptChunk, chunkHash,
  manifestJson, manifestHash, createReader, encryptFile, decryptFile,
  wrapKey, unwrapKey, wrapDkForShop, unwrapDkForShop, wrapDkForGrant, unwrapDkForGrant,
  encryptMeta, decryptMeta, decryptMetaText, checkMetaSeq,
  versionMetaJson, encryptVersionMeta, decryptVersionMeta,
  encryptLinkMeta, decryptLinkMeta,
  sha256, hex, unhex, b64url, unb64url,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytVault = api;

})();
