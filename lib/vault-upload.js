'use strict';

/**
 * One file into the Khayt Vault, for the Electron main process.
 *
 * The JavaScript twin of the native Mac app's `VaultUpload.run`
 * (mac/KhaytCore/Sources/KhaytCore/VaultUpload.swift). Same wire, same crypto
 * calls, same order, so a file uploaded here reads back on the Mac and the
 * iPhone, and a file either app uploaded dedupes here.
 *
 * ── THE ORDER (VaultUpload.swift, "THE ORDER, AND WHY") ─────────────────
 *
 * 1. Hash the plaintext (streamed when `readChunk` is given) and compute the
 *    dedupe tag. A 409 duplicate means the shop already has these bytes:
 *    return that file and version, upload nothing.
 * 2. POST, and only then encrypt: `uploadId` is in every chunk's AAD and in
 *    the chunk key, so nothing can be sealed before the cloud answers.
 * 3. Seal each chunk under a fresh DK, then the wrapped DK, the version's own
 *    record (its whole manifest) and the shop meta record. The raw DK is never
 *    handed to the spool; only its wrap under the vault key is.
 * 4. PUT the parts, `concurrency` at a time, recording each one sent.
 * 5. /complete with the wrapped DK, the version record and the meta. A 409
 *    parts-missing re-PUTs the STORED ciphertext (up to three /complete
 *    attempts, as the Swift).
 *
 * **Never re-encrypt under a new key or nonce.** Chunk nonces are counters
 * under a per-upload chunk key, so sealing chunk i twice is safe only when the
 * plaintext is the same. Where the sealed bytes are kept:
 *   - `spool` given: every sealed chunk goes into it before anything is PUT,
 *     with the upload state, exactly as the Mac's spool directory. A later run
 *     with the same spool and the same bytes RESUMES: same uploadId, the same
 *     sealed bytes, only the parts not yet sent, fresh presigned URLs.
 *   - `bytes` given, no spool: the sealed chunks are held in memory.
 *   - `readChunk` given, no spool: memory stays bounded (one chunk per part in
 *     flight). A part to send or re-send is sealed again from the source under
 *     the SAME DK and nonce, which gives the same bytes, and is checked against
 *     the manifest's hash before it goes anywhere; a source that changed under
 *     us is refused ('source-changed'), never sent.
 *
 * **Failure.** Without a spool the DK lives only in this call, so nothing can
 * resume it: any failure after the POST abandons the upload (DELETE) to free
 * its reservation. With a spool, a failure while SENDING keeps the upload and
 * the spool for the next run, as the Mac does; a failure while sealing
 * abandons and clears it.
 *
 * **seq.** The meta record's seq is one more than the last seq this device saw
 * for the file (`VaultSync.putFile` passes `live.entry.seq` as `lastSeq`;
 * `VaultUpload.seal` writes `(lastSeq ?? 0) + 1`). Pass `lastSeq`, or a
 * `state` with `nextSeq(fileId)` that owns that per-device memory.
 */

const nodeCrypto = require('node:crypto');
const VC = require('./vault-crypto.js');

const CONCURRENCY = 3;
const TAG_BYTES = 16;
const COMPLETE_ATTEMPTS = 3;

const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const unb64 = (s) => new Uint8Array(Buffer.from(String(s || ''), 'base64'));
const u8 = (x) => (x instanceof Uint8Array ? x : new Uint8Array(x || []));

function uploadError(reason, message, extra) {
  const e = new Error(message);
  e.name = 'VaultUploadError';
  e.reason = reason;
  if (extra) Object.assign(e, extra);
  return e;
}
// Never sent, never logged, never retried: a re-sealed chunk whose bytes differ
// would put two plaintexts under one DK and counter nonce — GCM nonce reuse.
const sourceChanged = () => uploadError('source-changed', 'The file changed since the upload started; nothing more was sent.');

