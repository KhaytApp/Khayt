'use strict';

/**
 * The most one member may inflate to.
 *
 * EXPORTED because lib/zip-intake.js has to charge its budget the same number.
 * It charged the DECLARED size and charged nothing at all when a member declared
 * none — while this cap let exactly those members inflate to the full ceiling.
 * A 0.47 MB archive of eight members each declaring `size: 0` therefore passed a
 * 2 GiB budget "costing 0 MB" and wrote 480 MB to disk; at 512 members the
 * ceiling is about 200 GB. Reachable by a shop dropping a downloaded model pack,
 * not only by a compromised renderer.
 *
 * The two numbers must not drift apart again: test/zip-intake.test.js asserts
 * the budget charges what this permits.
 */
const MAX_INFLATED = 400 * 1024 * 1024;

/**
 * Minimal, dependency-free ZIP reader — just enough to pull named members out of a
 * 3MF container (which is a ZIP): the embedded slicer thumbnail PNG and the small
 * *.config text members that carry colour / filament-swap info.
 *
 * Design rules:
 *   - Central-directory driven. Sizes come from the central directory, so entries
 *     written with a streaming data-descriptor (flag bit 3, zero sizes in the local
 *     header) still read correctly.
 *   - Supports STORE (method 0) and DEFLATE (method 8) via Node's built-in zlib,
 *     and zip64 containers (see findEocd). Encrypted / other methods are skipped
 *     (return null), never guessed.
 *   - NEVER throws on malformed input — returns empty listings / null members so the
 *     main process can't be crashed by a bad file.
 *
 * Pure Node (uses Buffer + zlib) — main-process only, no DOM.
 */
let zlib = null;
try { zlib = require('zlib'); } catch (_) { zlib = null; }

const SIG_EOCD  = 0x06054b50;
const SIG_CDH   = 0x02014b50;
const SIG_LFH   = 0x04034b50;
const SIG_EOCD64 = 0x06064b50;      // zip64 end of central directory record
const SIG_LOC64  = 0x07064b50;      // zip64 end of central directory locator
const U32_MAX   = 0xffffffff;
const U16_MAX   = 0xffff;

/**
 * A 64-bit little-endian field, as a JS number.
 *
 * Bounded to what a Number holds exactly and to what this reader will ever be
 * handed: anything over 2^53 is not an offset into a file this process could
 * have in memory, and is reported as null rather than silently rounded — a
 * rounded offset is a read of arbitrary bytes.
 */
function u64(buf, at) {
  if (at + 8 > buf.length) return null;
  const lo = buf.readUInt32LE(at), hi = buf.readUInt32LE(at + 4);
  if (hi > 0x1fffff) return null;
  return hi * 0x100000000 + lo;
}

function toBuf(input) {
  if (Buffer.isBuffer(input)) return input;
  if (input instanceof ArrayBuffer) return Buffer.from(input);
  if (ArrayBuffer.isView(input)) return Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  return null;
}

/**
 * Find the End-Of-Central-Directory record by scanning backward from the tail.
 *
 * ── ZIP64, AND WHY A 34 KB FILE NEEDS IT ────────────────────────────────────
 *
 * This returned null for any archive whose EOCD carried the zip64 markers,
 * and the comment said why: nothing this reads is near 4 GB. True — and
 * beside the point, because some writers emit zip64 for EVERY archive, size
 * regardless. Thirteen of one shop's eighty-five 3MFs were such files, the
 * smallest 34 KB, and every one came back as an empty listing: no thumbnail,
 * no geometry, no key. The Mac app refused them the same way, so the two
 * apps agreed on those files perfectly, and both were wrong.
 *
 * When the 32-bit fields are the 0xFFFF markers, the real values are in the
 * zip64 EOCD record, found through the locator that sits just before the
 * plain EOCD. Both are checked for their signature and for pointing inside
 * the file — a misread offset is a read of arbitrary bytes.
 */
