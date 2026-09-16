'use strict';

/**
 * Two figures a month, twelve months back: what an hour of printing earned,
 * and what a gram of material cost.
 *
 * Both were drawn by `renderCostTrends` in `renderer/analytics.js` from
 * arithmetic inside the render function, and both were wrong:
 *
 *   Revenue per print-hour counted `status === 'completed'` only. In Khayt's
 *   pipeline `delivered` is PAST completed — a job that was finished AND
 *   handed over left the chart, so a shop that delivers promptly saw its best
 *   months as its emptiest. (The same fault has now been found in five
 *   charts; see the quote funnel, product profitability, new-vs-returning and
 *   client LTV.)
 *
 *   "Average material cost per gram" divided a spool's cost by its REMAINING
 *   weight, so a spool got dearer per gram as it was used up and a nearly
 *   finished one cost a fortune. And it was computed from today's shelf for
 *   every one of the twelve months, so the "trend" was one number twelve
 *   times. A gram costs what the spool cost divided by what it weighed NEW
 *   (`spoolWeight`), and the month it belongs to is the month the spool was
 *   opened.
 *
 * PURE. Money and scope are injected, as every report here does — `revenueOf`
 * is `order-money`'s answer and `countsForBusiness` is `business-scope`'s —
 * and a month with no answer says `null`, never 0: no hours printed is not
 * "earned nothing per hour", and no spool opened is not "material was free".
 */
(function (global) {

  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  const listOf = (v) => (Array.isArray(v) ? v : []);
  /** Finished work, in either of the two statuses that mean it. */
  const DONE = new Set(['completed', 'delivered']);

  /** `YYYY-MM` of an ISO instant or day, in the shop's own calendar. */
  function monthOf(iso) {
    if (!iso) return null;
    const s = String(iso);
    // A day string is already local; an instant is turned into the local day.
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s.slice(0, 7);
    const d = new Date(s);
    if (Number.isNaN(d.getTime())) return null;
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  }

  /** The month a job counts in: when it was finished, else when it was taken. */
  function monthDone(o) {
    return monthOf(o.completedAt) || monthOf(o.deliveredAt) || monthOf(o.date);
  }

  /** The `months` month keys ending with the month of `now`, oldest first. */
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
   * @param orders   the book's `printLog`
   * @param spools   the book's `inventory`
   * @param opts     { now, months = 12, revenueOf, countsForBusiness }
   * @returns {{ months: Array<{key, revenue, hours, perHour, costPerGram, spoolsOpened}>,
   *             perHour: number|null, costPerGram: number|null }}
   *   `perHour` / `costPerGram` at the top are the whole window's figures.
   */
  function costTrends(orders, spools, opts) {
    const o = opts || {};
    const months = o.months > 0 ? Math.floor(o.months) : 12;
    const revenueOf = typeof o.revenueOf === 'function' ? o.revenueOf : (x) => num(x.price);
    const counts = typeof o.countsForBusiness === 'function' ? o.countsForBusiness : () => true;
    const keys = monthKeys(o.now, months);
    const buckets = {};
    for (const k of keys) buckets[k] = { key: k, revenue: 0, hours: 0, costSum: 0, gramSum: 0, spoolsOpened: 0 };

    for (const job of listOf(orders)) {
      if (!job || !DONE.has(job.status) || job.voidedAt || !counts(job)) continue;
      const k = monthDone(job);
      if (!k || !buckets[k]) continue;
      buckets[k].revenue += num(revenueOf(job));
      buckets[k].hours += num(job.printTime);
    }
    let allCost = 0, allGrams = 0;
    for (const spool of listOf(spools)) {
      if (!spool) continue;
      const cost = num(spool.cost), grams = num(spool.spoolWeight);
      if (cost <= 0 || grams <= 0) continue;
      allCost += cost; allGrams += grams;
      const k = monthOf(spool.openedAt);
      if (!k || !buckets[k]) continue;
      buckets[k].costSum += cost;
      buckets[k].gramSum += grams;
      buckets[k].spoolsOpened += 1;
    }

    let revenue = 0, hours = 0;
    const rows = keys.map((k) => {
      const b = buckets[k];
      revenue += b.revenue; hours += b.hours;
      return {
        key: k,
        revenue: round2(b.revenue),
        hours: round2(b.hours),
        perHour: b.hours > 0 ? round2(b.revenue / b.hours) : null,
        // Weighted by grams: two spools opened in a month cost what they cost
        // per gram between them, not the average of two per-gram figures.
        costPerGram: b.gramSum > 0 ? round4(b.costSum / b.gramSum) : null,
        spoolsOpened: b.spoolsOpened,
      };
    });
    return {
      months: rows,
      perHour: hours > 0 ? round2(revenue / hours) : null,
      costPerGram: allGrams > 0 ? round4(allCost / allGrams) : null,
    };
  }

  function round2(v) { return Math.round(v * 100) / 100; }
  function round4(v) { return Math.round(v * 10000) / 10000; }

  const api = { costTrends, monthKeys, monthDone, DONE };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCostTrends = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
