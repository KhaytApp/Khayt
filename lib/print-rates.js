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

  /**
   * The most a kWh can cost, in the shop's own currency — one bound for every
   * reader of a shop tariff (settings-edit on the way in; `shopTariff` here,
   * `elecRateFor` in public-quote and the Mac's setup preset on the way out).
   *
   * Per kWh, not per dollar, so it has to fit the currency with the smallest
   * unit Khayt prices in (lib/currencies.js): IQD (~1,300 to the US dollar)
   * and NGN (~1,500). A grid tariff there is tens to a few hundred a kWh,
   * KRW ~100–300, and the dearest real case — diesel off-grid at about
   * US$1/kWh — is ~1,300–1,600 in IQD/NGN. 10,000 leaves ~6× headroom over
   * that while still catching a figure typed in the wrong unit (Wh, or the
   * whole bill). The old 0–100 stored a Korean or Nigerian shop's real 250 as
   * 100, without a word.
   *
   * A value ABOVE it is clamped to it, not ignored: the shop did say a price,
   * and a book holding one (written before this bound, or by hand) is costed
   * at the most this allows rather than falling back to 0.18.
   */
  const MAX_ELEC_RATE = 10000;

  /**
   * A number, or null for "not said". Blank — '' or only whitespace — is not
   * said: `+'  '` is 0 in JavaScript, which costed a preset whose tariff field
   * held a space at a FREE kWh, while public-quote's `elecRateFor` (rightly)
   * read the same space as nothing. Both read it as nothing now. Only a
   * number or a string can say a number (`+[]` and `+true` are not answers),
   * which is the same test `elecRateFor` applies.
   */
  const numeric = (v) => {
    if (typeof v === 'string') { if (v.trim() === '') return null; }
    else if (typeof v !== 'number') return null;   // null, undefined, true, [], {}
    return isFinite(+v) ? +v : null;
  };

  /**
   * The rates for one part, from the shop's own things.
   *
   * Order, and it matters:
   *
   *   1. Khayt's defaults, so nothing is ever silently zero.
   *   1b. The SHOP'S OWN TARIFF, `settings.elecRate` — what a kWh costs this
   *      shop, whichever printer and whichever preset. Before it existed a
   *      tariff could only be written on a preset, so every costing that had
   *      no preset (a failed print, power by machine) was charged Khayt's
   *      0.18. Absent, blank, negative or not a number is "not said", and the
   *      default stands — a book written before the key is costed exactly as
   *      it was. Above `MAX_ELEC_RATE` is clamped to it.
   *      Blank (whitespace too) is "not said" in the preset and machine
   *      steps below as well, so a blank field defers rather than costing 0.
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
   * @param {object} [opts.settings] the shop's settings (only `elecRate` is read)
   * @param {object} [opts.preset]   a row from `printers`
   * @param {object} [opts.machine]  a row from `machines`
   * @param {number} [opts.recentMonthlyHours]  what that machine has printed a
   *   month lately, for a straight-line machine's hourly figure
   */
  function ratesFor(opts) {
    const o = opts || {};
    const out = defaultsFor(o.settings);

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
      //
      //    ONLY A POSITIVE ONE. A residual equal to the price leaves nothing to
      //    depreciate and a derived rate of 0, which silently replaced the
      //    flat wear rate and quoted the machine's wear as free. Nothing to
      //    derive from is "no derived rate", and the flat figure stands.
      if (typeof derived === 'number' && derived > 0) out.wearRate = derived;
    }
    return out;
  }

  /**
   * The shop's tariff from its settings, or null when it has not said one.
   * Blank, negative, NaN, Infinity or not a number is "not said"; above
   * `MAX_ELEC_RATE` is clamped to it.
   */
  function shopTariff(settings) {
    if (!settings || typeof settings !== 'object') return null;
    const v = numeric(settings.elecRate);
    return v !== null && v >= 0 ? Math.min(v, MAX_ELEC_RATE) : null;
  }

  /**
   * Khayt's defaults with the shop's own tariff over them — what a part is
   * costed at before any preset or machine has a say. PURE: the settings are
   * the caller's, so each app passes its own and gets a fresh object back.
   *
   * @param {object} [settings] the shop's settings
   */
  function defaultsFor(settings) {
    const out = Object.assign({}, DEFAULTS);
    const tariff = shopTariff(settings);
    if (tariff !== null) out.elecRate = tariff;
    return out;
  }

  const api = { DEFAULTS, MAX_ELEC_RATE, ratesFor, defaultsFor, shopTariff };
  Object.assign(global, { KhaytPrintRates: api });
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
