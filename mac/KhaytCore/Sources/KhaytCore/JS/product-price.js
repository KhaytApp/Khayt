'use strict';
/**
 * The price a shop actually charges, as opposed to the one arithmetic produced.
 *
 * The catalogue works out cost from parts and components, applies the margin and
 * shows the result — and that number was final. It is also a number like 43.71,
 * which no shop puts on a shelf. Reported exactly that way: "it does a good job
 * of calculating price but there should be a way to override the final price,
 * basically I like to round it up or down to multiples of fives."
 *
 * ── THREE LAYERS, AND THE ORDER MATTERS ────────────────────────────────────
 *
 *   cost      what the thing costs to make — parts + components
 *   base      cost + margin. This is the arithmetic, and it stays visible.
 *   final     base rounded to a step, unless the shop typed a price, in which
 *             case the shop's number wins outright.
 *
 * The base is never overwritten. A shop that rounds 43.71 up to 45 should still
 * be able to see the 43.71, because that is the number that tells it whether the
 * margin is working — and a shop that can only see its rounded price cannot tell
 * a healthy margin from a rounding accident.
 *
 * ── WHY ROUNDING IS NOT JUST Math.round(x / 5) * 5 ─────────────────────────
 *
 * Direction is a pricing decision, not a numerical one. Rounding to NEAREST
 * turns 42 into 40 and quietly gives away two units of margin on every sale;
 * rounding UP never does. Both are legitimate — a shop pricing against a
 * competitor wants nearest, a shop protecting a thin margin wants up — so this
 * asks rather than assumes, and defaults to `nearest` only because that is what
 * "round to fives" means in ordinary speech.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /** Rounding directions a shop can choose. */
  const MODES = ['nearest', 'up', 'down'];

  /** Steps offered in the UI. 0 means "do not round". */
  const STEPS = [0, 0.5, 1, 5, 10, 25, 50, 100];

  /** The step a shop gets when it switches rounding on without choosing one. */
  const DEFAULT_STEP = 5;

  /* null, undefined and '' are ABSENT, not zero.
   *
   * Number(null) and Number('') are both 0 and both finite, so the obvious
   * version of this treats "no override" as "this product is free". The editor
   * writes null the moment the box is cleared, so that path is not exotic: it is
   * what happens the first time a shop changes its mind about an override.
   */
  const num = (v) => {
    if (v === null || v === undefined || v === '') return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };

  /**
   * Round a value to a multiple of `step`.
   *
   * Returns the value untouched when there is nothing sensible to do: no step,
   * a negative step, or a value that is not a number. Rounding is a convenience
   * and must never be the reason a price becomes NaN on a product page.
   */
  function roundToStep(value, step, mode) {
    const v = num(value);
    const s = num(step);
    if (v === null) return null;
    if (s === null || s <= 0) return v;
    const m = MODES.includes(mode) ? mode : 'nearest';
    const q = v / s;
    /* Floating point, and why this is not `Math.ceil(q)`.
     *
     * 45 / 5 is 9.000000000000002 for plenty of real prices, so a value already
     * sitting exactly on a multiple rounds UP to the next one — 45 becomes 50,
     * and it does it again on every save. The epsilon says "close enough to a
     * whole multiple to already be one", which is the intent.
     */
    const EPS = 1e-9;
    const nearWhole = Math.abs(q - Math.round(q)) < EPS;
    const raw = nearWhole ? Math.round(q)
      : (m === 'up' ? Math.ceil(q) : m === 'down' ? Math.floor(q) : Math.round(q));
    // Two decimals: money. Without this, 0.5-steps produce 12.100000000000001.
    return Math.round(raw * s * 100) / 100;
  }

  /**
   * The three numbers, from a product's own fields.
   *
   * @param {object} product  { basePrice, priceOverride, priceRound: {step, mode} }
   * @param {number} basePrice  cost + margin, computed by the caller
   * @returns {{base:number, final:number, source:'override'|'rounded'|'base'}}
   */
  function finalPrice(product, basePrice) {
    const p = product || {};
    const base = num(basePrice) ?? 0;

    /* A typed price wins over everything, including rounding.
     *
     * `0` is a real answer — a giveaway, a sample, a part priced inside a
     * bundle — so the test is "is there a number here", not "is it truthy".
     * Treating 0 as absent would silently re-price free items at cost + margin.
     */
    const override = num(p.priceOverride);
    if (override !== null && override >= 0) {
      return { base, final: Math.round(override * 100) / 100, source: 'override' };
    }

    const r = p.priceRound || {};
    const step = num(r.step);
    if (step !== null && step > 0) {
      return { base, final: roundToStep(base, step, r.mode), source: 'rounded' };
    }
    return { base, final: base, source: 'base' };
  }

  /**
   * A short line saying which number a shop is looking at and why.
   *
   * A rounded price that does not say it is rounded looks like the arithmetic
   * produced it, and the shop stops being able to tell the two apart.
   */
  function describe(result, t) {
    const tr = typeof t === 'function' ? t : () => '';
    const r = result || {};
    if (r.source === 'override') return tr('pe.price_is_override') || 'Your own price';
    if (r.source === 'rounded') {
      if (Math.abs((r.final || 0) - (r.base || 0)) < 0.005) return tr('pe.price_is_base') || 'Calculated';
      return tr('pe.price_is_rounded') || 'Rounded from the calculated price';
    }
    return tr('pe.price_is_base') || 'Calculated';
  }

  const api = { MODES, STEPS, DEFAULT_STEP, roundToStep, finalPrice, describe };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytProductPrice = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
