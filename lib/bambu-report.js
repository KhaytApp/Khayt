'use strict';
(function () {
/**
 * What a Bambu printer says it is doing.
 *
 * Split out of `lib/bambu.js` so BOTH apps read a Bambu report the same way.
 * That file is Node-only from its first line — it hand-rolls MQTT 3.1.1 over a
 * TLS socket and `Buffer` is in its module scope, so it cannot be loaded in
 * JavaScriptCore at all. None of that is true of the part that decides what a
 * shop sees, which is a JSON object in and a status out.
 *
 * The transport is each app's own — Node sockets there, `NWConnection` here.
 * The MEANING is this file, once, because a printer reported as Idle in one app
 * and Printing in the other is the bug that shared modules exist to prevent.
 *
 * Pure: no Buffer, no sockets, no DOM.
 */

/** Map Bambu's gcode_state to a human label matching the other printer types. */
function bambuStateLabel(s) {
  const map = { IDLE: 'Idle', PREPARE: 'Preparing', RUNNING: 'Printing', PAUSE: 'Paused', FINISH: 'Finished', FAILED: 'Failed', SLICING: 'Slicing' };
  return map[String(s || '').toUpperCase()] || (s || 'Connected');
}

/**
 * Parse a `device/{serial}/report` JSON payload into the common status shape.
 * Returns null if the message has no `print` object (Bambu sends partial deltas).
 */
function parseBambuReport(payloadStr) {
  let obj;
  try { obj = JSON.parse(payloadStr); } catch { return null; }
  const p = obj && obj.print;
  if (!p || typeof p !== 'object') return null;
  // Only a full "pushall" snapshot carries gcode_state; ignore tiny deltas.
  if (p.gcode_state === undefined && p.mc_percent === undefined && p.subtask_name === undefined) return null;
  return {
    ok: true,
    state: bambuStateLabel(p.gcode_state),
    progress: typeof p.mc_percent === 'number' ? p.mc_percent : 0,
    filename: p.subtask_name || p.gcode_file || '',
    timeRemaining: typeof p.mc_remaining_time === 'number' ? p.mc_remaining_time * 60 : null, // min → sec
    tempNozzle: typeof p.nozzle_temper === 'number' ? p.nozzle_temper : null,
    tempBed: typeof p.bed_temper === 'number' ? p.bed_temper : null,
    layer: typeof p.layer_num === 'number' ? p.layer_num : null,
    totalLayers: typeof p.total_layer_num === 'number' ? p.total_layer_num : null,
    type: 'bambu',
  };
}

const api = { bambuStateLabel, parseBambuReport };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytBambuReport = api;
})();
