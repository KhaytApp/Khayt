#!/usr/bin/env node
'use strict';
/**
 * Generates docs/connector-relay.vectors.json: the shared test vectors for the
 * connector Cloud relay (Khayt for OrcaSlicer ⇄ the shop's Khayt computer,
 * through Khayt Cloud). Design: connector-cloud-relay-design.md rev 2,
 * sections 1, 2.2 and 11.
 *
 *   node scripts/gen-connector-relay-vectors.js          # rewrite the file
 *   node scripts/gen-connector-relay-vectors.js --check  # exit 1 if it differs
 *
 * ── TEST VALUES ONLY ─────────────────────────────────────────────────────
 *
 * Every key, IV and id below is derived from a fixed label, and the pairing
 * key K comes from docs/connector-pair.vectors.json case `first`, whose
 * private keys are themselves sample values. Nothing here may ever be used
 * outside tests. Real seals draw a random IV each time.
 *
 * ── DETERMINISTIC ────────────────────────────────────────────────────────
 *
 * Running this twice gives the same bytes. The large values (a 66 KiB slice
 * envelope, a 9 MiB file) are not stored: the file carries the rule that
 * makes them and the SHA-256 of what comes out, so every implementation
 * proves the exact bytes without the JSON growing to megabytes.
 *
 * test/connector-relay-vector.test.js re-runs build() and compares it with the
 * committed file, then walks every case with its own, separately written
 * opener.
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const OUT = path.join(ROOT, 'docs', 'connector-relay.vectors.json');
const PAIR = path.join(ROOT, 'docs', 'connector-pair.vectors.json');

// ── fixed rules (the design's constants) ────────────────────────────────

const L = {
  pairSalt: 'khayt-device-v1',
  relaySalt: 'khayt-connector-relay-v1',
  lanSealSalt: 'khayt-connector-seal-v1',
  aadPrefix: 'khayt-relay-v1',
  dkAad: 'khayt-relay-dk',
  chunkInfo: 'khayt-relay-chunk-v1',
  dedupe: 'khayt-relay-dedupe-v1',
};
const V = 1;
const CHUNK_BYTES = 4 * 1024 * 1024;
const PAD = { slice: 66 * 1024, small: 4 * 1024, queueStep: 16 * 1024, queueMax: 256 * 1024 };
const ID = /^[A-Za-z0-9_-]{8,64}$/;
const SKEW_MS = 10 * 60 * 1000;
const MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000 + SKEW_MS;
/** Up to this far ahead a slice is filed with a clock warning; beyond it, refused with a sealed status. */
const MAX_AHEAD_MS = 24 * 60 * 60 * 1000;

// ── primitives ──────────────────────────────────────────────────────────

const sha256 = (b) => crypto.createHash('sha256').update(b).digest();
const hex = (b) => Buffer.from(b).toString('hex');
const b64 = (b) => Buffer.from(b).toString('base64');
const b64url = (b) => Buffer.from(b).toString('base64url');
const utf8 = (s) => Buffer.from(String(s), 'utf8');

function hkdf(ikm, salt, info, len = 32) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, utf8(salt), utf8(info), len));
}

/** A fixed test value from a label: never random, never real. */
function fixed(label, len) {
  return sha256(utf8('khayt-relay-vectors|' + label)).subarray(0, len);
}

const X25519_PKCS8 = Buffer.from('302e020100300506032b656e04220420', 'hex');
function x25519(privHex, peerPrivHex) {
  const mine = crypto.createPrivateKey({ key: Buffer.concat([X25519_PKCS8, Buffer.from(privHex, 'hex')]), format: 'der', type: 'pkcs8' });
  const peer = crypto.createPrivateKey({ key: Buffer.concat([X25519_PKCS8, Buffer.from(peerPrivHex, 'hex')]), format: 'der', type: 'pkcs8' });
  const peerPub = crypto.createPublicKey(peer);
  const raw = (k) => k.export({ format: 'jwk' }).x;
  return {
    shared: crypto.diffieHellman({ privateKey: mine, publicKey: peerPub }),
    minePublic: Buffer.from(raw(crypto.createPublicKey(mine)), 'base64url'),
    peerPublic: Buffer.from(raw(peerPub), 'base64url'),
  };
}