/** Every chunk's ciphertext size: plaintext + 16; a 0-byte file is one 16-byte chunk. */
function sealedSizes(size) {
  const n = VC.chunkCount(size);
  const cb = VC.CHUNK_BYTES;
  const out = [];
  for (let i = 0; i < n; i++) out.push(i < n - 1 ? cb + TAG_BYTES : (size - (n - 1) * cb) + TAG_BYTES);
  return out;
}

/**
 * The shop meta record's JSON exactly as the Mac writes it: `VaultMeta`
 * through a JSONEncoder with sortedKeys + withoutEscapingSlashes. `path` and
 * `kind` are always present; `key` and `recordId` only when set.
 */
function metaJson(m) {
  const o = { seq: m.seq, uploadId: m.uploadId, manifestHash: m.manifestHash, size: m.size, sha256: m.sha256,
    name: String(m.name), path: String(m.path || ''), kind: String(m.kind || '') };
  if (m.key != null) o.key = String(m.key);
  if (m.recordId != null) o.recordId = String(m.recordId);
  const sorted = {};
  for (const k of Object.keys(o).sort()) sorted[k] = o[k];
  return JSON.stringify(sorted);
}

/** An in-memory spool. Not persistent: it lets one call keep its sealed bytes. */
function memorySpool() {
  let state = null;
  const chunks = new Map();
  return {
    persistent: false,
    load: () => (state ? JSON.parse(JSON.stringify(state)) : null),
    save: (s) => { state = JSON.parse(JSON.stringify(s)); },
    putChunk: (i, bytes) => { chunks.set(i, Uint8Array.from(bytes)); },
    getChunk: (i) => chunks.get(i) || null,
    clear: () => { state = null; chunks.clear(); },
  };
}

/** A source of plaintext: `bytes`, or `readChunk(offset, length)` with `size`. */
function source(o) {
  if (o.bytes != null) {
    const bytes = u8(o.bytes);
    return { size: bytes.length, read: async (off, len) => bytes.subarray(off, off + len), whole: bytes };
  }
  if (typeof o.readChunk !== 'function') throw new Error('uploadFile needs bytes or readChunk');
  if (!Number.isSafeInteger(o.size) || o.size < 0) throw new Error('uploadFile with readChunk needs size');
  return { size: o.size, read: async (off, len) => u8(await o.readChunk(off, len)), whole: null };
}

/** sha256 of the plaintext, a chunk at a time. */
async function digest(src) {
  const h = nodeCrypto.createHash('sha256');
  let size = 0;
  if (src.whole) { h.update(src.whole); size = src.whole.length; } else {
    for (let off = 0; off < src.size; off += VC.CHUNK_BYTES) {
      const pt = await src.read(off, Math.min(VC.CHUNK_BYTES, src.size - off));
      h.update(pt); size += pt.length;
    }
  }
  if (size !== src.size) throw sourceChanged();
  const d = new Uint8Array(h.digest());
  return { digest: d, sha256: VC.hex(d), size };
}

/** Every sealed chunk is in the spool and is still the bytes the manifest names (VaultUpload.spoolIntact). */
async function spoolIntact(spool, s) {
  if (!Array.isArray(s.chunkHashes) || s.chunkHashes.length !== s.sizes.length) return false;
  for (let i = 0; i < s.sizes.length; i++) {
    const d = await spool.getChunk(i);
    if (!d || d.length !== s.sizes[i] || await VC.chunkHash(d) !== s.chunkHashes[i]) return false;
  }
  return true;
}

