'use strict';
/**
 * The "From slicer" inbox on Windows/Linux: the native Mac's `SlicerInbox`,
 * item for item. A file a slicer sent (the OctoPrint path,
 * lib/main/slicer-upload.js) or a paired plugin sent (lib/main/connector-routes.js)
 * waits here until the shop decides what it becomes. NOTHING in the book is
 * written: no job, quote, client, spool or activity row.
 *
 *   <root>/<id>/<name>       the file, as the slicer named it (made safe)
 *   <root>/<id>/info.json    what is known about it (the Mac's SlicerUpload)
 *   <root>/.incoming/        bodies spooling in; emptied at launch
 *   <root>/.slices/          a paired plugin's slice records (connector-slices.js)
 *
 * <root> is `<userData>/From slicer`: this computer's, never the book's, so a
 * backup or a synced second computer does not carry another machine's G-code.
 * (The Mac keeps it beside the book; it has one book folder per Mac.)
 *
 * ONE DEDUPE FOR BOTH WAYS IN: the file's SHA-256. The same bytes from the
 * OctoPrint path and from a plugin are one item. Filing is synchronous, so the
 * check, the cap (100 items) and the write cannot interleave (the Mac takes a
 * lock for the same reason, beta.40 review).
 *
 * Main process only (node:fs, node:crypto).
 */
const crypto = require('crypto');
const nodePath = require('path');
const GcodeParse = require('../gcode-parse.js');

const FOLDER_NAME = 'From slicer';
const INFO_NAME = 'info.json';
const MAX_WAITING = 100;
const HEAD = 32 * 1024;
const TAIL = 64 * 1024;
const ID_RE = /^SU-\d{1,16}-[0-9a-f]{4}$/;

class InboxFull extends Error {
  constructor() { super('The Khayt slicer inbox is full — clear it in Khayt first'); this.code = 'inbox-full'; }
}
class InboxDuplicate extends Error {
  constructor(item) { super('duplicate'); this.code = 'duplicate'; this.item = item; }
}

/** Seconds precision, `Z`: the Mac's JSONEncoder `.iso8601`. */
const isoSeconds = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');

/** A file name as the inbox keeps it: no folders, no control characters, no leading dots. */
function safeName(v) {
  // eslint-disable-next-line no-control-regex
  const t = String(v == null ? '' : v).replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, '').trim();
  // Windows refuses < > : " | ? * (and \ /); a trailing dot or space is
  // dropped by Explorer and the slicer cannot open the file.
  let base = t.replace(/[\\/:<>"|?*]/g, '_').replace(/^\.+/, '').replace(/[. ]+$/, '').trim();
  // Reserved device names, whatever the extension: CON.gcode is a device.
  if (/^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\.|$)/i.test(base)) base = '_' + base;
  base = clipBytes(base, MAX_NAME_BYTES);
  return base && base !== '.' && base !== '..' ? base : '';
}

/** At most `max` UTF-8 bytes (ext4 allows 255), never splitting a character, keeping the extension. */
const MAX_NAME_BYTES = 200;
function clipBytes(name, max) {
  if (Buffer.byteLength(name, 'utf8') <= max) return name;
  const lower = name.toLowerCase();
  const ext = lower.endsWith('.gcode.3mf') ? name.slice(-10) : (name.lastIndexOf('.') > 0 && name.length - name.lastIndexOf('.') <= 12 ? name.slice(name.lastIndexOf('.')) : '');
  let stem = name.slice(0, name.length - ext.length);
  const room = max - Buffer.byteLength(ext, 'utf8');
  while (stem && Buffer.byteLength(stem, 'utf8') > room) stem = Array.from(stem).slice(0, -1).join('');
  return (stem.replace(/[. ]+$/, '') || '_') + ext;
}

/** The slicer's figures off a plain G-code's two ends (the Mac's SlicerFigures windows). */
function readGcodeFigures(fs, file, name) {
  const lower = String(name).toLowerCase();
  if (lower.endsWith('.gcode.3mf')) return null;
  const ext = lower.slice(lower.lastIndexOf('.') + 1);
  if (!['gcode', 'gco', 'g'].includes(ext)) return null;
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const size = fs.fstatSync(fd).size;
    const head = Buffer.alloc(Math.min(HEAD, size));
    fs.readSync(fd, head, 0, head.length, 0);
    const tailLen = Math.min(TAIL, Math.max(0, size - head.length));
    const tail = Buffer.alloc(tailLen);
    if (tailLen) fs.readSync(fd, tail, 0, tailLen, size - tailLen);
    const p = GcodeParse.parseGcodeText(head.toString('utf8') + '\n' + tail.toString('utf8'));
    return { filamentGrams: p.filamentGrams, printTimeMins: p.printTimeMins, filamentType: p.filamentType, slicer: p.slicer };
  } catch (_) {
    return null;
  } finally {
    if (fd != null) { try { fs.closeSync(fd); } catch (_) { /* gone */ } }
  }
}

/**
 * @param {object} o
 * @param {object} o.fs
 * @param {string} o.root           `<userData>/From slicer`
 * @param {function} [o.now]        wall ms
 * @param {function} [o.readFigures] (file, name) => {filamentGrams, printTimeMins, filamentType, slicer}|null
 */
