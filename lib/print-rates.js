/**
 * The rates a print costs money at, when nobody has said otherwise.
 *
 * Wear, power, labour and the failure allowance are four of the six things
 * `computePartBaseCost` adds up, and a caller that omits them does not get an
 * error — it gets a price with material in it and nothing else. On a real
 * 272g / 14.9h job that is 20.40 where Khayt's own calculator says 109.40.
 *
 * These numbers are not invented here. They are the values
 * `renderer/index.html` has shipped in the calculator's form since the first
 * release, which is what every shop that has never touched those fields is
 * quoted at:
 *
 *     <input id="wearRate"    value="0.75">
 *     <input id="powerDraw"   value="150">
 *     <input id="elecRate"    value="0.18">
 *     <input id="prepTime"    value="0.25">
 *     <input id="postTime"    value="0.5">
 *     <input id="laborRate"   value="90">
 *     <input id="failureRate" value="10">
 *
 * `test/print-rates.test.js` reads those attributes out of the HTML and
 * requires them to match, so the two cannot drift apart quietly — which is the
 * only failure this module can have.
 */
(function (global) {
  'use strict';

  /** Khayt's own opening figures. Hours, watts, and money per hour or kWh. */
  const DEFAULTS = Object.freeze({
    wearRate: 0.75,      // machine wear, per print hour
    powerDraw: 150,      // watts while printing
    elecRate: 0.18,      // per kWh
    prepTime: 0.25,      // hours before the print
    postTime: 0.5,       // hours after it
    laborRate: 90,       // per hour
    failureRate: 10,     // % added to the whole base
  });

  /** lib/depreciation.js, by whichever route this host loads modules. Absent
   *  (a renderer page that does not load it) means no derived rate at all,
   *  which is the old behaviour. */
  const depreciation = () => {
    if (global.KhaytDepreciation) return global.KhaytDepreciation;
    if (typeof require === 'function') {
      try { return require('./depreciation.js'); } catch (e) { return null; }
    }
    return null;
  };

  const numeric = (v) => (v === null || v === undefined || v === '' || !isFinite(+v)) ? null : +v;

  /**
   * The rates for one part, from the shop's own things.
   *
   * Order, and it matters:
   *
   *   1. Khayt's defaults, so nothing is ever silently zero.
   *   2. A saved printer preset, which is the shop writing down its own rates.
   *   3. The MACHINE the job is on, for the two things a machine knows about
   *      itself — its power draw and its wear rate. `applyMachineToCalculator`
   *      in renderer/build.js applies exactly these two, over everything else,
   *      and says why: "a machine carries the printer identity and the one
   *      printer-specific cost input it knows".
   *
   * Anything a caller has typed for this particular part wins over all of it,
   * which is the caller's business rather than this function's.
   *
   * @param {object} [opts]
   * @param {object} [opts.preset]   a row from `printers`
   * @param {object} [opts.machine]  a row from `machines`
   * @param {number} [opts.recentMonthlyHours]  what that machine has printed a
   *   month lately, for a straight-line machine's hourly figure
   */
  function ratesFor(opts) {
    const o = opts || {};
    const out = Object.assign({}, DEFAULTS);

    const preset = o.preset;
    if (preset && typeof preset === 'object') {
      for (const key of Object.keys(DEFAULTS)) {
        const v = numeric(preset[key]);
        if (v !== null) out[key] = v;
      }
    }

    const machine = o.machine;
    if (machine && typeof machine === 'object') {
      for (const key of ['powerDraw', 'wearRate']) {
        const v = numeric(machine[key]);
        if (v !== null) out[key] = v;
      }
      // 4. WHAT THE MACHINE COST, when the shop has said. A machine with a
      //    purchase price, an expected life and a residual value has a wear
      //    rate that is ARITHMETIC rather than a guess — lib/depreciation.js —
      //    and it replaces the flat figure. A machine without one, and every
      //    machine in a book written before the field existed, is costed
      //    exactly as it always was. A part's own wearRate still beats this,
      //    as it beats everything here (the caller's business, see above).
      //
      //    `recentMonthlyHours` is what the machine has actually printed a
      //    month lately; a straight-line machine needs its hours a month to
      //    turn a monthly amount into an hourly one.
      const D = depreciation();
      const derived = D ? D.hourlyRate(machine, { recentMonthlyHours: o.recentMonthlyHours }) : null;
      if (derived !== null && derived !== undefined) out.wearRate = derived;
    }
    return out;
  }

  const api = { DEFAULTS, ratesFor };
  Object.assign(global, { KhaytPrintRates: api });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
