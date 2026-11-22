'use strict';
// Minimal ZIP writer for tests — enough to exercise lib/zip-read.js and the 3MF
// path in lib/thumbnail-extract.js. Supports STORE (0) and DEFLATE (8). CRCs are
// written as 0 (the reader ignores them).
const zlib = require('zlib');

/**
 * entries: [{ name, data:Buffer|string, method?:0|8 }] → ZIP Buffer
 *
 * `opts.zip64` writes the archive the way a writer that always uses zip64
 * does — some do, size regardless: every 32-bit size and offset in the
 * central directory is the 0xFFFFFFFF marker with the real value in a zip64
 * extra field, and a zip64 end-of-central-directory record and locator sit
 * before the plain one. That is exactly the shape lib/zip-read.js used to
 * return an empty listing for, on a 34 KB file.
 */
function makeZip(entries, opts) {
  const zip64 = !!(opts && opts.zip64);
  const locals = [];
  const centrals = [];
  let offset = 0;
  for (const e of entries) {
    const raw = Buffer.isBuffer(e.data) ? e.data : Buffer.from(String(e.data), 'utf8');
    const method = e.method === 8 ? 8 : 0;
    const comp = method === 8 ? zlib.deflateRawSync(raw) : raw;
    const name = Buffer.from(e.name, 'utf8');

    const lfh = Buffer.alloc(30);
    lfh.writeUInt32LE(0x04034b50, 0);
    lfh.writeUInt16LE(20, 4);
    lfh.writeUInt16LE(0, 6);
    lfh.writeUInt16LE(method, 8);
    lfh.writeUInt32LE(0, 14);            // crc (ignored)
    lfh.writeUInt32LE(comp.length, 18);  // compressed size
    lfh.writeUInt32LE(raw.length, 22);   // uncompressed size
    lfh.writeUInt16LE(name.length, 26);
    lfh.writeUInt16LE(0, 28);            // extra len
    locals.push(lfh, name, comp);

    const cdh = Buffer.alloc(46);
    cdh.writeUInt32LE(0x02014b50, 0);
    cdh.writeUInt16LE(zip64 ? 45 : 20, 4);
    cdh.writeUInt16LE(zip64 ? 45 : 20, 6);
    cdh.writeUInt16LE(0, 8);
    cdh.writeUInt16LE(method, 10);
    cdh.writeUInt32LE(0, 16);            // crc
    cdh.writeUInt32LE(zip64 ? 0xffffffff : comp.length, 20);
    cdh.writeUInt32LE(zip64 ? 0xffffffff : raw.length, 24);
    cdh.writeUInt16LE(name.length, 28);
    cdh.writeUInt32LE(zip64 ? 0xffffffff : offset, 42);       // local header offset
    let extra = Buffer.alloc(0);
    if (zip64) {
      // id 0x0001, then: uncompressed size, compressed size, local offset.
      extra = Buffer.alloc(4 + 24);
      extra.writeUInt16LE(0x0001, 0); extra.writeUInt16LE(24, 2);
      extra.writeBigUInt64LE(BigInt(raw.length), 4);
      extra.writeBigUInt64LE(BigInt(comp.length), 12);
      extra.writeBigUInt64LE(BigInt(offset), 20);
      cdh.writeUInt16LE(extra.length, 30);
    }
    centrals.push({ cdh, name, extra });

    offset += lfh.length + name.length + comp.length;
  }
  const cdStart = offset;
  const cdBufs = [];
  for (const c of centrals) { cdBufs.push(c.cdh, c.name, c.extra); }
  const cd = Buffer.concat(cdBufs);

  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(zip64 ? 0xffff : entries.length, 8);
  eocd.writeUInt16LE(zip64 ? 0xffff : entries.length, 10);
  eocd.writeUInt32LE(zip64 ? 0xffffffff : cd.length, 12);
  eocd.writeUInt32LE(zip64 ? 0xffffffff : cdStart, 16);

  if (!zip64) return Buffer.concat([...locals, cd, eocd]);

  // The zip64 record (56 bytes) and the locator (20) that points at it.
  const rec = Buffer.alloc(56);
  rec.writeUInt32LE(0x06064b50, 0);
  rec.writeBigUInt64LE(BigInt(44), 4);           // size of the record after this field
  rec.writeUInt16LE(45, 12); rec.writeUInt16LE(45, 14);
  rec.writeBigUInt64LE(BigInt(entries.length), 24);
  rec.writeBigUInt64LE(BigInt(entries.length), 32);
  rec.writeBigUInt64LE(BigInt(cd.length), 40);
  rec.writeBigUInt64LE(BigInt(cdStart), 48);
  const loc = Buffer.alloc(20);
  loc.writeUInt32LE(0x07064b50, 0);
  loc.writeBigUInt64LE(BigInt(cdStart + cd.length), 8);   // where the record is
  loc.writeUInt32LE(1, 16);
  return Buffer.concat([...locals, cd, rec, loc, eocd]);
}

module.exports = { makeZip };
