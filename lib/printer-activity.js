'use strict';
(function (global) {

/**
 * What a printer is doing, as two CLOSED sets (KhaytPrinterActivity).
 *
 *   link      unpaired | connecting | online | reconnecting | offline | unauthorized
 *   activity  printing | paused | idle | finished | error | unknown   (null unless online)
 *
 * Every protocol reports its own words; the tables below turn each one Khayt
 * writes into the poll cache into an activity. A word in no table is
 * `unknown`, and the legacy projection reads it by the OLD substring rule, so
 * a firmware word nobody has mapped never reads differently than it did.
 *
 * `legacy(status, entry)` is lib/attention.js machineState's six values
 * (offline | error | reconnecting | printing | idle | unknown), which every
 * screen, the idle panel and lead-time-publish read. Each word CLASS below is
 * projected from its activity only once it is listed in `FIXED`; until then it
 * reads exactly as on main (the substring rule). Pure; no DOM, no I/O.
 *
 * WHERE THE WORDS COME FROM (only the U1, i.e. Moonraker, is on the bench, so
 * for the rest the source is the adapter that writes the word, and the
 * fixture in test/fixtures/printer-activity-vectors.json):
 *   moonraker   print_stats.state: standby, printing, paused, complete,
 *               cancelled, error (Moonraker docs, printer objects
 *               `print_stats`; lib/moonraker.js:296, measured on the U1)
 *   octoprint   state.text: Operational, Printing, Printing from SD, Sending
 *               file to SD, Pausing, Paused, Resuming, Cancelling, Finishing,
 *               Error…, Offline, Opening serial port, Detecting serial port,
 *               Detecting baudrate, Connecting (OctoPrint docs, Printer
 *               operations › state; lib/octoprint.js:50)
 *   prusalink   printer.state: IDLE, BUSY, PRINTING, PAUSED, FINISHED,
 *               STOPPED, ERROR, ATTENTION, READY (PrusaLink OpenAPI
 *               `StatusPrinter.state`; lib/prusalink.js:44)
 *   bambu       gcode_state through bambu-report's labels: Idle, Preparing,
 *               Printing, Paused, Finished, Failed, Slicing
 *               (lib/bambu-report.js:21)
 *   repetier    Khayt's own label: Offline, Paused, Preparing, Printing, Idle
 *               (lib/repetier.js; Offline is answered as a link)
 *   duet        state.status: idle, busy, printing, pausing, paused,
 *               resuming, cancelling, changingTool, processing, simulating,
 *               starting, halted, off, updating (RepRapFirmware object model
 *               `state.status`; lib/duet.js:293)
 *   sdcp        machine status idle, printing, transferring,
 *               exposure_testing, self_testing; while printing, the print
 *               sub-status homing, dropping, exposing, lifting, pausing,
 *               paused, stopping, stopped, complete, file_checking (SDCP v3
 *               spec; lib/sdcp.js:58-87)
 */

const LINKS = ['unpaired', 'connecting', 'online', 'reconnecting', 'offline', 'unauthorized'];
const ACTIVITIES = ['printing', 'paused', 'idle', 'finished', 'error', 'unknown'];
const OFFLINE_AFTER_MISSED_POLLS = 3;

/** A state word as the tables key it: lower case, `_`/`-` and runs of spaces as one space. */
function word(v) {
  return String(v == null ? '' : v).toLowerCase().replace(/[_-]+/g, ' ').replace(/\s+/g, ' ').trim();
}

/** The word classes. Each is a set of words and the activity (or link) they mean. */
const CLASSES = Object.freeze({
  // Working: the bed is not free.
  busy: { activity: 'printing', words: ['printing', 'printing from sd', 'sending file to sd', 'running',
    'preparing', 'slicing', 'starting', 'resuming', 'busy', 'processing', 'simulating', 'changingtool',
    'cancelling', 'canceling', 'finishing', 'homing', 'dropping', 'exposing', 'lifting', 'stopping',
    'file checking', 'transferring', 'exposure testing', 'self testing', 'updating'] },
  // Paused: busy too, never free (Dev Hub, Nov 19).
  paused: { activity: 'paused', words: ['paused', 'pausing', 'pause'] },
  // Free.
  idle: { activity: 'idle', words: ['idle', 'operational', 'ready', 'standby', 'connected'] },
  // A job ended; what is on the bed is C4's business.
  finished: { activity: 'finished', words: ['complete', 'completed', 'finished', 'finish', 'cancelled', 'canceled', 'stopped'] },
  // Needs a person before the printer is free (a failed print on the bed).
  person: { activity: 'error', words: ['error', 'failed', 'attention', 'halted'] },
  // Not linked: OctoPrint, Repetier and Duet say so in the state itself.
  unlinked: { link: 'reconnecting', words: ['offline', 'off', 'opening serial port', 'connecting',
    'detecting serial port', 'detecting baudrate'] },
});

/** word → class name. */
const WORDS = Object.freeze(Object.keys(CLASSES).reduce((m, k) => {
  for (const w of CLASSES[k].words) m[w] = k;
  return m;
}, {}));

/**
 * The classes whose legacy value comes from their activity. A class not
 * listed reads by the old substring rule, exactly as main did. `idle` and
 * `finished` read the same either way (idle, or printing while progress shows).
 */
const FIXED = Object.freeze(['paused', 'busy', 'person', 'unlinked']);

const AUTH = /\b401\b|\b403\b|unauthori[sz]ed|forbidden|access code/i;

function polled(machine) {
  const api = machine && machine.printerApi;
  return !!(api && api.type && api.type !== 'none');
}

/**
 * @param {object} machine   the machine record (`isOffline` is the shop's manual flag)
 * @param {object} [entry]   machineStatusCache[machine.id], if any
 * @param {object} [opts]    { offlineAfter } consecutive misses before `offline`
 * @returns {{ link: string, activity: string|null, manual?: true, word?: string, cls?: string }}
 */
function machineStatus(machine, entry, opts) {
  const offlineAfter = (opts && +opts.offlineAfter > 0) ? +opts.offlineAfter : OFFLINE_AFTER_MISSED_POLLS;
  if (machine && machine.isOffline) return { link: 'offline', activity: null, manual: true };
  if (!entry) return polled(machine) ? { link: 'connecting', activity: null } : { link: 'unpaired', activity: null };
  if (entry.error) {
    // The HTTP status when the poller kept it, else the words of the error.
    const code = +entry.httpStatus;
    const auth = code === 401 || code === 403 || (!(code > 0) && AUTH.test(String(entry.error)));
    if (auth) return { link: 'unauthorized', activity: null };
    return { link: (entry.consecutiveFailures || 0) >= offlineAfter ? 'offline' : 'reconnecting', activity: null };
  }
  const w = word(entry.state);
  const cls = Object.prototype.hasOwnProperty.call(WORDS, w) ? WORDS[w] : null;
  if (cls && CLASSES[cls].link) return { link: CLASSES[cls].link, activity: null, word: w, cls };
  return { link: 'online', activity: cls ? CLASSES[cls].activity : 'unknown', word: w, ...(cls ? { cls } : {}) };
}

/** The old rule, exactly (lib/attention.js before C2). */
function substringRule(entry) {
  const st = String((entry && entry.state) || '').toLowerCase();
  if (st.includes('error')) return 'error';
  if (st.includes('print')) return 'printing';
  return Math.round(+(entry && entry.progress) || 0) > 0 ? 'printing' : 'idle';
}

/**
 * The six legacy values from a status (and the cache entry it came from).
 * Pass `opts.offlineAfter` as machineStatus was given it.
 */
function legacy(status, entry, opts) {
  const s = status || {};
  const offlineAfter = (opts && +opts.offlineAfter > 0) ? +opts.offlineAfter : OFFLINE_AFTER_MISSED_POLLS;
  if (s.manual) return 'offline';
  switch (s.link) {
    case 'unpaired': return 'idle';           // nothing to poll: tracked by orders
    case 'connecting': return 'unknown';      // polled, never heard from
    case 'offline': return 'offline';
    case 'reconnecting':
    case 'unauthorized':
      // A failing poll reads as it always did; a state word that says the
      // printer is not linked reads by its class.
      if (entry && entry.error) return (entry.consecutiveFailures || 0) >= offlineAfter ? 'offline' : 'reconnecting';
      break;
    default: break;
  }
  if (!s.cls || FIXED.indexOf(s.cls) === -1) return substringRule(entry);
  if (CLASSES[s.cls].link) return 'reconnecting';
  switch (s.activity) {
    case 'printing':
    case 'paused': return 'printing';         // busy: never offered as free
    case 'error': return 'error';
    default: return substringRule(entry);
  }
}

const api = { LINKS, ACTIVITIES, CLASSES, WORDS, FIXED, OFFLINE_AFTER_MISSED_POLLS, word, machineStatus, legacy, substringRule };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytPrinterActivity = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