/**
 * Upload one file. Returns { fileId, version, rev, conflict, duplicate,
 * sha256, size, uploadId?, manifestHash?, meta? }. `duplicate: true` means the
 * shop already had these bytes at that fileId/version (rev is null then).
 *
 * @param {object} o
 * @param {Uint8Array} o.dek           the shop's DEK
 * @param {Uint8Array} [o.bytes]       the plaintext, or:
 * @param {Function} [o.readChunk]     async (offset, length) => Uint8Array, with `size`
 * @param {number} [o.size]
 * @param {string} [o.sha256]          the plaintext's hex sha256, when already known (checked)
 * @param {string} o.name
 * @param {string} [o.path]            folder inside the library, '' for the root
 * @param {string} [o.kind]            'stl', '3mf', …
 * @param {string} [o.key]             the LibraryRemote key (VaultRemote)
 * @param {string} [o.recordId]        the library record's id
 * @param {string} [o.fileId]          for a new version of an existing file
 * @param {number} [o.baseVersion]     the head this device last saw
 * @param {number} [o.lastSeq]         the last meta seq this device saw for the file
 * @param {object} [o.state]           { nextSeq(fileId) } — overrides lastSeq
 * @param {string} [o.deviceId]
 * @param {object} o.client            createVaultClient(...)
 * @param {number} [o.concurrency=3]
 * @param {object} [o.spool]           { load, save, putChunk, getChunk, clear } — makes it resumable
 * @param {Function} [o.onProgress]    ({phase, done, total})
 * @param {object} [o._test]           { dataKey, wrapNonce, versionMetaNonce, metaNonce } — pins the bytes
 */
async function uploadFile(o) {
  if (!o || !o.client) throw new Error('uploadFile needs a client');
  const { client } = o;
  const dek = u8(o.dek);
  const vaultKey = await VC.deriveVaultKey(dek);
  const progress = typeof o.onProgress === 'function' ? o.onProgress : () => {};
  const concurrency = Math.max(1, Math.floor(Number(o.concurrency) || CONCURRENCY));
  const src = source(o);
  const hashed = await digest(src);
  if (o.sha256 != null && String(o.sha256).toLowerCase() !== hashed.sha256) throw sourceChanged();
  progress({ phase: 'hashing', done: hashed.size, total: hashed.size });

  const resumable = !!o.spool;
  const spool = o.spool || (src.whole ? memorySpool() : null);

  // A spool from an earlier run: resume it when it is sealed and still these
  // bytes; otherwise give its upload up and clear it.
  if (resumable) {
    const prior = await spool.load();
    if (prior) {
      if (prior.sealed && prior.sourceSha256 === hashed.sha256 && await spoolIntact(spool, prior)) {
        try {
          return await send(prior, { client, spool, concurrency, firstPage: [], progress, resealer: null, resumable });
        } catch (e) {
          const gone = e && (e.reason === 'upload-expired' || e.reason === 'unknown-upload' || e.reason === 'unknown-file');
          if (!gone) throw e;
        }
      }
      try { await client.abandonUpload(prior.uploadId); } catch { /* best effort */ }
      await spool.clear();
    }
  }

  const sizes = sealedSizes(hashed.size);
  const tag = await VC.dedupeTagFromDigest(dek, hashed.digest);
  let start;
  try {
    start = await client.startUpload({ fileId: o.fileId, baseVersion: o.baseVersion, sizes, tag, deviceId: o.deviceId });
  } catch (e) {
    if (e && e.reason === 'duplicate') {
      return { fileId: e.fileId, version: e.version, rev: null, conflict: false, duplicate: true,
        sha256: hashed.sha256, size: hashed.size };
    }
    throw e;
  }

  let state = { v: 1, sourceSha256: hashed.sha256, size: hashed.size, fileId: start.fileId,
    uploadId: start.uploadId, version: start.version, sizes, sealed: false,
    chunkHashes: [], manifestHash: '', wrappedKey: '', versionMeta: '', meta: '', metaJSON: null, sent: [] };
  let resealer;
  try {
    // Written BEFORE sealing, so a crash mid-seal leaves an uploadId the next run can abandon.
    if (spool) await spool.save(state);
    const sealedOut = await seal(o, state, { src, vaultKey, spool, progress });
    state = sealedOut.state;
    resealer = sealedOut.resealer;
    if (spool) await spool.save(state);
  } catch (e) {
    try { await client.abandonUpload(start.uploadId); } catch { /* best effort */ }
    if (spool) await spool.clear();
    throw e;
  }
  try {
    return await send(state, { client, spool, concurrency, firstPage: start.parts, progress, resealer, resumable });
  } catch (e) {
    if (!resumable) {
      try { await client.abandonUpload(start.uploadId); } catch { /* best effort */ }
      if (spool) await spool.clear();
    }
    throw e;
  }
}

