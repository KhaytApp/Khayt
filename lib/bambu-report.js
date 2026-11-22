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

/**
 * Fold one report into the state held from the reports before it.
 *
 * ── WHY A HELD STATE AT ALL ───────────────────────────────────────────────
 *
 * OpenBambuAPI `mqtt.md`, `pushing.pushall`: "the P1 series only sends the
 * values that have been updated compared to the previous report", and "refrain
 * from executing this command at intervals less than 5 minutes on the P1P, as
 * it may cause lag due to its hardware limitations". The X1 sends the full
 * object every time. So a client that keeps one connection open and wants a
 * picture of the printer has to remember the last full report and lay each
 * delta over it — which is what ha-bambulab does (`pybambu/models.py`
 * `print_update`: every field is `data.get(key, self.key)`, i.e. a field the
 * message does not mention keeps its last value).
 *
 * The rule, and the reasons for its edges:
 *   - Only `print` is merged. `info` (versions) and `system` (LED replies) are
 *     other conversations on the same topic and carry nothing a card draws.
 *   - Objects merge key by key, recursively. A delta naming one field of a
 *     nested object (`ams.tray_now`) must not wipe its siblings.
 *   - ARRAYS ARE REPLACED, never merged by index. `hms: []` is how a printer
 *     says its warnings cleared — merging would keep them for ever.
 *   - A key present with `null` overwrites. The printer said so.
 *   - `__proto__` / `constructor` / `prototype` are dropped: the payload is
 *     whatever answered on the printer's address, and these keys on a plain
 *     object are a prototype write in JavaScript.
 *   - Nesting is capped at 32 levels; deeper is taken whole. A Bambu's report
 *     is four deep at most, and recursion on a peer's nesting is a stack.
 *
 * `msg` may be the raw payload string or an already-parsed object. Returns a
 * NEW object `{ print: {...} }` (or `prev` unchanged when the message carries no
 * `print` object); `prev` is never mutated. `parseBambuReport(JSON.stringify(
 * merged))` then reads the held state exactly as it reads a pushall.
 *
 * `BambuReportParityTests` holds the Swift port (`BambuReport.merge`) to this.
 */
const MERGE_DEPTH = 32;
const FORBIDDEN_KEYS = ['__proto__', 'constructor', 'prototype'];

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function mergeInto(base, delta, depth) {
  const out = {};
  for (const k of Object.keys(base)) {
    if (FORBIDDEN_KEYS.includes(k)) continue;
    out[k] = base[k];
  }
  for (const k of Object.keys(delta)) {
    if (FORBIDDEN_KEYS.includes(k)) continue;
    const next = delta[k];
    if (depth < MERGE_DEPTH && isPlainObject(next) && isPlainObject(out[k])) {
      out[k] = mergeInto(out[k], next, depth + 1);
    } else {
      out[k] = next;
    }
  }
  return out;
}

function mergeReport(prev, msg) {
  let obj = msg;
  if (typeof msg === 'string') {
    try { obj = JSON.parse(msg); } catch { return prev || null; }
  }
  const p = isPlainObject(obj) ? obj.print : null;
  if (!isPlainObject(p)) return prev || null;
  const held = isPlainObject(prev) && isPlainObject(prev.print) ? prev.print : {};
  return { print: mergeInto(held, p, 1) };
}

const api = { bambuStateLabel, parseBambuReport, mergeReport, MERGE_DEPTH };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytBambuReport = api;
})();
