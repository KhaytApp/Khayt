'use strict';

(function (global) {
/**
 * Joining an order to the model it printed, and to the settings it used.
 *
 * Three things now know something a shop wants, and none of them could reach the
 * others: lib/printer-actuals.js learns what a job actually cost,
 * lib/print-setups.js learns which settings worked, and lib/model-identity.js
 * recognises a file the shop already has. An order carried a free-text
 * `fileRef` — a filename somebody typed — so none of it joined up.
 *
 * With a real link, the question a shop actually has becomes answerable:
 * *for THIS part, printed with THESE settings, how far out is my estimate?*
 *
 * The hard part is not the join, it is the honesty of the arithmetic.
 *
 * ── Actuals live on the ORDER, estimates live on the PART ──────────────────
 *
 * A printer reports one duration and one filament figure for a job. An order can
 * hold four parts. Splitting one measurement across four parts in proportion to
 * their estimates is an APPORTIONMENT, not a measurement — and it is circular:
 * it uses the estimate to divide up the very number meant to check the estimate.
 * For a single-part order no such thing happens and the figure is exact.
 *
 * So the two are counted separately and never silently pooled. A shop reading
 * "your estimate runs 12% under" deserves to know whether that came from eleven
 * clean single-part jobs or from one four-part job divided by assumption.
 *
 * Pure: no store, no DOM, no clock.
 */

const num = (v) => {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : 0;
};

const round2 = (v) => (v === null ? null : Math.round(v * 100) / 100);
const round1 = (v) => (v === null ? null : Math.round(v * 10) / 10);

/** A part's own estimate: hours and grams, for the whole line (× qty). */
function partEstimate(part) {
  const p = part || {};
  const qty = Math.max(1, num(p.qty) || 1);
  return {
    hours: num(p.printTime) * qty,
    grams: (num(p.printWeight) + num(p.supportWeight)) * qty,
  };
}

/** Parts of an order that name both a file and the settings used. */
function linkedParts(order) {
  const parts = Array.isArray(order && order.parts) ? order.parts : [];
  return parts.filter((p) => p && p.printFileId);
}

/**
 * Split an order's measured actuals across its parts.
 *
 * `exact` is true only when the order has ONE part — then the job's figures are
 * that part's figures and nothing was divided. With more than one part the
 * split is proportional to the estimates, which is an assumption wearing the
 * clothes of a measurement, and is flagged as such.
 *
 * Returns [] when the order carries no actuals: an order nobody measured
 * contributes nothing, rather than contributing zeros.
 */
function allocateActuals(order) {
  const o = order || {};
  const parts = Array.isArray(o.parts) ? o.parts.filter(Boolean) : [];
  if (!parts.length) return [];

  const actHours = num(o.actualPrintTime);
  const actGrams = num(o.actualWeight);
  if (actHours <= 0 && actGrams <= 0) return [];

  const estimates = parts.map(partEstimate);
  const totalHours = estimates.reduce((s, e) => s + e.hours, 0);
  const totalGrams = estimates.reduce((s, e) => s + e.grams, 0);
  const single = parts.length === 1;

  return parts.map((p, i) => {
    const est = estimates[i];
    // Proportional to this part's share of the estimate. With one part the
    // share is 1 and nothing is assumed.
    const hShare = single ? 1 : (totalHours > 0 ? est.hours / totalHours : 1 / parts.length);
    const gShare = single ? 1 : (totalGrams > 0 ? est.grams / totalGrams : 1 / parts.length);
    return {
      partId: p.id || null,
      printFileId: p.printFileId || null,
      setupId: p.setupId || null,
      estHours: est.hours,
      estGrams: est.grams,
      actHours: actHours > 0 ? actHours * hShare : 0,
      actGrams: actGrams > 0 ? actGrams * gShare : 0,
      exact: single,
      // Carried through from lib/printer-actuals: did these figures come off a
      // printer, or off a keyboard? Both are actuals; only one is a measurement.
      measured: !!(o.actualsSource
        && (o.actualsSource.time && o.actualsSource.time !== 'manual'
          || o.actualsSource.weight && o.actualsSource.weight !== 'manual')),
    };
  });
}

function blankPerf() {
  return {
    jobs: 0, exactJobs: 0, apportionedJobs: 0, measuredJobs: 0,
    estHours: 0, actHours: 0, hoursDeltaPct: null,
    estGrams: 0, actGrams: 0, gramsDeltaPct: null,
  };
}

const pct = (est, act) => (est > 0 && act > 0 ? ((act - est) / est) * 100 : null);

/**
 * How the estimate has held up for one file, optionally narrowed to one setup.
 *
 * @param {Array} orders
 * @param {{printFileId: string, setupId?: string, exactOnly?: boolean}} q
 */
function setupPerformance(orders, q) {
  const list = Array.isArray(orders) ? orders.filter((o) => o && typeof o === 'object') : [];
  const want = q || {};
  // Redundant with the per-part filter below (nothing matches an absent id),
  // but it makes "no file asked for" mean "no answer" at the top of the
  // function rather than as a side effect further down.
  if (!want.printFileId) return blankPerf();
  const out = blankPerf();

  for (const order of list) {
    for (const a of allocateActuals(order)) {
      if (a.printFileId !== want.printFileId) continue;
      if (want.setupId && a.setupId !== want.setupId) continue;
      // Asking for only the trustworthy figures must not also count the rest.
      if (want.exactOnly && !a.exact) continue;
      out.jobs += 1;
      if (a.exact) out.exactJobs += 1; else out.apportionedJobs += 1;
      if (a.measured) out.measuredJobs += 1;
      out.estHours += a.estHours;
      out.actHours += a.actHours;
      out.estGrams += a.estGrams;
      out.actGrams += a.actGrams;
    }
  }

  out.estHours = round2(out.estHours);
  out.actHours = round2(out.actHours);
  out.estGrams = round1(out.estGrams);
  out.actGrams = round1(out.actGrams);
  out.hoursDeltaPct = round1(pct(out.estHours, out.actHours));
  out.gramsDeltaPct = round1(pct(out.estGrams, out.actGrams));
  return out;
}

/** Every setup a file has been printed with, each with its own record. */
function fileHistory(orders, printFileId) {
  const list = Array.isArray(orders) ? orders.filter((o) => o && typeof o === 'object') : [];
  if (!printFileId) return [];
  const seen = new Set();
  for (const order of list) {
    for (const a of allocateActuals(order)) {
      if (a.printFileId === printFileId) seen.add(a.setupId || '');
    }
  }
  return [...seen].map((setupId) => Object.assign(
    { setupId: setupId || null },
    setupPerformance(list, { printFileId, setupId: setupId || undefined })));
}

/**
 * Which setups an order's completion should be recorded against.
 *
 * One entry per distinct (file, setup) pair the order printed — a four-part
 * order that used one setup for all four is ONE outcome for that setup, not
 * four. Counting it four times would let a single job make a setup look proven.
 */
function outcomesForOrder(order, ok) {
  const pairs = new Map();
  for (const p of linkedParts(order)) {
    if (!p.setupId) continue;
    pairs.set(`${p.printFileId}::${p.setupId}`, { printFileId: p.printFileId, setupId: p.setupId, ok: !!ok });
  }
  return [...pairs.values()];
}

const api = {
  partEstimate, linkedParts, allocateActuals,
  setupPerformance, fileHistory, outcomesForOrder,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytOrderFileLink = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