function createSlicerInbox({ fs, root, now = Date.now, readFigures = null, maxWaiting = MAX_WAITING }) {
  const figuresOf = readFigures || ((file, name) => readGcodeFigures(fs, file, name));
  const incoming = nodePath.join(root, '.incoming');
  const slices = nodePath.join(root, '.slices');

  function fileOf(item) { return nodePath.join(root, item.id, item.name); }

  /** Everything waiting, newest first. A folder without a readable info.json, or whose file is gone, is not listed. */
  function list() {
    let names = [];
    try { names = fs.readdirSync(root); } catch (_) { return []; }
    const out = [];
    for (const n of names) {
      if (n.startsWith('.') || !ID_RE.test(n)) continue;
      let item;
      try { item = JSON.parse(fs.readFileSync(nodePath.join(root, n, INFO_NAME), 'utf8')); } catch (_) { continue; }
      if (!item || item.id !== n || typeof item.name !== 'string' || safeName(item.name) !== item.name) continue;
      if (!fs.existsSync(fileOf(item))) continue;
      out.push(item);
    }
    return out.sort((a, b) => String(b.arrived).localeCompare(String(a.arrived)) || String(b.id).localeCompare(String(a.id)));
  }

  function get(id) {
    if (typeof id !== 'string' || !ID_RE.test(id)) return null;
    return list().find((i) => i.id === id) || null;
  }

  /**
   * Move `upload` (a file under `.incoming`) into the inbox and write what is
   * known about it. `sha256` was worked out as the bytes landed. `origin`: a
   * paired plugin's {connectorId, connectorName, sliceId, suggested, slots}.
   * Throws InboxDuplicate (with the item holding the same bytes) or InboxFull.
   */
  function file(upload, name, { sha256, origin = null } = {}) {
    const clean = safeName(name);
    if (!clean) throw new Error('name');
    const waiting = list();
    const hash = typeof sha256 === 'string' && /^[0-9a-f]{64}$/.test(sha256) ? sha256 : null;
    if (hash) {
      const same = waiting.find((i) => i.sha256 === hash);
      if (same) throw new InboxDuplicate(same);
    }
    if (waiting.length >= maxWaiting) throw new InboxFull();
    const t = now();
    let id;
    do { id = `SU-${Math.floor(t)}-${crypto.randomBytes(2).toString('hex')}`; } while (fs.existsSync(nodePath.join(root, id)));
    const dir = nodePath.join(root, id);
    fs.mkdirSync(dir, { recursive: true });
    const dest = nodePath.join(dir, clean);
    try { fs.renameSync(upload, dest); }
    catch (e) { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) { /* scratch */ } throw e; }
    let size = 0;
    try { size = fs.statSync(dest).size; } catch (_) { size = 0; }
    const fig = (() => { try { return figuresOf(dest, clean); } catch (_) { return null; } })() || {};
    const pos = (v) => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : undefined);
    const txt = (v) => (typeof v === 'string' && v ? v : undefined);
    const item = { id, name: clean, arrived: isoSeconds(t), bytes: size };
    if (pos(fig.filamentGrams) !== undefined) item.grams = fig.filamentGrams;
    if (pos(fig.printTimeMins) !== undefined) item.minutes = fig.printTimeMins;
    if (txt(fig.filamentType)) item.material = fig.filamentType;
    if (txt(fig.slicer)) item.slicer = fig.slicer;
    if (hash) item.sha256 = hash;
    if (origin) {
      item.source = 'connector';
      item.connectorId = origin.connectorId;
      item.connectorName = origin.connectorName;
      item.sliceId = origin.sliceId;
      item.suggested = origin.suggested;
      if (origin.slots !== undefined && origin.slots !== null) item.slots = origin.slots;
    }
    try {
      const tmp = nodePath.join(dir, INFO_NAME + '.tmp');
      fs.writeFileSync(tmp, JSON.stringify(item), { mode: 0o600 });
      fs.renameSync(tmp, nodePath.join(dir, INFO_NAME));
    } catch (e) {
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) { /* scratch */ }
      throw e;
    }
    return item;
  }

  /** Take one item out (the shop discarded it, or made something of it). Its own folder, never above. */
  function remove(id) {
    if (typeof id !== 'string' || !ID_RE.test(id)) return false;
    const dir = nodePath.join(root, id);
    if (!fs.existsSync(dir)) return false;
    fs.rmSync(dir, { recursive: true, force: true });
    return true;
  }

  /** A fresh spool file under `.incoming`, in a folder of its own named after the file. */
  function spoolPath(name) {
    const dir = nodePath.join(incoming, 'khayt-' + crypto.randomBytes(12).toString('hex'));
    fs.mkdirSync(dir, { recursive: true });
    return nodePath.join(dir, safeName(name) || 'upload.part');
  }

  /** Bodies left half-spooled by a crash or a quit. Only at launch, when nothing is uploading. */
  function sweepIncoming() {
    let names = [];
    try { names = fs.readdirSync(incoming); } catch (_) { return 0; }
    for (const n of names) { try { fs.rmSync(nodePath.join(incoming, n), { recursive: true, force: true }); } catch (_) { /* next launch */ } }
    return names.length;
  }

  /** Free bytes on the inbox's disk, or null when the platform will not say. */
  function freeBytes() {
    try {
      fs.mkdirSync(root, { recursive: true });
      if (typeof fs.statfsSync !== 'function') return null;
      const s = fs.statfsSync(root);
      return Number(s.bavail) * Number(s.bsize);
    } catch (_) { return null; }
  }

  return { root, incoming, slices, list, get, file, remove, fileOf, spoolPath, sweepIncoming, freeBytes, maxWaiting };
}

module.exports = {
  createSlicerInbox, safeName, readGcodeFigures, isoSeconds, InboxFull, InboxDuplicate,
  FOLDER_NAME, INFO_NAME, MAX_WAITING, ID_RE,
};
