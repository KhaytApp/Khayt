'use strict';
(function (global) {

/**
 * What an inventory item is measured in.
 *
 * ── KHAYT'S ARITHMETIC WAS NEVER ABOUT GRAMS ──────────────────────────────
 *
 * It looked like it was. `partGramsConsumed`, `gramsPerDay`, `committedByItem`,
 * `costPerKilo`, `DEFAULT_LOW_STOCK = 200` — the word is everywhere. But every
 * one of those does the same arithmetic to a QUANTITY and only the labels, the
 * thresholds and the rate denominator ever knew what the quantity was. Take a
 * spool's cost and divide by what it held; the sum is identical whether it held
 * a thousand grams or a thousand millilitres.
 *
 * So this module does not teach the rules a second unit. It names the unit an
 * item is counted in, and answers the three questions that genuinely differ:
 *
 *   1. What is a price quoted PER? A kilo of filament, a litre of resin, one
 *      sheet of ply. `costPerKilo` was the only place the assumption was load
 *      bearing, and on a bottle of resin it answered in the wrong denominator.
 *   2. When is it LOW? 200 is a sensible last spool of filament and absurd for
 *      sheet goods, where two left is the moment to order.
 *   3. What does a screen WRITE after the number?
 *
 * ── ABSENT IS GRAMS, AND THAT IS NOT A DEFAULT ────────────────────────────
 *
 * The same rule as `machine-kinds`, for the same reason: every item in every
 * book that exists is filament measured in grams, because until now nothing
 * else could be recorded. A unit this build does not know also reads as grams,
 * so a newer Khayt cannot make a shelf row vanish from an older one.
 */

/**
 * A number, or null — and ABSENT IS NULL, not zero.
 *
 * `+null` is 0 and `Number.isFinite(0)` is true, so the one-liner everyone
 * writes treats a missing figure as a real zero. Written twice in this repo in
 * one day and wrong both times: in `machine-band` it made an unpollable printer
 * look like a print with zero seconds left.
 */
function num(x) {
  if (x === null || x === undefined || x === '') return null;
  const n = +x;
  return Number.isFinite(n) ? n : null;
}

/** The units, in the order a picker should offer them. */
const UNITS = ['g', 'ml', 'sheet'];

const SPEC = {
  g: {
    measure: 'mass',
    // A price is quoted per KILO, which is a thousand of these. This is the one
    // place the gram assumption was load bearing rather than cosmetic.
    per: 1000, rate: 'kg',
    // The figure Khayt has always used. Unchanged, deliberately: every existing
    // item is in grams and none of them may move.
    low: 200,
    // Whole grams. A shop weighs a spool to the gram and no finer.
    decimals: 0,
  },
  ml: {
    measure: 'volume',
    per: 1000, rate: 'L',
    // A 500 ml bottle is a common size and a resin printer can drink 150 ml in
    // one plate, so this is roughly "one more print in it".
    low: 150,
    decimals: 0,
  },
  sheet: {
    measure: 'count',
    // Quoted per sheet, so the rate denominator is one of them.
    per: 1, rate: 'sheet',
    // Two, because sheet goods are bought by the pack and a shop that waits
    // until the last one is a shop that stops.
    low: 2,
    // Half a sheet is a real thing to have left.
    decimals: 1,
  },
};

/**
 * The unit this item is counted in.
 *
 * Absent, blank, or a word this build does not know all read as grams — see the
 * header. The unknown case matters: it means a newer Khayt wrote a unit this
 * one has not learned, and reading that row as grams is wrong but survivable,
 * while dropping it from the shelf is not.
 */
function unitOf(item) {
  const said = String((item && item.unit) || '').trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(SPEC, said) ? said : 'g';
}

/** Everything known about a unit. Always an object; never null. */
function spec(unit) {
  const u = Object.prototype.hasOwnProperty.call(SPEC, String(unit)) ? String(unit) : 'g';
  return SPEC[u];
}

/**
 * What a price is quoted per, and how many of the counting unit that is.
 * `{ per: 1000, rate: 'kg' }` for grams; `{ per: 1, rate: 'sheet' }` for sheets.
 */
function rateUnit(unit) {
  const s = spec(unit);
  return { per: s.per, rate: s.rate };
}

/**
 * What one `rate` unit of this item cost — a kilo of it, a litre of it, one
 * sheet of it — from what the WHOLE item cost and what it held when it arrived.
 *
 * Never from what is LEFT. Dividing a price by the remainder made the figure a
 * shop compares suppliers on climb as the item emptied: 75 became 150 half way
 * down and 2,000 near the end, worst on exactly the item about to be reordered.
 * That is why the original was deleted rather than fixed, and why this needs
 * `originalQty` and answers null without it.
 */
function costPerRateUnit(cost, originalQty, unit) {
  // `+null` IS 0 AND `Number.isFinite(0)` IS TRUE, so the obvious guard lets
  // an absent cost through as free and an absent quantity through as a divide
  // by zero. Absent has to be tested for before it is coerced.
  const c = num(cost), q = num(originalQty);
  if (c === null || q === null || q <= 0) return null;
  const s = spec(unit);
  return { value: c / (q / s.per), rate: s.rate };
}

/**
 * When is an item low?
 *
 * Its own reorder point first, then the shop's threshold, then this unit's
 * default. The shop's single `lowStockThreshold` setting is a GRAM figure — it
 * has only ever been asked about filament — so it is honoured for grams and
 * ignored for anything else, where it would be a number about a different
 * quantity entirely. A shop that sets 500 g means five hundred grams, not five
 * hundred sheets.
 */
function lowThreshold(item, settings) {
  const own = num(item && item.reorderPoint);
  if (own !== null) return own;
  const unit = unitOf(item);
  const shopWide = num(settings && settings.lowStockThreshold);
  if (unit === 'g' && shopWide !== null) return shopWide;
  return spec(unit).low;
}

/**
 * The locale keys a screen needs, so nothing assembles a key name by hand.
 *
 * TWO KEYS, not one reused. The word after a quantity and the word after a
 * slash are not the same word: six of them are "6 sheets" and their price is
 * "24.00 / sheet". Reusing the first put "24.00 ﷼ / sheets" on the shelf. It
 * happens to be invisible for `kg` and `L`, which are the same either way, and
 * that is exactly why it survived being looked at.
 */
function keysFor(unit) {
  const u = unitOf({ unit });
  return { unit: 'unit.' + u, rate: 'unit.per_' + spec(u).rate };
}

const api = { UNITS, unitOf, spec, rateUnit, costPerRateUnit, lowThreshold, keysFor };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytInventoryUnits = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
