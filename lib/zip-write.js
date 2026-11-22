'use strict';
/**
 * Minimal, dependency-free ZIP writer — the counterpart to lib/zip-read.js. Just enough
 * to repackage a 3MF container after the converter rewrites some of its members: build a
 * ZIP Buffer from a list of { name, data } members.
 *
 * Design rules (mirror zip-read.js):
 *   - STORE (method 0) or DEFLATE (method 8, via Node's zlib.deflateRawSync). Per-member
 *     we keep whichever is smaller, so already-compressed PNGs aren't inflated.
 *   - Classic 32-bit ZIP: local file header + central directory + EOCD, CRC32 per member.
 *     No zip64 / encryption (3MF members are far under 4 GB).
 *   - Pure Node (Buffer + zlib) — main-process only, no DOM. Round-trips with openZip().
 */
let zlib = null;
try { zlib = require('zlib'); } catch (_) { zlib = null; }

const SIG_LFH = 0x04034b50;
const SIG_CDH = 0x02014b50;
const SIG_EOCD = 0x06054b50;

// Standard CRC-32 (IEEE 802.3), table-driven.
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0 ^ -1;
  for (let i = 0; i < buf.length; i++) c = (c >>> 8) ^ CRC_TABLE[(c ^ buf[i]) & 0xff];
  return (c ^ -1) >>> 0;
}

function toBuf(data) {
  if (Buffer.isBuffer(data)) return data;
  if (data == null) return Buffer.alloc(0);
  if (typeof data === 'string') return Buffer.from(data, 'utf8');
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  return Buffer.alloc(0);
}

/**
 * Validate a passthrough descriptor from zip-read's readEntryRaw. Anything that isn't a
 * complete, writable one falls back to compressing `data` normally — a member is never
 * written from a half-trusted descriptor.
 */
function passthrough(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (raw.method !== 0 && raw.method !== 8) return null;
  const comp = Buffer.isBuffer(raw.comp) ? raw.comp : (ArrayBuffer.isView(raw.comp) ? toBuf(raw.comp) : null);
  if (!comp) return null;
  if (!Number.isInteger(raw.size) || raw.size < 0 || raw.size > 0xffffffff) return null;
  if (!Number.isInteger(raw.crc)) return null;
  // A STORE member's stored bytes ARE its contents; a mismatch means the descriptor
  // doesn't describe this payload and we can't write a coherent header from it.
  if (raw.method === 0 && comp.length !== raw.size) return null;
  return { method: raw.method, comp, crc: raw.crc >>> 0, size: raw.size };
}

/**
 * Build a ZIP archive from members.
 *
 * A member is either content to compress (`data`) or a member copied from another archive
 * still compressed (`raw`, from zip-read's readEntryRaw). `raw` wins when present and
 * valid, and costs a memcpy instead of a deflate.
 *
 * @param {Array<{name: string, data?: Buffer|Uint8Array|ArrayBuffer|string, raw?: {method,comp,crc,size}, store?: boolean}>} members
 * @returns {Buffer|null} the ZIP bytes, or null if input is unusable.
 */
function writeZip(members) {
  if (!Array.isArray(members) || !members.length) return null;

  const fileParts = [];   // local header + data, in order
  const central = [];     // central-directory records
  let offset = 0;

  for (const m of members) {
    if (!m || typeof m.name !== 'string' || !m.name) return null;
    const nameBuf = Buffer.from(m.name.replace(/\\/g, '/'), 'utf8');

    // A member nobody rewrote can be copied across still compressed — see
    // zip-read's readEntryRaw. Deflating at level 9 costs about twenty seconds
    // for a 240 MB mesh, and repackaging a 3MF usually changes a few kilobytes
    // of config and not one byte of geometry.
    const pre = passthrough(m.raw);
    let method, body, crc, rawLen;
    if (pre) {
      method = pre.method; body = pre.comp; crc = pre.crc >>> 0; rawLen = pre.size;
    } else {
      const raw = toBuf(m.data);
      crc = crc32(raw);
      rawLen = raw.length;
      // Choose STORE vs DEFLATE (skip deflate if it doesn't help or zlib is unavailable).
      method = 0;
      body = raw;
      if (!m.store && zlib && raw.length > 0) {
        let def = null;
        try { def = zlib.deflateRawSync(raw, { level: 9 }); } catch (_) { def = null; }
        if (def && def.length < raw.length) { method = 8; body = def; }
      }
    }

    const lfh = Buffer.alloc(30);
    lfh.writeUInt32LE(SIG_LFH, 0);
    lfh.writeUInt16LE(20, 4);            // version needed
    lfh.writeUInt16LE(0x0800, 6);        // flags: UTF-8 filename
    lfh.writeUInt16LE(method, 8);
    lfh.writeUInt16LE(0, 10);            // mod time
    lfh.writeUInt16LE(0x21, 12);         // mod date (fixed 1980-01-01)
    lfh.writeUInt32LE(crc, 14);
    lfh.writeUInt32LE(body.length, 18);  // compressed size
    lfh.writeUInt32LE(rawLen, 22);       // uncompressed size
    lfh.writeUInt16LE(nameBuf.length, 26);
    lfh.writeUInt16LE(0, 28);            // extra length

    fileParts.push(lfh, nameBuf, body);

    const cdh = Buffer.alloc(46);
    cdh.writeUInt32LE(SIG_CDH, 0);
    cdh.writeUInt16LE(20, 4);            // version made by
    cdh.writeUInt16LE(20, 6);            // version needed
    cdh.writeUInt16LE(0x0800, 8);        // flags: UTF-8
    cdh.writeUInt16LE(method, 10);
    cdh.writeUInt16LE(0, 12);            // mod time
    cdh.writeUInt16LE(0x21, 14);         // mod date
    cdh.writeUInt32LE(crc, 16);
    cdh.writeUInt32LE(body.length, 20);
    cdh.writeUInt32LE(rawLen, 24);
    cdh.writeUInt16LE(nameBuf.length, 28);
    cdh.writeUInt16LE(0, 30);            // extra length
    cdh.writeUInt16LE(0, 32);            // comment length
    cdh.writeUInt16LE(0, 34);            // disk number
    cdh.writeUInt16LE(0, 36);            // internal attrs
    cdh.writeUInt32LE(0, 38);            // external attrs
    cdh.writeUInt32LE(offset, 42);       // local header offset

    central.push(Buffer.concat([cdh, nameBuf]));
    offset += lfh.length + nameBuf.length + body.length;
  }

  const cd = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(SIG_EOCD, 0);
  eocd.writeUInt16LE(0, 4);              // disk number
  eocd.writeUInt16LE(0, 6);             // cd start disk
  eocd.writeUInt16LE(members.length, 8);
  eocd.writeUInt16LE(members.length, 10);
  eocd.writeUInt32LE(cd.length, 12);
  eocd.writeUInt32LE(offset, 16);       // cd offset
  eocd.writeUInt16LE(0, 20);            // comment length

  return Buffer.concat([...fileParts, cd, eocd]);
}

const api = { writeZip, crc32 };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytZipWrite = api;
