'use strict';
/**
 * KHAYT AS A PRINTER IN THE SLICER, on Windows/Linux: the two OctoPrint
 * routes a slicer's "Send" uses (OrcaSlicer, PrusaSlicer, Bambu Studio with a
 * physical printer of host type OctoPrint). The native Mac's
 * `LanServer+SlicerUpload`, answer for answer (docs/LAN_API.md "GET
 * /api/version and POST /api/files/local").
 *
 *   GET  /api/version        → {"api":"0.1","server":"1.10.0","text":"OctoPrint 1.10.0 (Khayt)"}
 *   POST /api/files/local    multipart, the file in the field `file`
 *
 * Every file lands in the "From slicer" inbox (lib/main/slicer-inbox.js),
 * with the same SHA-256 dedupe a paired plugin's file gets. It NEVER starts a
 * print: `print` and `select` are read and ignored, and the answer says so.
 *
 * OFF, AND THEN NOT HERE: until "Accept files from slicers" is switched on
 * (lib/main/connector-local.js, this computer's own, default off) both routes
 * are the ordinary 404. On, `X-Api-Key` is checked before a byte of body is
 * read: none 401, wrong 403, ten wrong from one visitor 429 for a minute in
 * its OWN bucket (never the owner PIN's).
 *
 * TO DISK, NOT TO MEMORY: the body is parsed as it streams and the file part
 * written straight to a spool file under the inbox, hashed as it lands. At
 * most two uploads at once, shared with a plugin's (`uploads`), 1 GiB cap.
 *
 * Main process only (node:fs, node:crypto).
 */
const crypto = require('crypto');
const nodePath = require('path');
const fsDefault = require('fs');
const LanAuth = require('../lan-auth.js');
const { safeName, InboxFull, InboxDuplicate } = require('./slicer-inbox.js');

const VERSION_BODY = '{"api":"0.1","server":"1.10.0","text":"OctoPrint 1.10.0 (Khayt)"}';
const MAX_BYTES = 1 << 30;
const MAX_UPLOADS = 2;
const DISK_SPARE = 512 * 1024 * 1024;
const MAX_PARTS = 32;
const MAX_PART_HEAD = 16_384;
const LOCKOUT_MS = 60_000;
const MAX_FAILURE_KEYS = 5000;

/** A file a slicer may send here: G-code, binary G-code, and a sliced Bambu/Orca plate. */
function slicerFileTaken(name) {
  const lower = String(name).toLowerCase();
  if (lower.endsWith('.gcode.3mf')) return true;
  const ext = lower.includes('.') ? lower.slice(lower.lastIndexOf('.') + 1) : '';
  return ['gcode', 'gco', 'g', 'bgcode'].includes(ext);
}

