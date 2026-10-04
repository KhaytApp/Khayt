/**
 * What one part of a job costs to make.
 *
 * Material, machine wear, electricity, labour, the failure allowance and any
 * extra materials — the figure every price in the app is built on top of.
 *
 * IN lib/, NOT renderer/, and it always behaved like this. It has taken its
 * inventory and settings through an explicit `ctx` since the LAN server needed
 * it: "there is no renderer global in the main process, and quoting from the
 * phone must run THIS code rather than a second implementation. Two
 * implementations means two prices for one part." The native Mac app is the
 * third caller with no renderer, and lib/ is the directory it can reach.
 *
 * Reads the globals when no ctx is given, so the renderer is unaffected.
 */
(function (global) {
  /**
   * Per-unit cost of a part.
   *
   * `ctx` lets a caller supply the inventory and settings explicitly instead of
   * reading them off the global — the same pattern computeComponentsCost()
   * already uses below, and for the same reason. The renderer calls this with no
   * ctx and is unaffected; the LAN server needs it, because there is no renderer
   * global in the main process and quoting from the phone must run THIS code
   * rather than a second implementation. Two implementations means two prices
   * for one part, which is worse than not quoting on the phone at all.
   */
  /**
   * What the bought-in pieces a part uses cost, per printed unit — magnets,
   * heat-set inserts, screws. `part.consumables` is `[{consumableId, qty,
   * unitCost}]`, `qty` per ONE printed piece (the part's own `qty` multiplies
   * it, exactly as it multiplies the grams).
   *
   * Priced by `consumableUnitCost`: the shelf's CURRENT cost when the item is
   * on the shelf in reach (`ctx.consumables`, or the renderer's global) — a
   * shelf cost of 0 is free, as the shop said — else the `unitCost` the line
   * was written with, so an item since deleted, or a host that hands over only
   * the spools, still costs the magnet at what it cost when the part was made.
   *
   * `qty` is clamped to a finite 0…9999 per piece: a line written by hand or
   * by another app with `1e308` or `-4` must not make every price Infinity or
   * pay the shop for using magnets.
   *
   * A part with no `consumables` costs nothing extra: every part written
   * before this existed is unchanged.
   */
  function partConsumablesCost(part, ctx) {
    const lines = part && Array.isArray(part.consumables) ? part.consumables : [];
    if (!lines.length) return 0;
    const rows = (ctx && Array.isArray(ctx.consumables)) ? ctx.consumables
      : (typeof consumables !== 'undefined' && Array.isArray(consumables) ? consumables : []);
    let total = 0;
    for (const line of lines) {
      if (!line || !line.consumableId) continue;
      total += consumableUnitCost(line, rows) * consumableQty(line.qty);
    }
    return total;
  }

  /** The most of one consumable a single line can ask for. */
  const MAX_CONSUMABLE_QTY = 9999;

  /** A consumable quantity as a finite 0…9999; anything else is 0. */
  function consumableQty(q) {
    const n = +q;
    if (!Number.isFinite(n) || n <= 0) return 0;
    return Math.min(n, MAX_CONSUMABLE_QTY);
  }

  /**
   * What one of a consumable costs — ONE rule for a part's own consumables
   * and for a product's components, so the two cannot price the same magnet
   * differently.
   *
   *   - the shelf row exists: its `cost`, INCLUDING 0 (the shop said free);
   *   - the row is gone (deleted, or a host with no shelf in reach): the
   *     `unitCost` written on the line when it was made, else 0.
   *
   * A cost that is not a finite, non-negative number reads as 0.
   */
  function consumableUnitCost(line, rows) {
    const id = line && line.consumableId;
    const row = id ? (Array.isArray(rows) ? rows : []).find((c) => c && c.id === id) : null;
    const raw = row ? +row.cost : +(line && line.unitCost);
    return Number.isFinite(raw) && raw > 0 ? raw : 0;
  }

  function computePartBaseCost(part, ctx) {
    const inventory = (ctx && ctx.inventory) || global.inventory || [];
    const settings = (ctx && ctx.settings) || global.settings || {};

    const spoolCost = Math.max(0, +part.spoolCost || 0);
    const spoolWeight = Math.max(1, +part.spoolWeight || 1);
    const printWeight = Math.max(0, +part.printWeight || 0);
    const isResin = (() => {
      // A blended multicolour part carries a pre-summed spoolCost/spoolWeight
      // (both in grams), so its material cost is the FDM ratio by construction —
      // never the resin per-kg branch, even if its fallback filamentId is resin.
      if (part.colours && part.colours.length) return false;
      if (part.filamentId) {
        const invItem = inventory.find((i) => i.id === part.filamentId);
        if (invItem) return invItem.materialType === 'resin';
      }
      return false;
    })();
    const supportWeight = Math.max(0, +part.supportWeight || 0);
    const materialCost = isResin
      ? (spoolCost / 1000) * (printWeight + supportWeight)
      : (spoolCost / spoolWeight) * (printWeight + supportWeight);

    const printTime = Math.max(0, +part.printTime || 0);
    const wearCost = printTime * Math.max(0, +part.wearRate || 0);

    const powerDraw = Math.max(0, +part.powerDraw || 0);
    const elecRate = Math.max(0, +part.elecRate || 0);
    const powerCost = printTime * (powerDraw / 1000) * elecRate;

    const prepTime = Math.max(0, +part.prepTime || 0);
    const postTime = Math.max(0, +part.postTime || 0);
    const laborRate = Math.max(0, +part.laborRate || 0);
    const laborCost = (prepTime + postTime) * laborRate;

    const failureRate = Math.max(0, +part.failureRate || 0);
    let extraMatCost = 0;
    for (const em of part.extraMaterials || []) {
      if (!em.material || !em.weight) continue;
      const invItem = inventory.find((i) => i.material === em.material);
      if (invItem && invItem.cost > 0 && invItem.weight > 0) {
        const pricePerKg = (invItem.cost / invItem.weight) * 1000;
        extraMatCost += (em.weight / 1000) * pricePerKg;
      }
    }
    const packagingCost =
      Math.max(0, +settings.defaultPackagingCost || 0) / Math.max(1, +part.qty || 1);
    const consumablesCost = partConsumablesCost(part, ctx);
    const baseCost = materialCost + wearCost + powerCost + laborCost + extraMatCost + packagingCost
      + consumablesCost;
    return baseCost + baseCost * (failureRate / 100);
  }

  function getActivePriceTier(part) {
    if (!part.priceTiers || part.priceTiers.length === 0 || !part.qty) return null;
    const sorted = [...part.priceTiers].sort((a, b) => a.minQty - b.minQty);
    return [...sorted].reverse().find((ti) => +part.qty >= +ti.minQty) || null;
  }

  function computePartBreakdown(part, ctx) {
    const inventory = (ctx && ctx.inventory) || global.inventory || [];
    const settings = (ctx && ctx.settings) || global.settings || {};
    const spoolCost = Math.max(0, +part.spoolCost || 0);
    const spoolWeight = Math.max(1, +part.spoolWeight || 1);
    const printWeight = Math.max(0, +part.printWeight || 0);
    const isResin = (part.colours && part.colours.length)
      ? false
      : (part.filamentId
        ? inventory.find((i) => i.id === part.filamentId)?.materialType === 'resin'
        : false);
    const supportWt = Math.max(0, +part.supportWeight || 0);
    let material = isResin
      ? (spoolCost / 1000) * (printWeight + supportWt)
      : (spoolCost / spoolWeight) * (printWeight + supportWt);
    const printTime = Math.max(0, +part.printTime || 0);
    const machine =
      printTime * Math.max(0, +part.wearRate || 0) +
      printTime * (Math.max(0, +part.powerDraw || 0) / 1000) * Math.max(0, +part.elecRate || 0);
    const prepTime = Math.max(0, +part.prepTime || 0);
    const postTime = Math.max(0, +part.postTime || 0);
    const labor = (prepTime + postTime) * Math.max(0, +part.laborRate || 0);
    // Mirror computePartBaseCost so the live preview equals the committed cart cost:
    // include extra materials + packaging, and apply the failure buffer on the SAME base.
    let extraMatCost = 0;
    for (const em of part.extraMaterials || []) {
      if (!em.material || !em.weight) continue;
      const invItem = inventory.find((i) => i.material === em.material);
      if (invItem && invItem.cost > 0 && invItem.weight > 0) {
        const pricePerKg = (invItem.cost / invItem.weight) * 1000;
        extraMatCost += (em.weight / 1000) * pricePerKg;
      }
    }
    const packagingCost =
      Math.max(0, +settings.defaultPackagingCost || 0) / Math.max(1, +part.qty || 1);
    // Fold extra materials, packaging and the part's consumables into the
    // material bucket (no separate chip);
    // this keeps the {material, machine, labor, buffer} sum == committed base cost.
    material += extraMatCost + packagingCost + partConsumablesCost(part, ctx);
    const base = material + machine + labor;
    const buffer = base * (Math.max(0, +part.failureRate || 0) / 100);
    return { material, machine, labor, buffer };
  }

  // BOM: cost of the non-printed components of an assembly — Σ (consumable.cost × qtyPerUnit).
  // Pass the consumables collection explicitly so this is pure/testable; falls back to the
  // global `consumables` at call time when omitted (renderer usage). A deleted consumable
  // costs the `unitCost` written on the component, else 0 — see consumableUnitCost. Does NOT multiply by assemblyQty — the per-unit component cost folds into
  // the assembly's unit price, exactly like printed-part cost.
  function computeComponentsCost(components, cons) {
    const list = Array.isArray(components) ? components : [];
    const rows = cons || (typeof consumables !== 'undefined' ? consumables : []);
    let total = 0;
    for (const comp of list) {
      if (!comp || !comp.consumableId) continue;
      // The same rule as a part's own consumables (`consumableUnitCost`): the
      // shelf's cost while the row exists, else the cost written on the line.
      total += consumableUnitCost(comp, rows) * consumableQty(comp.qtyPerUnit);
    }
    return +total.toFixed(4);
  }

  /**
   * What one LINE of the cart actually costs — the per-unit cost times how many units.
   *
   * computePartBaseCost() is per-UNIT by construction: packaging is divided by qty, and
   * printWeight is a single unit's weight (partGramsConsumed multiplies by qty when
   * deducting stock). Summing it across an order and comparing that to the order's
   * revenue therefore understates cost by a factor of qty on every multi-unit line.
   *
   * Mirrors partGramsConsumed() in inventory.js — same shape, same reason.
   */
  function partTotalCost(part, ctx) {
    const qty = Math.max(1, +(part && part.qty) || 1);
    return computePartBaseCost(part, ctx) * qty;
  }

  const api = { computePartBaseCost, partTotalCost, getActivePriceTier, computePartBreakdown, computeComponentsCost, partConsumablesCost, consumableUnitCost, consumableQty };

  Object.assign(global, api);
  global.KhaytCalculatorCost = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
