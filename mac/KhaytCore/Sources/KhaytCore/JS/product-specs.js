'use strict';
/**
 * What a catalogue product is made of, for anyone downstream who has to know.
 *
 * A storefront selling printed parts needs three facts Khayt already holds and
 * had never published: how long the thing takes on a machine, what it weighs,
 * and what it is made of. Without them a shop types each one a second time into
 * its storefront's admin — and a hand-typed number that drifts from the shop's
 * own record is worse than no number, because both look authoritative.
 *
 * Asked for by the first real Medusa integration, where all three are
 * load-bearing: print hours decide whether a basket can be given a delivery date
 * at all, and material and weight reach the order queue and the courier.
 *
 * ── PRINT HOURS ARE MACHINE HOURS, AND NOTHING ELSE ────────────────────────
 *
 * A part carries `printTime` and also `prepTime` and `postTime` — preparation
 * and finishing labour. Only `printTime` belongs here.
 *
 * Finishing is already accounted for on the other side of this wire:
 * lib/lead-time.js folds finishing, dispatch and safety into `handlingDays` and
 * publishes that separately. A consumer that adds prep and post into its print
 * hours and then adds handlingDays on top has counted finishing twice, and every
 * date it quotes drifts later — silently, and in the direction that loses work.
 *
 * ── WEIGHT IS WHAT THE SHOP ACTUALLY TAKES OFF THE SPOOL ───────────────────
 *
 * Through partGramsConsumed()'s rule — print plus support, times quantity —
 * because that is what the app deducts from stock when a job completes. A
 * published weight that disagreed with the shop's own deduction would be a
 * second truth about the same gram.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  const num = (v) => {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? n : 0;
  };

  /** Grams a part draws: print + support, times quantity. Mirrors partGramsConsumed. */
  function partGrams(part) {
    const p = part || {};
    return (num(p.printWeight) + num(p.supportWeight)) * (num(p.qty) || 1);
  }

  /** Machine hours for a part: print time only, times quantity. */
  function partHours(part) {
    const p = part || {};
    return num(p.printTime) * (num(p.qty) || 1);
  }

  /**
   * The three facts, or nulls.
   *
   * NULL RATHER THAN ZERO where a product cannot answer. A product with no parts
   * has no print time — it is not a product that prints instantly, and a
   * consumer deciding whether it can quote a date has to be able to tell those
   * apart. Zero would read as an answer.
   */
  function productSpecs(product) {
    const parts = (product && Array.isArray(product.parts)) ? product.parts : [];
    if (!parts.length) return { printHours: null, weightGrams: null, material: '' };

    const hours = parts.reduce((s, p) => s + partHours(p), 0);
    const grams = parts.reduce((s, p) => s + partGrams(p), 0);
    // Distinct, in the order the shop listed them: a multi-part product can mix,
    // and "PETG, TPU" is what someone packing it needs to read.
    const material = [...new Set(parts
      .map((p) => String((p && p.material) || '').trim())
      .filter(Boolean))].join(', ');

    return {
      // Four places: a 12-minute part is 0.2 h and must not round to nothing.
      printHours: hours > 0 ? Math.round(hours * 10000) / 10000 : null,
      weightGrams: grams > 0 ? Math.round(grams * 100) / 100 : null,
      material,
    };
  }

  const api = { productSpecs, partGrams, partHours };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytProductSpecs = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