const pathOf = (rawUrl) => {
  let p = String(rawUrl || '');
  const q = p.indexOf('?');
  if (q >= 0) p = p.slice(0, q);
  if (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
  return p;
};
/** Is this the upload, from the request line alone. */
function isSlicerUpload(method, rawUrl) {
  if (String(method).toUpperCase() !== 'POST') return false;
  const p = pathOf(rawUrl);
  return p === '/api/files/local' || p === '/v1/files/local';
}

/** The boundary from a Content-Type, or null when it is not multipart form data with a usable one. */
function boundaryOf(contentType) {
  const ct = String(contentType || '');
  if (!ct.toLowerCase().startsWith('multipart/form-data')) return null;
  for (const param of ct.split(';').slice(1)) {
    const eq = param.indexOf('=');
    if (eq < 0) continue;
    if (param.slice(0, eq).trim().toLowerCase() !== 'boundary') continue;
    let v = param.slice(eq + 1).trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
    const n = Buffer.byteLength(v);
    return n >= 1 && n <= 200 ? v : null;
  }
  return null;
}

/** `; key=value` pairs, quoted or not, `;` inside quotes kept. */
function params(text) {
  const pieces = [];
  let cur = '', quoted = false, escaped = false;
  for (const ch of text) {
    if (escaped) { cur += ch; escaped = false; continue; }
    if (ch === '\\' && quoted) { escaped = true; cur += ch; continue; }
    if (ch === '"') quoted = !quoted;
    if (ch === ';' && !quoted) { pieces.push(cur); cur = ''; continue; }
    cur += ch;
  }
  pieces.push(cur);
  const out = [];
  for (const piece of pieces) {
    const eq = piece.indexOf('=');
    if (eq < 0) continue;
    const key = piece.slice(0, eq).trim().toLowerCase();
    let value = piece.slice(eq + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    out.push([key, value]);
  }
  return out;
}
/** `name` and `filename` from a part's head (filename* per RFC 5987 wins). */
function disposition(head) {
  let name = '', filename = null, starred = null;
  for (const line of head.split('\r\n')) {
    const colon = line.indexOf(':');
    if (colon < 0 || line.slice(0, colon).trim().toLowerCase() !== 'content-disposition') continue;
    for (const [k, v] of params(line.slice(colon + 1))) {
      if (k === 'name') name = v;
      else if (k === 'filename') filename = v;
      else if (k === 'filename*') {
        const bits = v.split("'");
        if (bits.length >= 3) { try { starred = decodeURIComponent(bits.slice(2).join("'")); } catch (_) { starred = null; } }
      }
    }
  }
  return { name, filename: starred != null ? starred : filename };
}

/**
 * A streaming multipart/form-data reader (RFC 7578). `onPart({name,
 * filename})` returns a sink `{ write(buf), end() }` or null to skip the
 * part. `push(chunk)` as bytes arrive, `finish()` at the end: true when the
 * body was well-formed multipart for this boundary and closed.
 */
function createMultipartReader(boundary, onPart) {
  const dash = Buffer.from('--' + boundary);
  const next = Buffer.from('\r\n--' + boundary);
  const blank = Buffer.from('\r\n\r\n');
  let buf = Buffer.alloc(0);
  let state = 'preamble';     // preamble | delimiter | head | body | done | bad
  let sink = null;
  let parts = 0;

  function step() {
    for (;;) {
      if (state === 'preamble') {
        const at = buf.indexOf(dash);
        if (at < 0) { if (buf.length > dash.length) buf = buf.subarray(buf.length - dash.length); return; }
        buf = buf.subarray(at + dash.length);
        state = 'delimiter';
      } else if (state === 'delimiter') {
        if (buf.length < 2) return;
        if (buf[0] === 0x2d && buf[1] === 0x2d) { state = 'done'; return; }
        let i = 0;
        while (i < buf.length && (buf[i] === 0x20 || buf[i] === 0x09)) i++;
        if (i + 2 > buf.length) return;
        if (buf[i] !== 13 || buf[i + 1] !== 10) { state = 'bad'; return; }
        buf = buf.subarray(i + 2);
        state = 'head';
      } else if (state === 'head') {
        const end = buf.indexOf(blank);
        if (end < 0) { if (buf.length > MAX_PART_HEAD) state = 'bad'; return; }
        if (end > MAX_PART_HEAD || ++parts > MAX_PARTS) { state = 'bad'; return; }
        const head = buf.subarray(0, end).toString('utf8');
        buf = buf.subarray(end + blank.length);
        sink = onPart(disposition(head)) || null;
        state = 'body';
      } else if (state === 'body') {
        const at = buf.indexOf(next);
        if (at < 0) {
          // Keep enough to find a delimiter split across two chunks.
          const keep = next.length - 1;
          if (buf.length > keep) {
            if (sink) sink.write(buf.subarray(0, buf.length - keep));
            buf = buf.subarray(buf.length - keep);
          }
          return;
        }
        if (sink) { sink.write(buf.subarray(0, at)); sink.end(); sink = null; }
        buf = buf.subarray(at + next.length);
        state = 'delimiter';
      } else return;
    }
  }
  return {
    push(chunk) { if (state === 'done' || state === 'bad') return; buf = buf.length ? Buffer.concat([buf, chunk]) : chunk; step(); },
    finish() { return state === 'done'; },
    get bad() { return state === 'bad'; },
  };
}

/**
 * @param {object} d
 * @param {object} d.inbox         lib/main/slicer-inbox.js
 * @param {object} d.uploads       { active } shared with the plugin's file path
 * @param {function} d.activeKey   () => the key, or null while uploads are off
 * @param {function} [d.refusal]   (headers, path) => {status, body}|null — a connector's key (connector-scope)
 * @param {function} [d.now]       ms, for the lockout
 * @param {function} [d.notFoundBody]
 * @param {function} [d.visitor]   (req) => the lockout key (per IP, /64)
 */
function createSlicerUpload(d) {
  const fs = d.fs || fsDefault;
  const now = d.now || Date.now;
  const notFoundBody = d.notFoundBody || (() => JSON.stringify({ error: 'Not found' }));
  const visitorOf = d.visitor || ((req) => LanAuth.lockoutKeyOf(String((req.socket && req.socket.remoteAddress) || '')));
  const failures = new Map();
  const maxBytes = Math.min(d.maxBytes || MAX_BYTES, MAX_BYTES);

  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, Object.assign({ 'Content-Type': 'application/json' }, headers));
    res.end(typeof body === 'string' ? body : JSON.stringify(body));
  };

  /** Null when this request carries the right key; [status, body] otherwise (404 while off). */
  function gate(req) {
    let key = null;
    try { key = d.activeKey(); } catch (_) { key = null; }
    if (!key) return [404, notFoundBody()];
    const provided = String(req.headers['x-api-key'] || '').trim();
    const visitor = visitorOf(req);
    const t = now();
    if (LanAuth.isLockedOut(failures.get(visitor), t)) return [429, { error: 'Too many attempts — try again in 1 minute' }];
    if (!provided) return [401, { error: 'No API key provided' }];
    const a = Buffer.from(provided), b = Buffer.from(key);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
      failures.set(visitor, LanAuth.bumpFailure(failures.get(visitor), t, { lockoutMs: LOCKOUT_MS }));
      LanAuth.sweepFailedAttempts(failures, t, MAX_FAILURE_KEYS);
      return [403, { error: 'Invalid API key' }];
    }
    failures.delete(visitor);
    return null;
  }

  /** GET /api/version — the slicer's "Test". */
  function version(req, res) {
    const refused = gate(req);
    if (refused) { send(res, refused[0], refused[1]); return; }
    send(res, 200, VERSION_BODY);
  }

  /** POST /api/files/local — judged from its head, then streamed to the inbox. */
  function upload(req, res, { expectContinue = false } = {}) {
    const refuse = (status, body) => {
      res.setHeader('Connection', 'close');
      res.on('finish', () => setTimeout(() => { try { req.socket.destroy(); } catch (_) { /* gone */ } }, 1000).unref());
      req.on('error', () => {});
      send(res, status, body);
    };
    // A connector's key opens /api/connectors/* only, here as everywhere.
    const scoped = typeof d.refusal === 'function' ? d.refusal(req.headers, '/api/files/local') : null;
    if (scoped) { refuse(scoped.status, scoped.body); return; }
    const refused = gate(req);
    if (refused) { refuse(refused[0], refused[1]); return; }
    const boundary = boundaryOf(req.headers['content-type']);
    const lenHeader = req.headers['content-length'];
    const length = /^\d{1,16}$/.test(String(lenHeader || '')) ? Number(lenHeader) : 0;
    if (!boundary || length <= 0) { refuse(400, { error: 'No file included' }); return; }
    if (length > maxBytes) { refuse(413, { error: 'File too large' }); return; }
    const free = d.inbox.freeBytes();
    if (free != null && free < length * 2 + DISK_SPARE) { refuse(507, { error: 'Not enough disk space on this computer' }); return; }
    if (d.uploads.active >= MAX_UPLOADS) { refuse(503, { ok: false, reason: 'busy' }); return; }

    d.uploads.active += 1;
    let released = false;
    const release = () => { if (!released) { released = true; d.uploads.active -= 1; } };
    let spool = null, spoolDir = null, out = null, name = null, wrongKind = null, failed = false;
    const hasher = crypto.createHash('sha256');
    const cleanup = () => { if (spoolDir) { try { fs.rmSync(spoolDir, { recursive: true, force: true }); } catch (_) { /* scratch */ } } };
    const fail = () => { if (failed) return; failed = true; release(); if (out) out.destroy(); cleanup(); };
    const reader = createMultipartReader(boundary, (part) => {
      if (part.name !== 'file' || part.filename == null || spool || wrongKind) return null;
      let n = safeName(part.filename);
      if (!n || n === 'model') n = 'upload.gcode';
      if (!slicerFileTaken(n)) { wrongKind = n; return null; }
      name = n;
      spool = d.inbox.spoolPath(n);
      spoolDir = nodePath.dirname(spool);
      out = fs.createWriteStream(spool, { mode: 0o600 });
      out.on('error', fail);
      let size = 0;
      return {
        write(b) {
          if (!b.length) return;
          size += b.length;
          hasher.update(b);
          if (!out.write(Buffer.from(b))) { req.pause(); out.once('drain', () => req.resume()); }
        },
        end() { out.bytes = size; },
      };
    });
    let got = 0;
    req.on('data', (c) => { if (failed) return; got += c.length; reader.push(c); });
    req.on('aborted', fail);
    req.on('error', fail);
    req.on('end', () => {
      if (failed) return;
      if (got !== length) { fail(); return; }
      const finishWith = (status, body, headers) => { release(); cleanup(); send(res, status, body, headers); };
      if (wrongKind) {
        if (out) out.destroy();
        finishWith(415, { error: `Could not upload the file "${wrongKind}", invalid type` });
        return;
      }
      if (!reader.finish() || !spool || !out || !(out.bytes > 0)) {
        if (out) out.destroy();
        finishWith(400, { error: 'No file included' });
        return;
      }
      out.once('close', () => {
        if (failed) return;
        const sha = hasher.digest('hex');
        try {
          d.inbox.file(spool, name, { sha256: sha });
        } catch (e) {
          // The same bytes already waiting: the slicer is told its file arrived, which it has.
          if (!(e instanceof InboxDuplicate)) {
            if (e instanceof InboxFull) { finishWith(409, { error: e.message }); return; }
            finishWith(500, { error: 'Could not store the file' });
            return;
          }
          if (typeof d.onDuplicate === 'function') { try { d.onDuplicate(name); } catch (_) { /* a notice */ } }
        }
        // OctoPrint's own answer. `print=true` is never acted on, and said so.
        const host = req.headers.host ? `http://${req.headers.host}` : '';
        const encoded = encodeURI(name).replace(/[?#]/g, encodeURIComponent);
        const resource = `${host}/api/files/local/${encoded}`;
        finishWith(201, {
          done: true, effectivePrint: false, effectiveSelect: false,
          files: { local: { name, display: name, path: name, origin: 'local',
            refs: { resource, download: `${host}/downloads/files/local/${encoded}` } } },
        }, { Location: resource });
      });
      out.end();
    });
    if (expectContinue) res.writeContinue();
  }

  return { gate, version, upload, isSlicerUpload };
}

module.exports = {
  createSlicerUpload, createMultipartReader, boundaryOf, disposition, slicerFileTaken, isSlicerUpload,
  VERSION_BODY, MAX_BYTES, MAX_UPLOADS,
};
