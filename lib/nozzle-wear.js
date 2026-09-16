'use strict';
/**
 * How much life a nozzle has left, and what has been spending it.
 *
 * The machine card has always shown "Xg / 2000g" against a nozzle. Three things
 * were wrong with that number, and this module exists because the third one
 * cannot be fixed by a bug fix alone.
 *
 *   1. It was always ZERO. The sum read `p.weight`, which is not a field a part
 *      has — the store keeps `printWeight` and `supportWeight` — so `+undefined
 *      || 0` made every job contribute nothing. Verified against a real shop:
 *      twelve completed jobs, 2,461 g through the machine, the card said 0 g.
 *      The warning has never fired for anybody.
 *
 *   2. 2000 g was a hard-coded fallback for every nozzle. Brass, hardened steel
 *      and ruby have wildly different lives, the app already asks which one is
 *      fitted, and then ignored the answer.
 *
 *   3. Grams are not interchangeable. A kilo of PLA and a kilo of carbon-filled
 *      PLA are not the same event for a brass nozzle: the first is most of its
 *      life, the second is several nozzles. Counting raw grams tells a shop
 *      running abrasives that it has plenty left, right up until parts start
 *      coming out wrong.
 *
 * THESE NUMBERS ARE RULES OF THUMB, NOT MEASUREMENTS. Nozzle wear depends on
 * filler load, flow rate, temperature and how much you care about dimensional
 * accuracy — nobody can give a shop a true figure for its own printing. They are
 * chosen to be the right ORDER OF MAGNITUDE and to be obviously editable: every
 * value here is a starting point the shop overrides per machine, and the UI says
 * so. The alternative on offer was a single 2000 that was wrong for four of the
 * five nozzle materials the app already lets you pick.
 *
 * Pure and dependency-free so it can be tested directly. Node + renderer.
 *
 * Wrapped in an IIFE because the renderer loads lib/ modules with plain
 * <script> tags into ONE shared global scope: a top-level `const api` here and
 * a top-level `const api` anywhere else is a redeclaration that makes the whole
 * file fail to parse. test/renderer-script-scope.test.js caught this one.
 */
