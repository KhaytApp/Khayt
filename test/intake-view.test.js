/**
 * How a read file is PRESENTED — the branch that can cost a shop money.
 *
 * lib/model-intake.js decides whether a number came from a slicer or from
 * geometry. If that distinction is lost on the way to the screen, a shop quotes
 * an estimate as though it were a sliced figure and eats the difference. So the
 * assertions here are mostly about wording and emphasis, not arithmetic.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { presentIntake, riskNote } = require('../lib/intake-view.js');
const { estimateFromStl } = require('../lib/stl-estimate.js');

const CUBE = { volumeMm3: 8000, areaMm2: 2400, bbox: { x: 20, y: 20, z: 20 }, triangleCount: 12 };
const opts = { infillPct: 0.2, estimate: estimateFromStl };
const keys = (v) => v.note.map((l) => l.key);

test('a slicer result is applied and named as the slicer\'s own figures', () => {
  const v = presentIntake({
    exact: true, source: 'slicer', printTimeMins: 193, filamentGrams: 41.83,
    slicer: 'PrusaSlicer', filamentType: 'PLA', filename: 'part.3mf',
  }, opts);
  assert.equal(v.mode, 'exact');
  assert.equal(v.weightG, 41.8);
  assert.equal(v.timeH, 3.22, '193 min → 3.22 h');
  assert.deepEqual(keys(v), ['intake.exact']);
  assert.equal(v.note[0].vars.slicer, 'PrusaSlicer');
  assert.equal(v.toast.kind, 'success');
  assert.equal(v.material, 'PLA');
  // The estimate wording must be nowhere near an exact result.
  assert.ok(!keys(v).some((k) => k.includes('estimate')), 'not called an estimate');
});

test('a geometry result is labelled an estimate, emphasised, before any number', () => {
  const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, opts);
  assert.equal(v.mode, 'estimate');
  assert.equal(v.note[0].key, 'intake.estimate_head');
  assert.equal(v.note[0].strong, true, 'the caveat is emphasised');
  assert.ok(keys(v).includes('intake.estimate_advice'), 'and says what to do about it');
  assert.equal(v.toast.kind, 'info', 'not a success — nothing was measured');
  assert.equal(v.material, null, 'no material is claimed from geometry alone');
  assert.ok(v.weightG > 0 && v.timeH > 0, 'but it still fills the form');
});

test('the caveat comes FIRST, so it cannot be missed', () => {
  // A reader who stops after one line must already know this is not measured.
  const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, opts);
  const headIdx = keys(v).indexOf('intake.estimate_head');
  const numbersIdx = keys(v).indexOf('stl.note_tpl');
  assert.ok(headIdx < numbersIdx, `caveat at ${headIdx}, numbers at ${numbersIdx}`);
});

test('exact is not honoured without both numbers', () => {
  // A truthy `exact` with a missing half would fill the form with a zero. The
  // flag alone is not trusted.
  const timeOnly = presentIntake({ exact: true, source: 'slicer', printTimeMins: 120, filamentGrams: null }, opts);
  assert.notEqual(timeOnly.mode, 'exact');
  const gramsOnly = presentIntake({ exact: true, source: 'slicer', printTimeMins: 0, filamentGrams: 10 }, opts);
  assert.notEqual(gramsOnly.mode, 'exact');
});

test('the note and the form field are rounded identically', () => {
  // If the note says 41.8 g and the field holds 41.83, the shop cannot tell
  // which one the price used.
  const v = presentIntake({
    exact: true, source: 'slicer', printTimeMins: 193, filamentGrams: 41.83, slicer: 'Orca',
  }, opts);
  assert.equal(v.note[0].vars.grams, v.weightG);
  assert.equal(v.note[0].vars.time, v.timeH);

  const e = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, opts);
  const tpl = e.note.find((l) => l.key === 'stl.note_tpl');
  assert.equal(tpl.vars.weight, e.weightG);
  assert.equal(tpl.vars.time, e.timeH);
});

test('a missing slicer name is left for the caller to fill, not blanked', () => {
  const v = presentIntake({ exact: true, source: 'slicer', printTimeMins: 60, filamentGrams: 5 }, opts);
  assert.equal(v.note[0].vars.slicer, null, 'null signals "substitute a default"');
});

test('the shop\'s infill drives the estimate', () => {
  const low = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, { ...opts, infillPct: 0.05 });
  const high = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, { ...opts, infillPct: 0.9 });
  assert.ok(high.weightG > low.weightG, `${high.weightG} should exceed ${low.weightG}`);
  const shown = (v) => v.note.find((l) => l.key === 'stl.note_assume').vars.infill;
  assert.equal(shown(low), 5);
  assert.equal(shown(high), 90);
});

test('an unreadable file explains which kind of unreadable', () => {
  const noSummary = presentIntake({ exact: false, source: null, warnings: ['no-slicer-summary'] }, opts);
  assert.equal(noSummary.mode, 'none');
  assert.equal(noSummary.toast.key, 'intake.no_summary');

  const unsupported = presentIntake({ exact: false, source: null, warnings: ['unsupported'] }, opts);
  assert.equal(unsupported.toast.key, 'intake.unsupported');

  /* The one kind of unreadable with an action attached, and it was the one
   * being reported as "could not read that file" — which reads as a BROKEN
   * file, so the shop re-exports a file that was never the problem. */
  const tooLarge = presentIntake({ ok: false, error: 'File too large (max 150 MB)',
    warnings: ['too-large'], filename: 'huge.3mf' }, opts);
  assert.equal(tooLarge.mode, 'none');
  assert.equal(tooLarge.toast.key, 'intake.too_large');

  const other = presentIntake({ exact: false, source: null, warnings: ['parse-failed'] }, opts);
  assert.equal(other.toast.key, 'calc.parse_failed');

  for (const bad of [null, undefined, {}]) {
    const v = presentIntake(bad, opts);
    assert.equal(v.mode, 'none', String(bad));
    assert.equal(v.weightG, null, 'and never invents a number');
  }
});

