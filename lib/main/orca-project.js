'use strict';
/**
 * A model with no settings of its own, made into a PROJECT 3MF for an Orca
 * fork, on Windows/Linux (the Mac's fix, #2731; rules in lib/slicer-project.js).
 *
 * Snapmaker Orca 2.4.1's command line segfaults whenever presets are handed to
 * it by flag (`--load-settings`, `--load-filaments`): exit 139 in under a
 * second, no G-code (reproduced Nov 27). The same presets inside the project's
 * `Metadata/project_settings.config`, sliced plainly, work. So:
 *
 *   buildStlProject({ stlPath, outPath, settingsJson, machine })
 *     an STL → a new 3MF: its mesh standing on the printer's bed, plus the
 *     settings. STREAMED: the STL is measured once (lib/stl-parse.js, lean),
 *     then its triangles go straight off the buffer into meshWriter (faces in
 *     an Int32Array) and the model XML is written to the file in pieces
 *     (xmlChunks), STORED with a running CRC and its header patched after, so
 *     a million-triangle mesh is never one string or one Buffer. Refused over
 *     MAX_STL_BYTES with the Mac's sentence.
 *
 *   addProjectConfig({ modelPath, outPath, settingsJson })
 *     a 3MF with no project settings → the same file with the config ADDED,
 *     every other member copied byte for byte, still compressed.
 *
 * Both return { ok: true, path } or { ok: false, error } (the shop's words).
 */
const nodeFs = require('fs');
const Project = require('../slicer-project.js');
const { parseStl, looksBinary } = require('../stl-parse.js');
const ZipRead = require('../zip-read.js');
const ZipWrite = require('../zip-write.js');

/** The Mac's cap (LanServer / SliceFlow): past it, the shop opens the file in the slicer. */
const MAX_STL_BYTES = 150 * 1024 * 1024;
const TOO_LARGE = 'This STL is too large to slice from Khayt. Open it in the slicer itself.';
const UNREADABLE = 'Khayt could not read this STL. Open it in the slicer itself.';

// ── CRC-32 (IEEE), fed in pieces ──────────────────────────────────────────
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    t[n] = c >>> 0;
  }
  return t;
})();
function crcUpdate(crc, buf) {
  let c = (crc ^ 0xFFFFFFFF) >>> 0;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

/**
 * A ZIP written member by member to a file descriptor, every member STORED.
 * A member is opened, fed in pieces, and closed; its local header is written
 * first with zeros and patched in place once its CRC and size are known, so
 * nothing is held whole. (No data descriptors: the slicers' zip readers want
 * the sizes in the local header.)
 */
function streamZip(fs, fd) {
  let offset = 0;
  const central = [];
  const writeAt = (buf, pos) => { let n = 0; while (n < buf.length) n += fs.writeSync(fd, buf, n, buf.length - n, pos + n); };
  const append = (buf) => { writeAt(buf, offset); offset += buf.length; };
  function header(name, crc, size) {
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0); h.writeUInt16LE(20, 4); h.writeUInt16LE(0x0800, 6);
    h.writeUInt16LE(0, 8); h.writeUInt16LE(0, 10); h.writeUInt16LE(0x21, 12);
    h.writeUInt32LE(crc >>> 0, 14); h.writeUInt32LE(size, 18); h.writeUInt32LE(size, 22);
    h.writeUInt16LE(name.length, 26); h.writeUInt16LE(0, 28);
    return h;
  }
  return {
    member(nameStr) {
      const name = Buffer.from(nameStr, 'utf8');
      const start = offset;
      append(header(name, 0, 0)); append(name);
      let crc = 0, size = 0;
      return {
        write(chunk) {
          const b = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk), 'utf8');
          crc = crcUpdate(crc, b); size += b.length;
          if (size > 0xFFFFFFFF) throw new Error('member too large for a zip');
          append(b);
        },
        close() {
          writeAt(header(name, crc, size), start);
          const c = Buffer.alloc(46);
          c.writeUInt32LE(0x02014b50, 0); c.writeUInt16LE(20, 4); c.writeUInt16LE(20, 6); c.writeUInt16LE(0x0800, 8);
          c.writeUInt16LE(0, 10); c.writeUInt16LE(0, 12); c.writeUInt16LE(0x21, 14);
          c.writeUInt32LE(crc >>> 0, 16); c.writeUInt32LE(size, 20); c.writeUInt32LE(size, 24);
          c.writeUInt16LE(name.length, 28);
          c.writeUInt32LE(start, 42);
          central.push(Buffer.concat([c, name]));
        },
      };
    },
    finish() {
      const cdStart = offset;
      for (const c of central) append(c);
      const e = Buffer.alloc(22);
      e.writeUInt32LE(0x06054b50, 0);
      e.writeUInt16LE(central.length, 8); e.writeUInt16LE(central.length, 10);
      e.writeUInt32LE(offset - cdStart, 12); e.writeUInt32LE(cdStart, 16);
      append(e);
    },
  };
}

