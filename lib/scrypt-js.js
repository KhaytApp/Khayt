'use strict';
(function () {

/**
 * Pure-JS scrypt (RFC 7914) for the remote-mobile PWA — WebCrypto has no scrypt,
 * so we need it to derive the same KEK the desktop's Node scrypt produced.
 *
 * Only the platform-less core (Salsa20/8 + BlockMix + ROMix) is hand-written;
 * PBKDF2-HMAC-SHA256 is INJECTED (Node `pbkdf2Sync` in tests, WebCrypto
 * `subtle.deriveBits` in the browser) so we don't reimplement SHA-256. Verified
 * byte-for-byte against Node `crypto.scryptSync` in test/scrypt-js.test.js.
 *
 * Async (the injected PBKDF2 may be async). N must be a power of two.
 */

function rotl(a, b) { return ((a << b) | (a >>> (32 - b))) >>> 0; }

/** Salsa20/8 core on 16 little-endian words, in place. */
function salsa20_8(B) {
  const x = new Uint32Array(16);
  for (let i = 0; i < 16; i++) x[i] = B[i];
  for (let i = 0; i < 4; i++) {
    x[4] ^= rotl(x[0] + x[12], 7); x[8] ^= rotl(x[4] + x[0], 9); x[12] ^= rotl(x[8] + x[4], 13); x[0] ^= rotl(x[12] + x[8], 18);
    x[9] ^= rotl(x[5] + x[1], 7); x[13] ^= rotl(x[9] + x[5], 9); x[1] ^= rotl(x[13] + x[9], 13); x[5] ^= rotl(x[1] + x[13], 18);
    x[14] ^= rotl(x[10] + x[6], 7); x[2] ^= rotl(x[14] + x[10], 9); x[6] ^= rotl(x[2] + x[14], 13); x[10] ^= rotl(x[6] + x[2], 18);
    x[3] ^= rotl(x[15] + x[11], 7); x[7] ^= rotl(x[3] + x[15], 9); x[11] ^= rotl(x[7] + x[3], 13); x[15] ^= rotl(x[11] + x[7], 18);
    x[1] ^= rotl(x[0] + x[3], 7); x[2] ^= rotl(x[1] + x[0], 9); x[3] ^= rotl(x[2] + x[1], 13); x[0] ^= rotl(x[3] + x[2], 18);
    x[6] ^= rotl(x[5] + x[4], 7); x[7] ^= rotl(x[6] + x[5], 9); x[4] ^= rotl(x[7] + x[6], 13); x[5] ^= rotl(x[4] + x[7], 18);
    x[11] ^= rotl(x[10] + x[9], 7); x[8] ^= rotl(x[11] + x[10], 9); x[9] ^= rotl(x[8] + x[11], 13); x[10] ^= rotl(x[9] + x[8], 18);
    x[12] ^= rotl(x[15] + x[14], 7); x[13] ^= rotl(x[12] + x[15], 9); x[14] ^= rotl(x[13] + x[12], 13); x[15] ^= rotl(x[14] + x[13], 18);
  }
  for (let i = 0; i < 16; i++) B[i] = (B[i] + x[i]) >>> 0;
}

/** BlockMix on 2r 64-byte blocks (words = Uint32Array(32*r)), in place. */
function blockMix(B, r) {
  const X = new Uint32Array(16);
  const Y = new Uint32Array(32 * r);
  for (let i = 0; i < 16; i++) X[i] = B[(2 * r - 1) * 16 + i];
  for (let i = 0; i < 2 * r; i++) {
    for (let j = 0; j < 16; j++) X[j] ^= B[i * 16 + j];
    salsa20_8(X);
    const dest = ((i % 2 === 0) ? (i / 2) : (r + (i - 1) / 2)) * 16;
    for (let j = 0; j < 16; j++) Y[dest + j] = X[j];
  }
  B.set(Y);
}

/** ROMix on a 128r-byte block (words = Uint32Array(32*r)), in place. */
function roMix(B, r, N) {
  const len = 32 * r;
  const V = new Uint32Array(len * N);
  for (let i = 0; i < N; i++) {
    V.set(B, i * len);
    blockMix(B, r);
  }
  for (let i = 0; i < N; i++) {
    const j = (B[(2 * r - 1) * 16] >>> 0) & (N - 1); // Integerify mod N (N is a power of 2)
    const off = j * len;
    for (let k = 0; k < len; k++) B[k] ^= V[off + k];
    blockMix(B, r);
  }
}

function bytesToWordsLE(bytes, off, words) {
  for (let i = 0; i < words.length; i++) {
    const b = off + i * 4;
    words[i] = (bytes[b] | (bytes[b + 1] << 8) | (bytes[b + 2] << 16) | (bytes[b + 3] << 24)) >>> 0;
  }
}
function wordsToBytesLE(words, bytes, off) {
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    const b = off + i * 4;
    bytes[b] = w & 0xff; bytes[b + 1] = (w >>> 8) & 0xff; bytes[b + 2] = (w >>> 16) & 0xff; bytes[b + 3] = (w >>> 24) & 0xff;
  }
}

/**
 * scrypt(password, salt, { N, r, p, keyLen }, pbkdf2) → Promise<Uint8Array>.
 * pbkdf2(passwordBytes, saltBytes, iterations, dkLenBytes) → Uint8Array|Promise.
 */
async function scrypt(password, salt, kdf, pbkdf2) {
  const N = kdf.N, r = kdf.r, p = kdf.p, keyLen = kdf.keyLen || kdf.dkLen || 32;
  if (typeof pbkdf2 !== 'function') throw new Error('pbkdf2 function required');
  if (N < 2 || (N & (N - 1)) !== 0) throw new Error('N must be a power of two ≥ 2');
  const pw = (password instanceof Uint8Array) ? password : new Uint8Array(password);
  const sl = (salt instanceof Uint8Array) ? salt : new Uint8Array(salt);

  const blockLenBytes = 128 * r;
  const B = new Uint8Array(await pbkdf2(pw, sl, 1, p * blockLenBytes));
  const words = new Uint32Array(32 * r);
  for (let i = 0; i < p; i++) {
    const off = i * blockLenBytes;
    bytesToWordsLE(B, off, words);
    roMix(words, r, N);
    wordsToBytesLE(words, B, off);
  }
  return new Uint8Array(await pbkdf2(pw, B, 1, keyLen));
}

const api = { scrypt, _salsa20_8: salsa20_8 };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytScrypt = api;

})();
