/**
 * How the last print on each machine ended, and a failed print's plug reading.
 *
 * Written by the printer poll (renderer/integrations.js `meterPrintEnergy`, off
 * the finish photo's end edge) and read by the waste forms (renderer/waste.js
 * `failedCostingFor`) to cost a failure with lib/failed-print-cost.js: the
 * printer's hours, else the estimate scaled by how far it got, and what its
 * plug metered. Its own file because Bed Ready loads the waste screen but not
 * the poll — there it is simply empty, and a failure is costed from the job.
 *
 * In memory only, as on the Mac (EnergyMeter.attempts): a failure logged
 * after a restart is costed at the machine's wattage instead.
 */
(function (global) {
  /** machineId → `{ orderId, outcome, durationS, progress, at }`. Every machine, plug or not. */
  const ended = {};
  /** machineId → `{ orderId, reading, at }` for a failed or cancelled print. */
  const attempts = {};
  const KEEP_MS = 24 * 3600 * 1000;

  /** Record how a print on this machine ended. */
  function recordEnd(machineId, end) { ended[String(machineId || '')] = end; }
  /** Keep a failed or cancelled print's reading for the waste row. */
  function keepAttempt(machineId, attempt) { attempts[String(machineId || '')] = attempt; }
  /** How the last print on this machine ended, or null. */
  function endedFor(machineId) { return ended[String(machineId || '')] || null; }
  /** The failed attempt's reading for this job, if it is recent and its own. */
  function attemptFor(orderId, now = Date.now()) {
    const id = String(orderId || '');
    if (!id) return null;
    const a = Object.values(attempts).find((x) => x && x.orderId === id && now - x.at < KEEP_MS);
    return a ? a.reading : null;
  }
  /** The attempt has been written onto a waste row: forget it, so the next
   *  failure logged against the job does not carry the same reading again. */
  function consumeAttempt(orderId) {
    for (const [mid, a] of Object.entries(attempts)) if (a && a.orderId === orderId) delete attempts[mid];
  }

  const api = { recordEnd, keepAttempt, endedFor, attemptFor, consumeAttempt };
  global.KhaytPrintEnds = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
