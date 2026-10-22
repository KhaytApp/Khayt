#!/usr/bin/env node
'use strict';
/**
 * Writes test/fixtures/vault-crypto-vectors.json.
 *
 * Deliberately built from node:crypto primitives ONLY (hkdfSync, aes-256-gcm,
 * scryptSync, createHmac) and NOT from lib/vault-crypto.js — so the vectors are
 * a second, independent reading of docs/vault-format.md, and both twins
 * (WebCrypto JS and CryptoKit Swift) are checked against it rather than
 * against themselves.
 *
 *   node scripts/gen-vault-crypto-vectors.js            # rewrite the file
 *   node scripts/gen-vault-crypto-vectors.js --check    # exit 1 if it would change
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const OUT = path.join(__dirname, '..', 'test', 'fixtures', 'vault-crypto-vectors.json');
const CHUNK_BYTES = 4194304;

const H = (s) => Buffer.from(s, 'hex');
const sha = (b) => crypto.createHash('sha256').update(b).digest();
const hkdf = (ikm, salt, info) => Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), 32));

function seal(key, nonce, pt, aad) {
  const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(aad);
  return Buffer.concat([c.update(pt), c.final(), c.getAuthTag()]);
}

/** Deterministic plaintext: byte k = (k * 31 + 7) mod 256. */
function plaintext(n) {
  const b = Buffer.alloc(n);
  for (let k = 0; k < n; k++) b[k] = (k * 31 + 7) & 0xff;
  return b;
}

const inputs = {
  shopDek: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
  dk: 'a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf',
  fileId: 'f_7Qm2xK9a',
  uploadId: 'u_01JB4ZP3',
  grantId: 'g_Hn8r2Lw5',
  linkSecret: '5f4dcc3b5aa765d61d8327deb882cf99e3b0c44298fc1c149afbf4c8996fb924',
  // "cafe" + U+0301 COMBINING ACUTE — NOT NFC on purpose; both twins must
  // normalise it to "café" before scrypt.
  password: 'café au lait',
  shopWrapNonce: '101112131415161718191a1b',
  grantWrapNonce: '202122232425262728292a2b',
  metaNonce: '303132333435363738393a3b',
  metaJson: '{"name":"Benchy بنشي.3mf","type":"model/3mf","size":40}',
};

function chunkNonce(i) {
  const n = Buffer.alloc(12);
  n.writeBigUInt64BE(BigInt(i), 4);
  return n;
}
function chunkAad(i, last) {
  return Buffer.from(`khayt-vault-v1|${inputs.fileId}|${inputs.uploadId}|${i}|${last ? '1' : '0'}`, 'utf8');
}

function fileCase(name, size, chunkBytes, { full = true } = {}) {
  const pt = plaintext(size);
  const dk = H(inputs.dk);
  const n = size === 0 ? 1 : Math.ceil(size / chunkBytes);
  const chunks = [];
  for (let i = 0; i < n; i++) {
    const last = i === n - 1;
    const part = pt.subarray(i * chunkBytes, Math.min(size, (i + 1) * chunkBytes));
    const sealed = seal(dk, chunkNonce(i), part, chunkAad(i, last));
    const c = { index: i, last, plainBytes: part.length, sha256: sha(sealed).toString('hex') };
    if (full || last) c.sealed = sealed.toString('hex');
    chunks.push(c);
  }
  const manifest = `{"v":1,"chunkBytes":${chunkBytes},"size":${size},"chunks":[${chunks.map((c) => `"${c.sha256}"`).join(',')}]}`;
  return {
    name, size, chunkBytes,
    plaintextSha256: sha(pt).toString('hex'),
    chunks,
    manifestJson: manifest,
    manifestHash: sha(Buffer.from(manifest, 'utf8')).toString('hex'),
  };
}

