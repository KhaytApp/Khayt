'use strict';
(function (global) {

/**
 * What is wrong with a printer, and what to do about it: ONE closed list for
 * every protocol (C3, batch 2 of ~/Khayt-proposals/prusa-ideas-plan.md).
 *
 * Each make reported its trouble its own way and each screen showed it as it
 * came: a Bambu sentence, a U1 exception id, OctoPrint's error string, a
 * PrusaLink "ATTENTION", Elegoo's error number. Now every one is a finding
 *
 *   { code, severity, action, source, head?, message?, ref? }
 *
 * from closed sets the three apps translate (`problem.<code>`,
 * `problem.action.<action>`). `message` is the printer's own words, kept for
 * the codes Khayt has no sentence of its own for (`printer-error`,
 * `printer-attention`, `printer-exception`); `ref` is the printer's code, to
 * look it up by (a Bambu HMS code, a U1 exception id). Worst first.
 *
 *   problemsFor(type, report)
 *     bambu      the report's `print` object  → lib/bambu-faults.js
 *     moonraker  the objects-query `status`   → lib/moonraker-problems.js
 *     anything   the adapter's normalised status ({ state, message })
 *                (octoprint, prusalink, duet, repetier, sdcp)
 *
 * The Bambu sentences and U1 rows stay in their own modules; this only says
 * what each MEANS. A Bambu fault is mapped by its fixed bundled sentence, and
 * the test walks every bundled code so a new one cannot land unmapped.
 * Severities: fatal, serious, common, info (Bambu's own four).
 *
 * Pure: no sockets, no DOM.
 */

const CODES = Object.freeze([
  'filament-runout', 'nozzle-clog', 'temperature', 'door-open', 'first-layer', 'spaghetti',
  'bed-plate', 'storage', 'file-rejected', 'power-lost', 'paused-by-user', 'print-cancelled',
  'printer-exception', 'printer-attention', 'printer-error',
]);
const ACTIONS = Object.freeze([
  'load-filament', 'clear-nozzle', 'check-heater', 'close-door', 'check-print', 'check-plate',
  'check-storage', 'reslice', 'resend-file', 'resume-on-printer', 'check-printer', 'none',
]);
const SEVERITIES = Object.freeze(['fatal', 'serious', 'common', 'info']);
const RANK = { fatal: 0, serious: 1, common: 2, info: 3 };

/** What each code asks of the shop, and how bad it is when the source does not say. */
const DEFAULTS = Object.freeze({
  'filament-runout': { action: 'load-filament', severity: 'serious' },
  'nozzle-clog': { action: 'clear-nozzle', severity: 'serious' },
  temperature: { action: 'check-heater', severity: 'fatal' },
  'door-open': { action: 'close-door', severity: 'common' },
  'first-layer': { action: 'check-print', severity: 'common' },
  spaghetti: { action: 'check-print', severity: 'serious' },
  'bed-plate': { action: 'check-plate', severity: 'common' },
  storage: { action: 'check-storage', severity: 'common' },
  'file-rejected': { action: 'reslice', severity: 'serious' },
  'power-lost': { action: 'resume-on-printer', severity: 'info' },
  'paused-by-user': { action: 'resume-on-printer', severity: 'info' },
  'print-cancelled': { action: 'none', severity: 'info' },
  'printer-exception': { action: 'check-printer', severity: 'common' },
  'printer-attention': { action: 'check-printer', severity: 'common' },
  'printer-error': { action: 'check-printer', severity: 'serious' },
});

function lib(name, file) {
  if (global && global[name]) return global[name];
  if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
  return null;
}
const clean = (v) => (v == null ? '' : String(v)).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 200);

function finding(code, src, extra) {
  const d = DEFAULTS[code];
  const sev = extra && SEVERITIES.includes(extra.severity) ? extra.severity : d.severity;
  const out = { code, severity: sev, action: (extra && extra.action) || d.action, source: src };
  if (extra && extra.head != null) out.head = extra.head;
  if (extra && extra.message) out.message = extra.message;
  if (extra && extra.ref != null) out.ref = String(extra.ref);
  return out;
}

/**
 * A Bambu fault's MEANING, from its bundled sentence. Order matters: the
 * first pattern that matches wins, specific before general.
 */
const BAMBU_MEANING = [
  [/ran out|run out|has run out/i, 'filament-runout'],
  [/canceled|cancelled|task was aborted(?!.*door)/i, 'print-cancelled'],
  [/paused by the user/i, 'paused-by-user'],
  [/power loss/i, 'power-lost'],
  [/door|top cover is open/i, 'door-open'],
  [/first layer/i, 'first-layer'],
  [/spaghetti|pile-up/i, 'spaghetti'],
  [/AMS mapping|AMS may be mismatched/i, 'printer-attention'],
  [/clog|extrusion motor is overloaded|unable to feed|pull out|cutter is stuck/i, 'nozzle-clog'],
  [/temperature|cooling fan|fan speed|cool down/i, 'temperature'],
  [/build plate/i, 'bed-plate'],
  [/storage|microsd|file is not available/i, 'storage'],
  [/sliced file is not consistent/i, 'file-rejected'],
  [/front cover|homing failed|busy|network/i, 'printer-attention'],
];
const BAMBU_SEVERITY = { fatal: 'fatal', serious: 'serious', common: 'common', info: 'info', unknown: 'common' };

function bambuMeaning(text) {
  const t = String(text || '');
  for (const [re, code] of BAMBU_MEANING) if (re.test(t)) return code;
  return null;
}

function fromBambu(print) {
  const B = lib('KhaytBambuFaults', './bambu-faults.js');
  if (!B || typeof B.faults !== 'function') return [];
  return B.faults(print).map((f) => {
    const code = (f.text && bambuMeaning(f.text)) || 'printer-error';
    const ref = f.kind === 'hms' ? 'HMS_' + f.code : f.code;
    // An HMS notice carries Bambu's own severity. A print_error does not:
    // bambu-faults marks every one 'serious', so a cancelled task read as
    // serious; it takes its meaning's severity instead.
    return finding(code, 'bambu', {
      severity: f.kind === 'hms' ? (BAMBU_SEVERITY[f.severity] || 'common') : undefined,
      ref,
      message: code === 'printer-error' ? (f.text ? clean(f.text) : null) : null,
    });
  });
}

function fromMoonraker(status) {
  const M = lib('KhaytMoonrakerProblems', './moonraker-problems.js');
  if (!M || typeof M.problems !== 'function') return [];
  return M.problems(status).map((p) => finding(p.code, 'moonraker', {
    severity: p.severity, head: p.head, ref: p.id, message: p.message || null,
  }));
}

/** SDCP (Elegoo) PrintInfo.ErrorNumber, by the sentence lib/sdcp.js gives it. */
const SDCP_ACTION = [
  [/different machine|resolution does not match/i, 'reslice'],
  [/checksum|could not be read|not recognised/i, 'resend-file'],
];

/** The printers that report only a state word and a message. */
function fromStatus(type, s) {
  const st = s && typeof s === 'object' ? s : {};
  const PA = lib('KhaytPrinterActivity', './printer-activity.js');
  const message = clean(st.message) || null;
  if (type === 'sdcp' && message) {
    const hit = SDCP_ACTION.find(([re]) => re.test(message));
    if (hit) return [finding('file-rejected', 'sdcp', { action: hit[1], message })];
  }
  const word = PA ? PA.word(st.state) : String(st.state || '').trim().toLowerCase();
  const cls = PA && Object.prototype.hasOwnProperty.call(PA.WORDS, word) ? PA.WORDS[word] : null;
  if (cls === 'person' || /\b(error|failed|halted|attention)\b/.test(word)) {
    const code = /attention/.test(word) ? 'printer-attention' : 'printer-error';
    return [finding(code, String(type || 'printer'), { message })];
  }
  // A message with no fault word is the printer talking, not a problem
  // (OctoPrint's "Printing from SD", Duet's display text).
  return [];
}

/**
 * @param {string} type    the machine's printerApi.type
 * @param {object} report  what that protocol reports (see the header)
 */
function problemsFor(type, report) {
  const t = String(type || '').toLowerCase();
  let out;
  if (t === 'bambu') out = fromBambu(report);
  else if (t === 'moonraker') {
    out = fromMoonraker(report);
    // A Klipper printer that is not a U1 has no exception_manager; its state still says when it failed.
    const ps = report && report.print_stats;
    if (!out.length && ps && typeof ps === 'object') out = fromStatus('moonraker', { state: ps.state, message: ps.message });
  } else out = fromStatus(t, report);
  return out.sort((a, b) => (RANK[a.severity] - RANK[b.severity]) || ((a.head ?? 99) - (b.head ?? 99)));
}

/** The worst problem, or null: what a card's one line shows. */
function worst(findings) {
  return Array.isArray(findings) && findings.length ? findings[0] : null;
}

const api = { CODES, ACTIONS, SEVERITIES, DEFAULTS, problemsFor, worst, bambuMeaning };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytPrinterProblems = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