function findEocd(buf) {
  const min = 22; // EOCD fixed size
  if (buf.length < min) return null;
  const maxComment = 0xffff;
  const start = Math.max(0, buf.length - (min + maxComment));
  for (let i = buf.length - min; i >= start; i--) {
    if (buf.readUInt32LE(i) !== SIG_EOCD) continue;
    let cdCount  = buf.readUInt16LE(i + 10);
    let cdSize   = buf.readUInt32LE(i + 12);
    let cdOffset = buf.readUInt32LE(i + 16);
    if (cdCount === U16_MAX || cdOffset === U32_MAX || cdSize === U32_MAX) {
      // The locator is the 20 bytes before the EOCD.
      const loc = i - 20;
      if (loc < 0 || buf.readUInt32LE(loc) !== SIG_LOC64) continue;
      const recAt = u64(buf, loc + 8);
      if (recAt === null || recAt + 56 > buf.length || buf.readUInt32LE(recAt) !== SIG_EOCD64) continue;
      const count64 = u64(buf, recAt + 32), size64 = u64(buf, recAt + 40), off64 = u64(buf, recAt + 48);
      if (count64 === null || size64 === null || off64 === null) continue;
      cdCount = count64; cdSize = size64; cdOffset = off64;
    }
    if (cdOffset + cdSize > buf.length) continue; // false-positive signature
    return { cdCount, cdSize, cdOffset };
  }
  return null;
}

/**
 * List the members of a ZIP.
 * @returns {Array<{name, method, compSize, size, crc, localOffset}>} (empty on any error)
 */
function listEntries(input) {
  const buf = toBuf(input);
  if (!buf) return [];
  const eocd = findEocd(buf);
  if (!eocd) return [];
  const entries = [];
  let p = eocd.cdOffset;
  for (let n = 0; n < eocd.cdCount; n++) {
    if (p + 46 > buf.length || buf.readUInt32LE(p) !== SIG_CDH) break;
    const method     = buf.readUInt16LE(p + 10);
    const crc        = buf.readUInt32LE(p + 16);
    const compSize   = buf.readUInt32LE(p + 20);
    const size       = buf.readUInt32LE(p + 24);
    const fnameLen   = buf.readUInt16LE(p + 28);
    const extraLen   = buf.readUInt16LE(p + 30);
    const commentLen = buf.readUInt16LE(p + 32);
    let localOffset = buf.readUInt32LE(p + 42);
    const name = buf.toString('utf8', p + 46, p + 46 + fnameLen);
    let compSize64 = compSize, size64 = size, ok = true;
    if (compSize === U32_MAX || size === U32_MAX || localOffset === U32_MAX) {
      // The zip64 extra field (id 0x0001) carries, IN THIS ORDER and only for
      // the fields that are marked: uncompressed size, compressed size, local
      // header offset. A marked field with no extra to read it from is a
      // malformed entry and is skipped, as it was.
      ok = false;
      let q = p + 46 + fnameLen; const end = q + extraLen;
      while (q + 4 <= end) {
        const id = buf.readUInt16LE(q), len = buf.readUInt16LE(q + 2);
        if (id === 0x0001) {
          let r = q + 4; const stop = Math.min(end, r + len);
          let s = size, c = compSize, o = localOffset;
          if (size === U32_MAX)        { s = u64(buf, r); r += 8; }
          if (compSize === U32_MAX)    { c = u64(buf, r); r += 8; }
          if (localOffset === U32_MAX) { o = u64(buf, r); r += 8; }
          if (r <= stop && s !== null && c !== null && o !== null) { size64 = s; compSize64 = c; localOffset = o; ok = true; }
          break;
        }
        q += 4 + len;
      }
    }
    if (ok) entries.push({ name, method, compSize: compSize64, size: size64, crc: crc >>> 0, localOffset });
    p += 46 + fnameLen + extraLen + commentLen;
  }
  return entries;
}