test('geometry with no estimator available degrades to "none", not to a raw volume', () => {
  // If stl-estimate did not load, showing 8000 mm3 in a grams field would be a
  // catastrophic misread. Better to say nothing.
  const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, { infillPct: 0.2 });
  assert.equal(v.mode, 'none');
  assert.equal(v.weightG, null);
});

test('a zero-volume mesh is not priced as a free part', () => {
  const v = presentIntake({ exact: false, source: 'geometry', geometry: { volumeMm3: 0, bbox: { x: 0, y: 0, z: 0 } } }, opts);
  assert.equal(v.mode, 'none');
});

/* ---- The options must actually arrive ---------------------------------
 * These exist because every test above passes an `opts` holding nothing but
 * `infillPct` and `estimate`, so none of them could notice that presentIntake
 * forwarded only the infill and dropped the rest. It did, and the calculator
 * quoted every unsliced file on the module defaults — PLA at 1.24 g/cm³ and a
 * shipped throughput — no matter what the shop had configured or measured.
 * ---------------------------------------------------------------------- */

test('the shop\'s density reaches the estimate, not just its infill', () => {
  const light = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, densityGPerCm3: 1.04 });          // ABS
  const heavy = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, densityGPerCm3: 4.0 });           // a filled filament
  assert.ok(heavy.weightG > light.weightG * 3,
    `density is being ignored: ${heavy.weightG} vs ${light.weightG}`);
  // And the note must quote the shop's figure, not the default it fell back to.
  const shown = (v) => v.note.find((l) => l.key === 'stl.note_assume').vars.density;
  assert.equal(shown(light), 1.04);
  assert.equal(shown(heavy), 4.0);
});

test('the shop\'s wall thickness reaches the estimate', () => {
  const thin = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, wallThicknessMm: 0.4 });
  const thick = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, wallThicknessMm: 3.6 });
  assert.ok(thick.weightG > thin.weightG,
    `wall thickness is being ignored: ${thick.weightG} vs ${thin.weightG}`);
});

