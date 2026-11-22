'use strict';

/**
 * Whether the shop keeps its promises: of the finished jobs that had a due
 * date, how many were done by it, and by how many days the rest missed.
 *
 * Lifted from `renderSLASection` in `renderer/analytics.js`. That function
 * had already been fixed once — it counted voided jobs and the shop's own
 * calibration prints as promises — and it still counted `status ===
 * 'completed'` only. `delivered` is PAST completed in Khayt's pipeline, so
 * the jobs a shop had finished AND handed over were the ones missing from its
 * delivery record. Eighth chart with the fault.
 *
 * A promise is a finished job with a due date. It is kept when the day it was
 * finished is on or before the due day, in the SHOP'S calendar: `completedAt`
 * and `deliveredAt` are instants, and comparing an instant's UTC date with a
 * local due date flips on-time to late near midnight. A job with no due date
 * made no promise and is not counted either way.
 *
 * PURE. `rate` is null when nothing was promised — "kept 0% of no promises"
 * is not a record, it is an absence of one.
 */
(function (global) {

  const listOf = (v) => (Array.isArray(v) ? v : []);
  const DONE = new Set(['completed', 'delivered']);
  const DAY = 86400000;

  function localDay(v) {
    if (!v) return null;
    const s = String(v);
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
    const d = new Date(s);
    if (Number.isNaN(d.getTime())) return null;
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  /** The local day a job was finished: completion, else delivery, else the day taken. */
  function finishedDay(o) {
    return localDay(o.completedAt) || localDay(o.deliveredAt) || localDay(o.date);
  }

  function daysBetween(fromDay, toDay) {
    const a = Date.parse(fromDay + 'T00:00:00'), b = Date.parse(toDay + 'T00:00:00');
    if (Number.isNaN(a) || Number.isNaN(b)) return null;
    return Math.round((b - a) / DAY);
  }

  /**
   * @param orders  the book's `printLog`
   * @param opts    { countsForBusiness, since?: 'YYYY-MM-DD' — a job's `date` on or after }
   * @returns {{ promised, onTime, late, rate: number|null, avgDelayDays: number|null,
   *             worstDelayDays: number|null, lateJobs: Array<{id, project, dueDate, finishedDay, delayDays}> }}
   */
  function onTime(orders, opts) {
    const o = opts || {};
    const counts = typeof o.countsForBusiness === 'function' ? o.countsForBusiness : () => true;
    let promised = 0, kept = 0;
    const lateJobs = [];
    for (const job of listOf(orders)) {
      if (!job || !DONE.has(job.status) || job.voidedAt || !counts(job)) continue;
      const due = localDay(job.dueDate);
      if (!due) continue;
      if (o.since && (!job.date || String(job.date) < o.since)) continue;
      const done = finishedDay(job);
      if (!done) continue;
      promised += 1;
      if (done <= due) { kept += 1; continue; }
      const delay = daysBetween(due, done);
      lateJobs.push({ id: job.id, project: job.project || '', dueDate: due, finishedDay: done,
                      delayDays: delay === null ? 0 : delay });
    }
    lateJobs.sort((a, b) => b.delayDays - a.delayDays);
    const late = lateJobs.length;
    const totalDelay = lateJobs.reduce((s, j) => s + j.delayDays, 0);
    return {
      promised, onTime: kept, late,
      rate: promised > 0 ? Math.round((kept / promised) * 1000) / 10 : null,
      avgDelayDays: late > 0 ? Math.round((totalDelay / late) * 10) / 10 : null,
      worstDelayDays: late > 0 ? lateJobs[0].delayDays : null,
      lateJobs,
    };
  }

  const api = { onTime, finishedDay, DONE };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOnTime = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
