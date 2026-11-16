const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

/**
 * The connector Cloud relay vectors (docs/connector-relay.vectors.json),
 * checked by a reference opener written here, separately from the generator,
 * from the rules in the file's `about` (connector-cloud-relay-design.md rev 2/3).
 *
 * The Swift and Python openers must pass the same file. Each refusal case
 * names the word the opener returns, so a case passes only when it fails for
 * the stated reason. The generator is also re-run and must reproduce the
 * committed file byte for byte, so the file cannot drift from its rules.
 */

const ROOT = path.join(__dirname, '..');
const VEC = JSON.parse(fs.readFileSync(path.join(ROOT, 'docs', 'connector-relay.vectors.json'), 'utf8'));
const PAIR = JSON.parse(fs.readFileSync(path.join(ROOT, 'docs', 'connector-pair.vectors.json'), 'utf8'));

const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const u8 = (s) => Buffer.from(s, 'utf8');
const hkdf = (ikm, salt, info) => Buffer.from(crypto.hkdfSync('sha256', ikm, u8(salt), u8(info), 32));
const ID = /^[A-Za-z0-9_-]{8,64}$/;

function x25519Shared(privHex, peerPublicB64) {
  const priv = crypto.createPrivateKey({ key: { kty: 'OKP', crv: 'X25519', d: Buffer.from(privHex, 'hex').toString('base64url'),
    x: crypto.createPublicKey(crypto.createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(privHex, 'hex')]), format: 'der', type: 'pkcs8' })).export({ format: 'jwk' }).x }, format: 'jwk' });
  const pub = crypto.createPublicKey({ key: { kty: 'OKP', crv: 'X25519', x: Buffer.from(peerPublicB64, 'base64').toString('base64url') }, format: 'jwk' });
  return crypto.diffieHellman({ privateKey: priv, publicKey: pub });
}

function keysFor(K, deviceId) {
  const k = (label) => hkdf(K, 'khayt-connector-relay-v1', label + '\n' + deviceId);
  return { up: k('up'), down: k('down'), wrap: k('wrap'), tag: k('tag'), lanSeal: hkdf(K, 'khayt-connector-seal-v1', deviceId) };
}

const first = PAIR.cases.find((c) => c.name === 'first');
const K = hkdf(x25519Shared(first.serverPrivateHex, first.pluginPublic), 'khayt-device-v1', first.deviceId);
const KEYS = keysFor(K, first.deviceId);

function gcm(key, iv, data, aad) {
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  c.setAAD(u8(aad));
  const ct = Buffer.concat([c.update(data), c.final()]);
  return { ct, tag: c.getAuthTag() };
}
function ungcm(key, iv, ct, tag, aad) {
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
    d.setAAD(u8(aad));
    d.setAuthTag(tag);
    return Buffer.concat([d.update(ct), d.final()]);
  } catch { return null; }
}

/** The plaintext as the sender pads it: JSON, a 0x00 marker, zeros. */
function padded(e) {
  const body = u8(e.plaintextJson);
  return Buffer.concat([body, Buffer.alloc(e.padTo - body.length)]);
}
/** The ciphertext of an envelope, from the inline `ct` or regenerated from its rule. */
function ctOf(e) {
  if (e.envelope.ct) return Buffer.from(e.envelope.ct, 'base64');
  return gcm(KEYS[e.direction], Buffer.from(e.ivHex, 'hex'), padded(e), e.aad).ct;
}

/**
 * The reference opener. `env` is the wire envelope plus its ciphertext;
 * `as` says how the receiver opens it (key, kind, version, device);
 * `state` is what the receiver remembers. Returns {ok, plaintext} or a refusal word.
 */
function open(env, ct, as, state = {}) {
  const deviceId = as.deviceId || first.deviceId;
  const id = as.id || env.id;
  if (!ID.test(id) || !ID.test(deviceId) || !/^\d+$/.test(String(env.seq))) return 'bad-id';
  const keys = deviceId === first.deviceId ? KEYS : keysFor(K, deviceId);
  const key = keys[as.key];
  const aad = ['khayt-relay-v1', as.v || env.v, as.k || env.k, deviceId, id, env.seq].join('|');
  const plain = ungcm(key, Buffer.from(env.iv, 'base64'), ct, Buffer.from(env.tag, 'base64'), aad);
  if (!plain) return 'unopenable';
  const marker = plain.indexOf(0);
  if (marker < 0 || plain.subarray(marker).some((b) => b !== 0)) return 'bad-padding';
  const doc = JSON.parse(plain.subarray(0, marker).toString('utf8'));
  const kind = as.k || env.k;
  if (kind === 'queue' && state.lastSeq !== undefined && !(env.seq > state.lastSeq)) return 'stale';
  if (kind === 'slice') {
    if ((state.seenIds || []).includes(env.id)) return 'duplicate';
    if (state.nowIso) {
      const age = Date.parse(state.nowIso) - Date.parse(doc.at);
      if (age > VEC.rules.maxAgeMs) return 'stale';
      if (-age > VEC.rules.maxAheadMs) return 'future';
    }
  }
  return { ok: true, plaintext: doc };
}

