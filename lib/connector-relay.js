'use strict';
(function () {

/**
 * The connector Cloud relay's sealing rules: Khayt for OrcaSlicer ⇄ the shop's
 * Khayt computer, through Khayt Cloud, sealed end to end
 * (connector-cloud-relay-design.md, approved Nov 16 2026).
 *
 * Not wired yet: nothing calls this module. docs/connector-relay.vectors.json
 * is its contract, and test/connector-relay-vector.test.js holds it to that
 * file and to a second, separately written opener.
 *
 * ── RULES HERE, CRYPTO FROM THE HOST ─────────────────────────────────────
 *
 * Every rule lives in this file: key labels, AAD strings, padding, chunk
 * nonces, the dedupe input, the queue `seq`, the `at` window, the manifest
 * checks and the refusal words. The cipher itself does not. JavaScriptCore
 * (the Mac) has no crypto, so the host hands in six primitives, `P`:
 *
 *   P.hkdf(ikm, salt, info, length) → Uint8Array      HKDF-SHA256
 *   P.gcmSeal(key, iv, plaintext, aad) → { ct, tag }   AES-256-GCM, 16-byte tag
 *   P.gcmOpen(key, iv, ct, tag, aad) → Uint8Array|null null when it does not open
 *   P.hmac(key, data) → Uint8Array                     HMAC-SHA256
 *   P.sha256(data) → Uint8Array
 *   P.random(n) → Uint8Array                           n random bytes (IVs, DK)
 *
 * All arguments and results are Uint8Array (salt and info included: this file
 * encodes the strings). All are synchronous: Node's crypto and a CryptoKit
 * bridge are; WebCrypto is not, and no browser seals relay mail. Node gets
 * `nodePrimitives()` below; the Mac passes its CryptoKit bridge.
 *
 * ── JAVASCRIPTCORE-SAFE ──────────────────────────────────────────────────
 *
 * No host globals of any kind (no Node byte type, no text codec, no base64
 * helpers): the file carries its own UTF-8, hex and base64. `require` is reached only inside
 * `nodePrimitives()`, which the Mac never calls. Wrapped in an IIFE so its
 * names stay out of the one JSC context every bundled module shares.
 */

const V = 1;
const L = {
  relaySalt: 'khayt-connector-relay-v1',
  lanSealSalt: 'khayt-connector-seal-v1',
  aad: 'khayt-relay-v1',
  dkAad: 'khayt-relay-dk',
  chunkInfo: 'khayt-relay-chunk-v1',
  dedupe: 'khayt-relay-dedupe-v1',
};
const KEY_BYTES = 32;
const IV_BYTES = 12;
const TAG_BYTES = 16;
const CHUNK_BYTES = 4 * 1024 * 1024;
const PAD = { slice: 66 * 1024, small: 4 * 1024, queueStep: 16 * 1024, queueMax: 256 * 1024 };
const KINDS = ['slice', 'name', 'queue', 'status', 'token'];
const DIRECTION = { slice: 'up', name: 'up', queue: 'down', status: 'down', token: 'down' };
const WRAP_MODES = ['k1'];
const SKEW_MS = 10 * 60 * 1000;
const MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000 + SKEW_MS;
const MAX_AHEAD_MS = 24 * 60 * 60 * 1000;
const ID = /^[A-Za-z0-9_-]{8,64}$/;

/** Every word an opener can refuse with; the vectors' `expect` values are these. */
const REFUSALS = ['bad-id', 'unopenable', 'bad-padding', 'stale', 'duplicate', 'future',
  'unopenable-wrap', 'bad-manifest', 'hash-mismatch'];

// ── bytes (plain Uint8Array only) ────────────────────────────────────────

function utf8(str) {
  const out = [];
  const s = String(str);
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
    }
    if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd; // a lone surrogate becomes U+FFFD, as the web's encoder writes it
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return Uint8Array.from(out);
}

/** Strict UTF-8 decode; null for bytes that are not UTF-8. */
function fromUtf8(b) {
  let s = '';
  for (let i = 0; i < b.length;) {
    const x = b[i];
    let c, n;
    if (x < 0x80) { c = x; n = 1; }
    else if (x >= 0xc2 && x < 0xe0) { c = x & 31; n = 2; }
    else if (x >= 0xe0 && x < 0xf0) { c = x & 15; n = 3; }
    else if (x >= 0xf0 && x < 0xf5) { c = x & 7; n = 4; }
    else return null;
    if (i + n > b.length) return null;
    for (let k = 1; k < n; k++) {
      const y = b[i + k];
      if ((y & 0xc0) !== 0x80) return null;
      c = (c << 6) | (y & 63);
    }
    if ((n === 3 && (c < 0x800 || (c >= 0xd800 && c <= 0xdfff))) || (n === 4 && (c < 0x10000 || c > 0x10ffff))) return null;
    s += String.fromCodePoint(c);
    i += n;
  }
  return s;
}

function concat(...parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function bytes(x, what) {
  if (x instanceof Uint8Array) return x;
  throw new TypeError((what || 'value') + ' must be a Uint8Array');
}

const HEX = '0123456789abcdef';
function toHex(b) {
  let s = '';
  for (let i = 0; i < b.length; i++) s += HEX[b[i] >> 4] + HEX[b[i] & 15];
  return s;
}
function fromHex(s) {
  if (typeof s !== 'string' || s.length % 2 || /[^0-9a-fA-F]/.test(s)) return null;
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function toBase64(b, url) {
  let s = '';
  let i = 0;
  for (; i + 2 < b.length; i += 3) {
    const n = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
    s += B64[n >> 18] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
  }
  if (i < b.length) {
    const n = (b[i] << 16) | ((i + 1 < b.length ? b[i + 1] : 0) << 8);
    s += B64[n >> 18] + B64[(n >> 12) & 63] + (i + 1 < b.length ? B64[(n >> 6) & 63] : '=') + '=';
  }
  return url ? s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') : s;
}
/** Standard padded base64, or base64url without padding when `url`; null when malformed. */
function fromBase64(s, url) {
  if (typeof s !== 'string') return null;
  let t = s;
  if (url) {
    if (/[^A-Za-z0-9_-]/.test(t) || t.length % 4 === 1) return null;
    t = t.replace(/-/g, '+').replace(/_/g, '/');
    while (t.length % 4) t += '=';
  } else if (!/^[A-Za-z0-9+/]*={0,2}$/.test(t) || t.length % 4) return null;
  const pad = t.endsWith('==') ? 2 : t.endsWith('=') ? 1 : 0;
  const out = new Uint8Array((t.length / 4) * 3 - pad);
  let o = 0;
  for (let i = 0; i < t.length; i += 4) {
    const n = (B64.indexOf(t[i]) << 18) | (B64.indexOf(t[i + 1]) << 12)
      | ((t[i + 2] === '=' ? 0 : B64.indexOf(t[i + 2])) << 6) | (t[i + 3] === '=' ? 0 : B64.indexOf(t[i + 3]));
    if (o < out.length) out[o++] = (n >> 16) & 255;
    if (o < out.length) out[o++] = (n >> 8) & 255;
    if (o < out.length) out[o++] = n & 255;
  }
  return out;
}

const refuse = (reason) => ({ ok: false, reason });

// ── keys ────────────────────────────────────────────────────────────────

function checkId(id) {
  return typeof id === 'string' && ID.test(id);
}

/** The relay's four keys from the pairing key K: up (plugin→Mac), down (Mac→plugin), wrap, tag. */
function deriveKeys(P, K, deviceId) {
  bytes(K, 'K');
  if (K.length !== KEY_BYTES) throw new Error('K must be 32 bytes');
  if (!checkId(deviceId)) throw new Error('deviceId outside [A-Za-z0-9_-]{8,64}');
  const k = (label) => P.hkdf(K, utf8(L.relaySalt), utf8(label + '\n' + deviceId), KEY_BYTES);
  return { up: k('up'), down: k('down'), wrap: k('wrap'), tag: k('tag') };
}

/** The LAN seal key (connector-routes-design.md 4): never a relay key. */
function lanSealKey(P, K, connectorId) {
  return P.hkdf(bytes(K, 'K'), utf8(L.lanSealSalt), utf8(connectorId), KEY_BYTES);
}

// ── envelopes ───────────────────────────────────────────────────────────

function envelopeAad(v, k, deviceId, id, seq) {
  return [L.aad, v, k, deviceId, id, seq].join('|');
}

/** The padded size for a kind: fixed, or the next 16 KiB step for a queue (≤ 256 KiB); null if too big. */
function padSize(k, jsonBytes) {
  if (k === 'slice') return jsonBytes + 1 <= PAD.slice ? PAD.slice : null;
  if (k === 'queue') {
    const n = Math.ceil((jsonBytes + 1) / PAD.queueStep) * PAD.queueStep;
    return n <= PAD.queueMax ? n : null;
  }
  return jsonBytes + 1 <= PAD.small ? PAD.small : null;
}

/** JSON, one 0x00 marker, zeros to `size`. */
function pad(json, size) {
  const out = new Uint8Array(size);
  out.set(json, 0);
  return out;
}

/** The JSON bytes before the marker; null when there is no marker or a non-zero byte after it. */
function unpad(plain) {
  const at = plain.indexOf(0);
  if (at < 0) return null;
  for (let i = at + 1; i < plain.length; i++) if (plain[i] !== 0) return null;
  return plain.subarray(0, at);
}

/**
 * Seal one message. `m`: `{ k, deviceId, id, seq?, plaintext }` (`seq` only for
 * a queue; 0 otherwise). The IV comes from `P.random(12)`; `opts.iv` is for
 * test vectors only.
 * Returns `{ ok, envelope, padTo }` or a refusal.
 */
function seal(P, keys, m, opts) {
  const o = opts || {};
  if (KINDS.indexOf(m.k) < 0) throw new Error('unknown kind ' + m.k);
  if (!checkId(m.deviceId) || !checkId(m.id)) return refuse('bad-id');
  const seq = m.k === 'queue' ? m.seq : 0;
  if (!Number.isSafeInteger(seq) || seq < 0) throw new Error('seq must be a non-negative integer');
  const json = utf8(JSON.stringify(m.plaintext));
  const size = padSize(m.k, json.length);
  if (size === null) return refuse('too-large');
  const iv = o.iv ? bytes(o.iv, 'iv') : P.random(IV_BYTES);
  if (iv.length !== IV_BYTES) throw new Error('iv must be 12 bytes');
  const sealed = P.gcmSeal(keys[DIRECTION[m.k]], iv, pad(json, size), utf8(envelopeAad(V, m.k, m.deviceId, m.id, seq)));
  return {
    ok: true, padTo: size,
    envelope: { v: V, k: m.k, id: m.id, seq, iv: toBase64(iv), ct: toBase64(sealed.ct), tag: toBase64(sealed.tag) },
  };
}

/**
 * Open one message as the receiver expects it. `as`: `{ k, deviceId }`, plus
 * for tests `{ v, key }` (`key` names one of `keys`, defaulting to the kind's
 * direction). Returns `{ ok: true, plaintext }` or `{ ok: false, reason }`.
 * Kind rules (queue order, slice time, seen ids) are `judgeQueue` / `judgeSlice`.
 */
function open(P, keys, envelope, as) {
  const a = as || {};
  const e = envelope && typeof envelope === 'object' ? envelope : {};
  const k = a.k || e.k;
  if (!checkId(a.deviceId) || !checkId(e.id) || !Number.isSafeInteger(e.seq) || e.seq < 0) return refuse('bad-id');
  if (KINDS.indexOf(k) < 0) return refuse('unopenable');
  // The AAD is built from what the RECEIVER expects (its kind, its version, its
  // device), never from the envelope's own labels: a relabelled envelope fails here.
  const key = keys[a.key || DIRECTION[k]];
  const iv = fromBase64(e.iv), ct = fromBase64(e.ct), tag = fromBase64(e.tag);
  if (!key || !iv || iv.length !== IV_BYTES || !ct || !tag || tag.length !== TAG_BYTES) return refuse('unopenable');
  const plain = P.gcmOpen(key, iv, ct, tag, utf8(envelopeAad(a.v || V, k, a.deviceId, e.id, e.seq)));
  if (!plain) return refuse('unopenable');
  const json = unpad(plain);
  if (!json) return refuse('bad-padding');
  const text = fromUtf8(json);
  let doc;
  try { doc = text === null ? undefined : JSON.parse(text); } catch (_) { doc = undefined; }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return refuse('bad-padding');
  return { ok: true, plaintext: doc };
}

/**
 * A slice's time and id, against the Mac's memory. `state`: `{ nowMs, seenIds }`
 * (seenIds: a Set or array). Returns `{ ok: true, clock: null | 'ahead' }` or
 * a refusal: `duplicate` (the only one deleted without a status), `stale`, `future`.
 */
function judgeSlice(doc, id, state) {
  const s = state || {};
  const seen = s.seenIds;
  if (seen && (typeof seen.has === 'function' ? seen.has(id) : seen.indexOf(id) >= 0)) return refuse('duplicate');
  const at = doc && typeof doc.at === 'string' ? Date.parse(doc.at) : NaN;
  if (!Number.isFinite(at)) return refuse('stale');
  const now = Number.isFinite(s.nowMs) ? s.nowMs : Date.now();
  if (now - at > MAX_AGE_MS) return refuse('stale');
  if (at - now > MAX_AHEAD_MS) return refuse('future');
  return { ok: true, clock: at - now > SKEW_MS ? 'ahead' : null };
}

/** How long the Mac must remember a slice id: until its `at` + 15 days. */
function rememberUntil(doc) {
  const at = doc && typeof doc.at === 'string' ? Date.parse(doc.at) : NaN;
  return Number.isFinite(at) ? at + 15 * 24 * 60 * 60 * 1000 : null;
}

/** A queue snapshot must carry a larger `seq` than the last one accepted. */
function judgeQueue(seq, lastSeq) {
  if (Number.isSafeInteger(lastSeq) && !(seq > lastSeq)) return refuse('stale');
  return { ok: true };
}

/** The Mac's next queue `seq`: max(last + 1, unix ms). */
function nextSeq(lastSeq, nowMs) {
  const last = Number.isSafeInteger(lastSeq) ? lastSeq : 0;
  return Math.max(last + 1, Number.isFinite(nowMs) ? Math.floor(nowMs) : Date.now());
}

// ── dedupe ──────────────────────────────────────────────────────────────

function dedupeInput(t) {
  return [L.dedupe, t.sha256hex, t.intent, t.target || '', t.startPrint ? '1' : '0'].join('\n');
}

/** The tag the cloud may compare: never the hash itself. base64url, no padding. */
function dedupeTag(P, tagKey, t) {
  if (!/^[0-9a-f]{64}$/.test(t.sha256hex)) throw new Error('sha256hex must be 64 lower-case hex');
  return toBase64(P.hmac(tagKey, utf8(dedupeInput(t))), true);
}

// ── files ───────────────────────────────────────────────────────────────

function chunkCount(size) {
  if (!Number.isSafeInteger(size) || size < 0) throw new Error('size must be a non-negative integer');
  return size === 0 ? 1 : Math.ceil(size / CHUNK_BYTES);
}

function chunkNonce(i) {
  if (!Number.isSafeInteger(i) || i < 0) throw new Error('chunk index must be a non-negative integer');
  const n = new Uint8Array(IV_BYTES);
  let x = i;
  for (let b = 11; b >= 4; b--) { n[b] = x % 256; x = Math.floor(x / 256); }
  return n;
}

function chunkAad(fileId, i, last) {
  if (typeof last !== 'boolean') throw new Error('last must be a boolean');
  return [L.aad, V, fileId, i, last ? 1 : 0].join('|');
}

function chunkKey(P, dk, fileId) {
  if (!checkId(fileId)) throw new Error('fileId outside [A-Za-z0-9_-]{8,64}');
  return P.hkdf(bytes(dk, 'DK'), utf8(fileId), utf8(L.chunkInfo), KEY_BYTES);
}

/**
 * Seal chunk `i`. `plain` is that chunk's bytes; the last chunk is padded with
 * zeros to a whole chunk here. Returns ct || tag (chunkBytes + 16 bytes).
 * The caller seals from an immutable outbox copy (design 2.2): one DK, one
 * fileId, one set of bytes.
 */
function sealChunk(P, ck, fileId, i, last, plain) {
  bytes(plain, 'chunk');
  if (plain.length > CHUNK_BYTES || (!last && plain.length !== CHUNK_BYTES)) throw new Error('chunk size');
  const body = last && plain.length < CHUNK_BYTES ? pad(plain, CHUNK_BYTES) : plain;
  const s = P.gcmSeal(ck, chunkNonce(i), body, utf8(chunkAad(fileId, i, last)));
  return concat(s.ct, s.tag);
}

/** Open chunk `i` as the position the reader expects; null when it does not open. */
function openChunk(P, ck, fileId, i, last, sealed) {
  bytes(sealed, 'chunk');
  if (sealed.length !== CHUNK_BYTES + TAG_BYTES) return null;
  return P.gcmOpen(ck, chunkNonce(i), sealed.subarray(0, CHUNK_BYTES), sealed.subarray(CHUNK_BYTES), utf8(chunkAad(fileId, i, last)));
}

function dkAad(fileId) { return [L.dkAad, V, fileId].join('|'); }

/** base64(iv || ct || tag) of DK under the wrap key, wrap mode k1. */
function wrapDk(P, wrapKey, dk, fileId, iv) {
  bytes(iv, 'iv');
  const s = P.gcmSeal(wrapKey, iv, bytes(dk, 'DK'), utf8(dkAad(fileId)));
  return toBase64(concat(iv, s.ct, s.tag));
}

function unwrapDk(P, wrapKey, wrappedDk, fileId) {
  const w = fromBase64(wrappedDk);
  if (!w || w.length !== IV_BYTES + KEY_BYTES + TAG_BYTES) return null;
  return P.gcmOpen(wrapKey, w.subarray(0, IV_BYTES), w.subarray(IV_BYTES, w.length - TAG_BYTES),
    w.subarray(w.length - TAG_BYTES), utf8(dkAad(fileId)));
}

/** A manifest the reader can trust the shape of: null, or `unopenable-wrap` / `bad-manifest`. */
function checkManifest(m) {
  if (!m || typeof m !== 'object') return 'bad-manifest';
  if (WRAP_MODES.indexOf(m.wrap) < 0) return 'unopenable-wrap';
  const n = m.chunks;
  if (!checkId(m.fileId) || !Number.isSafeInteger(n) || n < 1 || !Number.isSafeInteger(m.bytes) || m.bytes < 0) return 'bad-manifest';
  if (n !== chunkCount(m.bytes)) return 'bad-manifest';
  if (!/^[0-9a-f]{64}$/.test(m.sha256 || '')) return 'bad-manifest';
  if (!Array.isArray(m.chunkHashes) || m.chunkHashes.length !== n
    || m.chunkHashes.some((h) => typeof h !== 'string' || !/^[0-9a-f]{64}$/.test(h))) return 'bad-manifest';
  return null;
}

/** How many plaintext bytes of the last chunk are the file (the rest is padding). */
function lastChunkBytes(m) {
  return m.bytes - (m.chunks - 1) * CHUNK_BYTES;
}

/**
 * Read a whole file held in memory (tests, small files). Hosts with large files
 * stream the same steps: unwrap, then openChunk per index, hashing as they go.
 * `sealedAt(i)` returns the sealed chunk at position i. Returns
 * `{ ok: true, bytes }` or a refusal.
 */
function readFile(P, wrapKey, manifest, sealedAt) {
  const bad = checkManifest(manifest);
  if (bad) return refuse(bad);
  const dk = unwrapDk(P, wrapKey, manifest.wrappedDk, manifest.fileId);
  if (!dk) return refuse('unopenable');
  const ck = chunkKey(P, dk, manifest.fileId);
  const parts = [];
  for (let i = 0; i < manifest.chunks; i++) {
    const last = i === manifest.chunks - 1;
    const s = sealedAt(i);
    // The listed hash lets a host refuse a chunk as it streams in; the AAD
    // (index, last) is what proves its position either way.
    const plain = s && toHex(P.sha256(s)) === manifest.chunkHashes[i] ? openChunk(P, ck, manifest.fileId, i, last, s) : null;
    if (!plain) return refuse('unopenable');
    parts.push(last ? plain.subarray(0, lastChunkBytes(manifest)) : plain);
  }
  const whole = concat(...parts);
  if (toHex(P.sha256(whole)) !== manifest.sha256) return refuse('hash-mismatch');
  return { ok: true, bytes: whole };
}

// ── Node's primitives (never called on the Mac) ─────────────────────────

function nodePrimitives() {
  const c = require('node:crypto');
  // Node hands back its own byte type, a Uint8Array subclass; copy it to a plain one.
  const u = (b) => Uint8Array.from(b);
  return {
    hkdf: (ikm, salt, info, len) => new Uint8Array(c.hkdfSync('sha256', ikm, salt, info, len)),
    gcmSeal(key, iv, plaintext, aad) {
      const x = c.createCipheriv('aes-256-gcm', key, iv);
      x.setAAD(aad);
      const ct = concat(u(x.update(plaintext)), u(x.final()));
      return { ct, tag: u(x.getAuthTag()) };
    },
    gcmOpen(key, iv, ct, tag, aad) {
      try {
        const x = c.createDecipheriv('aes-256-gcm', key, iv);
        x.setAAD(aad);
        x.setAuthTag(tag);
        return concat(u(x.update(ct)), u(x.final()));
      } catch (_) { return null; }
    },
    hmac: (key, data) => u(c.createHmac('sha256', key).update(data).digest()),
    sha256: (data) => u(c.createHash('sha256').update(data).digest()),
    random: (n) => u(c.randomBytes(n)),
  };
}

const api = {
  V, CHUNK_BYTES, PAD, KINDS, DIRECTION, WRAP_MODES, REFUSALS, MAX_AGE_MS, MAX_AHEAD_MS, SKEW_MS,
  deriveKeys, lanSealKey, envelopeAad, padSize, seal, open, judgeSlice, judgeQueue, nextSeq, rememberUntil,
  dedupeInput, dedupeTag,
  chunkCount, chunkNonce, chunkAad, chunkKey, sealChunk, openChunk, wrapDk, unwrapDk, checkManifest, lastChunkBytes, readFile,
  utf8, fromUtf8, toHex, fromHex, toBase64, fromBase64,
  nodePrimitives,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytConnectorRelay = api;
})();
