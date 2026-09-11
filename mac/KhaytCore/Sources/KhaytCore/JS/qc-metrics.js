'use strict';
(function (global) {
/**
 * How much of the shop's work passes inspection first time.
 *
 * Pass rate is the easy figure and the less useful one: a shop that reprints
 * until it passes has a pass rate near 100% and a quality problem. FIRST-PASS
 * YIELD is the honest number — of the jobs that went through QC, how many were
 * right the first time — and a reprint chain collapses to its root so a job
 * reprinted three times counts once.
 *
 * ── LIFTED, NOT WRITTEN ───────────────────────────────────────────────────
 *
 * This was `computeQcMetrics` in `renderer/order-flows.js`: already pure, and
 * in a file the Mac app cannot load. Moving it is most of the change.
 *
 * ── AND THE ONE CORRECTION ────────────────────────────────────────────────
 *
 * It returned `passRate: 0` for a shop that has never inspected anything —
 * which renders as "0% pass", i.e. everything failed, about a shop that has
 * simply not started. Both rates are null now when there is nothing behind
 * them, and `qcd` says how much there is.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Where an order stands with QC, from whichever field recorded it.
 *
 * `qcStatus` first, then the timestamps, then the stage. A job sitting AT the
 * QC stage is `pending`, which is neither a pass nor a fail and must not be
 * counted as either.
 */
function qcStatusOf(order) {
  if (!order) return null;
  if (order.qcStatus) return order.qcStatus;
  if (order.qcPassedAt) return 'pass';
  if (order.qcFailedAt) return 'fail';
  if (order.status === 'qc') return 'pending';
  return null;
}

/**
 * @param {object[]} orders  already filtered to the period being reported
 * @returns {{
 *   qcd, passed, failed, passRate, roots, firstPass, firstPassYield,
 *   defectsByType, rmaCount, rmaCost
 * }}
 */
function qcMetrics(orders) {
  const list = (Array.isArray(orders) ? orders : []).filter(Boolean);
  const qcd = list.filter((o) => {
    const s = qcStatusOf(o);
    return s === 'pass' || s === 'fail';
  });
  const passed = qcd.filter((o) => qcStatusOf(o) === 'pass').length;

  // A reprint chain is ONE job for yield. A job reprinted three times and
  // passing on the fourth is one job that failed first time, not three passes
  // and a fail.
  const roots = new Set(qcd.map((o) => o.reprintChain || o.id));
  const firstPass = list.filter((o) => !o.reprintOf && qcStatusOf(o) === 'pass').length;

  const defectsByType = {};
  for (const order of list) {
    for (const defect of (Array.isArray(order.defects) ? order.defects : [])) {
      const kind = (defect && defect.type) || 'other';
      defectsByType[kind] = (defectsByType[kind] || 0) + 1;
    }
  }

  const rma = list.filter((o) => o.rma);
  // What the shop ate putting a warranty job right — the cost of the
  // replacement, not what the customer was charged, which was nothing.
  const rmaCost = list.filter((o) => o.reprintReason === 'rma')
    .reduce((s, o) => s + num(o.costBasis), 0);

  return {
    qcd: qcd.length,
    passed,
    failed: qcd.length - passed,
    // NULL, not nought. Nought renders as "everything failed" about a shop
    // that has simply never inspected anything.
    passRate: qcd.length ? passed / qcd.length : null,
    roots: roots.size,
    firstPass,
    firstPassYield: roots.size ? firstPass / roots.size : null,
    defectsByType,
    /// The commonest defect, which is the actionable half — a shop can go and
    /// do something about "layer shift" and nothing about a percentage.
    worstDefect: Object.entries(defectsByType)
      .sort((a, b) => b[1] - a[1])
      .map(([type, count]) => ({ type, count }))[0] || null,
    rmaCount: rma.length,
    rmaCost: Math.round(rmaCost * 100) / 100,
  };
}

const api = { qcMetrics, qcStatusOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytQcMetrics = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
