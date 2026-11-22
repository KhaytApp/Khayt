'use strict';
/**
 * Sending a sliced file to a printer: what each printer's API is asked.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * The request shapes lived inside `uploadGcodeToPrinter` in main.js, so the
 * Mac app — which links the same printers, polls them and pauses them — could
 * not send one a file at all. What a printer is ASKED is a rule and lives here;
 * the bytes on the wire (fetch and FormData in Electron, URLSession on the Mac)
 * stay with each app.
 *
 * ── TWO NAMING BUGS THE LIFT FIXES ────────────────────────────────────────
 *
 * Every HTTP upload was named `khayt-….gcode` whatever it was. Two real files
 * are not G-code text:
 *
 *   - a Prusa CORE One / MK4 / XL slices to BINARY G-code, `.bgcode`, by
 *     default. Uploaded as `.gcode`, the printer reads it as text and refuses
 *     it — so the Prusa path only ever worked for shops that had turned binary
 *     G-code off.
 *   - a 3MF sent to Moonraker or OctoPrint was stored as `.gcode` and failed on
 *     the printer, rather than being refused here where the shop can see why.
 *
 * So the remote name keeps the source's kind, and a file the printer cannot run
 * is refused before a byte is sent.
 *
 * Pure: the name's timestamp is the caller's.
 */
(function (global) {
  /** Printers this can send to over HTTP, and Bambu, which is FTPS + MQTT. */
  const HTTP_TYPES = ['octoprint', 'moonraker', 'prusalink'];
  const SUPPORTED = HTTP_TYPES.concat(['bambu']);

  /** What each printer can run. `gcode` covers .gcode/.gco/.g/.nc. */
  const RUNS = {
    octoprint: ['gcode'],
    moonraker: ['gcode'],
    prusalink: ['gcode', 'bgcode'],
    // A Bambu prints a sliced project (`.gcode.3mf`) or plain G-code.
    bambu: ['gcode', '3mf'],
  };

  /** The kind of a file by its name: `gcode`, `bgcode`, `3mf`, or null. */
  function kindOf(name) {
    const n = String(name || '').toLowerCase();
    if (/\.bgcode$/.test(n)) return 'bgcode';
    if (/\.3mf$/.test(n)) return '3mf';
    if (/\.(gcode|gco|g|nc)$/.test(n)) return 'gcode';
    return null;
  }

  /**
   * Whether this printer can be sent this file. `{ ok: true }`, or
   * `{ ok: false, code }` — `unsupported` for a printer type this cannot send
   * to yet, `not_sliced` for a model that has to go through a slicer first,
   * `wrong_kind` for a sliced file this printer cannot run.
   */
  function check(type, sourceName) {
    if (SUPPORTED.indexOf(type) === -1) return { ok: false, code: 'unsupported' };
    const kind = kindOf(sourceName);
    if (!kind) return { ok: false, code: 'not_sliced' };
    // A plain .3mf is a model; only Bambu runs a sliced project, and a
    // project that was never sliced fails on the printer, not here.
    if (RUNS[type].indexOf(kind) === -1) return { ok: false, code: 'wrong_kind', kind };
    return { ok: true, kind };
  }

  /** `khayt-<base36 time>.<ext>`, keeping what the source is. */
  function remoteName(sourceName, nowMs) {
    const kind = kindOf(sourceName) || 'gcode';
    return `khayt-${Math.floor(nowMs).toString(36)}.${kind}`;
  }

  /**
   * The request for an HTTP printer. Returns
   * `{ method, path, headers, body }` where `body` is either
   * `{ kind: 'multipart', file: { field, contentType }, fields: [[name, value], …] }`
   * — the file part FIRST, as both printers were always sent it — or
   * `{ kind: 'raw', contentType }`, the file's bytes as the whole body.
   * Null for a type that is not spoken over HTTP.
   */
  function request(type, opts) {
    const o = opts || {};
    const start = !!o.startPrint;
    const key = o.apiKey || '';
    if (type === 'octoprint') {
      return {
        method: 'POST', path: '/api/files/local',
        // OctoPrint always wants the header, even empty: its own error for a
        // missing key is clearer than a 403 from a proxy in front of it.
        headers: { 'X-Api-Key': key },
        body: { kind: 'multipart', file: { field: 'file', contentType: 'text/plain' },
          fields: [['select', 'true'], ['print', start ? 'true' : 'false']] },
      };
    }
    if (type === 'moonraker') {
      return {
        method: 'POST', path: '/server/files/upload',
        // Moonraker on a LAN usually trusts the network and has no key.
        headers: key ? { 'X-Api-Key': key } : {},
        body: { kind: 'multipart', file: { field: 'file', contentType: 'text/plain' },
          fields: [['root', 'gcodes'], ['print', start ? 'true' : 'false']] },
      };
    }
    if (type === 'prusalink') {
      return {
        method: 'PUT', path: `/api/v1/files/usb/${encodeURIComponent(o.name || '')}`,
        headers: { 'X-Api-Key': key, 'Content-Type': 'application/octet-stream',
          'Print-After-Upload': start ? '1' : '0' },
        body: { kind: 'raw', contentType: 'application/octet-stream' },
      };
    }
    return null;
  }

  /** A printer's answer: 2xx is taken, anything else is the printer's refusal. */
  function accepted(status) { return status >= 200 && status < 300; }

  const api = { HTTP_TYPES, SUPPORTED, RUNS, kindOf, check, remoteName, request, accepted };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrinterUpload = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