const ENV = Object.fromEntries(VEC.envelopes.map((e) => [e.name, e]));
const F = VEC.file;
const CHUNK = F.chunkBytes;

function fileBytes(rule) {
  const unit = u8(rule.text);
  const out = Buffer.alloc(rule.bytes);
  for (let o = 0; o < out.length; o += unit.length) unit.copy(out, o, 0, Math.min(unit.length, out.length - o));
  return out;
}
const PLAIN = fileBytes(F.plaintext);

/** Every sealed chunk, made from the rules (DK, nonce counter, AAD with last). */
function sealedChunks() {
  const chunkKey = hkdf(Buffer.from(F.dkHex, 'hex'), F.fileId, 'khayt-relay-chunk-v1');
  return F.chunks.map((c) => {
    const part = PLAIN.subarray(c.index * CHUNK, (c.index + 1) * CHUNK);
    const body = c.last ? Buffer.concat([part, Buffer.alloc(CHUNK - part.length)]) : part;
    const n = Buffer.alloc(12); n.writeBigUInt64BE(BigInt(c.index), 4);
    const { ct, tag } = gcm(chunkKey, n, body, `khayt-relay-v1|1|${F.fileId}|${c.index}|${c.last ? 1 : 0}`);
    return Buffer.concat([ct, tag]);
  });
}
const SEALED = sealedChunks();

/** The reference file reader: unwrap DK, open chunks in `order`, cut padding, check the hash. */
function readFile(manifest, opts = {}) {
  if (manifest.wrap !== 'k1') return 'unopenable-wrap';
  const n = manifest.chunks;
  if (!(manifest.bytes <= n * CHUNK && manifest.bytes > (n - 1) * CHUNK)) return 'bad-manifest';
  const w = Buffer.from(manifest.wrappedDk, 'base64');
  const dk = ungcm(KEYS.wrap, w.subarray(0, 12), w.subarray(12, w.length - 16), w.subarray(w.length - 16),
    `khayt-relay-dk|1|${opts.unwrapFileId || manifest.fileId}`);
  if (!dk) return 'unopenable';
  const chunkKey = hkdf(dk, manifest.fileId, 'khayt-relay-chunk-v1');
  const order = opts.order || [...Array(n).keys()];
  if (order.length !== n) return 'bad-manifest';
  const parts = [];
  for (let i = 0; i < n; i++) {
    const s = SEALED[order[i]];
    const last = opts.lastFlags ? opts.lastFlags[i] : i === n - 1;
    const nonce = Buffer.alloc(12); nonce.writeBigUInt64BE(BigInt(i), 4);
    const p = ungcm(chunkKey, nonce, s.subarray(0, s.length - 16), s.subarray(s.length - 16),
      `khayt-relay-v1|1|${manifest.fileId}|${i}|${last ? 1 : 0}`);
    if (!p) return 'unopenable';
    parts.push(p);
  }
  const whole = Buffer.concat(parts).subarray(0, manifest.bytes);
  if (sha(whole) !== manifest.sha256) return 'hash-mismatch';
  return { ok: true, bytes: whole.length };
}

test('the generator reproduces the committed file byte for byte', () => {
  const gen = require('../scripts/gen-connector-relay-vectors.js');
  assert.equal(gen.serialise(gen.build()), fs.readFileSync(gen.OUT, 'utf8'));
});

test('K chains from connector-pair.vectors.json case "first", and the four relay keys match', () => {
  assert.deepEqual(VEC.from, { file: 'docs/connector-pair.vectors.json', case: 'first' });
  assert.equal(VEC.k.deviceId, first.deviceId);
  assert.equal(VEC.k.kHex, K.toString('hex'));
  for (const label of ['up', 'down', 'wrap', 'tag']) {
    assert.equal(VEC.derived[label].keyHex, KEYS[label].toString('hex'), label);
    assert.equal(VEC.derived[label].info, label + '\n' + first.deviceId);
  }
  assert.equal(VEC.derived.lanSealKeyHex, KEYS.lanSeal.toString('hex'));
  const all = ['up', 'down', 'wrap', 'tag', 'lanSeal'].map((l) => KEYS[l].toString('hex'));
  assert.equal(new Set(all).size, 5, 'every key distinct, the LAN seal key included');
  assert.ok(!all.includes(K.toString('hex')), 'no relay key is K itself');
});