test('a calibrated throughput changes the TIME and leaves the weight alone', () => {
  // The whole point of lib/estimate-calibration.js: only the time was ever
  // guessed. A calibration that moved the weight would be changing an answer
  // nobody asked it to.
  const base = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, opts);
  const slow = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, throughputMm3PerS: 2.7, calibratedFrom: { scope: 'shop', jobs: 4 } });
  assert.ok(slow.timeH > base.timeH,
    `a slower measured rate must mean a longer job: ${slow.timeH} vs ${base.timeH}`);
  assert.equal(slow.weightG, base.weightG, 'calibration must not touch the weight');
});

test('a measured rate and a guessed one never read the same', () => {
  const guessed = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, opts);
  const measured = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, throughputMm3PerS: 2.7, calibratedFrom: { scope: 'shop', jobs: 4 } });

  const keyOf = (v) => v.note.map((l) => l.key).find((k) => k.startsWith('stl.note_rate_'));
  assert.equal(keyOf(guessed), 'stl.note_rate_assumed');
  assert.equal(keyOf(measured), 'stl.note_rate_measured_shop');
  assert.notEqual(keyOf(guessed), keyOf(measured));

  // The count is what makes "measured" checkable rather than a claim.
  const line = measured.note.find((l) => l.key.startsWith('stl.note_rate_measured'));
  assert.equal(line.vars.n, 4);
});

test('the note says WHICH printers earned the rate', () => {
  // A rate this machine earned describes it. A shop-wide one is other printers'
  // history standing in for it — the same number, honestly weaker. Presenting
  // them identically overstates what the second one knows.
  const keyOf = (v) => v.note.map((l) => l.key).find((k) => k.startsWith('stl.note_rate_'));

  const own = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'machine', jobs: 5 } });
  assert.equal(keyOf(own), 'stl.note_rate_measured_machine');

  const pooled = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'shop', jobs: 5 } });
  assert.equal(keyOf(pooled), 'stl.note_rate_measured_shop');

  assert.notEqual(keyOf(own), keyOf(pooled), 'the two claims must not read the same');
  // Same rate, same job count — only the provenance differs, so nothing but the
  // scope may account for the different wording.
  assert.equal(own.calibrated.gramsPerHour, pooled.calibrated.gramsPerHour);
  assert.equal(own.calibrated.scope, 'machine');
  assert.equal(pooled.calibrated.scope, 'shop');
});

test('the rate is reported with how far the jobs behind it disagreed', () => {
  // The overclaim this exists to stop: "27 g/h — measured from 12 jobs on this
  // printer" reads as a machine specification, and grams-per-hour is not one.
  // Measured on one real printer it ran 1.9 → 48.6 g/h across 67 jobs, tracking
  // the part rather than the machine. The median stays; the certainty goes.
  const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'machine', jobs: 12, spread: 0.12 } });
  const line = v.note.find((l) => l.key.startsWith('stl.note_rate_'));
  assert.equal(line.key, 'stl.note_rate_spread_machine');
  assert.equal(line.vars.pct, 12, 'the spread is shown as a percentage');
  assert.equal(line.vars.n, 12);
  assert.equal(v.calibrated.spreadPct, 12, 'and is on the structured result too');

  const shop = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'shop', jobs: 12, spread: 0.34 } });
  assert.equal(shop.note.find((l) => l.key.startsWith('stl.note_rate_')).key,
    'stl.note_rate_spread_shop');
});

test('a wider spread is reported as wider, not rounded away', () => {
  // The whole point is that the shop can tell 12% from 34%.
  const pct = (s) => presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'machine', jobs: 20, spread: s } })
    .note.find((l) => l.key.startsWith('stl.note_rate_')).vars.pct;
  assert.equal(pct(0.12), 12);
  assert.equal(pct(0.34), 34);
  assert.ok(pct(0.34) > pct(0.12), 'a wider spread must read as wider');
  // A spread too small to round to a whole percent must not read as "exactly",
  // which is the one thing measured data never is.
  assert.equal(pct(0.001), 1, 'floors at 1%, never 0');
});

