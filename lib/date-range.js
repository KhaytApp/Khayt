'use strict';
/**
 * Which records fall in a period — "this month", "last quarter", a custom span.
 *
 * Every list in Khayt that has a range picker filtered through one function in
 * the renderer, `inRange`, which read the clock and two page-level globals for
 * the custom span. Lifted so the Mac app's Expenses, Waste and Reports screens
 * answer "this month" the same way — the same string-slicing rule, the same
 * local calendar, the same treatment of an unparseable date.
 *
 * PURE: the clock and the custom span are passed in. Dates are compared as
 * `YYYY-MM-DD` strings on purpose: a record's date is written in the shop's
 * local time, and comparing it as a Date would shift it by a day at either end
 * of the month for any shop not on UTC.
 */
(function (global) {

  const RANGES = ['all', 'month', 'last_month', 'quarter', 'last_quarter', 'year', 'custom'];

  const pad = (n) => String(n).padStart(2, '0');
  /** A Date as the shop writes a day: `YYYY-MM-DD`, in local time. */
  function localDay(d) {
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }
  /** `YYYY-MM`, in local time. */
  function localMonth(d) {
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`;
  }

  /**
   * @param {string} dateStr   the record's date, `YYYY-MM-DD` or an ISO stamp
   * @param {string} range     one of RANGES
   * @param {object} [ctx]     `{ now: Date, from: 'YYYY-MM-DD', to: 'YYYY-MM-DD' }`
   */
  function inRange(dateStr, range, ctx) {
    if (!range || range === 'all') return true;
    if (!dateStr) return false;
    /* ONE DELIBERATE CHANGE from the renderer's original, which asked only
     * whether the string parsed as a date and then sliced it.
     *
     * A record dated "2026" parses, and every branch below slices ten
     * characters out of it — so it fell out of every period except `year`,
     * which it landed in because `"2026".slice(0, 4)` happens to be the year.
     * A malformed date filed into a period by accident is worse than one left
     * out of all of them, and the Mac app has to give the same answer without
     * carrying JavaScript's date parser to do it. Every record Khayt writes is
     * `YYYY-MM-DD`, so nothing a shop has changes. */
    if (!/^\d{4}-\d{2}-\d{2}/.test(String(dateStr))) return false;
    if (isNaN(new Date(dateStr))) return false;
    const c = ctx || {};
    if (range === 'custom') {
      const from = c.from || '';
      const to = c.to || '';
      if (!from && !to) return true;
      const ds = String(dateStr).slice(0, 10);
      if (from && ds < from) return false;
      if (to && ds > to) return false;
      return true;
    }
    const now = c.now instanceof Date ? c.now : new Date();
    const nowY = now.getFullYear();
    const nowM = now.getMonth();
    const ds = String(dateStr).slice(0, 10);
    if (range === 'month') return ds.slice(0, 7) === `${nowY}-${pad(nowM + 1)}`;
    if (range === 'last_month') {
      const lm = new Date(nowY, nowM - 1, 1);
      return ds.slice(0, 7) === `${lm.getFullYear()}-${pad(lm.getMonth() + 1)}`;
    }
    if (range === 'quarter') {
      const nowQ = Math.floor(nowM / 3);
      const dsMonth = parseInt(ds.slice(5, 7), 10) - 1;
      const dsYear = parseInt(ds.slice(0, 4), 10);
      return dsYear === nowY && Math.floor(dsMonth / 3) === nowQ;
    }
    if (range === 'last_quarter') {
      const lastQEnd = new Date(nowY, nowM - (nowM % 3), 0);
      const lastQStart = new Date(lastQEnd.getFullYear(), Math.floor(lastQEnd.getMonth() / 3) * 3, 1);
      const fromStr = localDay(lastQStart);
      const toStr = localDay(lastQEnd);
      return ds >= fromStr && ds <= toStr;
    }
    if (range === 'year') return ds.slice(0, 4) === String(nowY);
    return true;
  }

  /**
   * The span a range covers, as `{ from, to }` (`YYYY-MM-DD`), with `to` cut to
   * today for a range still running — or null for `all`, and for a custom
   * range with no bounds, whose span is the data's own and only the caller
   * knows it. Written beside inRange from the SAME definitions, so the two can
   * never disagree about which days a period holds. A straight-line machine's
   * depreciation is pro-rated over this (lib/machine-pl.js, lib/depreciation.js).
   */
  function bounds(range, ctx) {
    const c = ctx || {};
    const now = c.now instanceof Date ? c.now : new Date();
    const today = localDay(now);
    const cap = (to) => (to > today ? today : to);
    const y = now.getFullYear(), m = now.getMonth();
    const span = (a, z) => ({ from: localDay(a), to: cap(localDay(z)) });
    if (range === 'month') return span(new Date(y, m, 1), new Date(y, m + 1, 0));
    if (range === 'last_month') return span(new Date(y, m - 1, 1), new Date(y, m, 0));
    if (range === 'quarter') { const q = m - (m % 3); return span(new Date(y, q, 1), new Date(y, q + 3, 0)); }
    if (range === 'last_quarter') {
      const end = new Date(y, m - (m % 3), 0);
      return span(new Date(end.getFullYear(), Math.floor(end.getMonth() / 3) * 3, 1), end);
    }
    if (range === 'year') return span(new Date(y, 0, 1), new Date(y, 11, 31));
    if (range === 'custom' && (c.from || c.to)) {
      const from = c.from || '';
      const to = cap(c.to || today);
      return from ? { from, to } : null;
    }
    return null;
  }

  const api = { RANGES, inRange, bounds, localDay, localMonth };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytDateRange = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
