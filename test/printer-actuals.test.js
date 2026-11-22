/**
 * Reading what a print actually used off the printer.
 *
 * The reason this matters: Khayt already had `actualPrintTime` and
 * `actualWeight`, and the only thing that wrote them was a dialog pre-filled
 * with the ESTIMATE. A shop that hits confirm records the estimate twice under
 * two names, and the variance report says "spot on" for a job that ran two hours
 * over. So the tests here care most about two things — that a measurement is a
 * measurement, and that a non-measurement is never dressed up as one.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  extractActuals, filamentMmToGrams, compareToEstimate, hasActuals, prefillActuals,
  DEFAULT_DIAMETER_MM, DEFAULT_DENSITY_G_CM3, COMPLETION_MAX_AGE_MS,
} = require('../lib/printer-actuals.js');

test('a metre of 1.75mm PLA weighs about 3 grams', () => {
  // Checkable by eye against any filament spec sheet, which is the point — a
  // conversion nobody can sanity-check is a conversion nobody will trust.
  const g = filamentMmToGrams(1000);
  assert.ok(Math.abs(g - 2.98) < 0.01, `got ${g}`);
  assert.equal(DEFAULT_DIAMETER_MM, 1.75);
  assert.equal(DEFAULT_DENSITY_G_CM3, 1.24);
});

test('diameter matters more than it looks', () => {
  // 2.85mm stock is 2.65× the cross-section of 1.75mm. A shop running 2.85 and
  // getting 1.75 maths would under-report every job's material by over half.
  const thin = filamentMmToGrams(1000, { diameterMm: 1.75 });
  const thick = filamentMmToGrams(1000, { diameterMm: 2.85 });
  assert.ok(Math.abs(thick / thin - (2.85 / 1.75) ** 2) < 1e-9);
  assert.ok(thick > thin * 2.5);
});

test('density is honoured — resin and PETG are not PLA', () => {
  const pla = filamentMmToGrams(1000, { densityGPerCm3: 1.24 });
  const petg = filamentMmToGrams(1000, { densityGPerCm3: 1.27 });
  assert.ok(petg > pla);
  assert.ok(Math.abs(petg / pla - 1.27 / 1.24) < 1e-9);
});

test('a nonsensical length or stock yields nothing, not zero', () => {
  for (const bad of [0, -5, null, undefined, NaN, 'abc', {}]) {
    assert.equal(filamentMmToGrams(bad), null, JSON.stringify(bad));
  }
  // Config that is PRESENT but impossible is refused rather than silently
  // replaced with the default — a corrupt setting should surface, not hide
  // behind a plausible-looking weight.
  assert.equal(filamentMmToGrams(1000, { diameterMm: 0 }), null);
  assert.equal(filamentMmToGrams(1000, { densityGPerCm3: -1 }), null);
  assert.equal(filamentMmToGrams(1000, { diameterMm: 'wide' }), null);
  // Absent config, though, uses the documented default.
  assert.ok(filamentMmToGrams(1000, {}) > 0);
  assert.ok(filamentMmToGrams(1000, { diameterMm: undefined }) > 0);
  assert.equal(filamentMmToGrams(1000, { diameterMm: undefined }), filamentMmToGrams(1000));
});

test('Moonraker: filament_used and print_duration are read', () => {
  const raw = { result: { status: { print_stats: {
    filament_used: 14025.6, print_duration: 11560, total_duration: 12900, state: 'complete',
  } } } };
  const a = extractActuals('moonraker', raw);
  assert.equal(a.source, 'moonraker');
  assert.equal(a.filamentMm, 14025.6);
  assert.equal(a.durationS, 11560);
  assert.ok(Math.abs(a.filamentGrams - 41.83) < 0.01, `got ${a.filamentGrams}`);
});

test('Moonraker: print_duration, NOT total_duration', () => {
  // total_duration includes heating and idling either side of the job. Comparing
  // that against a sliced estimate reports an overrun that never happened.
  const raw = { result: { status: { print_stats: { print_duration: 100, total_duration: 9999 } } } };
  assert.equal(extractActuals('moonraker', raw).durationS, 100);
});

test('OctoPrint: job.filament is the SLICER\'S estimate, and is refused as one', () => {
  // These three tests used to assert the opposite, and that is how the defect
  // survived: they were written against the field's units, which are correct,
  // rather than against its provenance, which is not.
  //
  // OctoPrint fills job.filament from the file's GCODE ANALYSIS
  // (octoprint/printer/standard.py: filament = fileData["analysis"]["filament"]),
  // computed once at upload. It is the whole file's predicted total and it does
  // not move while the job runs.
  //
  // The fixture below is that job TEN MINUTES IN. A reader that trusts the field
  // reports the entire spool figure as measured and a variance of exactly zero.
  const raw = {
    job: { filament: { tool0: { length: 14025.6, volume: 33.74 } } },
    progress: { printTime: 600, completion: 5.2 },
  };
  const a = extractActuals('octoprint', raw);

  assert.equal(a.filamentGrams, null, 'the analysis total must not be reported as measured');
  assert.equal(a.filamentMm, null);

  // Time is genuinely measured, and stays measured — printTime is elapsed
  // printing, not a prediction. Losing it too would have been the other mistake.
  assert.equal(a.durationS, 600);
  assert.equal(a.source, 'octoprint');
});

test('OctoPrint: an estimate-shaped actual never reports a zero variance', () => {
  // The failure this prevents, stated as a shop would see it: quoted 33.74 cm3
  // of PLA, ten minutes into a job that will take three hours, and told the
  // print used exactly what was quoted.
  const a = extractActuals('octoprint', {
    job: { filament: { tool0: { length: 14025.6, volume: 33.74 } } },
    progress: { printTime: 600 },
  });
  const cmp = compareToEstimate({ printTime: 3.2, weightG: 33.74 * 1.24 }, a);

  assert.equal(cmp.gramsDeltaPct, null, '"we do not know" must not read as "spot on"');
  assert.equal(cmp.actualGrams, null);
  // …while the time axis still reports the real overrun/underrun.
  assert.equal(cmp.actualHours, 0.17);
  assert.ok(cmp.hoursDeltaPct < 0);
});

test('OctoPrint offers time and asks for the weight — the PrusaLink shape', () => {
  // Both hosts measure one axis and predict the other, so the dialog must say
  // measured for the one and estimated for the other. Identical treatment is the
  // point: which host a shop happens to run must not change what "measured"
  // means.
  const octo = extractActuals('octoprint', {
    job: { filament: { tool0: { length: 14025.6, volume: 33.74 } } },
    progress: { printTime: 11560 },
  });
  const prusa = extractActuals('prusalink', { job: { time_printing: 11560 } });

  assert.equal(octo.filamentGrams, prusa.filamentGrams);
  assert.equal(octo.durationS, prusa.durationS);

  const prefill = prefillActuals({
    estimate: { printTime: 3.2, weightG: 41.8 },
    completion: { at: 1000, filename: 'vase.gcode', actuals: octo },
    now: 1000 + 60_000,
  });
  assert.equal(prefill.timeMeasured, true);
  assert.equal(prefill.weightMeasured, false);
  assert.equal(prefill.weightG, 41.8, 'the estimate fills the axis nothing measured');
});

test('Duet reads rawExtrusion and duration', () => {
  const a = extractActuals('duet', { result: { job: { rawExtrusion: 5000, duration: 3600 } } });
  assert.equal(a.filamentMm, 5000);
  assert.equal(a.durationS, 3600);
  assert.ok(a.filamentGrams > 0);
});

test('PrusaLink gives time but no filament, and does not pretend otherwise', () => {
  const a = extractActuals('prusalink', { job: { time_printing: 900 } });
  assert.equal(a.durationS, 900);
  assert.equal(a.filamentGrams, null, 'inventing a weight here would be a lie');
  assert.equal(hasActuals(a), true, 'a time on its own is still worth recording');
});

test('PrusaLink file metadata is NOT treated as a measurement', () => {
  // Prusa's /api/v1/job exposes file.meta with "filament used [g]" — but that is
  // the gcode's own header, i.e. what the SLICER predicted, not what the printer
  // used. Reading it here would report the estimate back as the actual and make
  // every variance read as zero. Verified against Prusa's OpenAPI spec
  // 2026-07-31: /api/v1/status carries no filament figure at all.
  const withMeta = {
    job: {
      time_printing: 900,
      file: { meta: { 'filament used [g]': 41.83, 'filament used [mm]': 14025.6 } },
    },
  };
  const a = extractActuals('prusalink', withMeta);
  assert.equal(a.durationS, 900, 'the time is still read');
  assert.equal(a.filamentMm, null, 'and the slicer figure is ignored');
  assert.equal(a.filamentGrams, null);
});

test('Bambu reports neither, and claims neither', () => {
  // Its MQTT payload has no cumulative extrusion, and elapsed-from-percent is
  // badly behaved at both ends of a job.
  const a = extractActuals('bambu', { print: { mc_percent: 50, mc_remaining_time: 30 } });
  assert.equal(a.filamentGrams, null);
  assert.equal(a.durationS, null);
  assert.equal(hasActuals(a), false);
});

test('an idle printer reports nothing, not a free print', () => {
  // Zero grams recorded against a job says it cost no material. That is a worse
  // answer than "we don't know".
  const idle = extractActuals('moonraker', {
    result: { status: { print_stats: { filament_used: 0, print_duration: 0 } } } });
  assert.equal(idle.filamentMm, null);
  assert.equal(idle.filamentGrams, null);
  assert.equal(idle.durationS, null);
  assert.equal(hasActuals(idle), false);
});

test('junk in never becomes numbers out', () => {
  for (const raw of [null, undefined, '', 42, [], {}]) {
    const a = extractActuals('moonraker', raw);
    assert.equal(a.filamentGrams, null, JSON.stringify(raw));
    assert.equal(a.durationS, null, JSON.stringify(raw));
  }
  // An unrecognised printer must report nothing even when handed a payload that
  // happens to LOOK like another vendor's. Guessing a schema by shape would put
  // one vendor's units on another vendor's numbers.
  const moonShaped = { result: { status: { print_stats: { filament_used: 14025.6, print_duration: 11560 } } } };
  const unknown = extractActuals('some-new-printer', moonShaped);
  assert.equal(unknown.source, null);
  assert.equal(unknown.filamentGrams, null, 'not parsed as Moonraker');
  assert.equal(unknown.durationS, null);
  assert.equal(hasActuals(unknown), false);
  assert.equal(extractActuals('', moonShaped).source, null);
  assert.doesNotThrow(() => extractActuals(null, null));
  // Negative readings are not measurements.
  assert.equal(extractActuals('moonraker', {
    result: { status: { print_stats: { filament_used: -5, print_duration: -1 } } } }).filamentGrams, null);
});

test('the comparison reports a real overrun', () => {
  const actual = extractActuals('moonraker', {
    result: { status: { print_stats: { filament_used: 14025.6, print_duration: 11560 } } } });
  const c = compareToEstimate({ printTime: 3, weightG: 40 }, actual);
  assert.equal(c.estimatedHours, 3);
  assert.equal(c.actualHours, 3.21);
  assert.equal(c.hoursDeltaPct, 7, '3.21h against a 3h estimate is 7% over');
  assert.equal(c.estimatedGrams, 40);
  assert.equal(c.actualGrams, 41.8);
  assert.equal(c.gramsDeltaPct, 4.6);
  assert.equal(c.measured, true);
});

test('"we do not know" never looks like "it was spot on"', () => {
  // A zero delta means the estimate was right. A missing measurement must not
  // render as one, or a shop reads a margin report full of false confidence.
  const c = compareToEstimate({ printTime: 3, weightG: 40 }, { durationS: null, filamentGrams: null });
  assert.equal(c.actualHours, null);
  assert.equal(c.hoursDeltaPct, null, 'null, not 0');
  assert.equal(c.actualGrams, null);
  assert.equal(c.gramsDeltaPct, null);
  assert.equal(c.measured, false);
});

test('a measurement on one axis only reports on that axis', () => {
  const c = compareToEstimate({ printTime: 3, weightG: 40 }, { durationS: 10800, filamentGrams: null });
  assert.equal(c.actualHours, 3);
  assert.equal(c.hoursDeltaPct, 0, 'bang on, and we know it');
  assert.equal(c.gramsDeltaPct, null, 'and nothing is claimed about weight');
  assert.equal(c.measured, true);
});

test('a missing estimate does not produce a percentage of nothing', () => {
  const c = compareToEstimate({ printTime: 0, weightG: 0 }, { durationS: 3600, filamentGrams: 10 });
  assert.equal(c.actualHours, 1, 'the measurement still stands on its own');
  assert.equal(c.hoursDeltaPct, null, 'but a delta against zero is meaningless');
  assert.equal(c.gramsDeltaPct, null);
  assert.doesNotThrow(() => compareToEstimate(null, null));
});

test('an under-run reports as negative', () => {
  const c = compareToEstimate({ printTime: 4, weightG: 100 }, { durationS: 7200, filamentGrams: 50 });
  assert.equal(c.hoursDeltaPct, -50);
  assert.equal(c.gramsDeltaPct, -50);
});

/* ============================================================
   What the completion dialog should offer
   ============================================================ */

