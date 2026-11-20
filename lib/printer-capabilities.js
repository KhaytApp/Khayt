'use strict';
(function (global) {

/**
 * Which controls a printer card offers, per MODEL, on top of what its
 * PROTOCOL can send (C5, batch 2 of ~/Khayt-proposals/prusa-ideas-plan.md).
 *
 * lib/printer-commands.js `supports(type, command)` answers for a protocol:
 * every Bambu speaks MQTT `ledctrl`, so every Bambu card drew a light switch,
 * including the P1P, which has no light unless its camera-and-LED kit is
 * fitted. A protocol says what can be SENT; only the model says whether
 * anything is there to receive it.
 *
 *   capability(machine, control) → { state, reason }
 *     state 'yes'      the protocol sends it and the model has it
 *           'no'       one of the two cannot: the card hides it
 *           'addon'    the model has it only with an accessory the shop has
 *                      not recorded (machine.addons): hidden, with the reason
 *           'unknown'  the protocol sends it and nobody has said whether the
 *                      model has it: shown, and the press says what happened
 *     reason  'protocol' | 'model' | 'addon' | null
 *
 * The table holds only what is KNOWN, with where it is known from. A model
 * that is not in it, or a control a row does not mention, is 'unknown' and
 * left to the protocol: a missing row never hides a button a printer has.
 *
 * `machine.catalogId` is lib/printer-catalog.js's id, written when the shop
 * picked the model. `machine.addons` (array) lists fitted accessories by the
 * table's addon key.
 *
 * Pure data and lookups. No DOM, no I/O.
 */

/** Every control a card can draw. pause/resume/cancel are lib/printer-commands COMMANDS. */
const CONTROLS = Object.freeze(['pause', 'resume', 'cancel', 'speed', 'light', 'chamber-light', 'exclude-object']);

/**
 * Per model: true (has it), false (has not), or { addon } (only with that
 * accessory). Sources per row; nothing here is guessed.
 */
const MODELS = Object.freeze({
  // Bambu: speed profiles on every model Bambu Studio offers them for; the
  // chamber light by model (Bambu product pages; ha-bambulab's per-model
  // entity table).
  'bambu-x1c': { speed: true, light: true },
  'bambu-x1e': { speed: true, light: true },
  'bambu-p1s': { speed: true, light: true },
  'bambu-h2d': { speed: true, light: true },
  'bambu-p1p': { speed: true, light: { addon: 'bambu-p1-camera-led' } },   // "P1P – Chamber Camera & LED" kit
  'bambu-a1': { speed: true },          // light: not confirmed either way
  'bambu-a1-mini': { speed: true },     // light: not confirmed either way
  // Snapmaker U1: the chamber LED is switched over Moonraker (lib/webcam.js
  // chamberLightFor), proven on the shop's U1 (#2589).
  'snapmaker-u1': { 'chamber-light': true },
  // Resin printers: no part to drop from a plate, and Klipper's exclude_object
  // is an FDM feature.
  'anycubic-photon-m5s': { 'exclude-object': false },
  'anycubic-photon-m3': { 'exclude-object': false },
  'elegoo-saturn4-ultra': { 'exclude-object': false },
  'elegoo-mars5-ultra': { 'exclude-object': false },
});

/**
 * Which protocol can SEND each control at all, from this app: `transports`
 * is what the host can speak (Bambu needs 'mqtt'; lib/printer-commands.js
 * `opts.transports`). Default: both apps that draw cards speak MQTT.
 */
const DEFAULT_TRANSPORTS = Object.freeze(['mqtt']);
/** Controls only a model row can turn on (see capability). */
const VENDOR_ONLY = Object.freeze(['chamber-light']);
function protocolCan(type, control, transports) {
  const t = String(type || '').toLowerCase();
  if (!t || t === 'none') return false;
  const PC = (global && global.KhaytPrinterCommands)
    || (typeof require === 'function' ? (() => { try { return require('./printer-commands.js'); } catch (_) { return null; } })() : null);
  const tr = Array.isArray(transports) ? transports : DEFAULT_TRANSPORTS;
  if (['pause', 'resume', 'cancel'].includes(control)) return !!(PC && PC.supports(t, control, { transports: tr }));
  if (control === 'speed' || control === 'light') return !!(PC && !PC.buildControl(t, control, control === 'speed' ? 2 : 'on', { sequenceId: 0, transports: tr }).unsupported);
  if (control === 'chamber-light' || control === 'exclude-object') return t === 'moonraker';
  return false;
}

function capability(machine, control, opts) {
  if (!CONTROLS.includes(control)) return { state: 'no', reason: 'protocol' };
  const m = machine && typeof machine === 'object' ? machine : {};
  const type = m.printerApi && m.printerApi.type;
  if (!protocolCan(type, control, opts && opts.transports)) return { state: 'no', reason: 'protocol' };
  const row = Object.prototype.hasOwnProperty.call(MODELS, String(m.catalogId || '')) ? MODELS[m.catalogId] : null;
  const has = row && Object.prototype.hasOwnProperty.call(row, control) ? row[control] : undefined;
  if (has === true) return { state: 'yes', reason: null };
  if (has === false) return { state: 'no', reason: 'model' };
  if (has && typeof has === 'object' && has.addon) {
    const fitted = Array.isArray(m.addons) && m.addons.includes(has.addon);
    return fitted ? { state: 'yes', reason: null } : { state: 'addon', reason: 'addon', addon: has.addon };
  }
  // A VENDOR'S control (the U1's chamber LED is Snapmaker's own Moonraker
  // object, not a Klipper standard) is drawn only where the table says the
  // model has it: on any other Klipper printer it would be a button with
  // nothing behind it.
  if (VENDOR_ONLY.includes(control)) return { state: 'no', reason: 'model' };
  return { state: 'unknown', reason: null };
}

/** The controls a card draws: everything but 'no' and an unfitted 'addon'. */
function cardControls(machine, opts) {
  return CONTROLS.filter((c) => { const s = capability(machine, c, opts).state; return s === 'yes' || s === 'unknown'; });
}

const api = { CONTROLS, MODELS, DEFAULT_TRANSPORTS, VENDOR_ONLY, capability, cardControls, protocolCan };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytPrinterCapabilities = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
