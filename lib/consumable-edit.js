'use strict';
/**
 * A consumable, as the other shelf records it — and what changing one means.
 *
 * Glue, IPA, mailing bags, brass nozzles, gloves. Both halves of this were
 * inline in `renderer/inventory.js`'s `openConsumableEditor`, built out of a
 * modal's form controls, which is why only the Electron window could add a
 * consumable or correct one.
 *
 * That is not a cosmetic gap. The Mac app draws `ConsumablesCard` — "what is
 * about to run out that is not filament" — from `lib/consumable-reorder.js`,
 * and that card reads an empty shelf on the shop this was written for, because
 * the Mac is the app they use and the Mac could not put anything ON the shelf.
 * A screen that can only ever say nothing is worse than no screen: it reads as
 * "nothing is running out".
 *
 * PURE: no DOM, no clock, no storage. `ctx.id` is the caller's.
 *
 * ── WHY THE UNIT IS FREE TEXT HERE AND A VOCABULARY ON A SPOOL ─────────────
 *
 * `lib/spool-edit.js` puts a spool's unit through `KhaytInventoryUnits.unitOf`,
 * because a spool's unit DECIDES ARITHMETIC: every rate in the app reads a
 * spool as grams, so a unit nobody knows reads back as grams for ever and the
 * shop's answer is silently lost.
 *
 * A consumable's unit decides nothing. `consumable-reorder.js` trims it and
 * prints it beside the item's own number — "~2 roll", "~500 each" — and never
 * converts with it. Forcing it through a closed list would refuse "roll",
 * "sheet" and "bottle", which is most of what is actually on that shelf, and
 * would buy nothing at all in return.
 */
(function (global) {

  const num = (v, fallback) => { const n = parseFloat(v); return Number.isFinite(n) ? n : fallback; };
  /** Counts, prices and thresholds are never negative. A negative shelf is not a shelf. */
  const clampPositive = (v) => Math.max(0, num(v, 0));
  const trim = (v) => String(v == null ? '' : v).trim();
  /** The editor's rule: a blank optional field is ABSENT, not empty. */
  const orAbsent = (v) => trim(v) || undefined;

  /**
   * The fields this rule owns.
   *
   * A consumable record carries more than this — `id`, and whatever the
   * deduction paths stamp on it — so both entry points write the fields they
   * are handed and leave the rest of the record alone. A caller sending a key
   * that is not here has it ignored, which is the same bargain every other
   * `*-edit` rule in this directory makes, and the reason to read this list
   * before adding a field to a form.
   */
  const FIELDS = ['name', 'stock', 'unit', 'cost', 'minStock', 'usagePerHour',
                  'category', 'isPackaging'];

  /**
   * A new consumable.
   *
   * `input`: any of FIELDS. `ctx`: `{ id }`.
   * Returns `{ consumable }`, or `{ refused: 'name' }` — the one thing this
   * refuses, because an unnamed consumable cannot be found on the shelf, cannot
   * be picked on a purchase order, and reads as a blank row that looks like a
   * fault.
   *
   * Everything else has a defensible zero. Note that a consumable created with
   * no stock is immediately LOW by `consumable-reorder.isLow` — `stock <= 0` is
   * low whatever the threshold — which is correct: writing down a thing you
   * have run out of is exactly when a shop adds one.
   */
  function newConsumable(input, ctx) {
    const i = input || {};
    const name = trim(i.name);
    if (!name) return { refused: 'name' };
    const consumable = {
      id: (ctx && ctx.id) || undefined,
      name,
      stock: clampPositive(i.stock),
      unit: trim(i.unit),
      cost: clampPositive(i.cost),
      minStock: clampPositive(i.minStock),
      usagePerHour: clampPositive(i.usagePerHour),
      isPackaging: !!i.isPackaging,
    };
    const category = orAbsent(i.category);
    if (category) consumable.category = category;
    return { consumable };
  }

  /**
   * Change an existing one, in place, touching only the fields it is handed.
   *
   * Absent leaves alone: a caller correcting a count must not blank the
   * category, and a caller renaming one must not reset the stock to zero.
   */
  function applyEdit(consumable, input) {
    const i = input || {};
    const has = (key) => Object.prototype.hasOwnProperty.call(i, key) && i[key] !== undefined;

    if (has('name')) {
      const name = trim(i.name);
      if (!name) return { refused: 'name' };
      consumable.name = name;
    }
    if (has('stock')) consumable.stock = clampPositive(i.stock);
    if (has('unit')) consumable.unit = trim(i.unit);
    if (has('cost')) consumable.cost = clampPositive(i.cost);
    if (has('minStock')) consumable.minStock = clampPositive(i.minStock);
    /* 0 is not "unset" — it is the shop switching hourly deduction OFF, which
     * is what the form's own placeholder has always said. So it is stored as 0
     * rather than dropped, or the next read cannot tell "never configured"
     * from "deliberately stopped". */
    if (has('usagePerHour')) consumable.usagePerHour = clampPositive(i.usagePerHour);
    if (has('isPackaging')) consumable.isPackaging = !!i.isPackaging;
    /* Clearing a category is a real edit — the item goes back to Uncategorised,
     * which `consumable-categories.js` treats as a category of its own. Written
     * as ABSENT rather than '' so the two spellings of "no category" that the
     * grouping already folds together never both appear on one shelf. */
    if (has('category')) consumable.category = orAbsent(i.category);

    return { consumable };
  }

  const api = { newConsumable, applyEdit, FIELDS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytConsumableEdit = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