function build() {
  const shopDek = H(inputs.shopDek);
  const vaultKey = hkdf(shopDek, Buffer.from('khayt-vault-v1', 'utf8'), 'vault');
  const dedupeKey = hkdf(vaultKey, Buffer.alloc(0), 'khayt-vault-dedupe-v1');

  const SMALL = 16; // scaled-down chunk size for the shape cases
  const files = [
    fileCase('empty', 0, SMALL),
    fileCase('under-one-chunk', 10, SMALL),
    fileCase('exactly-one-chunk', SMALL, SMALL),
    fileCase('one-chunk-plus-one', SMALL + 1, SMALL),
    fileCase('two-and-a-half-chunks', SMALL * 2 + SMALL / 2, SMALL),
    // The real 4 MiB boundary: first chunk is full-size, second is one byte.
    // Only the last chunk's bytes are stored (the first would be 8 MiB of hex).
    fileCase('real-4mib-plus-one', CHUNK_BYTES + 1, CHUNK_BYTES, { full: false }),
  ];
  for (const f of files) {
    f.dedupeTag = crypto.createHmac('sha256', dedupeKey).update(H(f.plaintextSha256)).digest('hex');
  }

  const dk = H(inputs.dk);
  const shopAad = `khayt-vault-dk|${inputs.fileId}|${inputs.uploadId}`;
  const shopWrap = Buffer.concat([H(inputs.shopWrapNonce),
    seal(vaultKey, H(inputs.shopWrapNonce), dk, Buffer.from(shopAad, 'utf8'))]);

  const grantSalt = Buffer.from(inputs.grantId, 'utf8');
  const linkSecret = H(inputs.linkSecret);
  const linkKeyNoPassword = hkdf(linkSecret, grantSalt, 'khayt-link-v1');
  const pwNfc = inputs.password.normalize('NFC');
  const p = crypto.scryptSync(Buffer.from(pwNfc, 'utf8'), Buffer.from(`khayt-link-pw|${inputs.grantId}`, 'utf8'), 32,
    { N: 32768, r: 8, p: 1, maxmem: 96 * 1024 * 1024 });
  const linkKeyPassword = hkdf(Buffer.concat([linkSecret, p]), grantSalt, 'khayt-link-v1');

  const grantAad = `khayt-link-dk|${inputs.grantId}|${inputs.fileId}`;
  const grantWrap = (kek) => Buffer.concat([H(inputs.grantWrapNonce),
    seal(kek, H(inputs.grantWrapNonce), dk, Buffer.from(grantAad, 'utf8'))]);

  const metaAad = `khayt-vault-meta|${inputs.fileId}`;
  const meta = Buffer.concat([H(inputs.metaNonce),
    seal(vaultKey, H(inputs.metaNonce), Buffer.from(inputs.metaJson, 'utf8'), Buffer.from(metaAad, 'utf8'))]);

  return {
    _comment: 'Generated by scripts/gen-vault-crypto-vectors.js from node:crypto only. Spec: docs/vault-format.md. Do not hand-edit.',
    format: 1,
    inputs,
    plaintextRule: 'byte k = (k * 31 + 7) mod 256',
    derived: {
      vaultKey: vaultKey.toString('hex'),
      dedupeKey: dedupeKey.toString('hex'),
      linkKeyNoPassword: linkKeyNoPassword.toString('hex'),
      passwordNfcHex: Buffer.from(pwNfc, 'utf8').toString('hex'),
      linkPasswordScrypt: p.toString('hex'),
      linkKeyPassword: linkKeyPassword.toString('hex'),
    },
    files,
    wraps: {
      shop: { kek: 'vaultKey', aad: shopAad, nonce: inputs.shopWrapNonce, wrapped: shopWrap.toString('hex') },
      grantNoPassword: { kek: 'linkKeyNoPassword', aad: grantAad, nonce: inputs.grantWrapNonce,
        wrapped: grantWrap(linkKeyNoPassword).toString('hex') },
      grantPassword: { kek: 'linkKeyPassword', aad: grantAad, nonce: inputs.grantWrapNonce,
        wrapped: grantWrap(linkKeyPassword).toString('hex') },
    },
    meta: { aad: metaAad, nonce: inputs.metaNonce, json: inputs.metaJson, sealed: meta.toString('hex') },
  };
}

if (require.main === module) {
  const text = JSON.stringify(build(), null, 2) + '\n';
  if (process.argv.includes('--check')) {
    const cur = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : '';
    if (cur !== text) { console.error('vault-crypto-vectors.json is stale'); process.exit(1); }
    console.log('vault-crypto-vectors.json is current');
  } else {
    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, text);
    console.log('wrote', OUT);
  }
}

module.exports = { build };