/** Every triangle of an STL, read straight off the buffer: binary by DataView, ASCII by the same pattern parseStl uses. */
function eachTriangle(buf, fn) {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  if (looksBinary(dv) || (dv.byteLength >= 84 && !/facet|vertex/i.test(buf.subarray(0, Math.min(buf.length, 4096)).toString('latin1')))) {
    const count = Math.min(dv.getUint32(80, true), Math.floor((dv.byteLength - 84) / 50));
    let off = 84;
    for (let i = 0; i < count; i++) {
      off += 12;
      fn(dv.getFloat32(off, true), dv.getFloat32(off + 4, true), dv.getFloat32(off + 8, true),
        dv.getFloat32(off + 12, true), dv.getFloat32(off + 16, true), dv.getFloat32(off + 20, true),
        dv.getFloat32(off + 24, true), dv.getFloat32(off + 28, true), dv.getFloat32(off + 32, true));
      off += 38;
    }
    return;
  }
  const text = buf.toString('utf8');
  const re = /vertex\s+(-?[\d.eE+]+)\s+(-?[\d.eE+]+)\s+(-?[\d.eE+]+)/g;
  const v = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    v.push(parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]));
    if (v.length < 9) continue;
    fn(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8]);
    v.length = 0;
  }
}

function buildStlProject({ stlPath, outPath, settingsJson, machine, fs = nodeFs, maxBytes = MAX_STL_BYTES } = {}) {
  let size = 0;
  try { size = fs.statSync(stlPath).size; } catch (_) { return { ok: false, error: UNREADABLE }; }
  if (size > maxBytes) return { ok: false, error: TOO_LARGE };
  let buf;
  try { buf = fs.readFileSync(stlPath); } catch (_) { return { ok: false, error: UNREADABLE }; }
  let bbox;
  try { const r = parseStl(buf); if (!r.triangleCount) return { ok: false, error: UNREADABLE }; bbox = r.bbox; } catch (_) { return { ok: false, error: UNREADABLE }; }
  const w = Project.meshWriter(Project.offsetFor(bbox, Project.bedCentre(machine)));
  eachTriangle(buf, (ax, ay, az, bx, by, bz, cx, cy, cz) => { w.add(ax, ay, az, bx, by, bz, cx, cy, cz); });
  buf = null;   // the mesh lives in the writer now
  if (!w.counts().triangles) return { ok: false, error: UNREADABLE };
  let fd = null;
  try {
    fd = fs.openSync(outPath, 'w');
    const zip = streamZip(fs, fd);
    for (const m of Project.stlProjectMembers(settingsJson)) {
      const out = zip.member(m.name);
      if (m.name === Project.MODEL_MEMBER) w.xmlChunks((s) => out.write(s));
      else out.write(m.text);
      out.close();
    }
    zip.finish();
  } catch (e) {
    try { if (fd !== null) fs.closeSync(fd); } catch (_) { /* closing */ }
    fd = null;
    try { fs.rmSync(outPath, { force: true }); } catch (_) { /* gone */ }
    return { ok: false, error: `Khayt could not write the project for this STL (${String((e && e.message) || e).slice(0, 80)}).` };
  } finally { try { if (fd !== null) fs.closeSync(fd); } catch (_) { /* closed */ } }
  return { ok: true, path: outPath, counts: w.counts() };
}

function addProjectConfig({ modelPath, outPath, settingsJson, fs = nodeFs } = {}) {
  let buf;
  try { buf = fs.readFileSync(modelPath); } catch (_) { return { ok: false, error: 'Khayt could not read this 3MF.' }; }
  let entries;
  try { entries = ZipRead.listEntries(buf); } catch (_) { return { ok: false, error: 'Khayt could not read this 3MF.' }; }
  const config = Project.configMember(settingsJson);
  const members = [];
  for (const e of entries) {
    if (!e || typeof e.name !== 'string' || e.name.endsWith('/')) continue;
    if (e.name === config.name) continue;   // never two of it
    let raw = null;
    try { raw = ZipRead.readEntryRaw(buf, e); } catch (_) { raw = null; }
    if (!raw) return { ok: false, error: 'Khayt could not read this 3MF.' };
    members.push({ name: e.name, raw });
  }
  members.push({ name: config.name, data: config.text });
  const out = ZipWrite.writeZip(members);
  if (!out) return { ok: false, error: 'Khayt could not write the project for this 3MF.' };
  try { fs.writeFileSync(outPath, out); } catch (e) { return { ok: false, error: 'Khayt could not write the project for this 3MF.' }; }
  return { ok: true, path: outPath };
}

module.exports = { buildStlProject, addProjectConfig, streamZip, crcUpdate, eachTriangle, MAX_STL_BYTES, TOO_LARGE };