function gcmSeal(key, iv, plaintext, aad) {
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  c.setAAD(utf8(aad));
  const ct = Buffer.concat([c.update(plaintext), c.final()]);
  return { ct, tag: c.getAuthTag() };
}

// ── the relay's rules ───────────────────────────────────────────────────

function deriveKeys(K, deviceId) {
  const k = (label) => hkdf(K, L.relaySalt, label + '\n' + deviceId);
  return { up: k('up'), down: k('down'), wrap: k('wrap'), tag: k('tag'), lanSeal: hkdf(K, L.lanSealSalt, deviceId) };
}

function envelopeAad(v, k, deviceId, id, seq) {
  if (!ID.test(deviceId) || !ID.test(id)) throw new Error('id outside [A-Za-z0-9_-]{8,64}');
  if (!Number.isSafeInteger(seq) || seq < 0) throw new Error('seq must be a non-negative integer');
  return [L.aadPrefix, v, k, deviceId, id, seq].join('|');
}

function padTo(kind, jsonLength) {
  if (kind === 'slice') return PAD.slice;
  if (kind === 'queue') {
    const n = Math.ceil((jsonLength + 1) / PAD.queueStep) * PAD.queueStep;
    if (n > PAD.queueMax) throw new Error('queue snapshot over 256 KiB');
    return n;
  }
  return PAD.small;
}

function pad(json, size) {
  const body = utf8(json);
  if (body.length + 1 > size) throw new Error(`plaintext ${body.length} B does not fit ${size} B`);
  return Buffer.concat([body, Buffer.alloc(size - body.length)]); // first padding byte is the 0x00 marker
}

/** queue seq: max(last + 1, unix ms), so a restored Mac starts above what it gave before. */
const nextSeq = (lastSeq, nowMs) => Math.max(lastSeq + 1, nowMs);

function dedupeTag(tagKey, sha256hex, intent, target, startPrint) {
  const input = [L.dedupe, sha256hex, intent, target, startPrint ? '1' : '0'].join('\n');
  return { input, tag: b64url(crypto.createHmac('sha256', tagKey).update(utf8(input)).digest()) };
}

function chunkNonce(i) {
  const n = Buffer.alloc(12);
  n.writeBigUInt64BE(BigInt(i), 4);
  return n;
}
const chunkAad = (fileId, i, last) => [L.aadPrefix, V, fileId, i, last ? 1 : 0].join('|');
const dkAad = (fileId) => [L.dkAad, V, fileId].join('|');

function sealEnvelope(keys, dir, deviceId, k, id, seq, plaintextObj, iv, opts = {}) {
  const json = JSON.stringify(plaintextObj);
  const size = padTo(k, utf8(json).length);
  const padded = pad(json, size);
  const aad = envelopeAad(V, k, deviceId, id, seq);
  const { ct, tag } = gcmSeal(keys[dir], iv, padded, aad);
  const out = {
    name: opts.name || k, direction: dir, k, id, seq,
    plaintext: plaintextObj, plaintextJson: json, padTo: size, paddedSha256: hex(sha256(padded)),
    aad, ivHex: hex(iv),
    envelope: { v: V, k, id, seq, iv: b64(iv), tag: b64(tag) },
    ctBytes: ct.length, ctSha256: hex(sha256(ct)),
  };
  if (opts.inlineCt) out.envelope.ct = b64(ct);
  return out;
}

