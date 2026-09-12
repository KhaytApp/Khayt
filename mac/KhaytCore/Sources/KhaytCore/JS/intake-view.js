'use strict';
/**
 * What the calculator should SAY about a file it just read.
 *
 * lib/model-intake.js decides whether a number came from a slicer or from
 * geometry. This decides how that is presented, and it lives here rather than
 * inside the renderer's event wiring because it is the one piece of R1 that can
 * do real harm: a geometric estimate shown as though it were a sliced figure
 * becomes a quote the shop cannot honour. That branch needs a test, and a
 * function buried in wireEvents() cannot have one.
 *
 * Returns keys and interpolation values, not sentences — the caller translates.
 * Numbers are rounded here so the note and the form field can never disagree
 * about what was applied.
 */
(function (global) {
  const round1 = (v) => Math.round(v * 10) / 10;
  const round2 = (v) => Math.round(v * 100) / 100;
  /**
   * The histories a rate can come from, narrowest first — each has its own
   * wording because each is a materially different claim. "This model with
   * these settings, three times" is worth more than "your printers, on
   * average", and the shop should be able to tell which it is holding.
   */
  const SCOPES = ['setup', 'file', 'machine', 'shop'];

  /**
   * @param {object} res         a model-intake result (or the IPC echo of one)
   * @param {object} [opts]      the estimator options in full — everything
   *                             lib/stl-estimate.js accepts is forwarded, so the
   *                             shop's density, wall and calibrated throughput
   *                             all reach the number the calculator shows
   * @param {number} [opts.infillPct]  0..1, the shop's current infill
   * @param {function} [opts.estimate] estimateFromStl, injected so this module
   *                                   stays free of a hard dependency
   * @param {{scope: string, jobs: number}} [opts.calibratedFrom]
   *                             set by lib/estimate-calibration.js when measured
   *                             jobs earned the rate; drives measured-vs-assumed
   * @returns {{
   *   mode: 'exact'|'estimate'|'none',
   *   weightG: number|null, timeH: number|null,
   *   calibrated: {scope: string, jobs: number, gramsPerHour: number}|null,
   *   note: Array<{key: string, vars?: object, strong?: boolean}>,
   *   toast: {key: string, kind: string},
   *   material: string|null
   * }}
   */
  /**
   * The lines that say what might go wrong, appended to the quote's own note.
   *
   * Deliberately AFTER the price rather than instead of it. The shop asked what
   * this costs and must get an answer; "there are overhangs" is the second thing
   * they need, not a reason to withhold the first. Each line carries its own
   * measurement so the reader can disagree with it — a shop that supports
   * everything by default will scroll past the overhang line, and should be able
   * to see immediately that it is the one to scroll past.
   *
   * Structured, not prose: the caller renders these through the same i18n path
   * as every other note line, and a test asserting a sentence would prove nothing
   * about what the shop was told.
   */
  function riskNote(res) {
    const risk = res && res.risk;
    if (!risk || !Array.isArray(risk.risks) || !risk.risks.length) return [];
    const pct = (f) => Math.max(1, Math.round((Number(f) || 0) * 100));
    const lines = [];
    for (const r of risk.risks) {
      if (r.id === 'overhang') {
        lines.push({ key: 'risk.overhang', vars: { pct: pct(r.fraction), deg: Math.round(r.thresholdDeg) } });
      } else if (r.id === 'bridge') {
        lines.push({ key: 'risk.bridge', vars: { pct: pct(r.fraction) } });
      } else if (r.id === 'thin') {
        lines.push(r.severity === 'crit'
          ? { key: 'risk.thin_crit', vars: { mm: round2(r.meanThicknessMm), nozzle: r.nozzleDiameter }, strong: true }
          : { key: 'risk.thin', vars: { mm: round2(r.meanThicknessMm), bores: round1(r.bores) } });
      } else if (r.id === 'bed') {
        lines.push({ key: 'risk.bed', vars: {
          x: Math.round(r.bbox.x), y: Math.round(r.bbox.y), z: Math.round(r.bbox.z),
          bx: Math.round(r.bed.x), by: Math.round(r.bed.y), bz: Math.round(r.bed.z),
        }, strong: true });
      } else if (r.id === 'bed-rotate') {
        lines.push({ key: 'risk.bed_rotate' });
      } else if (r.id === 'inverted-winding') {
        lines.push({ key: 'risk.inverted' });
      }
    }
    // Only worth a heading if something is being said under it.
    return lines.length ? [{ key: 'risk.head', strong: true }, ...lines] : [];
  }

  function presentIntake(res, opts = {}) {
    const none = (key) => ({
      mode: 'none', weightG: null, timeH: null, note: [],
      toast: { key, kind: 'warning' }, material: null,
    });

    if (!res) return none('calc.parse_failed');

    // --- The slicer already worked this out. -------------------------------
    // Guarded on the numbers as well as the flag: `exact` without both figures
    // would fill the form with a missing half that reads as zero.
    if (res.exact && res.printTimeMins > 0 && res.filamentGrams > 0) {
      return {
        mode: 'exact',
        weightG: round1(res.filamentGrams),
        timeH: round2(res.printTimeMins / 60),
        note: [{
          key: 'intake.exact',
          vars: {
            file: res.filename || '',
            slicer: res.slicer || null,       // caller substitutes 'your slicer'
            grams: round1(res.filamentGrams),
            time: round2(res.printTimeMins / 60),
          },
        }],
        toast: { key: 'intake.exact_toast', kind: 'success' },
        material: res.filamentType || null,
      };
    }

    // --- Nobody sliced it: geometry, clearly flagged. -----------------------
    const g = res.geometry;
    if (res.source === 'geometry' && g && g.volumeMm3 > 0 && typeof opts.estimate === 'function') {
      const infillPct = Number.isFinite(opts.infillPct) ? opts.infillPct : 0.2;
      // The WHOLE option set, not just the infill. The caller has already folded
      // the shop's own settings and any calibration learned from its measured
      // jobs into `opts`; forwarding one field of it meant the calculator quoted
      // on the module defaults — PLA at 1.24 and a shipped throughput — while
      // the settings panel showed the shop something else entirely, and a
      // measured rate never reached a quote at all.
      const est = opts.estimate(g, Object.assign({}, opts, { infillPct }));

      // Where the rate came from. lib/estimate-calibration.js sets
      // `calibratedFrom` only when real jobs earned it, so its absence is the
      // honest signal that the time below is a guess.
      const cal = (opts.calibratedFrom && opts.calibratedFrom.jobs > 0) ? opts.calibratedFrom : null;
      // Rearranged back out of the throughput the estimator works in: grams per
      // hour is the figure a shop can recognise, and the only one it can measure.
      const rateGPerH = round1(
        est.assumptions.densityGPerCm3 * est.assumptions.throughputMm3PerS * 3.6);
      // How far the jobs behind that rate disagreed, as a percentage. Shown
      // because the rate on its own reads as a machine specification, and it is
      // not one: on a real printer the same machine ran from 1.9 to 48.6 g/h
      // depending on what it was printing. A shop told "27 g/h" plans on 27; a
      // shop told "27, give or take 12%" knows what it is holding.
      const spreadPct = (cal && Number.isFinite(cal.spread))
        ? Math.max(1, Math.round(cal.spread * 100))
        : null;
      // Which history earned the rate, narrowest first. Anything unrecognised
      // takes the weakest claim rather than inventing a stronger one.
      const scope = SCOPES.indexOf(cal && cal.scope) >= 0 ? cal.scope : 'shop';

      return {
        mode: 'estimate',
        weightG: round1(est.estWeightG),
        timeH: round2(est.estPrintTimeH),
        // Surfaced so the caller can style the whole block as a warning rather
        // than relying on one line of prose being read.
        reliable: est.reliable !== false,
        // Provenance of the RATE, structured. Prose can be reworded or
        // translated away; a test asserting on the sentence proves nothing about
        // what the shop was told.
        calibrated: cal
          ? { scope: cal.scope || 'shop', jobs: cal.jobs, gramsPerHour: rateGPerH, spreadPct }
          : null,
        note: [
          // First line, emphasised: the reader must not have to reach the third
          // line to learn this is not a measurement.
          { key: 'intake.estimate_head', strong: true },
          // Second line, also emphasised, ONLY when the geometry is outside what
          // the estimator can describe. Measured against a real slicer, those
          // parts come out anywhere from +58% to -66%, which is not a margin —
          // it is the difference between a job and a loss.
          ...(est.reliable === false ? [{ key: 'intake.estimate_unreliable', strong: true }] : []),
          { key: 'stl.note_tpl', vars: {
            x: est.dimsMm.x, y: est.dimsMm.y, z: est.dimsMm.z,
            solid: est.solidWeightG, weight: est.estWeightG, time: est.estPrintTimeH } },
          { key: 'stl.note_assume', vars: {
            infill: Math.round(infillPct * 100), density: est.assumptions.densityGPerCm3 } },
          // A measured rate and a guessed one must never read the same. The time
          // above is the half of the estimate that moves most between shops, and
          // a shop that has taught Khayt what its printers do should be able to
          // see that it took.
          //
          // Scope is part of that claim, not decoration: a rate this machine
          // earned describes it, while a shop-wide one is other printers'
          // history standing in for it — the same number, honestly weaker. A
          // CoreXY and a bedslinger genuinely disagree, which is why
          // estimate-calibration prefers the machine's own history and only
          // falls back to the pool.
          //
          // And it is reported as the MIDDLE of those jobs, with how far they
          // disagreed, rather than as a rate the printer runs at. It is not one:
          // the same machine measured anywhere from 1.9 to 48.6 g/h across 67
          // jobs, because grams-per-hour follows the part, not the printer. The
          // median is still the best single number there is — but stated bare it
          // reads as a specification, and a shop plans against it as though the
          // next job will hit it.
          cal
            ? { key: (spreadPct == null ? 'stl.note_rate_measured_' : 'stl.note_rate_spread_') + scope,
                vars: { rate: rateGPerH, n: cal.jobs, pct: spreadPct } }
            : { key: 'stl.note_rate_assumed', vars: { rate: rateGPerH } },
          { key: 'intake.estimate_advice' },
          ...riskNote(res),
        ],
        toast: { key: 'intake.estimate_toast', kind: 'info' },
        material: null,
      };
    }

    // --- Nothing usable. Say which kind of nothing. -------------------------
    const w = res.warnings || [];
    // A file past the size ceiling is the one kind of nothing with an action
    // attached, and it was the one being reported as "could not read that file"
    // — which reads as a broken file, so the shop re-exports a file that was
    // never the problem.
    if (w.includes('too-large')) return none('intake.too_large');
    if (w.includes('no-slicer-summary')) return none('intake.no_summary');
    if (w.includes('unsupported')) return none('intake.unsupported');
    return none('calc.parse_failed');
  }

  const api = { presentIntake, riskNote };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytIntakeView = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