(function (global) {

    /**
   * The published table. Every figure carries its source; see that file.
   *
   * The numbers this module used to carry were invented — plausible, labelled
   * "rules of thumb", and checked against nothing. Two were wrong in a direction
   * that mattered: glow-in-the-dark was rated the most abrasive filament going
   * when a controlled test measured no wear from it at all, and brass was given
   * 2 kg of life when published figures start at 3 kg and reach 15.
   */
  // require() under Node and the test runner; the global under the renderer,
  // where lib/ modules arrive as <script> tags. Wrapped in try/catch rather than
  // a typeof check because a renderer that DOES expose require would resolve
  // './nozzle-wear-data.js' against the wrong directory and throw — and falling
  // back is right in both cases.
  let DATA;
  try { DATA = require('./nozzle-wear-data.js'); } catch (e) { DATA = null; }
  if (!DATA) DATA = global.KhaytNozzleWearData;

  /**
   * A shop's own overrides, from `settings.nozzleWear`.
   *
   * The published figures disagree by an order of magnitude and none of them
   * knows this shop's filament, flow rate or tolerance for dimensional drift.
   * So they are a starting point with an escape hatch, not an answer — and the
   * escape hatch has to be first-class, or the honest thing to do with an
   * unverifiable number would be to leave it out entirely.
   *
   *   settings.nozzleWear = {
   *     life:      { brass: 4000, ... },        // grams, per nozzle material
   *     abrasive:  { carbon: 14, ... },         // multiplier, per class key
   *   }
   */
  function overrides(settings) {
    const o = (settings && settings.nozzleWear) || {};
    return { life: o.life || {}, abrasive: o.abrasive || {} };
  }

  /** Multiplier for a material string, honouring any per-shop override. */
  function abrasivenessFor(material, settings) {
    const s = String(material == null ? '' : material);
    if (!s.trim()) return 1;
    const ov = overrides(settings).abrasive;
    for (const cls of DATA.ABRASIVE_CLASSES) {
      if (!cls.pattern.test(s)) continue;
      const custom = +ov[cls.key];
      return Number.isFinite(custom) && custom > 0 ? custom : cls.multiplier;
    }
    return 1;
  }

  /** Which class a material string falls into, or null when it is unfilled. */
  function classifyMaterial(material) {
    const s = String(material == null ? '' : material);
    if (!s.trim()) return null;
    return DATA.ABRASIVE_CLASSES.find((c) => c.pattern.test(s)) || null;
  }

  /** The suggested threshold for a nozzle material, honouring any override. */
  function defaultThresholdFor(material, settings) {
    const key = String(material || 'brass').toLowerCase().trim();
    const custom = +overrides(settings).life[key];
    if (Number.isFinite(custom) && custom > 0) return custom;
    const row = DATA.NOZZLE_LIFE_G[key] || DATA.NOZZLE_LIFE_G.other;
    return row.grams;
  }

  /** Every suggested figure, for a settings table the shop can edit. */
  function suggestions(settings) {
    const ov = overrides(settings);
    return {
      checkedOn: DATA.CHECKED_ON,
      sources: DATA.SOURCES,
      life: Object.entries(DATA.NOZZLE_LIFE_G).map(([key, row]) => ({
        key, label: row.label, grams: row.grams, note: row.note,
        estimated: !!row.estimated, source: row.source ? DATA.SOURCES[row.source] : null,
        override: Number.isFinite(+ov.life[key]) && +ov.life[key] > 0 ? +ov.life[key] : null,
      })),
      abrasive: DATA.ABRASIVE_CLASSES.map((c) => ({
        key: c.key, label: c.label, multiplier: c.multiplier, note: c.note,
        estimated: !!c.estimated, source: c.source ? DATA.SOURCES[c.source] : null,
        override: Number.isFinite(+ov.abrasive[c.key]) && +ov.abrasive[c.key] > 0 ? +ov.abrasive[c.key] : null,
      })),
    };
  }

  /**
   * Grams a part draws, print plus support, times quantity.
   *
   * Mirrors partGramsConsumed() in inventory.js — the same shape for the same
   * reason. Supports are real filament through the same nozzle, and a part printed
   * ten times wears it ten times.
   */
  function partGrams(p) {
    if (!p) return 0;
    return ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1);
  }


  /** Wear from the printer's own job history. Same shape as the order-log path. */
  function fromHistory(jobs, nozzle, since, settings) {
    const MH = (typeof require === 'function' ? (() => { try { return require('./moonraker-history.js'); } catch (e) { return null; } })() : null)
      || global.KhaytMoonrakerHistory;
    const threshold = +nozzle.gramsThreshold > 0
      ? +nozzle.gramsThreshold
      : defaultThresholdFor(nozzle.material, settings);
    const t = MH ? MH.totalsSince(jobs, since) : { grams: 0, byMaterial: [] };
    let wear = 0;
    const byMaterial = t.byMaterial.map((row) => {
      const mult = abrasivenessFor(row.material, settings);
      wear += row.grams * mult;
      return { material: row.material, grams: row.grams, wear: row.grams * mult, mult };
    }).sort((a, b) => b.wear - a.wear);
    const worstRow = byMaterial.find((r) => r.mult > 1) || null;
    return {
      grams: t.grams,
      wear: Math.round(wear * 100) / 100,
      threshold,
      pct: threshold > 0 ? Math.min(100, (wear / threshold) * 100) : 0,
      over: threshold > 0 && wear >= threshold,
      abrasive: wear > t.grams,
      worst: worstRow ? { material: worstRow.material, mult: worstRow.mult } : null,
      byMaterial,
      // So the card can say WHERE the figure came from. A number sourced from
      // the machine itself and one inferred from orders are different claims.
      source: 'printer',
    };
  }

  /**
   * Wear on one machine's nozzle since it was fitted.
   *
   * @param {object[]} printLog  every order
   * @param {object} machine     the machine, with .id and .nozzle
   * @returns {{grams: number, wear: number, threshold: number, pct: number,
   *            over: boolean, abrasive: boolean, worst: {material: string, mult: number}|null,
   *            byMaterial: Array<{material: string, grams: number, wear: number, mult: number}>}}
   *   `grams` is what actually went through — what a shop recognises from its own
   *   records. `wear` is what it cost the nozzle, and is what the threshold is
   *   measured against. They are equal until somebody prints something filled.
   */
  function nozzleWear(printLog, machine, settings) {
    const nozzle = (machine && machine.nozzle) || {};
    const since = nozzle.installedAt || '';

    /* THE PRINTER'S OWN HISTORY WINS, WHERE THERE IS ONE.
     *
     * Counting completed ORDERS answers "how much did we sell", not "how much
     * has gone through this nozzle". Test prints, reprints, calibration and
     * anything nobody paid for are all real filament and none of them is an
     * order. A machine that has extruded three and a half kilos while nineteen
     * of its jobs were orders reports a fraction of its wear, and the warning
     * fires late — the direction that ruins parts rather than wasting nozzles.
     *
     * So an imported history replaces the order log HERE and nowhere else.
     * Using both would double-count every job that is an order AND a print. */
    const history = machine && machine.printerHistory;
    if (history && Array.isArray(history.jobs) && history.jobs.length) {
      return fromHistory(history.jobs, nozzle, since, settings);
    }
    const threshold = +nozzle.gramsThreshold > 0
      ? +nozzle.gramsThreshold
      : defaultThresholdFor(nozzle.material, settings);

    const totals = new Map();   // material -> { grams, mult }
    let grams = 0;
    let wear = 0;

    for (const o of Array.isArray(printLog) ? printLog : []) {
      if (!o || o.machineId !== (machine && machine.id)) continue;
      // Finished by either spelling: a legacy `delivered` job wore the nozzle too.
      if (o.status !== 'completed' && o.status !== 'delivered') continue;
      // A job dated before the nozzle went in belongs to the previous one. An
      // order with no date sorts as '' and is excluded by the same comparison,
      // which is right: it cannot be shown to have happened since.
      if ((o.date || '') < since) continue;
      for (const p of o.parts || []) {
        const g = partGrams(p);
        if (!g) continue;
        const material = String((p && p.material) || '').trim();
        const mult = abrasivenessFor(material, settings);
        grams += g;
        wear += g * mult;
        const key = material || '(unspecified)';
        const row = totals.get(key) || { grams: 0, mult };
        row.grams += g;
        totals.set(key, row);
      }
    }

    const byMaterial = [...totals.entries()]
      .map(([material, r]) => ({ material, grams: r.grams, wear: r.grams * r.mult, mult: r.mult }))
      .sort((a, b) => b.wear - a.wear);
    const worstRow = byMaterial.find((r) => r.mult > 1) || null;

    return {
      grams,
      wear,
      threshold,
      pct: threshold > 0 ? Math.min(100, (wear / threshold) * 100) : 0,
      over: threshold > 0 && wear >= threshold,
      abrasive: wear > grams,
      worst: worstRow ? { material: worstRow.material, mult: worstRow.mult } : null,
      byMaterial,
    };
  }

  const api = {
    DATA,
    abrasivenessFor,
    classifyMaterial,
    defaultThresholdFor,
    suggestions,
    partGrams,
    nozzleWear,
    fromHistory,
    // Kept so callers that only need the list of materials do not reach into DATA.
    get MATERIAL_LIFE_G() {
      const out = {};
      for (const [k, v] of Object.entries(DATA.NOZZLE_LIFE_G)) out[k] = v.grams;
      return out;
    },
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytNozzleWear = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
