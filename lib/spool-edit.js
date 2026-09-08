'use strict';
/**
 * A spool, as the shelf records it — and what changing one means.
 *
 * Both were inline in renderer/inventory.js, built from a row of form controls
 * and from a modal's fields, which is why only the Electron window could add a
 * spool or correct one. A shop's shelf drifts constantly (auto-deduction takes
 * grams off, a spool runs out early, a price changes between orders), so a Mac
 * app that could show the shelf and not correct it was a Mac app a shop still
 * had to leave.
 *
 * PURE: no DOM, no clock. `ctx.id` and `ctx.today` are the caller's.
 *
 * `ctx.settings` IS MUTATED by `applyEdit` when a colour variant is named: the
 * shop's colour library is a setting, and the editor has always added to it.
 * The caller must write the settings with the spool, or the next editor offers
 * a colour list that has forgotten what was just typed.
 */
(function (global) {

  const num = (v, fallback) => { const n = parseFloat(v); return Number.isFinite(n) ? n : fallback; };
  const clampPositive = (v) => Math.max(0, num(v, 0));
  const trim = (v) => String(v == null ? '' : v).trim();
  /** The editor's rule: a blank optional field is ABSENT, not empty. */
  const orAbsent = (v) => trim(v) || undefined;

  /**
   * A new spool.
   *
   * `input`: `{ material, cost, weight, color, materialType, lot, locationId }`
   * `ctx`:   `{ id, today, activeLocation }`
   * Returns `{ spool }`, or `{ refused: 'material' }` — the one thing the form
   * refuses, because a spool with no material cannot be matched to a job.
   */
  function newSpool(input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const material = trim(i.material);
    if (!material) return { refused: 'material' };
    return {
      spool: {
        id: c.id,
        material,
        cost: clampPositive(i.cost),
        // THE TAX INSIDE THAT PRICE, when the shop can reclaim it.
        //
        // Same shape as an expense's: an amount off the supplier's invoice, not
        // a rate. What a spool COST the shop is `cost` and stays `cost` — that
        // is what left the bank. What a job is COSTED at is the price without
        // the tax, because a registered shop gets the tax back and charging it
        // to a print would understate every margin it ever quotes.
        //
        // Absent is zero, which is what every spool bought before this carries,
        // and it changes nothing about any of them. `netCost` below is the one
        // place that decides.
        vatAmount: Math.min(clampPositive(i.cost), clampPositive(i.vatAmount)),
        // A kilo is the default, and the floor is one gram: a spool weighing
        // nothing divides into every cost-per-gram in the app.
        weight: Math.max(1, num(i.weight, 1000)),
        // WHAT IT WEIGHED WHEN IT ARRIVED, written once and never touched
        // again. `weight` is what is LEFT and falls as the shop prints, so
        // anything that divides the spool's price by it drifts: a 1 kg roll
        // bought at 75 reads 150 once half gone, and 2,000 on one nearly
        // empty. That is the figure a shop compares two suppliers with, and it
        // was wrong on exactly the spools it most wanted to reorder.
        //
        // Only for spools bought from now on. Neither book records this for
        // one already on the shelf, and it cannot be recovered — a shop that
        // has used half a roll no longer has any record of the other half.
        spoolWeight: Math.max(1, num(i.weight, 1000)),
        color: i.color || '#888888',
        purchasedAt: c.today,
        materialType: i.materialType || 'fdm',
        lot: orAbsent(i.lot),
        // The branch chosen, or the one being looked at.
        locationId: (trim(i.locationId) || c.activeLocation || '') || undefined,
      },
    };
  }

  /**
   * Correct a spool. MUTATES it, the way every shelf rule here mutates.
   *
   * `input` carries only the fields the screen showed; anything absent is left
   * alone, which is what lets a smaller editor exist without wiping the fields
   * it does not display.
   *
   * A COST CHANGE IS REMEMBERED. The old price is pushed onto `priceHistory`
   * before the new one lands, because "what did this material cost last time"
   * is the question a shop asks when a supplier's invoice looks wrong.
   *
   * Returns `{ colourAdded }` — the colour variant this edit taught the shop's
   * library, if any, so the caller knows the settings changed too.
   */
  function applyEdit(spool, input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const has = (key) => Object.prototype.hasOwnProperty.call(i, key) && i[key] !== undefined;

    if (has('material')) {
      const material = trim(i.material);
      if (!material) return { refused: 'material' };
      spool.material = material;
    }
    /* What this item is COUNTED IN — grams of filament, millilitres of resin,
     * sheets of ply.
     *
     * Refused into the vocabulary here, where the value is written, rather than
     * at each screen that reads it: a unit nobody knows, stored once, reads
     * back as grams for ever and the shop's answer is silently lost.
     *
     * Absent leaves it alone. A caller editing only a price must not turn a
     * bottle of resin into a spool of filament, and every item written before
     * this field existed is in grams by the module's own rule. */
    if (has('unit')) {
      const U = (typeof global !== 'undefined') && global.KhaytInventoryUnits;
      spool.unit = U ? U.unitOf({ unit: i.unit }) : (trim(i.unit) || 'g');
    }
    if (has('color')) spool.color = i.color || '#888888';
    if (has('materialType')) spool.materialType = i.materialType || 'fdm';

    let colourAdded;
    if (has('colourVariant')) {
      const variant = trim(i.colourVariant);
      spool.colourVariant = variant || undefined;
      if (variant && c.settings) {
        if (!c.settings.filamentColours) c.settings.filamentColours = {};
        const known = c.settings.filamentColours[spool.material]
          || (c.settings.filamentColours[spool.material] = []);
        if (!known.includes(variant)) { known.push(variant); colourAdded = variant; }
      }
    }
    if (has('vatAmount')) {
      spool.vatAmount = Math.min(clampPositive(spool.cost), clampPositive(i.vatAmount));
    }
    if (has('cost')) {
      const cost = clampPositive(i.cost);
      if (cost !== spool.cost) {
        if (!spool.priceHistory) spool.priceHistory = [];
        spool.priceHistory.push({ cost: spool.cost, date: c.today });
      }
      spool.cost = cost;
      // The tax can never exceed the price it sits inside, so lowering the
      // price lowers it with it — but ONLY on a spool that has one. Writing
      // `vatAmount: 0` onto every legacy roll somebody retypes a price on adds
      // a field that record has no use for, and changes rows that did not need
      // to change.
      if (spool.vatAmount != null) {
        spool.vatAmount = Math.min(cost, clampPositive(spool.vatAmount));
      }
    }
    if (has('weight')) spool.weight = Math.max(0, num(i.weight, 0));
    if (has('purchasedAt')) spool.purchasedAt = i.purchasedAt || undefined;
    if (has('openedAt')) spool.openedAt = i.openedAt || undefined;
    if (has('lot')) spool.lot = orAbsent(i.lot);
    if (has('locationId')) spool.locationId = trim(i.locationId) || undefined;
    // Print settings: zero means "not set", not "print at zero degrees".
    if (has('printTemp')) { const v = num(i.printTemp, 0); spool.printTemp = v > 0 ? v : undefined; }
    if (has('bedTemp')) { const v = num(i.bedTemp, 0); spool.bedTemp = v > 0 ? v : undefined; }
    if (has('maxSpeed')) { const v = num(i.maxSpeed, 0); spool.maxSpeed = v > 0 ? v : undefined; }
    if (has('reorderPoint')) { const v = num(i.reorderPoint, 200); spool.reorderPoint = v >= 0 ? v : 200; }
    if (has('reorderQty')) { const v = num(i.reorderQty, 1000); spool.reorderQty = v >= 0 ? v : 1000; }
    return { colourAdded };
  }

  /** The colour variants a shop has named for a material. */
  function coloursFor(settings, material) {
    return ((settings || {}).filamentColours || {})[material] || [];
  }

  /**
   * What a spool costs a job, which is not what it cost the shop.
   *
   * A registered shop reclaims the tax on a purchase, so the tax is not part of
   * what a print consumes. An unregistered one reclaims nothing and every riyal
   * is the cost. A spool that never recorded a tax figure reclaims nothing
   * either — no tax is invented on a receipt nobody described.
   *
   * @param {object} spool
   * @param {boolean} reclaims whether the shop can recover input tax
   */
  function netCost(spool, reclaims) {
    const paid = clampPositive(spool && spool.cost);
    if (!reclaims) return paid;
    return Math.max(0, paid - Math.min(paid, clampPositive(spool && spool.vatAmount)));
  }

  const api = { newSpool, applyEdit, coloursFor, netCost };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSpoolEdit = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
