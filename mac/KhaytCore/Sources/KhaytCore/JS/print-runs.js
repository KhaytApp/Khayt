'use strict';
/**
 * Which machine a job was actually printed on, and when.
 *
 * ── WHY ────────────────────────────────────────────────────────────────────
 *
 * Every figure that ties a job to a machine — the machine P&L
 * (`machine-pl.js`), nozzle wear (`nozzle-wear.js`), hours run and
 * depreciation (`depreciation.js`), capacity, reliability, the finish photo's
 * job lookup (`print-finish-photo.js`) — reads ONE field: `order.machineId`.
 * That field was only ever written by hand, or by the scheduler and the
 * dispatcher proposing a printer. Sending the job's file to a printer from
 * Khayt wrote nothing at all, so a job planned for the Ender and sent to the
 * Prusa went on charging its hours, its wear and its depreciation to the
 * Ender, and a job nobody assigned was "Unassigned" in the P&L however many
 * times Khayt itself had started it.
 *
 * So a send records itself, on the field everything already reads rather than
 * a parallel one nobody reads.
 *
 * ── THE PLAN IS NOT OVERWRITTEN SILENTLY ──────────────────────────────────
 *
 * When the job already names a different machine — picked by hand, or
 * accepted from the scheduler — the actual machine still wins `machineId`
 * (it is what printed, and what wore), and the one that was planned is kept
 * in `plannedMachineId`, so the inspector can say "Printed on X (planned Y)".
 * A machineId that a previous SEND wrote is not a plan, and is not kept as
 * one: a reprint on another printer after a failure is not a change of plan.
 *
 * ── REPRINTS ARE NOT COUNTED TWICE ────────────────────────────────────────
 *
 * Each send is appended to `printRuns` (newest last, capped), which is
 * HISTORY and nothing else: no rule sums it. A job is still one row in every
 * machine figure, on whichever machine printed it last — the print whose
 * actuals the completion records. A failed attempt is already costed where
 * Khayt has always costed it, as a waste entry carrying the machine of the
 * moment (`failed-print-cost.js`), which is now the machine that really ran it.
 *
 * ── WHAT IS ON DISK ALREADY ───────────────────────────────────────────────
 *
 * A job with no `printRuns` reads exactly as before: `printedOn` is null and
 * every machine figure goes on reading `machineId`. Nothing migrates.
 *
 * Pure: no clock, no store. The caller passes the time and writes the fields
 * inside its own write chain, against the record as it is on disk.
 */
(function (global) {

  /** A job remembers its last fifty sends and no more. */
  const RUNS_CAP = 50;

  /** A job that is over is not this job's print any more. */
  const CLOSED = ['completed', 'cancelled'];

  const text = (v) => (v == null ? '' : String(v)).trim();

  /** The last path component — what a printer and a job agree a file is called. */
  function leaf(name) {
    return text(name).split(/[\\/]/).pop() || '';
  }

  /** The runs on a record, oldest first, skipping anything that is not one. */
  function runsOf(order) {
    const runs = order && Array.isArray(order.printRuns) ? order.printRuns : [];
    return runs.filter((r) => r && typeof r === 'object' && text(r.machineId));
  }

  /**
   * The fields a send writes onto a job, or null when it writes none.
   *
   * @param {object} order  the job as it is on disk
   * @param {{machineId:string, at:string, started?:boolean, file?:string}} run
   * @returns {null | {machineId:string, plannedMachineId:(string|null), printRuns:object[]}}
   *   `plannedMachineId: null` means the key comes OFF the record — the job
   *   was sent to the machine it was planned for.
   */
  function fields(order, run) {
    if (!order || typeof order !== 'object') return null;
    const machineId = text(run && run.machineId);
    const at = text(run && run.at);
    if (!machineId || !at) return null;
    if (CLOSED.includes(order.status)) return null;

    const runs = runsOf(order);
    const last = runs.length ? runs[runs.length - 1] : null;
    const current = text(order.machineId);
    // The machine on the job is a PLAN unless the last send is what put it there.
    const currentIsPlan = !!current && !(last && text(last.machineId) === current);
    let planned = currentIsPlan ? current : (text(order.plannedMachineId) || null);
    if (planned === machineId) planned = null;

    const entry = { machineId, at, started: !!(run && run.started) };
    const file = leaf(run && run.file);
    if (file) entry.file = file;

    return {
      machineId,
      plannedMachineId: planned,
      printRuns: runs.concat([entry]).slice(-RUNS_CAP),
    };
  }

  /**
   * What the inspector says about where a job printed, or null when Khayt
   * never sent it anywhere.
   *
   * `planned` is the machine the job names that is NOT the one it last went
   * to: the plan the send departed from, or one the shop picked since (the
   * plan for the next print). Null when there is nothing to contrast.
   *
   * @returns {null | {machineId, at, started, file, planned, earlier: object[]}}
   */
  function printedOn(order) {
    const runs = runsOf(order);
    if (!runs.length) return null;
    const last = runs[runs.length - 1];
    const lastId = text(last.machineId);
    const current = text(order && order.machineId);
    let planned = current && current !== lastId ? current : (text(order && order.plannedMachineId) || null);
    if (planned === lastId) planned = null;
    return {
      machineId: lastId,
      at: text(last.at),
      started: !!last.started,
      file: text(last.file) || null,
      planned,
      // Newest first, the latest left out — it is the headline.
      earlier: runs.slice(0, -1).reverse().map((r) => ({
        machineId: text(r.machineId), at: text(r.at), started: !!r.started,
      })),
    };
  }

  const api = { fields, printedOn, RUNS_CAP };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintRuns = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