const NOW = 1_700_000_000_000;
const EST = { printTime: 3, weightG: 40 };
const completion = (actuals, ageMs = 60_000, filename = 'bracket.gcode') =>
  ({ at: NOW - ageMs, filename, actuals });
const MEASURED = { filamentGrams: 41.83, durationS: 11560, source: 'moonraker' };

test('the dialog offers the MEASUREMENT, not the estimate again', () => {
  // The whole reason this exists. Pre-filling from the estimate meant a shop
  // that hit confirm recorded the estimate twice and reported no variance.
  const p = prefillActuals({ estimate: EST, completion: completion(MEASURED), now: NOW });
  assert.equal(p.timeH, 3.21);
  assert.equal(p.weightG, 41.8);
  assert.equal(p.timeMeasured, true);
  assert.equal(p.weightMeasured, true);
  assert.equal(p.measured, true);
  assert.equal(p.source, 'moonraker');
  assert.equal(p.filename, 'bracket.gcode');
  assert.notEqual(p.timeH, EST.printTime, 'it is not the estimate');
});

test('with nothing measured it falls back to the estimate and SAYS so', () => {
  const p = prefillActuals({ estimate: EST, completion: null, now: NOW });
  assert.equal(p.timeH, 3);
  assert.equal(p.weightG, 40);
  assert.equal(p.measured, false, 'the estimate must never be labelled measured');
  assert.equal(p.timeMeasured, false);
  assert.equal(p.weightMeasured, false);
  assert.equal(p.staleReason, 'nothing-measured');
});