test('a calibration with no spread falls back rather than inventing certainty', () => {
  // Older stored calibrations, or any caller that supplies none, must not be
  // rendered as "give or take 0%".
  for (const bad of [undefined, null, NaN]) {
    const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
      { ...opts, calibratedFrom: { scope: 'machine', jobs: 6, spread: bad } });
    const line = v.note.find((l) => l.key.startsWith('stl.note_rate_'));
    assert.equal(line.key, 'stl.note_rate_measured_machine', String(bad));
    assert.equal(v.calibrated.spreadPct, null, String(bad));
  }
});

test('each history the rate came from reads as a different claim', () => {
  // "Three prints of this exact model with these settings" is worth more than
  // "your printers, on average". Presenting them alike would waste the only
  // distinction that makes a narrow rate worth computing.
  const keyFor = (scope) => presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope, jobs: 4, spread: 0.1 } })
    .note.find((l) => l.key.startsWith('stl.note_rate_')).key;

  assert.equal(keyFor('setup'), 'stl.note_rate_spread_setup');
  assert.equal(keyFor('file'), 'stl.note_rate_spread_file');
  assert.equal(keyFor('machine'), 'stl.note_rate_spread_machine');
  assert.equal(keyFor('shop'), 'stl.note_rate_spread_shop');
  assert.equal(new Set(['setup', 'file', 'machine', 'shop'].map(keyFor)).size, 4,
    'four scopes, four distinct strings');
});

test('the narrow scopes also survive having no spread', () => {
  const keyFor = (scope) => presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope, jobs: 4 } })
    .note.find((l) => l.key.startsWith('stl.note_rate_')).key;
  assert.equal(keyFor('setup'), 'stl.note_rate_measured_setup');
  assert.equal(keyFor('file'), 'stl.note_rate_measured_file');
});

test('the structured result carries the narrow scope too', () => {
  const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'file', jobs: 3, spread: 0.05 } });
  assert.equal(v.calibrated.scope, 'file');
  assert.equal(v.calibrated.jobs, 3);
});

test('an unrecognised scope claims the weaker of the two', () => {
  // calibrate() only ever returns 'machine' or 'shop', but a claim to describe
  // one printer must be earned explicitly — anything else falls back to the
  // shop-wide wording rather than overstating.
  for (const scope of [undefined, null, '', 'workshop', 'MACHINE']) {
    const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
      { ...opts, calibratedFrom: { scope, jobs: 3 } });
    const key = v.note.map((l) => l.key).find((k) => k.startsWith('stl.note_rate_'));
    assert.equal(key, 'stl.note_rate_measured_shop', `scope=${JSON.stringify(scope)}`);
  }
});

test('the rate in the note is the rate the time was built on', () => {
  // Shown in grams per hour because that is the only form a shop can measure;
  // the estimator works in mm3/s. If these drift apart the note is describing a
  // different estimate from the one in the form.
  const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, densityGPerCm3: 1.24, throughputMm3PerS: 2.7, calibratedFrom: { scope: 'shop', jobs: 5 } });
  const line = v.note.find((l) => l.key.startsWith('stl.note_rate_measured'));
  assert.equal(line.vars.rate, Math.round(1.24 * 2.7 * 3.6 * 10) / 10);
  assert.equal(v.calibrated.gramsPerHour, line.vars.rate, 'the structured figure and the prose agree');
});

test('provenance is structured, not only prose', () => {
  // A caller styling the block, and a test asserting on it, must not have to
  // parse a translated sentence.
  const guessed = presentIntake({ exact: false, source: 'geometry', geometry: CUBE }, opts);
  assert.equal(guessed.calibrated, null);

  const measured = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
    { ...opts, calibratedFrom: { scope: 'machine', jobs: 6 } });
  assert.equal(measured.calibrated.scope, 'machine');
  assert.equal(measured.calibrated.jobs, 6);
});

test('a calibration nobody earned is not presented as measured', () => {
  // calibrate() returns null rather than a zero-job result, but the renderer
  // spreads whatever it is given — a malformed marker must not upgrade a guess.
  for (const bad of [{ scope: 'shop', jobs: 0 }, { scope: 'shop' }, {}]) {
    const v = presentIntake({ exact: false, source: 'geometry', geometry: CUBE },
      { ...opts, calibratedFrom: bad });
    assert.equal(v.calibrated, null, JSON.stringify(bad));
    assert.ok(v.note.some((l) => l.key === 'stl.note_rate_assumed'), JSON.stringify(bad));
  }
});

