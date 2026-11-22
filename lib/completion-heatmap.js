'use strict';
(function (global) {

/**
 * Twelve weeks of finished work, by day of the week.
 *
 * `renderer/analytics.js buildHandoffHeatmapCells` counted it inline; the Mac
 * draws the same grid, so the counting is here. A cell is how many finished
 * jobs were completed on that weekday in that week, week 0 the oldest and 11
 * the one `now` is in, measured back from `now` in whole 7-day spans — the
 * way the desktop always counted it.
 *
 * The caller filters the orders to the range it is showing; this keeps the
 * finished ones that say when they finished.
 *
 * PURE: `now` comes in; weekday is the Date's local one, as the screens draw.
 */

const WEEK_MS = 7 * 86400000;

function finishedRule(opts) {
  if (opts && typeof opts.isFinished === 'function') return opts.isFinished;
  const S = (typeof global !== 'undefined' && global.KhaytOrderStatus) || (() => {
    try { return require('./order-status.js'); } catch (e) { return null; }
  })();
  return S ? (o) => S.isFinished(o) : (o) => !!o && (o.status === 'completed' || o.status === 'delivered');
}

/**
 * @returns {{matrix: number[][], maxVal: number, jobs: number, hasData: boolean}}
 *   `matrix[dow][week]`, dow 0 = Sunday. `hasData` is five finished jobs or
 *   more — fewer draws a grid that says nothing.
 */
function heatmap(orders, opts) {
  const o2 = opts || {};
  const isFinished = finishedRule(o2);
  const now = o2.now instanceof Date ? o2.now.getTime() : (o2.now != null ? +o2.now : Date.now());
  const completed = (Array.isArray(orders) ? orders : []).filter((o) => o && isFinished(o) && o.completedAt);
  const matrix = Array.from({ length: 7 }, () => Array(12).fill(0));
  completed.forEach((o) => {
    try {
      const d = new Date(o.completedAt);
      const week = Math.min(11, Math.floor((now - d.getTime()) / WEEK_MS));
      const dow = d.getDay();
      if (week >= 0 && week < 12) matrix[dow][11 - week]++;
    } catch (_) { /* ignore */ }
  });
  const maxVal = Math.max(1, ...matrix.flat());
  return { matrix, maxVal, jobs: completed.length, hasData: completed.length >= 5 };
}

/** How strongly a cell is tinted: 0.12 for none, up to 0.97 for the busiest. */
function intensity(count, maxVal) {
  return 0.12 + (count / Math.max(1, maxVal)) * 0.85;
}

const api = { heatmap, intensity };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytCompletionHeatmap = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
