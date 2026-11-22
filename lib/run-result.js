'use strict';
(function (global) {

/**
 * ONE result for each print run: finished, failed or cancelled (P4, batch 3
 * of ~/Khayt-proposals/prusa-ideas-plan.md).
 *
 * A job's `printRuns` (lib/print-runs.js) said where each send went and when,
 * and nothing about how it ended, so a printer's success rate could not be
 * counted at all. Two things can say:
 *
 *   the PRINTER  how its job ended, kept on the completion it froze
 *                (lib/printer-poll-cache.js `result`, from the ending word)
 *   the SHOP     a mark of its own: a failed check, a scrapped print, or
 *                "it printed fine" on a printer that only went back to idle
 *
 * The shop's mark wins: a printer that says "complete" over a print that
 * came off the plate as spaghetti finished nothing. The printer's word is
 * kept as `printerResult` beside it, so a report can tell the two apart.
 *
 *   withResult(order, { machineId, at, result, source: 'printer'|'shop' })
 *     → the new `printRuns`, or null when nothing changes
 *
 * The run it lands on is the latest run on that machine sent at or before
 * `at` (the completion's time). Written ONCE: a re-poll, a restart, or the
 * Mac and the desktop both finding the same completion change nothing. A
 * printer's result never replaces the shop's; the shop's replaces the
 * printer's (and a later shop mark replaces an earlier one).
 *
 * Pure: no clock, no store.
 */

const RESULTS = Object.freeze(['finished', 'failed', 'cancelled']);
const SOURCES = Object.freeze(['printer', 'shop']);
const text = (v) => (v == null ? '' : String(v)).trim();
const ms = (v) => { const n = typeof v === 'number' ? v : Date.parse(text(v)); return Number.isFinite(n) ? n : null; };

function withResult(order, mark) {
  const m = mark && typeof mark === 'object' ? mark : {};
  if (!RESULTS.includes(m.result) || !SOURCES.includes(m.source)) return null;
  const machineId = text(m.machineId);
  const at = ms(m.at);
  if (!machineId || at === null) return null;
  const runs = order && Array.isArray(order.printRuns) ? order.printRuns : null;
  if (!runs || !runs.length) return null;
  let index = -1;
  for (let i = runs.length - 1; i >= 0; i--) {
    const r = runs[i];
    if (!r || text(r.machineId) !== machineId) continue;
    const sent = ms(r.at);
    if (sent !== null && sent <= at) { index = i; break; }
  }
  if (index < 0) return null;
  const run = runs[index];
  let next;
  if (m.source === 'printer') {
    if (run.result && run.resultSource === 'shop') {
      if (run.printerResult === m.result) return null;
      next = Object.assign({}, run, { printerResult: m.result });   // kept beside the shop's
    } else {
      if (run.result === m.result && run.resultSource === 'printer') return null;
      if (run.result && run.resultSource === 'printer') return null;  // the first word stands
      next = Object.assign({}, run, { result: m.result, resultSource: 'printer', printerResult: m.result });
    }
  } else {
    if (run.result === m.result && run.resultSource === 'shop') return null;
    next = Object.assign({}, run, { result: m.result, resultSource: 'shop' });
    if (run.resultSource === 'printer' && !run.printerResult) next.printerResult = run.result;
  }
  const out = runs.slice();
  out[index] = next;
  return out;
}

/** The result a run carries, or null: what every report reads. */
function resultOf(run) {
  return run && RESULTS.includes(run.result) ? run.result : null;
}

const api = { RESULTS, SOURCES, withResult, resultOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytRunResult = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
