'use strict';
(function (global) {

/**
 * How often each printer's prints come out right (P6, batch 3 of
 * ~/Khayt-proposals/prusa-ideas-plan.md), beside the hours and utilisation
 * Machine profit already shows.
 *
 * Counted from ONE result per run (lib/run-result.js), across every job's
 * `printRuns`: a reprint is its own run, so a job that failed once and
 * printed the second time is one failure and one success on whichever
 * printers ran them. Cancelled runs are counted and shown but left out of
 * the rate: a shop that cancels a print it no longer needs has not seen the
 * printer fail. Runs with no result yet are `unknown`, never a success.
 *
 *   successRates({ orders, machines, from, to, minRuns, dayOf })
 *     → rows [{ machineId, finished, failed, cancelled, unknown, rate, enough }]
 *       worst rate first; `rate` = finished / (finished + failed), null with
 *       no decided runs; `enough` false below `minRuns` decided runs (5), so
 *       one failure in two prints does not read as a 50% printer.
 *   successPercent(rate) → whole percent to SHOW, or null: never 100 unless
 *       every decided run succeeded, never 0 unless none did.
 *
 * `from`/`to` are YYYY-MM-DD, compared with the day each run was SENT, as
 * `dayOf(run.at)` gives it. A run's `at` is a full UTC stamp (the desktop's
 * toISOString, the Mac's StoreWriter.iso), and the shop's days are local:
 * cutting the stamp to ten characters gives the UTC day, so in a shop west of
 * UTC an evening print counted on tomorrow, and east of UTC an early-morning
 * one on yesterday. The caller says what a day is:
 *   - the desktop passes `localDayOf` below (this computer's own calendar);
 *   - the Mac passes its book-calendar function from Swift.
 * Without `dayOf`, the first ten characters, as before, so an older caller
 * gives the same answer it always did. Pure; JavaScriptCore-safe (no Node API).
 */

const MIN_RUNS = 5;
const day = (v) => String(v == null ? '' : v).slice(0, 10);
const pad = (n) => String(n).padStart(2, '0');

/**
 * A run's day on THIS computer's calendar: a full stamp ("…T21:30:00.000Z")
 * read in local time, a bare "YYYY-MM-DD" left as written (it is already a
 * day; reading it through Date would make it UTC midnight, the day before
 * west of UTC). Anything unreadable → '' (in no range).
 */
function localDayOf(at) {
  const s = String(at == null ? '' : at).trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  if (!/^\d{4}-\d{2}-\d{2}T/.test(s)) return '';
  const d = new Date(s);
  if (!Number.isFinite(d.getTime())) return '';
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function successRates(input) {
  const i = input || {};
  const RR = (global && global.KhaytRunResult) || (typeof require === 'function' ? require('./run-result.js') : null);
  const minRuns = Number.isInteger(i.minRuns) && i.minRuns > 0 ? i.minRuns : MIN_RUNS;
  const from = day(i.from), to = day(i.to);
  const dayOf = typeof i.dayOf === 'function' ? (at) => day(i.dayOf(at)) : day;
  const rows = new Map();
  const row = (id) => {
    if (!rows.has(id)) rows.set(id, { machineId: id, finished: 0, failed: 0, cancelled: 0, unknown: 0 });
    return rows.get(id);
  };
  for (const m of Array.isArray(i.machines) ? i.machines : []) if (m && m.id) row(String(m.id));
  for (const o of Array.isArray(i.orders) ? i.orders : []) {
    if (!o || o.deleted) continue;
    for (const r of Array.isArray(o.printRuns) ? o.printRuns : []) {
      if (!r || !r.machineId) continue;
      const d = (from || to) ? dayOf(r.at) : '';
      if ((from && (!d || d < from)) || (to && (!d || d > to))) continue;
      const res = RR ? RR.resultOf(r) : null;
      row(String(r.machineId))[res || 'unknown'] += 1;
    }
  }
  const out = [...rows.values()].map((x) => {
    const decided = x.finished + x.failed;
    // Three decimals, but a failure is never rounded away (1 in 2000 is not
    // 1) and a success never is either: successPercent reads 1 and 0 as "all"
    // and "none".
    let rate = decided ? Math.round((x.finished / decided) * 1000) / 1000 : null;
    if (rate === 1 && x.failed) rate = 0.999;
    if (rate === 0 && x.finished) rate = 0.001;
    return Object.assign(x, { rate, enough: decided >= minRuns });
  });
  // Worst first; a printer with no decided runs last; ties by id.
  return out.sort((a, b) => ((a.rate === null) - (b.rate === null)) || ((a.rate ?? 0) - (b.rate ?? 0)) || a.machineId.localeCompare(b.machineId));
}

/**
 * A rate as the whole percent every app shows (Dev Hub, Nov 24, for the desktop,
 * Mac and iPhone alike). It rounds as usual, but a printer that failed even once
 * never reads 100%, and one that succeeded even once never reads 0%:
 * 199 of 200 is 99, 1 of 200 is 1. `null` (no decided runs) and anything that
 * is not a rate between 0 and 1 give null, which is shown as "—".
 */
function successPercent(rate) {
  if (typeof rate !== 'number' || !Number.isFinite(rate) || rate < 0 || rate > 1) return null;
  const pct = Math.round(rate * 100);
  if (pct === 100 && rate < 1) return 99;
  if (pct === 0 && rate > 0) return 1;
  return pct;
}

const api = { MIN_RUNS, successRates, localDayOf, successPercent };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytPrinterSuccess = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