/** Seal every chunk under a fresh DK, re-hashing the plaintext as it goes (VaultUpload.seal). */
async function seal(o, state, { src, vaultKey, spool, progress }) {
  const s = { ...state };
  const t = o._test || {};
  const dk = t.dataKey ? u8(t.dataKey) : VC.newDataKey();
  const n = s.sizes.length;
  const h = nodeCrypto.createHash('sha256');
  const hashes = [];
  for (let i = 0; i < n; i++) {
    const pt = await src.read(i * VC.CHUNK_BYTES, s.sizes[i] - TAG_BYTES);
    if (pt.length + TAG_BYTES !== s.sizes[i]) throw sourceChanged();
    h.update(pt);
    const sealed = await VC.encryptChunk(dk, s.fileId, s.uploadId, i, i === n - 1, pt);
    if (spool) await spool.putChunk(i, sealed);
    hashes.push(await VC.chunkHash(sealed));
    progress({ phase: 'sealing', done: i + 1, total: n });
  }
  if (!src.whole) {
    const extra = await src.read(s.size, 1);
    if (extra && extra.length) throw sourceChanged();
  }
  if (VC.hex(new Uint8Array(h.digest())) !== s.sourceSha256) throw sourceChanged();
  s.chunkHashes = hashes;
  s.manifestHash = await VC.manifestHash(s.size, hashes);
  s.wrappedKey = b64(await VC.wrapDkForShop(vaultKey, dk, s.fileId, s.uploadId,
    t.wrapNonce ? { _nonce: t.wrapNonce } : undefined));
  const seq = o.state && typeof o.state.nextSeq === 'function'
    ? await o.state.nextSeq(s.fileId)
    : (o.lastSeq == null ? 0 : o.lastSeq) + 1;
  VC.checkMetaSeq(seq, null);
  const meta = { seq, uploadId: s.uploadId, manifestHash: s.manifestHash, size: s.size, sha256: s.sourceSha256,
    name: String(o.name == null ? '' : o.name), path: o.path || '', kind: o.kind || '' };
  if (o.key != null) meta.key = o.key;
  if (o.recordId != null) meta.recordId = o.recordId;
  // The version's own record: its whole manifest, so a reader can check every chunk as it streams.
  s.versionMeta = b64(await VC.encryptVersionMeta(vaultKey, s.fileId, s.uploadId,
    { size: s.size, chunkHashes: hashes, seq }, t.versionMetaNonce ? { _nonce: t.versionMetaNonce } : {}));
  s.meta = b64(await VC.encryptMeta(vaultKey, s.fileId, s.uploadId, metaJson(meta),
    t.metaNonce ? { _nonce: t.metaNonce } : {}));
  s.metaJSON = JSON.parse(metaJson(meta));
  s.sealed = true;
  // No spool: a part is sealed again on demand under the same DK (same key,
  // same counter nonce, same plaintext → the same bytes), checked against the
  // manifest before it is sent. The DK stays in this closure only.
  const resealer = spool ? null : async (i) => {
    const pt = await src.read(i * VC.CHUNK_BYTES, s.sizes[i] - TAG_BYTES);
    if (pt.length + TAG_BYTES !== s.sizes[i]) throw sourceChanged();
    const sealed = await VC.encryptChunk(dk, s.fileId, s.uploadId, i, i === n - 1, pt);
    if (await VC.chunkHash(sealed) !== hashes[i]) throw sourceChanged();
    return sealed;
  };
  return { state: s, resealer };
}

