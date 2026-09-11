'use strict';

/**
 * SDCP (Smart Device Control Protocol) v3.0.0 — Elegoo / CBD Technology resin
 * printers.
 *
 * Spec: cbd-tech/SDCP-Smart-Device-Control-Protocol-V3.0.0, the vendor's own
 * published document. Every payload in the tests below is copied from it, so the
 * parser is checked against the specification rather than against my reading of
 * it.
 *
 * WHAT THIS COVERS, AND WHAT IT DOES NOT
 *
 * The published v3.0.0 protocol is RESIN. Its status object carries UVLED
 * temperature, release-film count, exposure-screen hours, and print sub-states
 * called EXPOSURING / LIFTING / DROPPING. It contains no nozzle, no bed, no
 * extruder and no filament — checked, not assumed: the word "nozzle" does not
 * appear in the document once.
 *
 * So this reaches Elegoo's resin line (Mars, Saturn), two of which Khayt's
 * printer catalog already lists. It does NOT reach Centauri Carbon: that is an
 * FDM machine, and whatever it speaks is not this document. Anyone extending
 * this for Centauri is reverse-engineering, not implementing a spec, and should
 * say so.
 *
 * Elegoo's FDM Neptune 4 line runs Klipper, so it is already reachable through
 * the existing Moonraker adapter — SDCP adds nothing there.
 *
 * PURE ON PURPOSE
 *
 * No sockets. Discovery is UDP, control is a WebSocket, and both are trivially
 * mockable — but the part that is easy to get subtly wrong is the framing and
 * the status mapping, and that is what this file is. It can be tested completely
 * without a printer, which matters because there is no Elegoo resin machine on
 * the bench: the LAN hardware is a Prusa CORE One and a Snapmaker U1.
 *
 * Nothing here has been run against a real printer. Treat the transport wiring
 * as unverified until someone points it at one.
 */

