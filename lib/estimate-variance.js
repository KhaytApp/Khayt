'use strict';

(function (global) {
/**
 * What a model actually costs, against what it was quoted at.
 *
 * WHY THIS AND NOT THE ACCURACY PANEL
 *
 * Analytics already reports accuracy: an average time variance, an average
 * weight variance, and a table of orders. That answers "how good are my
 * estimates" and it is worth having. It is not actionable, because the unit is
 * the order — and an order happened once, to one customer, at a price already
 * charged.
 *
 * The unit a shop can act on is the MODEL. "This bracket is quoted at 41 g and
 * 3.2 h; across four prints it took 48 g and 3.8 h — 17% more filament and 19%
 * more time than you charge for" is a sentence that changes a price. The same
 * numbers grouped by order say only that some jobs ran long.
 *
 * (Those figures divide out, which is not decoration: an example nobody checked
 * is how a doc starts drifting from the thing it documents.)
 *
 * Everything needed already existed and none of it was joined up:
 * `order-file-link.js` allocates a finished job's real figures back to the parts
 * that made it, carrying the print file each came from and whether the figures
 * were measured or typed; `printer-actuals.js` compares one estimate to one
 * actual. That comparison had SEVEN tests and zero callers — analytics computed
 * its own average inline instead. This uses the tested one, which is the point
 * of it existing.
 *
 * MEASURED ONLY, AND EXACT ONLY
 *
 * Two filters, and neither implies the other.
 *
 *   measured — a printer reported these figures. A typed actual is usually the
 *              estimate confirmed, so including them would mostly compare an
 *              estimate to itself and report a variance near zero. That is the
 *              precise failure `printer-actuals.js` was written to end, and
 *              re-creating it one level up would be worse for being subtle.
 *   exact    — the job had ONE part, so nothing was divided. A multi-part job's
 *              per-part figures are a proportional share of a total, which is a
 *              reasonable way to split a bill and not a measurement of anything.
 *
 * The cost of both filters is jobs excluded, which is why `sampled` is reported
 * next to every figure. A shop with three prints of a model and one usable
 * reading should see "1 print", not a confident percentage.
 */

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

/**
 * Middle value. Median rather than mean: one rescued print should not move a
 * model's verdict.
 *
 * Rounded to one decimal because the even-count case averages two numbers and
 * hands back things like -1.9499999999999997, which is float noise wearing the
 * clothes of precision. A shop reads this to decide a price; the tenth of a
 * percent is already more than the data supports.
 */
function median(xs, places = 1) {
  const s = xs.filter((n) => Number.isFinite(n)).sort((a, b) => a - b);
  if (!s.length) return null;
  const m = Math.floor(s.length / 2);
  const v = s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
  const f = 10 ** places;
  return Math.round(v * f) / f;
}

/** How much confidence a count of prints deserves, said in words rather than a number. */
function confidenceFor(sampled) {
  if (sampled >= 5) return 'good';
  if (sampled >= 3) return 'fair';
  return 'thin';
}

/**
 * Group every usable reading by the print file it came from.
 *
 * @param {Array} orders
 * @param {{allocate: function, compare: function}} deps
 *   allocate  order-file-link.allocateActuals
 *   compare   printer-actuals.compareToEstimate
 * @param {object} [opts] {minSamples}
 * @returns {Array} one row per model, worst-underpriced first
 */
function varianceByModel(orders, deps, opts = {}) {
  const list = Array.isArray(orders) ? orders : [];
  const allocate = deps && deps.allocate;
  const compare = deps && deps.compare;
  if (typeof allocate !== 'function' || typeof compare !== 'function') return [];
  const minSamples = Number.isFinite(opts.minSamples) ? opts.minSamples : 1;

  const groups = new Map();
  for (const order of list) {
    if (!order || typeof order !== 'object') continue;
    for (const a of allocate(order)) {
      if (!a || !a.exact || !a.measured) continue;
      if (!a.printFileId) continue;          // nothing to attribute it to
      const estG = num(a.estGrams);
      const estH = num(a.estHours);
      const actG = num(a.actGrams);
      const actH = num(a.actHours);
      if (!actG && !actH) continue;

      // The tested comparison, one job at a time. It returns nulls rather than
      // zeros for a missing side, which is what keeps "we don't know" out of the
      // medians below instead of dragging them toward zero.
      const cmp = compare({ printTime: estH, weightG: estG }, { durationS: actH * 3600, filamentGrams: actG });

      if (!groups.has(a.printFileId)) {
        groups.set(a.printFileId, {
          printFileId: a.printFileId, name: '', sampled: 0,
          gramsPct: [], hoursPct: [], estG: [], actG: [], estH: [], actH: [],
          lastAt: null,
        });
      }
      const g = groups.get(a.printFileId);
      g.sampled += 1;
      if (cmp.gramsDeltaPct !== null) g.gramsPct.push(cmp.gramsDeltaPct);
      if (cmp.hoursDeltaPct !== null) g.hoursPct.push(cmp.hoursDeltaPct);
      if (estG) g.estG.push(estG);
      if (actG) g.actG.push(actG);
      if (estH) g.estH.push(estH);
      if (actH) g.actH.push(actH);
      const at = order.date || null;
      if (at && (!g.lastAt || String(at) > String(g.lastAt))) g.lastAt = at;
      if (!g.name && (a.partName || order.project)) g.name = a.partName || order.project;
    }
  }

  const rows = [];
  for (const g of groups.values()) {
    if (g.sampled < minSamples) continue;
    rows.push({
      printFileId: g.printFileId,
      name: g.name || '',
      sampled: g.sampled,
      confidence: confidenceFor(g.sampled),
      estGrams: median(g.estG, 2),
      actGrams: median(g.actG, 2),
      gramsDeltaPct: median(g.gramsPct),
      estHours: median(g.estH, 2),
      actHours: median(g.actH, 2),
      hoursDeltaPct: median(g.hoursPct),
      lastAt: g.lastAt,
    });
  }

  // Worst first, by whichever axis is further out — a model that takes 40%
  // longer than quoted matters as much as one that eats 40% more filament, and
  // sorting on one axis buries the other.
  const worst = (r) => Math.max(
    r.gramsDeltaPct === null ? 0 : r.gramsDeltaPct,
    r.hoursDeltaPct === null ? 0 : r.hoursDeltaPct,
  );
  rows.sort((a, b) => worst(b) - worst(a));
  return rows;
}

/**
 * The one sentence a row is worth, or null when it does not earn one.
 *
 * Only models that are consistently UNDER-quoted get a sentence, and only when
 * the miss is big enough to be worth a shop's attention. Over-quoting is not a
 * problem being solved here — a shop that charges too much finds out from its
 * customers — and reporting every 3% wobble as news is how a panel gets ignored.
 */
function advice(row, opts = {}) {
  const threshold = Number.isFinite(opts.thresholdPct) ? opts.thresholdPct : 10;
  if (!row || row.sampled < 2) return null;
  const g = row.gramsDeltaPct;
  const h = row.hoursDeltaPct;
  const worst = Math.max(g === null ? -Infinity : g, h === null ? -Infinity : h);
  if (!Number.isFinite(worst) || worst < threshold) return null;
  return {
    axis: (h !== null && h >= (g === null ? -Infinity : g)) ? 'time' : 'filament',
    pct: Math.round(worst),
    sampled: row.sampled,
    confidence: row.confidence,
  };
}

const api = { varianceByModel, advice, median, confidenceFor };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytEstimateVariance = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