test('every envelope: AAD, padding size, ciphertext hash, and it opens to its plaintext', () => {
  const sizes = { slice: 67584, name: 4096, status: 4096 };
  for (const e of VEC.envelopes) {
    assert.equal(e.aad, ['khayt-relay-v1', 1, e.k, first.deviceId, e.id, e.seq].join('|'), e.name);
    if (sizes[e.k]) assert.equal(e.padTo, sizes[e.k], e.name);
    else assert.equal(e.padTo, Math.ceil((u8(e.plaintextJson).length + 1) / 16384) * 16384, e.name);
    assert.equal(sha(padded(e)), e.paddedSha256, e.name);
    const ct = ctOf(e);
    assert.equal(ct.length, e.ctBytes, e.name);
    assert.equal(sha(ct), e.ctSha256, e.name);
    assert.equal(e.envelope.tag, gcm(KEYS[e.direction], Buffer.from(e.ivHex, 'hex'), padded(e), e.aad).tag.toString('base64'), e.name);
    const r = open(e.envelope, ct, { key: e.direction });
    assert.equal(typeof r, 'object', `${e.name}: ${r}`);
    assert.deepEqual(r.plaintext, e.plaintext, e.name);
    assert.equal(JSON.stringify(e.plaintext), e.plaintextJson, e.name);
  }
});

test('the slice carries a capture that connector-slice.js accepts whole, and the manifest of the file', () => {
  const S = require('../lib/connector-slice.js');
  const { capture, manifest } = ENV.slice.plaintext;
  const r = S.check(capture, {});
  assert.ok(r.ok, JSON.stringify(r));
  assert.deepEqual(r.dropped, []);
  assert.equal(capture.file.sha256, manifest.sha256);
  assert.equal(capture.file.bytes, manifest.bytes);
  assert.deepEqual(manifest, F.manifest);
});

test('the file: chunk hashes, wrapped key, and a full read back to the plaintext', () => {
  assert.equal(F.sha256, sha(PLAIN));
  assert.equal(F.chunks.length, Math.ceil(PLAIN.length / CHUNK));
  SEALED.forEach((s, i) => {
    assert.equal(s.length, CHUNK + 16, 'every chunk, the last included, is a whole padded chunk');
    assert.equal(sha(s), F.chunks[i].cipherSha256);
    assert.equal(F.manifest.chunkHashes[i], F.chunks[i].cipherSha256);
  });
  assert.equal(Buffer.from(F.fileId, 'base64url').length, 16);
  assert.match(F.fileId, ID);
  const r = readFile(F.manifest);
  assert.equal(typeof r, 'object', String(r));
  assert.equal(r.bytes, PLAIN.length);
});

test('queue seq = max(lastSeq + 1, unix ms)', () => {
  for (const c of VEC.seqRule) assert.equal(c.next, Math.max(c.lastSeq + 1, c.nowMs), c.note);
});

test('dedupe tag: HMAC under the tag key over hash, intent, target and startPrint; each differs', () => {
  for (const d of VEC.dedupe) {
    const input = ['khayt-relay-dedupe-v1', d.sha256hex, d.intent, d.target, d.startPrint ? '1' : '0'].join('\n');
    assert.equal(d.input, input);
    assert.equal(d.tag, crypto.createHmac('sha256', KEYS.tag).update(u8(input)).digest('base64url'));
    assert.ok(!d.tag.includes(d.sha256hex) && !input.includes(KEYS.tag.toString('hex')));
  }
  assert.equal(new Set(VEC.dedupe.map((d) => d.tag)).size, VEC.dedupe.length);
});

test('every must-refuse case fails, for exactly its stated reason', () => {
  assert.equal(VEC.mustRefuse.length, 19);
  for (const c of VEC.mustRefuse) {
    let got;
    if (c.envelope) {
      const e = ENV[c.envelope];
      got = open(e.envelope, ctOf(e), { key: e.direction, ...(c.open || {}) }, c.state || {});
    } else if (c.sealed) {
      const s = c.sealed.envelope;
      got = open(s, Buffer.from(s.ct, 'base64'), { key: 'up' });
    } else if (c.file) {
      got = readFile({ ...F.manifest, ...(c.file.manifestPatch || {}) }, c.file);
    }
    assert.equal(got, c.expect, c.name);
  }
});

test('the same opener accepts each base envelope when nothing is wrong (the refusals are not vacuous)', () => {
  const e = ENV.slice;
  assert.equal(typeof open(e.envelope, ctOf(e), { key: 'up' }, { seenIds: ['msg_Other000001'], nowIso: '2026-11-16T10:05:00Z' }), 'object');
  assert.equal(typeof open(e.envelope, ctOf(e), { key: 'up' }, { nowIso: '2026-11-16T09:50:00Z' }), 'object',
    'ten minutes ahead is still filed (with a clock warning), not refused');
  const q = ENV.queue;
  assert.equal(typeof open(q.envelope, ctOf(q), { key: 'down' }, { lastSeq: q.seq - 1 }), 'object');
});
