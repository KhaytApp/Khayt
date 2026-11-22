'use strict';
(function (global) {
/**
 * When the shop actually finishes work.
 *
 * Seven days by twenty-four hours, from the moment each job was marked done —
 * so it is when work LEFT the machines, not when it was ordered.
 *
 * ── AND THE THING THE GRID CANNOT SAY ─────────────────────────────────────
 *
 * A 168-cell heatmap is the shape of the data and not a finding. What a shop
 * can act on is narrower: which day carries the most, which hour, and how much
 * of the week's work is finishing on a day the shop is CLOSED. That last one is
 * either printers running unattended over a weekend, which is fine and worth
 * knowing, or somebody coming in on their day off, which is worth knowing for a
 * different reason. Neither app has said it.
 *
 * `delivered` counts as finished here, as everywhere: the version this
 * complements filtered on `completed` alone, so work that reached a customer
 * was not in the picture of when the shop is busy.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

const FINISHED = ['completed', 'delivered'];

/**
 * @param {object} input
 *   orders    every order; which are finished is part of the answer
 *   openDays  [bool × 7] by `getDay()` index, 0 = Sunday. Which days the shop
 *             works — from `working-week`, which the caller owns because it
 *             reads the settings.
 *   minimum   how many finished jobs before a grid means anything (default 10)
 * @param {object} deps
 *   whenOf    (order) => ms the job was finished, or null. Defaults to parsing
 *             `completedAt`; injected because the HOUR has to come out in the
 *             shop's own zone and only the caller knows it.
 *   inWindow  (order) => is it in the period being reported? Optional.
 * @returns {{matrix, byDay, byHour, totals}}
 */
function throughput(input, deps) {
  const i = input || {};
  const d = deps || {};
  const whenOf = typeof d.whenOf === 'function'
    ? d.whenOf
    : (o) => {
        const t = Date.parse(String((o && o.completedAt) || ''));
        return Number.isFinite(t) ? t : null;
      };
  const inWindow = typeof d.inWindow === 'function' ? d.inWindow : () => true;
  const openDays = Array.isArray(i.openDays) ? i.openDays : [];
  const minimum = i.minimum == null ? 10 : Math.max(0, num(i.minimum));

  const matrix = Array.from({ length: 7 }, () => new Array(24).fill(0));
  let counted = 0;
  let closedDay = 0;

  for (const order of (Array.isArray(i.orders) ? i.orders : [])) {
    if (!order || order.voidedAt) continue;
    if (!FINISHED.includes(String(order.status || ''))) continue;
    if (!inWindow(order)) continue;
    const at = whenOf(order);
    if (at == null) continue;
    const when = new Date(at);
    const day = when.getDay();
    const hour = when.getHours();
    if (!Number.isFinite(day) || !Number.isFinite(hour)) continue;
    matrix[day][hour] += 1;
    counted += 1;
    if (openDays.length === 7 && !openDays[day]) closedDay += 1;
  }

  const byDay = matrix.map((row, day) => ({
    day,
    jobs: row.reduce((s, n) => s + n, 0),
    open: openDays.length === 7 ? !!openDays[day] : true,
  }));
  const byHour = Array.from({ length: 24 }, (_, hour) => ({
    hour,
    jobs: matrix.reduce((s, row) => s + row[hour], 0),
  }));

  const best = (rows, key) => rows.reduce(
    (top, r) => (top == null || r.jobs > top.jobs ? r : top), null);
  const busiestDay = counted > 0 ? best(byDay) : null;
  const busiestHour = counted > 0 ? best(byHour) : null;

  return {
    matrix, byDay, byHour,
    totals: {
      jobs: counted,
      /// Is there enough to read a pattern from? Ten finished jobs spread over
      /// 168 cells is noise, and a grid of noise looks exactly like a finding.
      enough: counted >= minimum,
      busiestDay: busiestDay && busiestDay.jobs > 0 ? busiestDay.day : null,
      busiestHour: busiestHour && busiestHour.jobs > 0 ? busiestHour.hour : null,
      /// Work finishing on a day the shop does not work. Either printers
      /// running unattended, or somebody coming in on their day off.
      onClosedDays: closedDay,
      closedDayShare: counted > 0 ? closedDay / counted : null,
      /// The busiest single cell, which the grid is scaled against.
      peak: Math.max(0, ...matrix.map((row) => Math.max(...row))),
    },
  };
}

const api = { throughput, FINISHED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytThroughput = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
