'use strict';

(function (global) {
/**
 * Teaching the estimator what this shop's machines actually do.
 *
 * lib/stl-estimate.js turns geometry into a weight and a time using five
 * constants: density, infill, shell fraction, volumetric throughput and waste.
 * Four of them are the shop's own settings. The fifth — throughput — is the one
 * nobody can answer, because "effective volumetric flow including travel and
 * acceleration overhead" is not a number a shop knows about its own printer. It
 * has been 8 mm³/s for everyone since the estimator was written.
 *
 * It does not need to be guessed any more. Look at what the time estimate
 * actually computes:
 *
 *     volume = weight / density
 *     time   = volume / throughput
 *   ⇒ time   = weight / (density × throughput)
 *
 * Density and throughput only ever appear multiplied together, and that product
 * is **grams per hour** — which is measured directly by every job that reports
 * both its weight and its duration. So the two hardest constants to guess
 * collapse into one number the shop's own history already contains.
 *
 * What this module will not do:
 *
 *   - Learn from a job nobody measured. A typed figure is the shop's estimate of
 *     its own past, and calibrating an estimator against estimates is circular.
 *   - Learn from an apportioned job. When one duration was divided across four
 *     parts by their estimates, feeding that back in teaches the estimator its
 *     own assumptions.
 *   - Learn from one job. A single print says nothing about a machine, and a
 *     calibration confident after one sample is worse than no calibration.
 *   - Mix machines that disagree. A CoreXY and a bedslinger have genuinely
 *     different rates; averaging them fits neither.
 *
 * Pure: takes orders, returns numbers.
 */

const MIN_JOBS = 3;
/** Beyond this spread the jobs are not describing one rate. */
const MAX_RELATIVE_SPREAD = 0.6;

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

/**
 * Grams-per-hour readings from the jobs entitled to teach us anything.
 *
 * `printFileId` and `setupId` narrow to one model, or to one model printed with
 * one set of settings. They come off the allocation rather than the order
 * because the link belongs to the PART — one order can carry parts from
 * different files.
 *
 * @param {Array} orders
 * @param {{allocate: function}} deps  lib/order-file-link.js allocateActuals
 * @param {{machineId?: string, printFileId?: string, setupId?: string}} [q]
 */
function readings(orders, deps, q = {}) {
  const list = Array.isArray(orders) ? orders.filter((o) => o && typeof o === 'object') : [];
  const allocate = deps && deps.allocate;
  if (typeof allocate !== 'function') return [];
  const out = [];
  for (const order of list) {
    if (q.machineId && order.machineId !== q.machineId) continue;
    for (const a of allocate(order)) {
      // Both conditions matter and neither implies the other: `exact` means
      // nothing was divided, `measured` means a printer said so.
      if (!a.exact || !a.measured) continue;
      if (q.printFileId && a.printFileId !== q.printFileId) continue;
      if (q.setupId && a.setupId !== q.setupId) continue;
      const g = num(a.actGrams);
      const h = num(a.actHours);
      if (!g || !h) continue;
      out.push(g / h);
    }
  }
  return out;
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

/**
 * What this shop actually prints, in grams per hour.
 *
 * The median rather than the mean: one job that sat paused overnight, or one
 * where the shop typed the wrong hour, should not drag the figure it is meant to
 * establish.
 *
 * @returns {{gramsPerHour: number, jobs: number, spread: number}|null}
 *   null whenever there is not enough agreement to be worth trusting — the
 *   caller then keeps its configured value, which is the honest outcome.
 */
function learnGramsPerHour(orders, deps, q = {}) {
  const rates = readings(orders, deps, q);
  if (rates.length < MIN_JOBS) return null;

  const mid = median(rates);
  if (!(mid > 0)) return null;

  // How far the readings sit from that middle, relative to it. A shop whose jobs
  // disagree by more than this is not describing one rate, and averaging them
  // would produce a number that fits none of them.
  const spread = median(rates.map((r) => Math.abs(r - mid))) / mid;
  if (spread > MAX_RELATIVE_SPREAD) return null;

  return {
    gramsPerHour: Math.round(mid * 100) / 100,
    jobs: rates.length,
    spread: Math.round(spread * 100) / 100,
  };
}

/**
 * The narrowest calibration this shop has earned, falling back until one holds.
 *
 *   setup   this model, printed with these settings
 *   file    this model, however it was sliced
 *   machine this printer, whatever it was printing
 *   shop    everything
 *
 * Narrowest first, because grams-per-hour is not the machine constant the name
 * suggests. Measured across 67 finished jobs on ONE printer it ran from 1.9 to
 * 48.6 g/h: it follows the part's geometry, layer height and colour changes far
 * more than it follows the machine. A shop-wide median is therefore a statement
 * about the shop's recent MIX of work, and it misprices anything unlike that
 * mix. The same model printed the same way is the one comparison that holds
 * still, so prefer it whenever enough of them have finished.
 *
 * Every level must clear MIN_JOBS and the spread guard on its own; a file with
 * two prints behind it is not a calibration, and falls through to the level that
 * has earned one. That is why the fallbacks are tried in order rather than the
 * narrowest non-empty one being taken.
 */
function calibrate(orders, deps, q = {}) {
  // A setup belongs to a file, so the narrowest scope needs both to be named —
  // a setupId alone would silently pool identical setup ids across files.
  if (q.printFileId && q.setupId) {
    const own = learnGramsPerHour(orders, deps,
      { printFileId: q.printFileId, setupId: q.setupId });
    if (own) return Object.assign({ scope: 'setup' }, own);
  }
  if (q.printFileId) {
    const own = learnGramsPerHour(orders, deps, { printFileId: q.printFileId });
    if (own) return Object.assign({ scope: 'file' }, own);
  }
  if (q.machineId) {
    const own = learnGramsPerHour(orders, deps, { machineId: q.machineId });
    if (own) return Object.assign({ scope: 'machine' }, own);
  }
  const shop = learnGramsPerHour(orders, deps, {});
  if (shop) return Object.assign({ scope: 'shop' }, shop);
  return null;
}

/**
 * Fold a calibration into the options lib/stl-estimate.js takes.
 *
 * Expressed as a throughput so the estimator is unchanged: throughput is
 * gramsPerHour ÷ density ÷ 3.6, which is the same rearrangement as above read
 * backwards. The estimator keeps one way of computing a time; this only supplies
 * a better number for it.
 */
function applyCalibration(opts, cal) {
  const o = Object.assign({}, opts || {});
  if (!cal || !(cal.gramsPerHour > 0)) return o;
  const density = num(o.densityGPerCm3) || 1.24;
  o.throughputMm3PerS = cal.gramsPerHour / density / 3.6;
  // So a caller can say where the number came from rather than presenting a
  // measured rate and a guessed one identically.
  //
  // `spread` travels with it because a rate alone overstates itself. Measured
  // against this shop's own history, grams-per-hour is NOT a property of the
  // machine: across 67 finished jobs on one printer it ran from 1.9 to 48.6 g/h
  // — it tracks the job's geometry, layer height and colour changes, while the
  // slicer's own time estimate for those same jobs was accurate to about ±5%.
  // The median is still the best single number available, but a caller that
  // shows it without saying how far the jobs disagreed is claiming a machine
  // constant that does not exist.
  o.calibratedFrom = {
    scope: cal.scope || 'shop',
    jobs: cal.jobs,
    spread: Number.isFinite(cal.spread) ? cal.spread : null,
  };
  return o;
}

const api = {
  MIN_JOBS, MAX_RELATIVE_SPREAD,
  readings, learnGramsPerHour, calibrate, applyCalibration,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytEstimateCalibration = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
