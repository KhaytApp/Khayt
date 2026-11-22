'use strict';
(function (global) {

/**
 * "Waiting at the machine": the printer needs a PERSON before it can do
 * anything more (C4, batch 3 of ~/Khayt-proposals/prusa-ideas-plan.md).
 *
 * Derived from what is STORED, so it survives a reconnect and a restart:
 * the poll cache is rebuilt empty when the app starts or the printer drops
 * off the network, and a "your print is done" that lived only there was
 * forgotten the moment the printer came back answering "idle". What is on
 * disk is enough:
 *
 *   machine.bedClearedAt     when someone last said the bed is clear
 *   completions              the printer's finished jobs, persisted per machine
 *                            (lib/printer-poll-cache.js), each with `at` and,
 *                            since P4, how it ended (`result`)
 *   opts.lastFinishedAt      the latest completedAt of a job on this machine
 *                            in the book (auto-dispatch plan()'s figure)
 *
 * and, while the printer answers, its live problems (lib/printer-problems.js).
 *
 *   waiting(machine, { completions, lastFinishedAt, live, problems })
 *     `live` is the poll's entry ({ state }) while the printer answers: a
 *     printer that is printing (or paused mid-print) again has had its bed
 *     cleared, stamped or not, so it is not waiting for one (correctness
 *     review of #2613: it showed "print to take off" over a running job).
 *     → [{ reason, since }]  from the closed set, most urgent first:
 *        'filament-runout'    live: a head ran out mid-print
 *        'printer-attention'  live: the printer is asking for someone
 *        'print-to-take-off'  a print finished and the bed was not cleared since
 *        'bed-to-clear'       a print ended badly (failed, cancelled) and its
 *                             leftovers were not cleared since
 *
 * A machine that clears its own bed (`clearsOwnBed: true`, the shop's word)
 * never waits for a bed. The same rule as dispatch: a bed is clear only when
 * it was said to be AFTER the last print ended (lib/auto-dispatch.js bedState).
 * Pure: the clock is never read.
 */

/** The live word says a job is on the bed now (printer-activity's busy or paused class). */
function runningNow(live) {
  if (!live || typeof live !== 'object' || live.error) return false;
  const A = (global && global.KhaytPrinterActivity) || (typeof require === 'function' ? require('./printer-activity.js') : null);
  if (!A) return false;
  const cls = A.WORDS[A.word(live.state)];
  return cls === 'busy' || cls === 'paused';
}

const REASONS = Object.freeze(['filament-runout', 'printer-attention', 'print-to-take-off', 'bed-to-clear']);
const ms = (v) => { const n = typeof v === 'number' ? v : Date.parse(String(v == null ? '' : v)); return Number.isFinite(n) ? n : null; };

function waiting(machine, opts = {}) {
  const m = machine && typeof machine === 'object' ? machine : {};
  const out = [];

  // Live: only while the printer is answering (problems is lib/printer-problems.js's list).
  for (const p of Array.isArray(opts.problems) ? opts.problems : []) {
    if (!p) continue;
    if (p.code === 'filament-runout' && !out.some((x) => x.reason === 'filament-runout')) out.push({ reason: 'filament-runout', since: null, head: p.head ?? null });
    else if ((p.code === 'printer-attention' || p.code === 'door-open') && !out.some((x) => x.reason === 'printer-attention')) out.push({ reason: 'printer-attention', since: null });
  }

  // Stored: the last print that ended on this machine, against the last "bed is clear".
  if (m.clearsOwnBed !== true && !runningNow(opts.live)) {
    let last = null;
    for (const c of Array.isArray(opts.completions) ? opts.completions : []) {
      const at = ms(c && c.at);
      if (at !== null && (!last || at > last.at)) last = { at, result: c.result || null };
    }
    const book = ms(opts.lastFinishedAt);
    if (book !== null && (!last || book > last.at)) last = { at: book, result: 'finished' };
    const cleared = ms(m.bedClearedAt);
    if (last && !(cleared !== null && cleared > last.at)) {
      const reason = last.result === 'failed' || last.result === 'cancelled' ? 'bed-to-clear' : 'print-to-take-off';
      out.push({ reason, since: last.at });
    }
  }
  return out.sort((a, b) => REASONS.indexOf(a.reason) - REASONS.indexOf(b.reason));
}

const api = { REASONS, waiting };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytWaitingAtMachine = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