test('mode never claims more certainty than the source supports', () => {
  // The invariant the UI depends on.
  const cases = [
    { exact: true, source: 'slicer', printTimeMins: 100, filamentGrams: 10 },
    { exact: false, source: 'geometry', geometry: CUBE },
    { exact: false, source: null, warnings: ['unsupported'] },
  ];
  for (const c of cases) {
    const v = presentIntake(c, opts);
    if (v.mode === 'exact') assert.equal(c.source, 'slicer');
    if (v.mode === 'estimate') assert.equal(c.source, 'geometry');
    if (v.mode !== 'exact') {
      assert.ok(!v.note.some((l) => l.key === 'intake.exact'),
        'only an exact result may use the exact wording');
    }
  }
});

/*
 * The break-risk lines.
 *
 * They come AFTER the price, never instead of it: the shop asked what this
 * costs and must get an answer. "There are overhangs" is the second thing they
 * need, not a reason to withhold the first.
 */

test('risk lines carry their own measurement, so the reader can disagree', () => {
  const lines = riskNote({
    risk: {
      risks: [
        { id: 'overhang', severity: 'warn', fraction: 0.235, thresholdDeg: 45 },
        { id: 'bridge', severity: 'warn', fraction: 0.09 },
      ],
    },
  });
  assert.equal(lines[0].key, 'risk.head');
  assert.equal(lines[0].strong, true, 'the heading must stand out from the estimate above it');

  const over = lines.find((l) => l.key === 'risk.overhang');
  assert.equal(over.vars.pct, 24, '23.5% rounds to 24');
  assert.equal(over.vars.deg, 45, 'the shop’s own support angle travels with the line');

  const bridge = lines.find((l) => l.key === 'risk.bridge');
  assert.equal(bridge.vars.pct, 9);
});

test('a wall too thin to print reads differently from one that is merely thin', () => {
  const crit = riskNote({ risk: { risks: [
    { id: 'thin', severity: 'crit', meanThicknessMm: 0.18, nozzleDiameter: 0.4, bores: 0.45 },
  ] } });
  assert.equal(crit[1].key, 'risk.thin_crit');
  assert.equal(crit[1].strong, true, 'unprintable must not read as a footnote');
  assert.equal(crit[1].vars.mm, 0.18);
  assert.equal(crit[1].vars.nozzle, 0.4);

  const warn = riskNote({ risk: { risks: [
    { id: 'thin', severity: 'warn', meanThicknessMm: 0.71, nozzleDiameter: 0.4, bores: 1.775 },
  ] } });
  assert.equal(warn[1].key, 'risk.thin');
  assert.ok(!warn[1].strong);
  assert.equal(warn[1].vars.bores, 1.8);
});

test('a clean model says nothing at all — no heading over an empty list', () => {
  assert.deepEqual(riskNote({ risk: { risks: [], worst: null } }), []);
  assert.deepEqual(riskNote({ risk: null }), []);
  assert.deepEqual(riskNote({}), []);
  assert.deepEqual(riskNote(null), []);
  assert.deepEqual(riskNote({ risk: { risks: 'nonsense' } }), []);
});

test('the estimate keeps its own note, and the risks are appended after it', () => {
  // Regression on the ordering: a shop that drops a file wants the number first.
  const res = {
    source: 'geometry', exact: false, filename: 'x.stl', geometry: CUBE,
    risk: { risks: [{ id: 'overhang', severity: 'warn', fraction: 0.2, thresholdDeg: 45 }] },
  };
  const view = presentIntake(res, opts);
  assert.equal(view.mode, 'estimate');
  const keys = view.note.map((l) => l.key);
  assert.equal(keys[0], 'intake.estimate_head', 'the estimate must still lead');
  assert.ok(keys.indexOf('risk.head') > keys.indexOf('intake.estimate_advice'),
    'the risks were put ahead of the price the shop asked for');
});
