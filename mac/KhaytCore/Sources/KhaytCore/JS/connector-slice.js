'use strict';
(function () {

/**
 * A capture from a paired slicer plugin (Khayt for OrcaSlicer): checked and
 * copied field by field — pure.
 *
 * What the plugin announces before it sends the file (`POST
 * /api/connectors/slices`, already unsealed and under the route's 64 KB cap).
 * It is a SUGGESTION for the "From slicer" inbox and nothing more:
 *
 * ── INBOX-FIRST ──────────────────────────────────────────────────────────
 *
 * No intent here creates or changes a job, quote, client or spool. `quote`,
 * `job`, `attach` and `print` are kept as `suggested` beside the inbox item
 * for the shop to act on (or not). The figures are "what the slicer said":
 * the Mac reads the file itself when it arrives, and its own reading wins.
 *
 * ── REFUSED, OR DROPPED ──────────────────────────────────────────────────
 *
 * What identifies the file (id, idem, name, bytes, sha256) is refused when
 * wrong: the upload is bound to it. What only describes the slice (a preset
 * name, a thumbnail, one filament row) is dropped when wrong and named in
 * `dropped`, so a slicer that writes something odd still gets its file in.
 * Unknown keys never pass: the output is built from an allowlist.
 */

const MAX_META_BYTES = 64 * 1024;
const MAX_THUMB_BYTES = 48 * 1024;
const MAX_THUMB_SIDE = 512;
const MAX_FILE_BYTES = 1024 * 1024 * 1024;
const MAX_SLOTS = 32;
const MAX_OBJECTS = 64;
const INTENTS = ['inbox', 'quote', 'job', 'attach', 'print'];
const FILE_TYPES = ['gcode', 'bgcode', 'gcode.3mf'];

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);

// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;

function text(v, max) {
  if (typeof v !== 'string') return null;
  const clean = v.replace(CONTROL, '').trim();
  if (!clean) return null;
  return clean.length > max ? clean.slice(0, max) : clean;
}

function count(v, max) {
  return Number.isInteger(v) && v >= 0 && v <= max ? v : null;
}

function amount(v, max) {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= max ? v : null;
}

const HEX64 = /^[0-9a-f]{64}$/;
const ID = /^[A-Za-z0-9_-]{8,64}$/;

/** The file's kind from its name, or null when the inbox does not take it. */
function fileType(name) {
  const lower = name.toLowerCase();
  if (lower.endsWith('.gcode.3mf')) return 'gcode.3mf';
  const ext = lower.includes('.') ? lower.slice(lower.lastIndexOf('.') + 1) : '';
  if (ext === 'bgcode') return 'bgcode';
  if (['gcode', 'gco', 'g'].includes(ext)) return 'gcode';
  return null;
}

/** A name as a file on the Mac may carry it: no folders, no control characters. */
function safeName(v) {
  const t = text(v, 200);
  if (!t) return null;
  const base = t.replace(/[\\/]/g, '_').replace(/^\.+/, '');
  return base && base !== '.' && base !== '..' ? base : null;
}

function base64Bytes(b64) {
  if (typeof b64 !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(b64) || b64.length % 4 !== 0) return -1;
  const pad = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0;
  return (b64.length / 4) * 3 - pad;
}

function refuse(reason, field) { return { ok: false, reason, field }; }

/**
 * `check(capture, opts)` → `{ ok: true, capture, dropped }` or `{ ok: false, reason, field }`.
 * `opts.maxFileBytes`: the Mac's own cap (`slicerMaxBytes`), at most 1 GiB.
 */
function check(input, opts) {
  const o = isObj(opts) ? opts : {};
  const maxFile = Math.min(Number.isInteger(o.maxFileBytes) && o.maxFileBytes > 0 ? o.maxFileBytes : MAX_FILE_BYTES, MAX_FILE_BYTES);
  if (!isObj(input)) return refuse('not-an-object', null);
  if (input.v !== 1) return refuse('version', 'v');
  if (input.kind !== 'slice') return refuse('kind', 'kind');
  if (typeof input.id !== 'string' || !ID.test(input.id)) return refuse('bad-id', 'id');

  const f = isObj(input.file) ? input.file : null;
  if (!f) return refuse('no-file', 'file');
  const name = safeName(f.name);
  if (!name) return refuse('bad-name', 'file.name');
  const type = fileType(name);
  if (!type) return refuse('wrong-kind', 'file.name');
  if (!Number.isInteger(f.bytes) || f.bytes < 1) return refuse('bad-size', 'file.bytes');
  if (f.bytes > maxFile) return refuse('too-large', 'file.bytes');
  const sha = typeof f.sha256 === 'string' ? f.sha256.toLowerCase() : '';
  if (!HEX64.test(sha)) return refuse('bad-hash', 'file.sha256');
  if (input.idem !== 'sha256:' + sha) return refuse('idem-mismatch', 'idem');

  const intent = INTENTS.includes(input.intent) ? input.intent : 'inbox';
  const dropped = [];
  if (input.intent !== undefined && intent !== input.intent) dropped.push('intent');

  const suggested = { intent };
  if (intent === 'attach') {
    const jobId = text(input.jobId, 64);
    if (jobId) suggested.jobId = jobId; else { suggested.intent = 'inbox'; dropped.push('jobId'); }
  }
  if (intent === 'print') {
    const machineId = text(input.machineId, 64);
    if (machineId) suggested.machineId = machineId; else { suggested.intent = 'inbox'; dropped.push('machineId'); }
    // Asked, and kept as asked — v1 never starts a print from here.
    suggested.startPrint = input.startPrint === true;
  }

  const out = {
    v: 1,
    id: input.id,
    idem: 'sha256:' + sha,
    file: { name, bytes: f.bytes, sha256: sha, type },
    suggested,
  };

  const at = typeof input.at === 'string' && !Number.isNaN(Date.parse(input.at)) ? input.at : null;
  if (at) out.at = at; else if (input.at !== undefined) dropped.push('at');

  if (isObj(input.slicer)) {
    out.slicer = {
      name: text(input.slicer.name, 64),
      version: text(input.slicer.version, 32),
      plugin: text(input.slicer.plugin, 32),
    };
  }
  if (isObj(input.printer)) {
    out.printer = { preset: text(input.printer.preset, 128), nozzle: amount(input.printer.nozzle, 5) };
  }
  // Read through a name of its own: the bundle guard refuses the text of
  // Node's global followed by a dot, which JavaScriptCore does not have.
  const proc = input['process'];
  if (isObj(proc)) {
    out.process = { preset: text(proc.preset, 128), layerHeight: amount(proc.layerHeight, 5) };
  }
  if (isObj(input.plate)) {
    const objects = Array.isArray(input.plate.objects)
      ? input.plate.objects.map((x) => text(x, 120)).filter(Boolean).slice(0, MAX_OBJECTS) : [];
    out.plate = { index: count(input.plate.index, 1000), name: text(input.plate.name, 120), objects };
  }
  for (const [key, max] of [['timeSec', 60 * 60 * 24 * 90], ['layers', 1e6], ['toolchanges', 1e6]]) {
    if (input[key] === undefined) continue;
    const n = count(input[key], max);
    if (n === null) dropped.push(key); else out[key] = n;
  }

  if (Array.isArray(input.filaments)) {
    const seen = new Set();
    const rows = [];
    input.filaments.forEach((row, i) => {
      const slot = isObj(row) ? count(row.slot, MAX_SLOTS) : null;
      const grams = isObj(row) ? amount(row.grams, 1e6) : null;
      if (slot === null || slot < 1 || seen.has(slot) || grams === null) { dropped.push(`filaments[${i}]`); return; }
      if (grams === 0) return; // an unused slot, as the design says: not a row
      seen.add(slot);
      const colour = typeof row.colour === 'string' && /^#[0-9A-Fa-f]{6}$/.test(row.colour) ? row.colour.toUpperCase() : null;
      rows.push({
        slot, grams,
        cm3: amount(row.cm3, 1e6), mm: amount(row.mm, 1e9),
        type: text(row.type, 32), colour, preset: text(row.preset, 128),
        density: amount(row.density, 30), costPerKg: amount(row.costPerKg, 1e6), cost: amount(row.cost, 1e7),
      });
    });
    out.filaments = rows.slice(0, MAX_SLOTS).sort((a, z) => a.slot - z.slot);
  }

  if (input.thumbnail !== undefined) {
    const t = isObj(input.thumbnail) ? input.thumbnail : {};
    const kind = t.type === 'png' || t.type === 'jpg' ? t.type : null;
    const w = count(t.w, MAX_THUMB_SIDE), h = count(t.h, MAX_THUMB_SIDE);
    const bytes = base64Bytes(t.b64);
    if (kind && w && h && bytes > 0 && bytes <= MAX_THUMB_BYTES) out.thumbnail = { type: kind, w, h, b64: t.b64 };
    else dropped.push('thumbnail');
  }

  return { ok: true, capture: out, dropped };
}

const api = { check, fileType, MAX_META_BYTES, MAX_THUMB_BYTES, MAX_FILE_BYTES, INTENTS, FILE_TYPES };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytConnectorSlice = api;
})();