/** The member's stored (still-compressed) bytes, or null if the headers don't line up. */
function sliceStored(buf, entry) {
  const lo = entry.localOffset;
  if (lo + 30 > buf.length || buf.readUInt32LE(lo) !== SIG_LFH) return null;
  // Local header may have its own (different) filename/extra lengths.
  const fnameLen = buf.readUInt16LE(lo + 26);
  const extraLen = buf.readUInt16LE(lo + 28);
  const dataStart = lo + 30 + fnameLen + extraLen;
  const dataEnd = dataStart + entry.compSize;
  if (dataEnd > buf.length) return null;
  return buf.subarray(dataStart, dataEnd);
}

/**
 * One entry's bytes AS STORED — still compressed, with the descriptors needed to write
 * them into another archive untouched: `{ method, comp, crc, size, compSize }`, or null
 * if the entry uses a method we can't also write.
 *
 * This is what lets a repackage skip the member entirely. Inflating a 240 MB mesh only to
 * deflate it back to the same bytes costs about twenty seconds per member and buys
 * nothing when nothing rewrote it.
 *
 * `comp` is a view into the source buffer, not a copy — it stays valid only while that
 * buffer does, which is the whole point. The CRC is the source's own; a passthrough
 * reproduces the member exactly, including a CRC that was already wrong.
 */
function readEntryRaw(input, entry) {
  const buf = toBuf(input);
  if (!buf || !entry) return null;
  if (entry.method !== 0 && entry.method !== 8) return null;
  const comp = sliceStored(buf, entry);
  if (!comp) return null;
  return { method: entry.method, comp, crc: entry.crc >>> 0, size: entry.size, compSize: entry.compSize };
}

/** Read + decompress one central-directory entry → Buffer, or null on any problem. */
function readEntry(input, entry) {
  const buf = toBuf(input);
  if (!buf || !entry) return null;
  const comp = sliceStored(buf, entry);
  if (!comp) return null;
  try {
    if (entry.method === 0) return Buffer.from(comp);           // STORE
    if (entry.method === 8) {                                   // DEFLATE
      if (!zlib) return null;
      // Zip-bomb guard: bound the inflated size. The central directory declares the
      // uncompressed size; honour it (with a little slack) and cap at a hard ceiling so
      // a member that lies about its size — or has none (streaming descriptor) — can't
      // inflate to gigabytes and OOM the process. Over-limit throws → caught → null.
      const cap = entry.size > 0 ? Math.min(entry.size + 1024, MAX_INFLATED) : MAX_INFLATED;
      return zlib.inflateRawSync(comp, { maxOutputLength: cap });
    }
    return null; // unsupported method
  } catch (_) {
    return null;
  }
}

/**
 * Convenience: open a ZIP and expose lookups.
 * @returns {{ entries, file(name)=>Buffer|null, match(regexp)=>Buffer|null, matchName(regexp)=>entry|null }}
 */
function openZip(input) {
  const buf = toBuf(input);
  const entries = listEntries(buf);
  const norm = (s) => String(s).replace(/^\.?\//, '').toLowerCase();
  return {
    entries,
    file(name) {
      const target = norm(name);
      const e = entries.find((x) => norm(x.name) === target);
      return e ? readEntry(buf, e) : null;
    },
    /** As stored, still compressed — see readEntryRaw. */
    raw(name) {
      const target = norm(name);
      const e = entries.find((x) => norm(x.name) === target);
      return e ? readEntryRaw(buf, e) : null;
    },
    rawOf(entry) {
      return entry ? readEntryRaw(buf, entry) : null;
    },
    entryData(entry) {
      return entry ? readEntry(buf, entry) : null;
    },
    matchName(re) {
      return entries.find((x) => re.test(x.name)) || null;
    },
    match(re) {
      const e = entries.find((x) => re.test(x.name));
      return e ? readEntry(buf, e) : null;
    },
  };
}

const api = { listEntries, readEntry, readEntryRaw, openZip, findEocd, MAX_INFLATED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytZip = api;
