'use strict';
/**
 * Pure print estimator: turn STL geometry (lib/stl-parse.js) into a *draft*
 * weight + print-time estimate the calculator can price. Like lib/ai-quote.js,
 * it fills the form and surfaces its assumptions — it NEVER finalizes a price.
 *
 * Estimates are deliberately simple + transparent (no slicing):
 *  - weight = solidWeight × (shell + (1−shell)·infill)
 *  - time   = printedVolume / volumetricThroughput
 * Every knob is an option with a sane default; the UI lets the user adjust.
 */
(function (global) {
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  // Where the surface-area shell model stops being trustworthy. See `reliable`
  // below for the measurements this came from.
  const SHELL_RELIABLE_MAX = 0.85;
  const round1 = (v) => Math.round(v * 10) / 10;
  const round2 = (v) => Math.round(v * 100) / 100;

  // Fallbacks, not doctrine. Every one of these is a shop setting now
  // (settings.estimator, see fromSettings below); these are what a shop that has
  // said nothing gets, and they are the values this estimator always used, so an
  // unconfigured shop's numbers do not move.
  //
  // throughputMm3PerS is the weakest of them by far: "effective volumetric flow
  // including travel and acceleration overhead" is not something a shop knows
  // about its own printer, and 8 mm³/s with PLA implies about 35 g/h, which no
  // real FDM machine sustains. lib/estimate-calibration.js derives it from the
  // shop's own measured jobs instead, and that beats anything typed here.
  const DEFAULTS = {
    densityGPerCm3: 1.24,     // PLA
    infillPct: 0.2,           // 20%
    shellFactor: 0.35,        // FALLBACK only — used when a mesh gives us no surface area
    wallThicknessMm: 1.2,     // ~3 perimeters at 0.4mm; the shell is derived from area × this
    throughputMm3PerS: 8,     // see above — measured in preference to guessed
    wastePct: 0.03,           // purge/brim/support slack
  };

  /**
   * Read the shop's estimator settings, falling back per-field.
   *
   * Per-field on purpose: a shop that set only a density should keep the
   * defaults for everything else rather than having a partial object replace the
   * lot.
   */
  function fromSettings(settings) {
    const e = (settings && settings.estimator) || {};
    const pick = (key, lo, hi) => {
      const v = Number(e[key]);
      return Number.isFinite(v) && v >= lo && v <= hi ? v : DEFAULTS[key];
    };
    return {
      densityGPerCm3:    pick('densityGPerCm3', 0.1, 25),
      infillPct:         pick('infillPct', 0, 1),
      shellFactor:       pick('shellFactor', 0, 1),
      wallThicknessMm:   pick('wallThicknessMm', 0.1, 20),
      throughputMm3PerS: pick('throughputMm3PerS', 0.5, 500),
      wastePct:          pick('wastePct', 0, 0.5),
    };
  }

  /**
   * @param geom { volumeMm3, bbox:{x,y,z} } from parseStl
   * @param opts subset of DEFAULTS
   * @returns { solidVolumeCm3, solidWeightG, estWeightG, estPrintTimeH, dimsMm, effectiveFraction, assumptions[] }
   */
  function estimateFromStl(geom, opts = {}) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const density = Math.max(0.1, +o.densityGPerCm3 || DEFAULTS.densityGPerCm3);
    const infill = clamp(+o.infillPct || 0, 0, 1);
    const shell = clamp(+o.shellFactor || 0, 0, 1);
    const throughput = Math.max(0.5, +o.throughputMm3PerS || DEFAULTS.throughputMm3PerS);
    const waste = clamp(+o.wastePct || 0, 0, 0.5);
    const wallThickness = clamp(+o.wallThicknessMm || DEFAULTS.wallThicknessMm, 0.1, 20);

    const volMm3 = Math.max(0, +geom?.volumeMm3 || 0);
    const solidVolumeCm3 = volMm3 / 1000;
    const solidWeightG = solidVolumeCm3 * density;

    // Shell is a SURFACE, not a fixed share of the volume.
    //
    // This used to be a flat `shellFactor` — 35% of the solid, whatever the part
    // was. That cannot be right at two sizes at once: walls scale with area
    // (L²) and the part with volume (L³), so the shell's share must fall as
    // things get bigger. The constant happened to be about right near 20 mm,
    // which is calibration-cube size and probably why it survived; a 100 mm cube
    // was quoted at 613 g against a physical ~327 g, and a 200 mm one at more
    // than double. That is a customer's quote, and estimate-calibration never
    // corrects weight — only time — so nothing downstream would have learned it
    // away.
    //
    // area × wall is the first-order term and it OVER-counts, because walls
    // meeting at an edge or corner get charged twice. The error is worst on
    // small parts (a 10 mm cube comes out ~24% high) and negligible on large
    // ones (a 100 mm cube lands within 1%). That trade is deliberate: on a small
    // part 24% is a fraction of a gram, and erring high on a quote is the safe
    // direction; on a big part the absolute error is what the shop actually
    // bills for. The exact correction needs edge length, which a triangle soup
    // does not give us generically.
    const areaMm2 = Math.max(0, +geom?.areaMm2 || 0);
    // Kept UNCLAMPED as well, and reported as `rawShell`. Not because the
    // reliability test below needs it — the clamp caps at 1, which is already
    // past the threshold, so that check reads the same either way — but because
    // "1.0" and "7.6" are very different diagnoses of the same clamped answer,
    // and only the raw figure tells you how far outside its range a model is.
    const rawShell = areaMm2 > 0 && volMm3 > 0 ? (areaMm2 * wallThickness) / volMm3 : null;
    const shellFromArea = rawShell === null ? null : clamp(rawShell, 0, 1);
    // Older geometry (and any caller that never had areaMm2) keeps the constant
    // rather than silently pricing at zero shell.
    const shellFraction = shellFromArea === null ? shell : shellFromArea;

    // Is this estimate worth believing?
    //
    // Scored against PrusaSlicer on real geometry (scripts/verify-estimator.mjs).
    // Below the threshold the model lands within ~13%. At or above it, the shell
    // term has swallowed the part and there is no infill headroom left to be
    // wrong about — a 3mm plate came out +58%, and a HueForge relief, whose raw
    // shell is about 7, came out -66% because a slicer lays a minimum extrusion
    // width no matter how thin the geometry is. No volume-based model can see
    // that, so the only honest move is to say the number is unreliable.
    //
    // This over-warns: a ribbed comb sits at 0.89 and was accurate to 2%. That
    // trade is deliberate. Telling a shop to go and slice a part it could have
    // quoted costs a minute; quoting a relief at a third of its cost is a job
    // taken at a loss.
    //
    // AND: a measurement that did not produce finite numbers is not a
    // measurement. `1e999` in an STL parses to Infinity, and the geometry then
    // comes back with volumeMm3 NaN and a null dimension — from a parse that
    // reported SUCCESS. Every figure below is clamped, so what reached the
    // caller was a confident 0 g / 0 h estimate marked reliable:
    //
    //     estWeightG 0, estPrintTimeH 0, dimsMm {x: null, y: 2, z: 2}, reliable true
    //
    // That number is shown to CUSTOMERS — lib/public-quote.js and the LAN intake
    // form both print it — so an unmeasurable model was quoted as free, and the
    // one flag that would have warned about it said the figure was sound.
    const measurable = Number.isFinite(+(geom && geom.volumeMm3))
      && ['x', 'y', 'z'].every((k) => Number.isFinite(+((geom && geom.bbox) || {})[k]));
    const reliable = measurable && (rawShell === null ? true : rawShell < SHELL_RELIABLE_MAX);

    const effectiveFraction = shellFraction + (1 - shellFraction) * infill;
    const estWeightG = solidWeightG * effectiveFraction * (1 + waste);

    const printedVolumeMm3 = (estWeightG / density) * 1000;
    const estPrintTimeH = printedVolumeMm3 / (throughput * 3600);

    const bbox = geom && geom.bbox ? geom.bbox : { x: 0, y: 0, z: 0 };
    const dimsMm = { x: round1(bbox.x || 0), y: round1(bbox.y || 0), z: round1(bbox.z || 0) };

    return {
      solidVolumeCm3: round1(solidVolumeCm3),
      solidWeightG: round1(solidWeightG),
      estWeightG: round1(estWeightG),
      estPrintTimeH: round2(estPrintTimeH),
      effectiveFraction: Math.round(effectiveFraction * 100) / 100,
      shellFraction: Math.round(shellFraction * 1000) / 1000,
      // Which model produced that shell, because the two are not comparable and
      // a number nobody can attribute is a number nobody can check.
      shellSource: shellFromArea === null ? 'assumed' : 'surface-area',
      // Callers that show this number to anyone must check `reliable` and say so.
      reliable,
      rawShell: rawShell === null ? null : Math.round(rawShell * 1000) / 1000,
      dimsMm,
      assumptions: {
        densityGPerCm3: density, infillPct: infill, shellFactor: shell,
        wallThicknessMm: wallThickness,
        throughputMm3PerS: throughput, wastePct: waste,
      },
    };
  }

  const api = { estimateFromStl, fromSettings, ESTIMATE_DEFAULTS: DEFAULTS, SHELL_RELIABLE_MAX };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStl = Object.assign(global.KhaytStl || {}, api);
})(typeof globalThis !== 'undefined' ? globalThis : this);
