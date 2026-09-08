'use strict';

/**
 * A job that failed inspection.
 *
 * Three records, and each one is read by something different:
 *
 *   the ORDER      `qcStatus: 'fail'`, `qcFailedAt`, `qcAt`, the inspector.
 *                  `qcStatusOf` reads these, `computeQcMetrics` counts them,
 *                  and a failure that writes none of them is not counted as a
 *                  failure — it is not counted at all, so the pass rate is
 *                  computed over a shrinking subset of the shop's work.
 *   a DEFECT       what went wrong, how badly, and the note. The analytics
 *                  screen's defects-by-type table is built from these.
 *   a WASTE row    the filament the failed print consumed and what it cost.
 *                  The waste screen labels and filters by `failureType`, so
 *                  inventing a category puts a value there it cannot name.
 *
 * All three were written in two places — `renderer/order-flows.js` and
 * `renderer/bedready-queue.js` — and they had drifted. Bed Ready's defect
 * carried no `severity` and no `photoRef`, and it never set the inspector: a
 * failure recorded there answered "how bad was it" with `undefined`, for ever.
 *
 * PURE: no globals, no clock. The cost of the wasted filament is derived from
 * the spool it came off, which is why `ctx.inventory` is here — the same list
 * `lib/order-deduction.js` draws from.
 */
(function (global) {

  /**
   * The failure categories, from `renderer/waste.js`'s own labels.
   *
   * A category this list does not contain reaches the waste screen as a value
   * it cannot name, so the list IS the contract rather than a suggestion.
   */
  const FAILURE_TYPES = [
    'bed_adhesion', 'nozzle_jam', 'warping', 'stringing', 'operator_error',
    'design_issue', 'power_failure', 'material_quality', 'other',
  ];

  /** How badly. `major` is the default, because an unclassified failure that
   *  reads as minor is one nobody goes back to look at. */
  const SEVERITIES = ['major', 'minor'];

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});
  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const numberOf = (v) => {
    const n = +v;
    return Number.isFinite(n) ? n : 0;
  };

  /**
   * What the wasted filament cost, from the spool it came off.
   *
   * Nothing when no weight was recorded and nothing when the material is not on
   * the shelf: a cost invented from a spool that does not exist is worse than
   * an honest zero, which at least reads as "not measured".
   *
   * ── ONE RULE, NOT TWO ─────────────────────────────────────────────────────
   *
   * This used to divide the roll's price by `spool.weight` — what is LEFT, not
   * what was bought — so the plastic grew dearer every time somebody used some.
   * `lib/waste-entry.js` had exactly the same line and exactly the same defect,
   * and fixing one would have left the other: a QC failure and a waste entry
   * for the same 180 g off the same roll would then have cost different
   * amounts. It delegates now, so there is one answer.
   */
  function wasteCost(materialName, grams, inventory, reclaims) {
    const W = (typeof global !== 'undefined' && global.KhaytWasteEntry) || null;
    if (W && typeof W.costOf === 'function') {
      return W.costOf(materialName, grams, inventory, reclaims);
    }
    // Standalone fallback, kept correct rather than kept as it was.
    const g = Math.max(0, numberOf(grams));
    if (!materialName || g <= 0) return 0;
    const spool = arrayOf(inventory).find(i => i && i.material === materialName);
    if (!spool || numberOf(spool.cost) <= 0) return 0;
    const bought = numberOf(spool.spoolWeight) > 0
      ? numberOf(spool.spoolWeight) : numberOf(spool.weight);
    if (bought <= 0) return 0;
    return (numberOf(spool.cost) / bought) * g;
  }

  /**
   * Record a QC failure against a job.
   *
   * `failure`: `{ failureType, severity, reason, weight, inspector, photoRef }`.
   * `ctx`: `{ now, inventory, wasteLog, wasteId, defaultReason, settings,
   *           machines, today }`.
   *
   * The waste row is unshifted onto `ctx.wasteLog` when one is supplied — newest
   * first, the way the waste screen reads it. The order is mutated in place.
   *
   * A FAILED PRINT TAKES ITS FILAMENT OFF THE SHELF.
   *
   * It did not use to. The waste row recorded the grams and their cost and the
   * inventory was left alone — "unchanged accounting" — while the reprint later
   * deducted only its own. So the filament a failed attempt really burned
   * through never left the shelf, and a shop's stock read high by the grams of
   * every failure it had ever had.
   *
   * The grams come off the SAME spools a completion would have used, in the
   * same proportions, because that is what the printer was printing from. The
   * job is NOT marked `materialDeducted` — it is not done, and the reprint must
   * still deduct its own.
   *
   * `deducted` in the result says what actually came off, and `spools` which
   * ones, so a host that lets a shop undo the failure can put it back.
   */
  function record(order, failure, ctx) {
    const f = failure || {};
    const c = ctxOf(ctx);
    const nowIso = new Date(typeof c.now === 'number' ? c.now : Date.now()).toISOString();
    const failureType = FAILURE_TYPES.indexOf(f.failureType) === -1 ? 'other' : f.failureType;
    const severity = SEVERITIES.indexOf(f.severity) === -1 ? 'major' : f.severity;
    const reason = f.reason || '';
    const weight = Math.max(0, numberOf(f.weight));

    const waste = {
      id: c.wasteId || null,
      date: nowIso.split('T')[0],
      material: order.material || '',
      machineId: order.machineId || null,
      weight: weight || 0,
      cost: wasteCost(order.material, weight, c.inventory, c.reclaimsTax),
      reason: reason || c.defaultReason || '',
      orderId: order.id,
      failureType,
    };
    const log = c.wasteLog;
    if (Array.isArray(log)) log.unshift(waste);

    // The grams the failed attempt burned through, off the spools it was
    // printing from. `weight` is what the printer measured where a printer
    // measured it, and what the shop typed where it did not.
    const D = deduction();
    const taken = (D && weight > 0)
      ? D.deductActual(order, weight, {
          settings: c.settings, inventory: c.inventory, machines: c.machines,
          today: waste.date,
        })
      : { deducted: 0, spools: [], drawn: [], nowLow: [] };
    // WHAT CAME OFF EACH SPOOL, so a host that undoes the failure can put the
    // right grams back on each. `spoolId` is kept alongside for the single-spool
    // case, which is what the waste screen's own delete has always read.
    if (taken.drawn.length) waste.drawn = taken.drawn.slice();
    if (taken.spools.length === 1) waste.spoolId = taken.spools[0];

    order.qcStatus = 'fail';
    order.qcFailedAt = nowIso;
    order.qcAt = nowIso;
    // The inspector who found it, or the one already on the job. Never blanked
    // by a caller that does not keep a roster.
    order.inspector = f.inspector || order.inspector || null;

    if (!Array.isArray(order.defects)) order.defects = [];
    order.defects.push({
      type: failureType,
      severity,
      note: reason,
      photoRef: f.photoRef || null,
      at: nowIso,
    });

    return {
      waste,
      deducted: taken.deducted,
      spools: taken.spools,
      nowLow: taken.nowLow,
      effects: [
        { type: 'save' },
        { type: 'render_waste' },
        { type: 'render_inventory' },
      ],
    };
  }

  /** The shelf rules, however this file happens to be loaded. */
  function deduction() {
    if (typeof global.KhaytOrderDeduction !== 'undefined') return global.KhaytOrderDeduction;
    try { return require('./order-deduction.js'); } catch (e) { return null; }
  }

  const api = { FAILURE_TYPES, SEVERITIES, wasteCost, record };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytQcFailure = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
