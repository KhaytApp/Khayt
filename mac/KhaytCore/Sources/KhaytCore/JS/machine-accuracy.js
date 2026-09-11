'use strict';

(function (global) {
/**
 * How far each machine runs from the time it was quoted at.
 *
 * WHAT WAS THERE, AND WHY IT SHOWED NOTHING
 *
 * Analytics drew this twice — a headline percentage (`#timestampAccuracySection`)
 * and a per-machine breakdown (`#machineAccuracySection`) — and both worked the
 * actual out the same way:
 *
 *     actualH = (completedAt - printingStartedAt) / 3600000
 *
 * `printingStartedAt` is written in exactly one place: `order-status.js`, when a
 * job is dragged into the printing stage BY HAND. A shop whose jobs are logged
 * from the printer's own history never passes through that stage, so the field is
 * never set, so both panels filtered every order out and rendered an empty
 * string. On the book this was found against — nineteen finished prints, every
 * one of them carrying a Moonraker-measured duration in `actualPrintTime` — the
 * accuracy panels were blank, and the machine had been measuring itself all
 * along.
 *
 * THE WALL CLOCK IS NOT THE PRINT EITHER
 *
 * Even where both timestamps exist, the difference between them is not what the
 * print took. It is what the print took plus however long it sat finished on the
 * bed before somebody marked it done — overnight, in the common case. That is a
 * one-sided error: it can only ever make a machine look slower than it is, and a
 * shop reading "this printer runs 40% over" would raise its prices to cover time
 * nobody spent printing.
 *
 * So this reads `actualPrintTime`, and only when `actualsSource` says a PRINTER
 * put it there. A typed actual is usually the estimate confirmed — the precise
 * failure `printer-actuals.js` exists to end — and counting those would compare
 * an estimate to itself and report a machine as perfectly calibrated.
 *
 * The cost of that filter is jobs excluded, which is why `sampled` is reported
 * beside every figure and never rounded away.
 *
 * ONE JOB, ONE VOTE
 *
 * Both old panels summed the hours and divided: `Σactual / Σestimate`. That lets
 * a single forty-hour print outvote a dozen short ones, so a machine's verdict
 * could be decided by the one job least like the rest of its work. This takes the
 * median of the per-job percentages instead, the same way `estimate-variance.js`
 * does for models, and for the same reason — one rescued print should not move a
 * verdict.
 *
 * The headline and the breakdown come off the same filtered readings here, so
 * they can no longer disagree: before, one averaged across every job and the
 * other averaged per machine without ever rolling up, and nothing made the two
 * add up.
 */

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : 0;
};

/**
 * Did a PRINTER supply this order's duration, or did somebody type it?
 *
 * The time axis specifically. An order can be measured on weight and typed on
 * time — PrusaLink reports a duration and no filament, Moonraker reports both,
 * and a shop can fill in either by hand — so "this order was measured" is not a
 * single fact and must not be read as one here.
 */
function timeWasMeasured(order) {
  const src = order && order.actualsSource;
  return !!(src && src.time && src.time !== 'manual');
}

/**
 * Has this print finished?
 *
 * BOTH SPELLINGS, and a store can hold either. `order-status.js` derives the
 * delivered STAGE from `status === 'completed'` plus a `deliveredAt`, so the
 * status field on a handed-over job stays `completed` — but books written by
 * older versions, and the bundled sample shop, store the literal string
 * `delivered` instead. Testing only for `completed` therefore passed every unit
 * test written against a fresh order and silently dropped five of the sample's
 * six measured prints, because the one it kept was the one job nobody had got
 * round to delivering.
 *
 * A print that has been handed to a customer is not less finished than one
 * sitting on the shelf, and the machine timed it either way.
 */
function isFinished(order) {
  const s = order && order.status;
  return s === 'completed' || s === 'delivered';
}

/**
 * Every finished print this can say anything about.
 *
 * @returns {Array<{machineId, estHours, actHours, at}>}
 */
function readings(orders) {
  const list = Array.isArray(orders) ? orders : [];
  const out = [];
  for (const o of list) {
    if (!o || typeof o !== 'object') continue;
    if (!isFinished(o)) continue;
    if (!timeWasMeasured(o)) continue;
    const estHours = num(o.printTime);
    const actHours = num(o.actualPrintTime);
    if (!estHours || !actHours) continue;
    out.push({
      machineId: o.machineId ? String(o.machineId) : '',
      estHours,
      actHours,
      at: o.completedAt || o.date || null,
    });
  }
  return out;
}

/**
 * Fold a set of readings into one verdict.
 *
 * `deps.compare` is `printer-actuals.compareToEstimate` — the tested comparison,
 * one job at a time. It returns null rather than zero for a side it does not
 * know, which is what keeps "we have no idea" out of the median instead of
 * dragging it toward nothing. Doing the subtraction here instead would be a
 * second opinion about the shop's own arithmetic, which is how the two apps
 * come to disagree.
 */
function fold(rows, deps) {
  const { compare, median, confidence } = deps;
  const pcts = [];
  const est = [];
  const act = [];
  let lastAt = null;
  for (const r of rows) {
    const cmp = compare({ printTime: r.estHours }, { durationS: r.actHours * 3600 });
    if (cmp.hoursDeltaPct !== null) pcts.push(cmp.hoursDeltaPct);
    est.push(r.estHours);
    act.push(r.actHours);
    if (r.at && (!lastAt || String(r.at) > String(lastAt))) lastAt = r.at;
  }
  return {
    sampled: rows.length,
    confidence: confidence(rows.length),
    estHours: median(est, 2),
    actHours: median(act, 2),
    hoursDeltaPct: median(pcts),
    lastAt,
  };
}

/**
 * One row per machine, the one running furthest over its quote first.
 *
 * Sorted by signed percentage rather than distance from zero: a machine that
 * finishes early is not a problem a shop needs to look at, and putting it at the
 * top of the list next to one that runs 30% long says they are equally worth
 * attention.
 *
 * Orders with no `machineId` are dropped rather than pooled under "unassigned".
 * The question this answers is which MACHINE to trust, and a bucket holding
 * every machine at once cannot answer it.
 *
 * @param {Array} orders
 * @param {{compare: function, median: function, confidence: function}} deps
 *   compare     printer-actuals.compareToEstimate
 *   median      estimate-variance.median
 *   confidence  estimate-variance.confidenceFor — so the two panels cannot
 *               disagree about what counts as enough evidence
 * @param {object} [opts] {minSamples}
 */
function accuracyByMachine(orders, deps, opts = {}) {
  if (!usable(deps)) return [];
  const minSamples = Number.isFinite(opts.minSamples) ? opts.minSamples : 1;
  const groups = new Map();
  for (const r of readings(orders)) {
    if (!r.machineId) continue;
    if (!groups.has(r.machineId)) groups.set(r.machineId, []);
    groups.get(r.machineId).push(r);
  }
  const rows = [];
  for (const [machineId, rs] of groups) {
    if (rs.length < minSamples) continue;
    rows.push({ machineId, ...fold(rs, deps) });
  }
  rows.sort((a, b) => (b.hoursDeltaPct || 0) - (a.hoursDeltaPct || 0));
  return rows;
}

/**
 * The whole shop in one figure, or null when nothing was measured.
 *
 * Null and not zero. "Every print landed on its estimate" and "no printer has
 * ever told us anything" are opposite states, and a headline reading +0% for the
 * second one is the failure this module was written to end, one level up.
 *
 * Unassigned jobs COUNT here, unlike the breakdown: they are still the shop's
 * prints, and the question "how good are our estimates" does not need to know
 * which machine ran them.
 */
function accuracyOverall(orders, deps, opts = {}) {
  if (!usable(deps)) return null;
  const minSamples = Number.isFinite(opts.minSamples) ? opts.minSamples : 1;
  const rows = readings(orders);
  if (rows.length < minSamples) return null;
  return fold(rows, deps);
}

const usable = (d) => !!(d
  && typeof d.compare === 'function'
  && typeof d.median === 'function'
  && typeof d.confidence === 'function');

const api = { accuracyByMachine, accuracyOverall, readings, timeWasMeasured, isFinished };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachineAccuracy = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
