'use strict';

/**
 * How long a job takes, from the day it was taken to the day it was finished.
 *
 * Two readings of the same interval, both lifted from inline arithmetic in
 * `renderer/analytics.js` (`renderCycleTimeChart`, `renderLeadTimeChart`):
 *
 *   `cycleTime`         — the average, month by month, for the months a shop
 *                         finished anything in;
 *   `leadTimeByProduct` — the average, fastest and slowest per product, so a
 *                         shop can see which of the things it sells is the one
 *                         that always runs late.
 *
 * Both counted `status === 'completed'` only. `delivered` is PAST completed in
 * Khayt's pipeline, so a job finished and handed over left both charts — the
 * sixth and seventh chart with the fault. Both take completed OR delivered now,
 * and a job's finish is `completedAt`, else `deliveredAt`: a job marked
 * delivered without ever passing through completed still has a day it was done.
 *
 * The lead-time table keyed on the job's free-text name (`project`), so a
 * product spelled two ways was two products and a job taken from the catalogue
 * did not join its product. It keys on `productId` when the job has one, and
 * on the name only when it does not.
 *
 * PURE. A month with nothing finished has `null`, not 0 — no jobs is not "done
 * in no time". A negative interval (finished before it was taken, a typed
 * date) is a job that cannot be measured and is left out, as it always was.
 */
(function (global) {

  const listOf = (v) => (Array.isArray(v) ? v : []);
  const DONE = new Set(['completed', 'delivered']);
  const DAY = 86400000;

  function finishedAt(o) {
    return o.completedAt || o.deliveredAt || null;
  }

  /** Days from the day taken to the finish instant, or null where it cannot be told. */
  function daysToFinish(o) {
    if (!o || !DONE.has(o.status) || o.voidedAt || !o.date) return null;
    const end = Date.parse(finishedAt(o) || '');
    const start = Date.parse(String(o.date).length === 10 ? o.date + 'T00:00:00' : o.date);
    if (Number.isNaN(end) || Number.isNaN(start)) return null;
    const days = (end - start) / DAY;
    return days < 0 ? null : days;
  }

  function monthOf(iso) {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return null;
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  }

  function monthKeys(now, months) {
    const d = new Date(typeof now === 'number' ? now : (now instanceof Date ? now.getTime() : Date.now()));
    const out = [];
    for (let i = months - 1; i >= 0; i--) {
      const m = new Date(d.getFullYear(), d.getMonth() - i, 1);
      out.push(`${m.getFullYear()}-${String(m.getMonth() + 1).padStart(2, '0')}`);
    }
    return out;
  }

  /**
   * @returns {{ months: Array<{key, avgDays, jobs}>, avgDays: number|null, jobs: number }}
   */
  function cycleTime(orders, opts) {
    const o = opts || {};
    const months = o.months > 0 ? Math.floor(o.months) : 6;
    const counts = typeof o.countsForBusiness === 'function' ? o.countsForBusiness : () => true;
    const keys = monthKeys(o.now, months);
    const buckets = {};
    for (const k of keys) buckets[k] = { total: 0, jobs: 0 };
    let total = 0, jobs = 0;
    for (const job of listOf(orders)) {
      if (!job || !counts(job)) continue;
      const days = daysToFinish(job);
      if (days === null) continue;
      const k = monthOf(finishedAt(job));
      if (!k || !buckets[k]) continue;
      buckets[k].total += days; buckets[k].jobs += 1;
      total += days; jobs += 1;
    }
    return {
      months: keys.map((k) => ({
        key: k,
        avgDays: buckets[k].jobs > 0 ? round1(buckets[k].total / buckets[k].jobs) : null,
        jobs: buckets[k].jobs,
      })),
      avgDays: jobs > 0 ? round1(total / jobs) : null,
      jobs,
    };
  }

  /**
   * @returns {{ rows: Array<{key, productId, name, avgDays, fastest, slowest, jobs}>, jobs: number }}
   *   Slowest average first; `top` rows (default 10). `jobs` is every job
   *   measured, so a host can decide whether there is enough to show.
   */
  function leadTimeByProduct(orders, opts) {
    const o = opts || {};
    const top = o.top > 0 ? Math.floor(o.top) : 10;
    const counts = typeof o.countsForBusiness === 'function' ? o.countsForBusiness : () => true;
    const by = {};
    let jobs = 0;
    for (const job of listOf(orders)) {
      if (!job || !counts(job)) continue;
      const days = daysToFinish(job);
      if (days === null) continue;
      const productId = job.productId || null;
      const name = job.project || job.name || '';
      const key = productId ? `product:${productId}` : `name:${name.trim().toLowerCase()}`;
      const row = by[key] || (by[key] = { key, productId, name, total: 0, jobs: 0, fastest: Infinity, slowest: -Infinity });
      row.total += days; row.jobs += 1;
      if (days < row.fastest) row.fastest = days;
      if (days > row.slowest) row.slowest = days;
      if (!row.name && name) row.name = name;
      jobs += 1;
    }
    const rows = Object.values(by)
      .map((r) => ({ key: r.key, productId: r.productId, name: r.name || 'Unknown',
                     avgDays: round1(r.total / r.jobs), fastest: round1(r.fastest),
                     slowest: round1(r.slowest), jobs: r.jobs }))
      .sort((a, b) => b.avgDays - a.avgDays)
      .slice(0, top);
    return { rows, jobs };
  }

  function round1(v) { return Math.round(v * 10) / 10; }

  const api = { cycleTime, leadTimeByProduct, daysToFinish, monthKeys, DONE };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCycleTime = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