test('a stale completion is not offered for today\'s order', () => {
  // The shop has run other jobs since. Offering those figures would attach one
  // print's cost to another print's order.
  const p = prefillActuals({ estimate: EST, completion: completion(MEASURED, COMPLETION_MAX_AGE_MS + 1), now: NOW });
  assert.equal(p.measured, false);
  assert.equal(p.staleReason, 'too-old');
  assert.equal(p.timeH, 3, 'back to the estimate');

  // Just inside the window is still good.
  const fresh = prefillActuals({ estimate: EST, completion: completion(MEASURED, COMPLETION_MAX_AGE_MS - 1000), now: NOW });
  assert.equal(fresh.measured, true);
});

test('a completion stamped in the future is refused', () => {
  // Clock skew between the shop's machine and… itself, after a time change.
  const p = prefillActuals({ estimate: EST, completion: completion(MEASURED, -60_000), now: NOW });
  assert.equal(p.measured, false);
  assert.equal(p.staleReason, 'too-old');
});

test('a printer that measures only time gives a MIXED answer', () => {
  // PrusaLink reports duration and no filament. Claiming the weight was measured
  // would be a lie; discarding the time would throw away a real measurement.
  const p = prefillActuals({
    estimate: EST,
    completion: completion({ filamentGrams: null, durationS: 10_800, source: 'prusalink' }),
    now: NOW,
  });
  assert.equal(p.timeH, 3);
  assert.equal(p.timeMeasured, true, 'the time IS measured');
  assert.equal(p.weightG, 40, 'the weight falls back to the estimate');
  assert.equal(p.weightMeasured, false, 'and is not called measured');
  assert.equal(p.measured, true);
});

