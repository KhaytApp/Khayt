'use strict';
(function () {

/**
 * Revenue forecasting — pure math over completed-order history. Builds a monthly
 * revenue series and projects future months by least-squares linear regression
 * (falling back to the mean when there's too little signal). Side-effect free
 * (inject `now` + a `revenueOf` accessor) so it's unit-testable.
 *
 * Distinct from the dashboard's naive month-to-date extrapolation: this looks at
 * the trend across several whole months to project the next ones.
 */

const DAY = 86400000;

// LOCAL month, matching every other month bucket in renderer/analytics.js (:298, :665,
// :854, :917, :986, :1049). Using UTC in a UTC+3 shop put orders completed between 00:00
// and 03:00 on the 1st into the PREVIOUS month, and — because curKey is derived from
// Date.now() the same way — slid the entire forecast window back a month when the app was
// opened in those hours. The tests never caught it: they build both "now" and the fixtures
// with Date.UTC, so they were self-consistently wrong.
function ymKey(ms) { const d = new Date(ms); return d.getFullYear() * 12 + d.getMonth(); }
function ymLabel(k) { const y = Math.floor(k / 12); const m = k % 12; return y + '-' + String(m + 1).padStart(2, '0'); }
function orderMs(o) { const t = Date.parse(o.completedAt || o.deliveredAt || o.date || ''); return Number.isNaN(t) ? null : t; }

/**
 * Monthly completed-revenue series for the `months` whole months ENDING with the
 * month before `now` (current partial month excluded so the trend isn't skewed).
 * → [{ key, label, revenue }] oldest-first. Empty months are included as 0.
 */
function monthlyRevenueSeries(orders, opts = {}) {
  const now = opts.now || 0;
  const months = opts.months > 0 ? opts.months : 6;
  const revenueOf = typeof opts.revenueOf === 'function' ? opts.revenueOf : (o) => +o.price || 0;
  const done = new Set(['completed', 'delivered']);
  const curKey = ymKey(now);
  const startKey = curKey - months; // months before the current partial month
  const buckets = {};
  for (let k = startKey; k < curKey; k++) buckets[k] = 0;
  for (const o of Array.isArray(orders) ? orders : []) {
    if (!o || !done.has(o.status)) continue;
    const ms = orderMs(o);
    if (ms == null) continue;
    const k = ymKey(ms);
    if (k >= startKey && k < curKey) buckets[k] += +revenueOf(o) || 0;
  }
  const out = [];
  for (let k = startKey; k < curKey; k++) out.push({ key: k, label: ymLabel(k), revenue: Math.round(buckets[k] * 100) / 100 });
  return out;
}

/** Least-squares fit over y-values (x = 0..n-1). → { slope, intercept }. */
function linreg(values) {
  const n = values.length;
  if (n === 0) return { slope: 0, intercept: 0 };
  if (n === 1) return { slope: 0, intercept: values[0] };
  let sx = 0, sy = 0, sxx = 0, sxy = 0;
  for (let i = 0; i < n; i++) { sx += i; sy += values[i]; sxx += i * i; sxy += i * values[i]; }
  const denom = n * sxx - sx * sx;
  if (denom === 0) return { slope: 0, intercept: sy / n };
  const slope = (n * sxy - sx * sy) / denom;
  const intercept = (sy - slope * sx) / n;
  return { slope, intercept };
}

/**
 * Project `periods` future months from a revenue series.
 * → { history, projection:[{key,label,projected}], nextMonth, trendPct, method }
 * Needs ≥3 non-zero months for a trend; otherwise falls back to the mean.
 */
function forecast(orders, opts = {}) {
  const periods = opts.periods > 0 ? opts.periods : 3;
  const history = monthlyRevenueSeries(orders, opts);
  const vals = history.map((h) => h.revenue);
  const nonZero = vals.filter((v) => v > 0).length;
  const lastKey = history.length ? history[history.length - 1].key : ymKey(opts.now || 0) - 1;

  let projAt, method;
  if (nonZero >= 3) {
    const { slope, intercept } = linreg(vals);
    projAt = (i) => Math.max(0, intercept + slope * i);
    method = 'trend';
  } else {
    const mean = vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0;
    projAt = () => Math.max(0, mean);
    method = nonZero ? 'average' : 'none';
  }

  const projection = [];
  for (let p = 1; p <= periods; p++) {
    projection.push({ key: lastKey + p, label: ymLabel(lastKey + p), projected: Math.round(projAt(vals.length - 1 + p) * 100) / 100 });
  }
  const nextMonth = projection.length ? projection[0].projected : 0;
  const lastActual = vals.length ? vals[vals.length - 1] : 0;
  const trendPct = lastActual > 0 ? Math.round(((nextMonth - lastActual) / lastActual) * 1000) / 10 : null;
  return { history, projection, nextMonth, trendPct, method };
}

const api = { monthlyRevenueSeries, linreg, forecast, ymLabel };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytForecast = api;

})();
