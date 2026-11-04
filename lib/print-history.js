'use strict';

(function (global) {
/**
 * How many times each library model has been printed, and when last — read
 * off the JOBS, not kept as a counter.
 *
 * A print-file record carries `timesPrinted` and `lastPrinted`, but the only
 * thing that ever wrote them is the desktop library's manual "log a print"
 * button (renderer/printfiles.js `logPrint`). A job made from a model never
 * touched them, and the native Mac app has no such button at all — so for a
 * shop that runs its work as jobs, every model read "never printed", the
 * "Never printed" chip held the whole library, and "last printed" was blank
 * on models made a hundred times. The jobs already say which model they made
 * (`parts[].printFileId`, written by lib/part-from-print-file.js) and when
 * they finished, so the answer is derived from them instead of maintained by
 * hand beside them.
 *
 * ── WHAT COUNTS AS PRINTED ────────────────────────────────────────────────
 *
 * A job that is FINISHED — `status` `completed`, or the `delivered` older
 * books carry as a literal status (lib/order-status.js `isFinished`). Shipped
 * and delivered are date stamps on a job that stays `completed`, so they need
 * nothing of their own. A job that is still open has not printed yet; a
 * cancelled one never finished; a VOIDED one is taken out of the books and is
 * taken out of this too, like every other finished-work rule.
 *
 * ── ONE JOB IS ONE PRINT, WHATEVER THE QUANTITY ───────────────────────────
 *
 * `timesPrinted` counts JOBS (print runs): a job naming the model in a part
 * of quantity 3, or in two parts, is one time printed — the same unit the
 * desktop's "log a print" button counts, and what "Last run" means. How many
 * pieces came out is `copies`: the sum of those parts' quantities.
 *
 * `lastPrinted` is when the newest of those jobs finished: `completedAt`,
 * else (for a job finished before the stamp existed) `deliveredAt`,
 * `shippedAt`, then the job's own `date`. The stored text is returned as
 * written; only the comparison parses it.
 *
 * `timesFailed` counts failed inspections on any job naming the model, open
 * or not (lib/qc-failure.js pushes one `defects` entry per failure; a job
 * marked failed with no defect list counts as one).
 *
 * ── THE RECORD'S OWN COUNTER IS KEPT, NOT ADDED TO ────────────────────────
 *
 * `merge` takes the LARGER of the record's stored figure and the derived one.
 * A desktop shop that pressed "log a print" for prints with no job keeps that
 * count; one that pressed it for the same prints its jobs made is not counted
 * twice. Nothing here writes the record.
 *
 * Pure: no store, no clock, no DOM. O(jobs). Ported natively to the Mac as
 * `PrintHistory` (mac/KhaytCore/Sources/KhaytCore/PrintHistory.swift), held to
 * this file by `PrintHistoryParityTests`.
 */

const FINISHED = ['completed', 'delivered'];
const WHEN = ['completedAt', 'deliveredAt', 'shippedAt', 'date'];

/** Milliseconds for a stored instant, or null. Only text is read. */
function instant(v) {
  if (typeof v !== 'string' || !v) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
}

/** When a finished job printed, as the book wrote it, or null. */
function printedAt(order) {
  for (const k of WHEN) if (instant(order[k]) !== null) return order[k];
  return null;
}

/** How many times a job failed inspection. */
function failuresOf(order) {
  const defects = Array.isArray(order.defects)
    ? order.defects.filter((d) => d && typeof d === 'object' && !Array.isArray(d)).length : 0;
  const flagged = order.qcStatus ? order.qcStatus === 'fail' : (!!order.qcFailedAt && !order.qcPassedAt);
  return Math.max(defects, flagged ? 1 : 0);
}

/** A part's quantity: a whole number of at least one. */
function qtyOf(part) {
  const q = Number(part.qty);
  return Number.isFinite(q) && q >= 1 ? Math.floor(q) : 1;
}

/**
 * Every model's history, keyed by print-file id. A model no job has printed
 * or failed is absent.
 *
 * @param {Array} orders  the book's `printLog`
 * @returns {Object<string, {timesPrinted: number, copies: number, timesFailed: number,
 *   lastPrinted: string|null, lastJobId: string|null}>}
 */
function byFile(orders) {
  const out = new Map();
  for (const order of Array.isArray(orders) ? orders : []) {
    if (!order || typeof order !== 'object' || Array.isArray(order)) continue;
    if (order.voidedAt) continue;
    const parts = Array.isArray(order.parts) ? order.parts : [];
    const copies = new Map();
    for (const p of parts) {
      if (!p || typeof p !== 'object' || typeof p.printFileId !== 'string' || !p.printFileId) continue;
      copies.set(p.printFileId, (copies.get(p.printFileId) || 0) + qtyOf(p));
    }
    if (!copies.size) continue;
    const done = FINISHED.includes(order.status);
    const failed = failuresOf(order);
    if (!done && !failed) continue;
    const at = done ? printedAt(order) : null;
    const atMs = instant(at);
    for (const [id, n] of copies) {
      let e = out.get(id);
      if (!e) {
        e = { timesPrinted: 0, copies: 0, timesFailed: 0, lastPrinted: null, lastJobId: null };
        out.set(id, e);
      }
      e.timesFailed += failed;
      if (!done) continue;
      e.timesPrinted += 1;
      e.copies += n;
      if (atMs !== null && (e.lastPrinted === null || atMs > instant(e.lastPrinted))) {
        e.lastPrinted = at;
        e.lastJobId = typeof order.id === 'string' && order.id ? order.id : null;
      }
    }
  }
  return Object.fromEntries(out);
}

/** A stored counter: a whole number, or 0. */
function count(v) {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0;
}

/**
 * What a record shows: the larger of its own counters and the jobs', and the
 * later of the two last-printed instants.
 *
 * @param {object} record  a `printFiles` entry (its timesPrinted/timesFailed/lastPrinted)
 * @param {object} [entry] its `byFile` entry, if any
 * @returns {{timesPrinted: number, timesFailed: number, lastPrinted: string|null}}
 */
function merge(record, entry) {
  const r = record && typeof record === 'object' ? record : {};
  const e = entry && typeof entry === 'object' ? entry : {};
  const own = typeof r.lastPrinted === 'string' && r.lastPrinted ? r.lastPrinted : null;
  const derived = typeof e.lastPrinted === 'string' && e.lastPrinted ? e.lastPrinted : null;
  let lastPrinted = own;
  const a = instant(own);
  const b = instant(derived);
  // A stored value that will not parse loses to one that does: it cannot be
  // compared, and the job's is a real instant.
  if (b !== null && (a === null || b > a)) lastPrinted = derived;
  return {
    timesPrinted: Math.max(count(r.timesPrinted), count(e.timesPrinted)),
    timesFailed: Math.max(count(r.timesFailed), count(e.timesFailed)),
    lastPrinted,
  };
}

const api = { byFile, merge, printedAt, FINISHED };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytPrintHistory = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
