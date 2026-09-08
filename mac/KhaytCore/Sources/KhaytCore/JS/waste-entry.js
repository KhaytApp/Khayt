'use strict';
/**
 * A failed print, written down by hand.
 *
 * The waste log has two writers: a QC failure (`lib/qc-failure.js`, shared)
 * and this — the form a shop fills in when a print failed outside inspection.
 * This was renderer/waste.js's save handler, built inline from nine controls,
 * so only the Electron window could log one.
 *
 * ONE DELIBERATE FIX. The form deducted the wasted grams from the first spool
 * of that material and wrote NO `spoolId` on the entry — while the delete
 * path restores the grams by `entry.spoolId`. So a manually logged failure
 * took filament off the shelf that deleting the entry could never put back.
 * The entry now records which spool it came off. The renderer's delete path
 * needed no change: it was already reading the field nothing wrote.
 *
 * PURE: no DOM, no clock. `ctx.inventory` IS MUTATED when the entry deducts,
 * the way the shelf rules mutate — the caller saves the collection it passed.
 */
(function (global) {

  const FAILURE_TYPES = ['bed_adhesion', 'nozzle_jam', 'warping', 'stringing', 'operator_error',
                         'design_issue', 'power_failure', 'material_quality', 'other'];

  const num = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };
  const trim = (v) => String(v == null ? '' : v).trim();

  /**
   * What wasted grams of a material cost, from the first spool of it on the
   * shelf. Nothing when the material is not on the shelf or the spool has no
   * cost or no weight recorded — a cost invented from a spool that does not
   * exist is worse than none.
   *
   * ── DIVIDE BY WHAT THE ROLL WEIGHED, NOT BY WHAT IS LEFT ──────────────────
   *
   * `weight` FALLS as the shop prints. Dividing a roll's price by it makes the
   * plastic more expensive every time somebody uses some: a 500 g roll of PA-CF
   * bought at 240 costs 0.48 a gram, and this read 2.00 with 120 g left on it —
   * so 180 g of it was costed at 360.00 instead of 86.40, four times over, and
   * without bound as the roll empties. `spoolWeight` is what it weighed when it
   * arrived and is written once, which is exactly why it exists.
   *
   * A roll bought before that field did is the one case with no better answer:
   * what it originally weighed is unrecoverable, so `weight` is all there is.
   *
   * ── AND NET OF RECLAIMABLE TAX ────────────────────────────────────────────
   *
   * A registered shop gets the tax on a purchase back, so the plastic it threw
   * away cost it the price without the tax — the same basis a job is costed at.
   * `reclaims` comes from the caller because only it knows the shop's profile.
   */
  function costOf(material, grams, inventory, reclaims) {
    const g = Math.max(0, num(grams));
    if (!material || g <= 0) return 0;
    const spool = (inventory || []).find((i) => i && i.material === material);
    if (!spool || !(num(spool.cost) > 0)) return 0;
    const bought = num(spool.spoolWeight) > 0 ? num(spool.spoolWeight) : num(spool.weight);
    if (!(bought > 0)) return 0;
    const SE = (typeof global !== 'undefined' && global.KhaytSpoolEdit) || null;
    const price = (SE && typeof SE.netCost === 'function')
      ? SE.netCost(spool, !!reclaims)
      : num(spool.cost);
    return g * (price / bought);
  }

  /**
   * One entry, as the log records it.
   *
   * `input`: `{ date, material, failureType, weight, cost, reason, notes, orderId, machineId, deduct }`
   * `ctx`:   `{ id, today, inventory }`
   * Returns `{ entry }`, or `{ refused: 'material' }` when no material was given.
   */
  function newEntry(input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const material = trim(i.material);
    if (!material) return { refused: 'material' };
    const weight = Math.max(0, num(i.weight));
    const entry = {
      id: c.id,
      date: i.date || c.today,
      material,
      failureType: FAILURE_TYPES.includes(i.failureType) ? i.failureType : 'other',
      weight,
      cost: Math.max(0, num(i.cost)),
      reason: trim(i.reason),
      notes: trim(i.notes),
      orderId: trim(i.orderId) || null,
      machineId: trim(i.machineId) || null,
    };
    if (i.deduct && weight > 0) {
      const spool = (c.inventory || []).find((f) => f && f.material === material);
      if (spool) {
        spool.weight = Math.max(0, num(spool.weight) - weight);
        // So deleting the entry can put the grams back. See the header.
        if (spool.id != null) entry.spoolId = spool.id;
      }
    }
    return { entry };
  }

  /**
   * One entry for a print that failed on a JOB, and the filament it burned.
   *
   * The difference from `newEntry` is where the grams come from: a job's waste
   * comes off the spools that job was printing from, in the proportions its
   * parts were assigned — the same claims a completion would settle — rather
   * than off the first spool of a material. Logging waste against a job used
   * to record it and take nothing at all.
   *
   * `ctx`: `{ id, today, inventory, settings, machines }`. `ctx.inventory` IS
   * MUTATED. Returns `{ entry, deducted }`, or `{ refused: 'material' }`.
   */
  function forOrder(order, input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const material = trim(i.material);
    if (!material) return { refused: 'material' };
    const weight = Math.max(0, num(i.weight));
    const entry = {
      id: c.id,
      date: i.date || c.today,
      orderId: (order && order.id) || null,
      material,
      weight,
      failureType: FAILURE_TYPES.includes(i.failureType) ? i.failureType : 'other',
      notes: trim(i.notes),
      cost: Math.round(costOf(material, weight, c.inventory, c.reclaimsTax) * 100) / 100,
    };
    const D = deduction();
    const taken = (D && weight > 0 && order)
      ? D.deductActual(order, weight, {
          settings: c.settings, inventory: c.inventory, machines: c.machines, today: entry.date,
        })
      : { deducted: 0, spools: [], drawn: [] };
    if (taken.drawn.length) entry.drawn = taken.drawn.slice();
    if (taken.spools.length === 1) entry.spoolId = taken.spools[0];
    return { entry, deducted: taken.deducted };
  }

  /**
   * Take an entry out of the log, and put back exactly what it took.
   *
   * `drawn` says which spool and how much off each — a failure can spill onto
   * a sibling when the assigned spool runs out, and a row that remembers only
   * "which spool" restores the wrong amounts. `spoolId` + `weight` is the older
   * shape and is still honoured, for every entry written before `drawn`.
   *
   * `wasteLog` and `ctx.inventory` are mutated. Returns the entry removed, or
   * null when the id is not in the log.
   */
  function removeEntry(wasteLog, id, ctx) {
    const log = wasteLog || [];
    const idx = log.findIndex((w) => w && w.id === id);
    if (idx < 0) return null;
    const entry = log[idx];
    log.splice(idx, 1);
    const inventory = ((ctx || {}).inventory) || [];
    if (Array.isArray(entry.drawn) && entry.drawn.length) {
      const D = deduction();
      if (D) D.restoreDrawn(entry.drawn, { inventory });
      return entry;
    }
    if (entry.spoolId && num(entry.weight) > 0) {
      const spool = inventory.find((i) => i && i.id === entry.spoolId);
      if (spool) spool.weight = num(spool.weight) + num(entry.weight);
    }
    return entry;
  }

  /** The shelf rules, however this file happens to be loaded. */
  function deduction() {
    if (typeof global.KhaytOrderDeduction !== 'undefined') return global.KhaytOrderDeduction;
    try { return require('./order-deduction.js'); } catch (e) { return null; }
  }

  /** What the log comes to: entries, grams, cost, and failures by category. */
  function totals(wasteLog) {
    const byFailureType = {};
    let grams = 0, cost = 0, count = 0;
    for (const w of wasteLog || []) {
      if (!w) continue;
      count++;
      grams += num(w.weight);
      cost += num(w.cost);
      const ft = w.failureType || 'other';
      byFailureType[ft] = (byFailureType[ft] || 0) + 1;
    }
    return { count, grams, cost, byFailureType };
  }

  const api = { FAILURE_TYPES, costOf, newEntry, forOrder, removeEntry, totals };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWasteEntry = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