/** PUT what is not sent yet, then /complete; re-PUT what it says is missing (VaultUpload.send). */
async function send(state, ctx) {
  const s = { ...state, sent: Array.isArray(state.sent) ? state.sent.slice() : [] };
  const n = s.sizes.length;
  const sent = new Set(s.sent);
  const todo = [];
  for (let i = 0; i < n; i++) if (!sent.has(i)) todo.push(i);
  await putParts(todo, s, ctx, ctx.firstPage);
  if (!s.sealed || !s.wrappedKey || !s.versionMeta || !s.meta) throw uploadError('bad-spool', 'The upload spool is not sealed.');
  let lastMissing = [];
  for (let attempt = 0; attempt < COMPLETE_ATTEMPTS; attempt++) {
    ctx.progress({ phase: 'completing', done: n, total: n });
    try {
      const done = await ctx.client.completeUpload(s.uploadId, { manifestHash: s.manifestHash,
        wrappedKey: s.wrappedKey, versionMeta: s.versionMeta, meta: s.meta });
      if (ctx.spool) await ctx.spool.clear();
      return { ...done, duplicate: false, sha256: s.sourceSha256, size: s.size, uploadId: s.uploadId,
        manifestHash: s.manifestHash, meta: s.metaJSON };
    } catch (e) {
      if (!e || e.reason !== 'parts-missing') throw e;
      // The stored ciphertext again: the very bytes sealed the first time.
      const again = (Array.isArray(e.indexes) ? e.indexes : []).filter((i) => Number.isInteger(i) && i >= 0 && i < n);
      lastMissing = again;
      s.sent = s.sent.filter((i) => !again.includes(i));
      if (ctx.spool) await ctx.spool.save(s);
      await putParts(again, s, ctx, []);
    }
  }
  // The indexes the cloud last named (the Swift reports those not marked
  // sent, which is empty right after a re-PUT; the cloud's list says more).
  throw uploadError('parts-still-missing', 'Khayt Cloud kept reporting parts missing.', { indexes: lastMissing });
}

/**
 * The parts in `indexes`, at most `concurrency` at once, each recorded as it
 * lands. URLs come from `firstPage` where it has them, else from fresh
 * `parts?from=` pages (the cloud pages them, ≤256 at a time).
 */
async function putParts(indexes, s, ctx, firstPage) {
  if (!indexes.length) return;
  const urls = new Map();
  for (const p of firstPage || []) if (!urls.has(p.index)) urls.set(p.index, p);
  const queue = [...new Set(indexes)].sort((a, b) => a - b);
  let failed = null;
  // One taker at a time, so two workers never fetch the same page.
  let lock = Promise.resolve();
  const nextPart = () => {
    const p = lock.then(async () => {
      if (failed || !queue.length) return null;
      const i = queue.shift();
      if (!urls.has(i)) for (const q of await ctx.client.uploadParts(s.uploadId, i)) urls.set(q.index, q);
      const part = urls.get(i);
      if (!part || part.size !== s.sizes[i]) throw uploadError('bad-reply', `Khayt Cloud gave no usable URL for part ${i}.`, { index: i });
      return part;
    });
    lock = p.catch(() => {});
    return p;
  };
  const worker = async () => {
    for (;;) {
      const part = await nextPart();
      if (!part) return;
      const body = ctx.resealer ? await ctx.resealer(part.index) : await ctx.spool.getChunk(part.index);
      if (!body) throw uploadError('bad-spool', `Part ${part.index} is missing from the spool.`, { index: part.index });
      await ctx.client.putPart(part.url, body, { index: part.index, size: part.size });
      if (!s.sent.includes(part.index)) s.sent.push(part.index);
      if (ctx.spool) await ctx.spool.save(s);
      ctx.progress({ phase: 'sending', done: s.sent.length, total: s.sizes.length });
    }
  };
  const results = await Promise.allSettled(Array.from({ length: Math.min(ctx.concurrency, queue.length) }, () =>
    worker().catch((e) => { failed = failed || e; throw e; })));
  const bad = results.find((r) => r.status === 'rejected');
  if (bad) throw failed || bad.reason;
}

module.exports = { uploadFile, sealedSizes, metaJson, memorySpool, CONCURRENCY };