/** Discovery: broadcast this string over UDP and the mainboard answers. */
// WRAPPED, because the Mac app loads this into the ONE JavaScriptCore context
// every bundled module shares. Unwrapped it declared sixteen names at the top
// level of that context — `CMD`, `TOPIC`, `api`, `pct` — any of which another
// module could collide with silently.
//
// `test/bundled-modules-are-wrapped.test.js` is the guard, and it caught this
// the moment the module was added to the bundle rather than months later.
(function (global) {
  const DISCOVERY_PORT = 3000;
  const DISCOVERY_MAGIC = 'M99999';

  /** The mainboard's WebSocket lives here once discovery gives you its IP. */
  const WEBSOCKET_PORT = 3030;
  const websocketUrl = (ip) => `ws://${ip}:${WEBSOCKET_PORT}/websocket`;

  /** Top-level machine status (Status.CurrentStatus / PreviousStatus). */
  const MACHINE_STATUS = {
    0: 'idle',
    1: 'printing',
    2: 'transferring',
    3: 'exposure_testing',
    4: 'self_testing',
  };

  /**
   * Print sub-status (Status.PrintInfo.Status).
   *
   * The spec is explicit that this one LATCHES: "the sub-status will always retain
   * the most recent status, for example, after the print is completed, the
   * sub-status value will continue to be maintained as Print Completed". So it
   * answers "what happened last", not "what is happening now" — which is why the
   * top-level status decides whether a machine is busy, and this only refines it.
   */
  const PRINT_STATUS = {
    0: 'idle',
    1: 'homing',
    2: 'dropping',
    3: 'exposing',
    4: 'lifting',
    5: 'pausing',
    6: 'paused',
    7: 'stopping',
    8: 'stopped',
    9: 'complete',
    10: 'file_checking',
  };

  /** PrintInfo.ErrorNumber — why a job refused to run. */
  const PRINT_ERROR = {
    0: null,
    1: 'File checksum failed',
    2: 'File could not be read',
    3: 'Resolution does not match this printer',
    4: 'File format not recognised',
    5: 'File was sliced for a different machine',
  };

  /** Commands this module knows how to ask for. */
  const CMD = {
    STATUS_REFRESH: 0,
    ATTRIBUTES: 1,
    START: 128,
    PAUSE: 129,
    STOP: 130,
    RESUME: 131,
    STOP_FEEDING: 132,
    SKIP_PREHEAT: 133,
    RENAME: 192,
    FILE_LIST: 258,
    DELETE_FILES: 259,
    HISTORY: 320,
    TASK_DETAIL: 321,
    TERMINATE_TRANSFER: 255,
  };

  const TOPIC = {
    request: (id) => `sdcp/request/${id}`,
    response: (id) => `sdcp/response/${id}`,
    status: (id) => `sdcp/status/${id}`,
    attributes: (id) => `sdcp/attributes/${id}`,
    error: (id) => `sdcp/error/${id}`,
    notice: (id) => `sdcp/notice/${id}`,
  };

  /**
   * Parse a mainboard's answer to the UDP discovery broadcast.
   *
   * Returns null rather than throwing: this runs over a broadcast socket, so it
   * will be handed whatever else is shouting on the LAN.
   */
  function parseDiscoveryReply(raw) {
    let msg;
    try {
      msg = typeof raw === 'string' ? JSON.parse(raw) : raw;
    } catch { return null; }
    const d = msg && msg.Data;
    if (!d || typeof d !== 'object') return null;
    if (!d.MainboardID || !d.MainboardIP) return null;   // without both it is unusable
    return {
      brandId: msg.Id || null,
      name: d.Name || d.MachineName || 'Elegoo printer',
      model: d.MachineName || null,
      brand: d.BrandName || null,
      ip: d.MainboardIP,
      mainboardId: d.MainboardID,
      protocolVersion: d.ProtocolVersion || null,
      firmwareVersion: d.FirmwareVersion || null,
      url: websocketUrl(d.MainboardIP),
    };
  }

  /**
   * Build a control request.
   *
   * The envelope nests `Data` inside `Data`, which reads like a mistake and is
   * not — the outer carries the command and routing, the inner carries the
   * command's own arguments. Getting that wrong produces a frame the mainboard
   * ignores in silence, so it is built in one place.
   */
  function buildRequest(cmd, { mainboardId, data = {}, requestId, timestamp, brandId = '', from = 0 } = {}) {
    if (!Number.isInteger(cmd)) throw new Error('cmd must be an integer');
    if (!mainboardId) throw new Error('mainboardId required');
    return {
      Id: brandId,
      Data: {
        Cmd: cmd,
        Data: data,
        RequestID: requestId || mainboardId,
        MainboardID: mainboardId,
        TimeStamp: Number.isFinite(timestamp) ? timestamp : Math.floor(Date.now() / 1000),
        From: from,
      },
      Topic: TOPIC.request(mainboardId),
    };
  }

  /** Which kind of message is this? Returns null for anything unrecognised. */
  function messageKind(msg) {
    const t = msg && typeof msg.Topic === 'string' ? msg.Topic : '';
    const m = /^sdcp\/(request|response|status|attributes|error|notice)\//.exec(t);
    return m ? m[1] : null;
  }

  /** Clamp to a whole 0-100. Mirrors lib/printer-status.js, deliberately. */
  function pct(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) return 0;
    return Math.min(100, Math.max(0, Math.round(n)));
  }

  /**
   * Turn a status message into the shape every other Khayt printer adapter
   * returns, so the queue and fleet views need no special case.
   *
   * tempNozzle and tempBed are NULL, always. A resin printer has neither, and
   * reporting 0 would render as a cold hotend — a number that looks like a
   * measurement and is not one. The resin temperatures it does have are carried
   * alongside, additively.
   *
   * Progress prefers layers over time: resin jobs are layer-counted, the layer
   * numbers are exact, and TotalTicks is an estimate that drifts.
   */
  function statusFrom(msg) {
    const s = (msg && msg.Status) || {};
    const p = s.PrintInfo || {};

    const machine = MACHINE_STATUS[s.CurrentStatus] || null;
    const sub = PRINT_STATUS[p.Status] || null;

    // CurrentStatus can arrive as an array — the spec's own example shows
    // "CurrentStatus":[0,1,2,3], a machine doing several things at once. Printing
    // wins if it is in there, because that is what the shop needs to see.
    const current = Array.isArray(s.CurrentStatus)
      ? (s.CurrentStatus.includes(1) ? 1 : s.CurrentStatus[0])
      : s.CurrentStatus;
    const machineFromArray = MACHINE_STATUS[current] || machine;

    const layers = Number(p.TotalLayer) > 0
      ? pct((Number(p.CurrentLayer) || 0) / Number(p.TotalLayer) * 100)
      : null;
    const ticks = Number(p.TotalTicks) > 0
      ? pct((Number(p.CurrentTicks) || 0) / Number(p.TotalTicks) * 100)
      : null;

    const remainingMs = Number(p.TotalTicks) > 0 && Number.isFinite(Number(p.CurrentTicks))
      ? Math.max(0, Number(p.TotalTicks) - Number(p.CurrentTicks))
      : null;

    return {
      type: 'sdcp',
      state: machineFromArray === 'printing' && sub ? sub : (machineFromArray || 'Unknown'),
      machineState: machineFromArray,
      printState: sub,
      progress: layers != null ? layers : (ticks != null ? ticks : 0),
      progressSource: layers != null ? 'layers' : (ticks != null ? 'time' : 'none'),
      filename: typeof p.Filename === 'string' ? p.Filename : '',
      timeRemaining: remainingMs != null ? Math.round(remainingMs / 1000) : null,
      currentLayer: Number.isFinite(Number(p.CurrentLayer)) ? Number(p.CurrentLayer) : null,
      totalLayer: Number.isFinite(Number(p.TotalLayer)) ? Number(p.TotalLayer) : null,
      taskId: p.TaskId || null,
      error: PRINT_ERROR[p.ErrorNumber] || null,

      // Not applicable to a resin printer — see the note above.
      tempNozzle: null,
      tempBed: null,

      // Resin-specific, additive: consumables a shop actually replaces.
      tempUVLED: Number.isFinite(Number(s.TempOfUVLED)) ? Number(s.TempOfUVLED) : null,
      tempBox: Number.isFinite(Number(s.TempOfBox)) ? Number(s.TempOfBox) : null,
      releaseFilmCount: Number.isFinite(Number(s.ReleaseFilm)) ? Number(s.ReleaseFilm) : null,
      screenHours: Number.isFinite(Number(s.PrintScreen)) ? Math.round(Number(s.PrintScreen) / 3600) : null,
      mainboardId: msg && msg.MainboardID ? msg.MainboardID : null,
    };
  }

  /** Pull the useful bits out of an attribute message. */
  function attributesFrom(msg) {
    const a = (msg && msg.Attributes) || {};
    return {
      name: a.Name || null,
      model: a.MachineName || null,
      brand: a.BrandName || null,
      resolution: a.Resolution || null,
      firmwareVersion: a.FirmwareVersion || null,
      protocolVersion: a.ProtocolVersion || null,
      capabilities: Array.isArray(a.Capabilities) ? a.Capabilities : [],
      mainboardId: (msg && msg.MainboardID) || a.MainboardID || null,
    };
  }

  const api = {
    DISCOVERY_PORT, DISCOVERY_MAGIC, WEBSOCKET_PORT, websocketUrl,
    MACHINE_STATUS, PRINT_STATUS, PRINT_ERROR, CMD, TOPIC,
    parseDiscoveryReply, buildRequest, messageKind, statusFrom, attributesFrom,
  };
  // GUARDED, because the Mac app loads this file in JavaScriptCore, where there
  // is no `module` — an unguarded assignment throws on the last line and takes
  // the whole module with it. Every other shared module guards it; this one did
  // not need to until now, because nothing but Node had ever loaded it.
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  // And published as a global, which is how it is reached where there is no
  // `require`. It is loadable there precisely because it is pure —
  // `lib/sdcp-client.js` above it is not, and cannot be.
  if (typeof globalThis !== 'undefined') globalThis.KhaytSdcp = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
