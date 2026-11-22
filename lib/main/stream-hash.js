'use strict';
/**
 * SHA-256 of a file, read in chunks, so a 1 GB model is hashed without
 * holding it in memory. The digest is the same as lib/model-identity.js
 * `contentHash` over the whole buffer (and the Mac's 4 MB-chunk
 * LibraryImport.contentHash): lower-case hex, and nothing for an empty file.
 *
 * Main process only. Never throws: the answer says what happened.
 */
const fs = require('fs');
const crypto = require('crypto');

/**
 * @param {string} fullPath
 * @param {{maxBytes?: number, signal?: AbortSignal}} [opts]
 * @returns {Promise<{ok:true, contentHash:string, size:number}
 *   | {ok:false, error:'too-big'|'empty'|'not-a-file'|'aborted'|'unreadable'}>}
 */
async function hashFile(fullPath, opts) {
  const o = opts || {};
  const maxBytes = Number.isFinite(o.maxBytes) ? o.maxBytes : Infinity;
  let st;
  try { st = await fs.promises.stat(fullPath); } catch (_) { return { ok: false, error: 'unreadable' }; }
  if (!st.isFile()) return { ok: false, error: 'not-a-file' };
  if (st.size === 0) return { ok: false, error: 'empty' };
  if (st.size > maxBytes) return { ok: false, error: 'too-big' };
  if (o.signal && o.signal.aborted) return { ok: false, error: 'aborted' };
  return new Promise((resolve) => {
    const h = crypto.createHash('sha256');
    let size = 0;
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    const stream = fs.createReadStream(fullPath, { highWaterMark: 4 << 20 });
    const onAbort = () => { stream.destroy(); finish({ ok: false, error: 'aborted' }); };
    if (o.signal) o.signal.addEventListener('abort', onAbort, { once: true });
    stream.on('data', (chunk) => {
      size += chunk.length;
      // Grew past the cap while being read: stop rather than read on.
      if (size > maxBytes) { stream.destroy(); finish({ ok: false, error: 'too-big' }); return; }
      h.update(chunk);
    });
    stream.on('error', () => finish({ ok: false, error: 'unreadable' }));
    stream.on('end', () => {
      if (o.signal) o.signal.removeEventListener('abort', onAbort);
      finish(size === 0 ? { ok: false, error: 'empty' } : { ok: true, contentHash: h.digest('hex'), size });
    });
  });
}

module.exports = { hashFile };