// ── sample content ──────────────────────────────────────────────────────

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (const byte of buf) {
    c = (crc ^ byte) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([utf8(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
/** A 1×1 white PNG whose tEXt chunk carries the thumbnail canary. */
function canaryPng() {
  const ihdr = Buffer.from([0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]);
  const idat = require('node:zlib').deflateSync(Buffer.from([0, 255, 255, 255]), { level: 9 });
  return Buffer.concat([
    Buffer.from('89504e470d0a1a0a', 'hex'),
    pngChunk('IHDR', ihdr),
    pngChunk('tEXt', utf8('Comment\0KhaytRelayCanaryThumb_7q2')),
    pngChunk('IDAT', idat),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

const FILE_RULE = { kind: 'repeat', text: '; KHAYT-RELAY-CANARY-GCODE\nG1 X1 Y1\n', bytes: 9 * 1024 * 1024 };
function fileBytes(rule) {
  const unit = utf8(rule.text);
  const out = Buffer.alloc(rule.bytes);
  for (let o = 0; o < out.length; o += unit.length) unit.copy(out, o, 0, Math.min(unit.length, out.length - o));
  return out;
}

const AT = '2026-11-16T10:00:00Z';

// ── build ───────────────────────────────────────────────────────────────

function build() {
  const pairDoc = JSON.parse(fs.readFileSync(PAIR, 'utf8'));
  const first = pairDoc.cases.find((c) => c.name === 'first');
  const deviceId = first.deviceId;

  // K as both ends derive it, checked against the pairing file's public keys.
  const macSide = x25519(first.serverPrivateHex, first.pluginPrivateHex);
  const pluginSide = x25519(first.pluginPrivateHex, first.serverPrivateHex);
  if (!macSide.shared.equals(pluginSide.shared)) throw new Error('X25519 sides disagree');
  if (b64(macSide.minePublic) !== first.serverPublic || b64(pluginSide.minePublic) !== first.pluginPublic) {
    throw new Error('public keys differ from connector-pair.vectors.json');
  }
  const K = hkdf(macSide.shared, L.pairSalt, deviceId);
  const keys = deriveKeys(K, deviceId);
  const otherDeviceId = 'dev_SampleConnector0002';

  // The file, its data key and chunks.
  const plain = fileBytes(FILE_RULE);
  const fileSha = hex(sha256(plain));
  const fileId = b64url(fixed('fileId', 16));
  const otherFileId = b64url(fixed('otherFileId', 16));
  const DK = fixed('dk', 32);
  const wrapIv = fixed('wrapIv', 12);
  const wrapped = gcmSeal(keys.wrap, wrapIv, DK, dkAad(fileId));
  const wrappedDk = b64(Buffer.concat([wrapIv, wrapped.ct, wrapped.tag]));
  const chunkKey = hkdf(DK, fileId, L.chunkInfo);
  const nChunks = Math.ceil(plain.length / CHUNK_BYTES);
  const chunks = [];
  for (let i = 0; i < nChunks; i++) {
    const last = i === nChunks - 1;
    const part = plain.subarray(i * CHUNK_BYTES, (i + 1) * CHUNK_BYTES);
    const padded = last ? Buffer.concat([part, Buffer.alloc(CHUNK_BYTES - part.length)]) : part;
    const { ct, tag } = gcmSeal(chunkKey, chunkNonce(i), padded, chunkAad(fileId, i, last));
    const sealed = Buffer.concat([ct, tag]);
    chunks.push({
      index: i, last, aad: chunkAad(fileId, i, last), nonceHex: hex(chunkNonce(i)),
      plainBytes: part.length, paddedTo: CHUNK_BYTES, cipherBytes: sealed.length,
      cipherSha256: hex(sha256(sealed)), tagHex: hex(tag),
    });
  }
  const manifest = {
    fileId, wrap: 'k1', wrappedDk, chunks: nChunks, bytes: plain.length, sha256: fileSha,
    chunkHashes: chunks.map((c) => c.cipherSha256),
  };

  // The capture: a connector-slice.js v1 capture carrying every canary.
  const thumb = canaryPng();
  const capture = {
    v: 1, kind: 'slice', id: 'cap_SampleCapture0001', idem: 'sha256:' + fileSha, at: AT, intent: 'inbox',
    file: { name: 'KhaytRelayCanaryFile_7q2.gcode', bytes: plain.length, sha256: fileSha },
    slicer: { name: 'OrcaSlicer', version: '2.5.1', plugin: '0.1.0' },
    printer: { preset: 'KhaytRelayCanaryPreset_7q2', nozzle: 0.4 },
    process: { preset: 'KhaytRelayCanaryPreset_7q2', layerHeight: 0.2 },
    plate: { index: 1, name: 'KhaytRelayCanaryPlate_7q2', objects: ['KhaytRelayCanaryObject_7q2'] },
    timeSec: 3725, layers: 120,
    filaments: [{ slot: 1, grams: 12.34, type: 'PLA', colour: '#FFFFFF', preset: 'KhaytRelayCanaryPreset_7q2' }],
    thumbnail: { type: 'png', w: 1, h: 1, b64: b64(thumb) },
  };
  const checked = require(path.join(ROOT, 'lib', 'connector-slice.js')).check(capture, {});
  if (!checked.ok || checked.dropped.length) throw new Error('sample capture does not pass connector-slice.js: ' + JSON.stringify(checked));

  const queueSeq = 1795302000000; // 2026-11-23T… in ms; a clock value, as the rule makes it
  const queue = {
    v: 1, at: AT, shop: { name: 'KhaytRelayCanaryShop_7q2' },
    jobs: [{ id: 'ord-7q2', number: 'J-7Q2CANARY', stage: 'printing', machine: 'KhaytRelayCanaryMachine_7q2', file: 'KhaytRelayCanaryFile_7q2.gcode' }],
    machines: [{ id: 'm_7q2', name: 'KhaytRelayCanaryMachine_7q2', state: 'active' }],
    inbox: { waiting: 1 },
  };

  const env = {
    slice: sealEnvelope(keys, 'up', deviceId, 'slice', 'msg_SampleSlice00001', 0, { at: AT, capture, manifest }, fixed('iv-slice', 12)),
    name: sealEnvelope(keys, 'up', deviceId, 'name', 'msg_SampleName000001', 0, { at: AT, name: 'KhaytRelayCanaryName_7q2' }, fixed('iv-name', 12), { inlineCt: true }),
    queue: sealEnvelope(keys, 'down', deviceId, 'queue', 'msg_SampleQueue00001', queueSeq, queue, fixed('iv-queue', 12), { inlineCt: true }),
    status: sealEnvelope(keys, 'down', deviceId, 'status', 'msg_SampleStatus0001', 0, { at: AT, slice: 'msg_SampleSlice00001', state: 'in-inbox' }, fixed('iv-status', 12), { inlineCt: true }),
  };

  // Padding refusals need their own small sealed envelopes (kind `name`).
  const badPad = (label, buf) => {
    const id = 'msg_' + label;
    const aad = envelopeAad(V, 'name', deviceId, id, 0);
    const iv = fixed('iv-' + label, 12);
    const { ct, tag } = gcmSeal(keys.up, iv, buf, aad);
    return { k: 'name', id, seq: 0, aad, plaintextHex: undefined, envelope: { v: V, k: 'name', id, seq: 0, iv: b64(iv), ct: b64(ct), tag: b64(tag) } };
  };
  const json = utf8(JSON.stringify({ at: AT, name: 'x' }));
  const noMarker = Buffer.concat([json, Buffer.alloc(0)]);
  const nonZero = Buffer.concat([json, Buffer.alloc(PAD.small - json.length)]);
  nonZero[nonZero.length - 1] = 1;

  const mustRefuse = [
    { name: 'down-key-on-up-message', envelope: 'slice', open: { key: 'down' }, expect: 'unopenable' },
    { name: 'kind-swapped-in-aad', envelope: 'queue', open: { k: 'status' }, expect: 'unopenable' },
    { name: 'version-swapped-in-aad', envelope: 'slice', open: { v: 2 }, expect: 'unopenable' },
    { name: 'other-device', envelope: 'slice', open: { deviceId: otherDeviceId }, expect: 'unopenable',
      note: 'keys AND aad are derived for dev_SampleConnector0002' },
    { name: 'id-outside-alphabet', envelope: 'status', open: { id: 'msg|Sample|0001' }, expect: 'bad-id',
      note: 'refused before any key is used' },
    { name: 'queue-seq-not-larger', envelope: 'queue', state: { lastSeq: queueSeq }, expect: 'stale' },
    { name: 'slice-id-seen', envelope: 'slice', state: { seenIds: ['msg_SampleSlice00001'] }, expect: 'duplicate' },
    { name: 'slice-at-too-old', envelope: 'slice', state: { nowIso: '2026-11-30T10:10:01Z' }, expect: 'stale' },
    { name: 'slice-at-in-future', envelope: 'slice', state: { nowIso: '2026-11-15T09:59:59Z' }, expect: 'future',
      note: 'more than 24 h ahead: refused with a sealed refused:clock status, never silently' },
    { name: 'lan-seal-key', envelope: 'slice', open: { key: 'lanSeal' }, expect: 'unopenable' },
    { name: 'unknown-wrap-mode', file: { manifestPatch: { wrap: 'pk1' } }, expect: 'unopenable-wrap' },
    { name: 'no-pad-marker', sealed: badPad('NoPadMarker01', noMarker), expect: 'bad-padding',
      note: 'the JSON fills the plaintext: no 0x00 marker byte' },
    { name: 'non-zero-padding', sealed: badPad('NonZeroPad001', nonZero), expect: 'bad-padding',
      note: 'marker present, last byte 0x01' },
    { name: 'chunks-swapped', file: { order: [1, 0, 2] }, expect: 'unopenable' },
    { name: 'last-chunk-missing', file: { order: [0, 1], manifestPatch: { chunks: 2, bytes: 2 * CHUNK_BYTES } }, expect: 'unopenable',
      note: 'a truncated file read as a whole one: chunk 1 opened as the last chunk fails, its AAD says last=0' },
    { name: 'last-flag-lied', file: { lastFlags: [false, true, true] }, expect: 'unopenable' },
    { name: 'dk-wrapped-for-other-file', file: { unwrapFileId: otherFileId }, expect: 'unopenable' },
    { name: 'bytes-past-padding', file: { manifestPatch: { bytes: nChunks * CHUNK_BYTES + 1 } }, expect: 'bad-manifest' },
    { name: 'sha256-mismatch', file: { manifestPatch: { sha256: hex(sha256(utf8('not the file'))) } }, expect: 'hash-mismatch' },
  ];

  return {
    about: 'Connector Cloud relay v1 (connector-cloud-relay-design.md rev 2). TEST VALUES ONLY: K comes from '
      + 'docs/connector-pair.vectors.json case "first" (sample private keys); every other key, IV and id is '
      + 'SHA-256("khayt-relay-vectors|" + label) cut to length. Real seals use a random 12-byte IV. '
      + 'Encodings: hex for raw keys and IVs, standard padded base64 on the wire, base64url for fileId and the tag. '
      + 'Rules: K = HKDF-SHA256(X25519(mac, plugin), salt "khayt-device-v1", info deviceId). '
      + 'Relay keys = HKDF-SHA256(K, salt "khayt-connector-relay-v1", info label + "\\n" + deviceId) for up/down/wrap/tag; '
      + 'the LAN seal key = HKDF-SHA256(K, salt "khayt-connector-seal-v1", info deviceId) must differ from all four. '
      + 'Envelope = AES-256-GCM under up (plugin to Mac) or down (Mac to plugin), AAD "khayt-relay-v1|v|k|deviceId|id|seq", '
      + 'id and deviceId [A-Za-z0-9_-]{8,64}, seq decimal (0 for every kind but queue). Plaintext = UTF-8 JSON, one 0x00 '
      + 'marker, zeros to padTo (slice 67584; queue the next multiple of 16384 up to 262144; others 4096); '
      + 'a non-zero byte after the marker, or no marker, is bad-padding. Files: 4 MiB chunks, last padded with zeros, '
      + 'chunkKey = HKDF-SHA256(DK, salt utf8(fileId), info "khayt-relay-chunk-v1"), nonce = 4 zero bytes + uint64 BE index, '
      + 'chunk AAD "khayt-relay-v1|1|fileId|i|last(1/0)", sealed chunk = ct || 16-byte tag, chunkHashes = SHA-256 of sealed chunks; '
      + 'wrappedDk = base64(iv || ct || tag) of DK under wrap, AAD "khayt-relay-dk|1|fileId", wrap mode "k1". '
      + 'A manifest is bad when bytes > chunks*4194304 or bytes <= (chunks-1)*4194304. '
      + 'Slice at (stamped at announce): refused as stale when older than 14 d + 10 min, as future when more than 24 h ahead '
      + '(10 min to 24 h ahead is filed with a clock warning); a refusal always sends a sealed status. '
      + 'Dedupe tag = base64url HMAC-SHA256(tag, "khayt-relay-dedupe-v1\\n" + sha256hex + "\\n" + intent + "\\n" + target + "\\n" + startPrint 1/0). '
      + 'Queue seq = max(lastSeq + 1, unix ms); the plugin refuses seq <= lastSeq. '
      + 'Large ciphertexts are given by ctBytes + ctSha256; regenerate them from plaintextJson, padTo and ivHex.',
    WARNING: 'Sample keys. A build that finds one of these in a real pairing must refuse it.',
    generator: 'scripts/gen-connector-relay-vectors.js',
    from: { file: 'docs/connector-pair.vectors.json', case: 'first' },
    k: { deviceId, sharedHex: hex(macSide.shared), kHex: hex(K) },
    derived: {
      salt: L.relaySalt,
      up: { info: 'up\n' + deviceId, keyHex: hex(keys.up) },
      down: { info: 'down\n' + deviceId, keyHex: hex(keys.down) },
      wrap: { info: 'wrap\n' + deviceId, keyHex: hex(keys.wrap) },
      tag: { info: 'tag\n' + deviceId, keyHex: hex(keys.tag) },
      lanSealKeyHex: hex(keys.lanSeal),
    },
    otherDevice: { deviceId: otherDeviceId },
    rules: { chunkBytes: CHUNK_BYTES, pad: PAD, maxAgeMs: MAX_AGE_MS, skewMs: SKEW_MS, maxAheadMs: MAX_AHEAD_MS, idPattern: ID.source },
    envelopes: [env.slice, env.name, env.queue, env.status],
    seqRule: [
      { lastSeq: queueSeq, nowMs: queueSeq - 1000000, next: nextSeq(queueSeq, queueSeq - 1000000), note: 'clock behind: last + 1' },
      { lastSeq: 41, nowMs: queueSeq, next: nextSeq(41, queueSeq), note: 'restored from an old backup: the clock wins' },
    ],
    dedupe: [
      { sha256hex: fileSha, intent: 'inbox', target: '', startPrint: false, ...dedupeTag(keys.tag, fileSha, 'inbox', '', false) },
      { sha256hex: fileSha, intent: 'job', target: '', startPrint: false, ...dedupeTag(keys.tag, fileSha, 'job', '', false) },
      { sha256hex: fileSha, intent: 'attach', target: 'ord-7q2', startPrint: false, ...dedupeTag(keys.tag, fileSha, 'attach', 'ord-7q2', false) },
      { sha256hex: fileSha, intent: 'print', target: 'm_7q2', startPrint: true, ...dedupeTag(keys.tag, fileSha, 'print', 'm_7q2', true) },
    ],
    file: {
      fileId, otherFileId, chunkBytes: CHUNK_BYTES, plaintext: FILE_RULE, sha256: fileSha,
      dkHex: hex(DK), wrap: 'k1', wrapIvHex: hex(wrapIv), wrapAad: dkAad(fileId), wrappedDk,
      chunkKeyHex: hex(chunkKey), chunks, manifest,
    },
    mustRefuse,
  };
}

function serialise(doc) { return JSON.stringify(doc, null, 2) + '\n'; }

if (require.main === module) {
  const text = serialise(build());
  if (process.argv.includes('--check')) {
    const now = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : '';
    if (now !== text) { console.error('docs/connector-relay.vectors.json is out of date: run node scripts/gen-connector-relay-vectors.js'); process.exit(1); }
    console.log('connector-relay vectors up to date');
  } else {
    fs.writeFileSync(OUT, text);
    console.log('wrote ' + path.relative(ROOT, OUT) + ' (' + text.length + ' bytes)');
  }
}

module.exports = { build, serialise, OUT };