test('a printer that measures only WEIGHT gives the mirror answer', () => {
  // The other half of the mixed case: filament reported, duration missing (an
  // OctoPrint whose progress block came back without printTime). The time field
  // must not inherit the weight's "measured" label.
  const p = prefillActuals({
    estimate: EST,
    completion: completion({ filamentGrams: 41.83, durationS: null, source: 'octoprint' }),
    now: NOW,
  });
  assert.equal(p.weightG, 41.8);
  assert.equal(p.weightMeasured, true);
  assert.equal(p.timeH, 3, 'the time falls back to the estimate');
  assert.equal(p.timeMeasured, false, 'and must not borrow the weight\'s label');
  assert.equal(p.measured, true);
});

test('a completion carrying no usable figures is not offered', () => {
  for (const a of [null, {}, { filamentGrams: 0, durationS: 0 }, { filamentGrams: null, durationS: null }]) {
    const p = prefillActuals({ estimate: EST, completion: completion(a), now: NOW });
    assert.equal(p.measured, false, JSON.stringify(a));
    assert.equal(p.staleReason, 'nothing-measured', JSON.stringify(a));
  }
});

test('a missing estimate does not become a zero to confirm', () => {
  const p = prefillActuals({ estimate: {}, completion: null, now: NOW });
  assert.equal(p.timeH, null);
  assert.equal(p.weightG, null);
  assert.equal(p.measured, false);
});

test('prefill tolerates junk', () => {
  assert.doesNotThrow(() => prefillActuals(null));
  assert.doesNotThrow(() => prefillActuals({}));
  const p = prefillActuals({ estimate: EST, completion: { actuals: MEASURED }, now: NOW });
  assert.equal(p.measured, false, 'a completion with no timestamp cannot be aged');
});

test('measured is never true while both fields are estimates', () => {
  // The invariant the dialog\'s label depends on.
  const cases = [
    prefillActuals({ estimate: EST, completion: null, now: NOW }),
    prefillActuals({ estimate: EST, completion: completion(null), now: NOW }),
    prefillActuals({ estimate: EST, completion: completion(MEASURED, COMPLETION_MAX_AGE_MS * 2), now: NOW }),
  ];
  for (const p of cases) {
    assert.equal(p.measured, p.timeMeasured || p.weightMeasured);
    assert.equal(p.measured, false);
  }
});
