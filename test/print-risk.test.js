const { test } = require('node:test');
const assert = require('node:assert/strict');
const R = require('../lib/print-risk.js');

/*
 * A part can be priced perfectly and still fail on the plate, and a failed print
 * costs the filament, the hours and the delivery date. This module asks the
 * question the estimator does not.
 *
 * Two kinds of test below, deliberately.
 *
 * The geometry is SYNTHETIC and hand-computable — a cube, a plate, a wedge at a
 * known angle, a roof with a known ceiling. For those the right answer is
 * arithmetic, not opinion, so they pin the maths exactly rather than to a
 * tolerance somebody chose.
 *
 * The THRESHOLDS are not arithmetic, so those tests are anchored on the figures
 * measured across ~60 real models on the bench (functional parts, printer
 * spares, figurines, vases, wall-thickness coupons). The corpus is too big to
 * commit; the numbers it produced are recorded here as the cases that must keep
 * landing on the right side of each line.
 */

/* ── hand-built geometry ────────────────────────────────────────────────── */

/** Axis-aligned box as 12 triangles, wound outward (positive signed volume). */
function box(x0, y0, z0, x1, y1, z1) {
  const v = [
    [x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0],
    [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1],
  ];
  const q = (a, b, c, d) => [[v[a], v[b], v[c]], [v[a], v[c], v[d]]];
  return [
    ...q(0, 3, 2, 1),   // bottom (normal −Z)
    ...q(4, 5, 6, 7),   // top    (normal +Z)
    ...q(0, 1, 5, 4),   // −Y
    ...q(2, 3, 7, 6),   // +Y
    ...q(1, 2, 6, 5),   // +X
    ...q(0, 4, 7, 3),   // −X
  ];
}

const reverse = (tris) => tris.map(([a, b, c]) => [a, c, b]);

test('overhang angle follows the slicer convention, not an invented one', () => {
  // −n.z is the sine of the angle the SURFACE makes with vertical.
  assert.equal(R.overhangDegFor(0), null, 'a vertical wall is not an overhang');
  assert.equal(R.overhangDegFor(0.9), null, 'an upward face is not an overhang');
  assert.ok(Math.abs(R.overhangDegFor(-1) - 90) < 1e-9, 'a flat ceiling is a 90° overhang');
  assert.ok(Math.abs(R.overhangDegFor(-Math.SQRT1_2) - 45) < 1e-9, 'a 45° underside');
  assert.ok(Math.abs(R.overhangDegFor(-0.5) - 30) < 1e-9);
});

test('a cube on the plate has no overhang at all — its only downward face is the bed', () => {
  const a = R.analyzeTriangles(box(0, 0, 0, 10, 10, 10));
  assert.equal(a.totalAreaMm2, 600, '6 faces × 100 mm²');
  assert.equal(a.volumeMm3, 1000);
  assert.equal(a.bedContactAreaMm2, 100, 'the bottom face is 100 mm² and all of it is on the plate');
  assert.equal(R.overhangAreaAbove(a, 45), 0, 'the bed was counted as an overhang');
  assert.equal(R.overhangAreaAbove(a, 0), 0);
  assert.equal(a.windingFlipped, false);
});

test('the model’s own lowest point IS the plate, the way a slicer treats it', () => {
  // A model sitting at z=5 in the file is dropped onto the bed before it prints,
  // so its underside is a first layer and not a ceiling. Reading z=0 as the plate
  // instead would report every model authored above the origin as one enormous
  // bridge — which is a property of the file, not of the part.
  const a = R.analyzeTriangles(box(0, 0, 5, 10, 10, 15));
  assert.equal(a.bedZ, 5);
  assert.equal(a.bedContactAreaMm2, 100, 'the dropped underside is the first layer');
  assert.equal(R.overhangAreaAbove(a, 45), 0);
});

test('a slab held up over something lower is a bridge', () => {
  // A pad on the plate establishes where the bed is; the slab above it then has
  // nothing under its 100 mm² underside, which is the difference between a first
  // layer and a ceiling.
  const pad = box(0, 0, 0, 2, 2, 1);
  const slab = box(0, 0, 8, 10, 10, 10);
  const a = R.analyzeTriangles([...pad, ...slab]);

  assert.equal(a.bedZ, 0);
  assert.equal(a.bedContactAreaMm2, 4, 'only the pad is on the plate');
  assert.equal(R.overhangAreaAbove(a, 80), 100, 'the slab underside is a 100 mm² ceiling');
  assert.equal(R.overhangAreaAbove(a, 45), 100, 'a ceiling is also an overhang');

  // KNOWN LIMIT, and worth pinning as behaviour rather than discovering later:
  // this counts triangles, it does not slice. Where two solids overlap, the part
  // of an underside actually resting on the solid below is still counted as
  // ceiling — the 4 mm² above the pad here. A single watertight manifold, which
  // is what most real models are, has no such surface; a model assembled from
  // overlapping primitives over-reports by however much they overlap.
  assert.equal(R.overhangAreaAbove(a, 89), 100, 'the whole slab underside reads as ceiling, pad included');
});

test('the answer does not depend on which way the mesh is wound', () => {
  // A real file from the bench (aaa-dispenser.stl) had an inverted winding, and
  // an uncorrected reading would report its TOP faces as overhangs — precisely
  // backwards, and silently.
  const shape = [...box(0, 0, 0, 2, 2, 1), ...box(0, 0, 8, 10, 10, 10)];
  const forward = R.analyzeTriangles(shape);
  const backward = R.analyzeTriangles(reverse(shape));

  assert.equal(backward.windingFlipped, true, 'an inverted winding was not detected');
  assert.equal(forward.windingFlipped, false);
  // …and having detected it, both readings agree on the physical facts.
  assert.equal(backward.downwardAreaMm2, forward.downwardAreaMm2);
  assert.equal(backward.bedContactAreaMm2, forward.bedContactAreaMm2);
  assert.equal(R.overhangAreaAbove(backward, 80), R.overhangAreaAbove(forward, 80));
  assert.equal(backward.volumeMm3, forward.volumeMm3, 'volume is unsigned either way');
});

test('a 45° underside lands on 45°, and a support threshold either side of it decides', () => {
  // A cantilever leaning out: the cross-section in X–Z is the right triangle
  // (0,0) → (0,10) → (10,10), extruded 10 in Y. Its hypotenuse is an UNDERSIDE
  // descending at exactly 45°, area 10 × 10√2. (A ramp resting on the plate has
  // the same hypotenuse facing UP and is correctly no overhang at all — which is
  // the shape this test was first written with, and it found nothing.)
  const v = [
    [0, 0, 0], [0, 0, 10], [10, 0, 10],      // y = 0
    [0, 10, 0], [0, 10, 10], [10, 10, 10],   // y = 10
  ];
  const p = [
    [v[0], v[2], v[1]],                                  // −Y end
    [v[3], v[4], v[5]],                                  // +Y end
    [v[0], v[1], v[4]], [v[0], v[4], v[3]],              // vertical back, x = 0
    [v[1], v[2], v[5]], [v[1], v[5], v[4]],              // top, z = 10
    [v[0], v[3], v[5]], [v[0], v[5], v[2]],              // the 45° underside
  ];
  const a = R.analyzeTriangles(p);
  const slope = 10 * 10 * Math.SQRT2;
  assert.equal(a.volumeMm3, 500, 'the hand-built prism is not the shape it claims to be');
  assert.equal(a.windingFlipped, false, 'the hand-built winding is inconsistent');

  // Everything at or below 45° is caught; nothing steeper exists.
  assert.ok(Math.abs(R.overhangAreaAbove(a, 44) - slope) < 1e-6, 'the 45° face was missed at a 44° threshold');
  assert.equal(R.overhangAreaAbove(a, 46), 0, 'a 45° face was reported as steeper than 46°');
  assert.equal(R.overhangAreaAbove(a, 80), 0, 'a 45° slope is not a bridge');
});

/* ── mean wall thickness ────────────────────────────────────────────────── */

test('2V/A is the real thickness of a plate, and a size scale for a lump', () => {
  // A 100 × 100 × 1 plate: V = 10,000, A = 2·10,000 + 4·100 = 20,400.
  const plate = box(0, 0, 0, 100, 100, 1);
  const pa = R.analyzeTriangles(plate);
  assert.equal(pa.volumeMm3, 10000);
  assert.equal(pa.totalAreaMm2, 20400);
  const t = R.meanThicknessMm(pa.volumeMm3, pa.totalAreaMm2);
  assert.ok(Math.abs(t - 0.980) < 0.001, `expected ~0.98 mm, got ${t}`);

  // A solid cube is not "thin" in any sense, and must not read as though it were.
  const cube = R.analyzeTriangles(box(0, 0, 0, 10, 10, 10));
  assert.ok(R.meanThicknessMm(cube.volumeMm3, cube.totalAreaMm2) > 3);

  assert.equal(R.meanThicknessMm(0, 100), null, 'no volume is not a thickness of zero');
  assert.equal(R.meanThicknessMm(100, 0), null);
});

/* ── the thresholds, against what the bench corpus actually measured ─────── */

/** An analysis stub with a chosen fraction of its area beyond `deg`. */
function withOverhang(fractionAt45, fractionAt80, totalAreaMm2 = 1000) {
  const hist = new Float64Array(91);
  hist[85] = fractionAt80 * totalAreaMm2;
  hist[50] = (fractionAt45 - fractionAt80) * totalAreaMm2;
  return { totalAreaMm2, histogram: hist, volumeMm3: totalAreaMm2 * 10, windingFlipped: false };
}
const ids = (r) => r.risks.map((x) => x.id).sort();

test('a print-ready functional part raises nothing', () => {
  // Measured on the bench: clips, brackets, panels and trays sit at 0–2% overhang.
  const r = R.assessModel({ analysis: withOverhang(0.02, 0.005), nozzleDiameter: 0.4 });
  assert.deepEqual(ids(r), [], `a clean part was flagged: ${JSON.stringify(r.risks)}`);
  assert.equal(r.worst, null);
});

test('a figurine is flagged as needing support, and says how much', () => {
  // Bench figures: an elephant 23.5%, a Sly Cooper van 20.2%, a dino body 13.6%.
  const r = R.assessModel({ analysis: withOverhang(0.235, 0.09), nozzleDiameter: 0.4 });
  assert.ok(ids(r).includes('overhang'));
  const o = r.risks.find((x) => x.id === 'overhang');
  assert.equal(o.severity, 'warn');
  assert.ok(Math.abs(o.fraction - 0.235) < 1e-9, 'the measurement must travel with the finding');
  assert.equal(o.thresholdDeg, 45);
  // 9% near-horizontal is over the bridge line too, and is reported apart from
  // the slope: a 50° face prints rough, a ceiling droops.
  assert.ok(ids(r).includes('bridge'));
});

test('a slope and a ceiling are never folded into one number', () => {
  // 20% overhang but almost none of it horizontal — a slanted part, not a
  // cantilever. Flagging it as a bridge would be a false alarm the operator has
  // to disprove by hand.
  const r = R.assessModel({ analysis: withOverhang(0.20, 0.01), nozzleDiameter: 0.4 });
  assert.ok(ids(r).includes('overhang'));
  assert.ok(!ids(r).includes('bridge'), 'a sloped part was called a bridge');
});

test('the shop’s own support angle is what decides, not ours', () => {
  // PrusaSlicer ships 55°, Cura 45°. A shop set to 55° genuinely has less to
  // support, and the report must answer THEIR question.
  const hist = new Float64Array(91);
  hist[50] = 200;            // 20% of area, between 45° and 55°
  const analysis = { totalAreaMm2: 1000, histogram: hist, volumeMm3: 10000, windingFlipped: false };

  const at45 = R.assessModel({ analysis, supportThresholdDeg: 45 });
  assert.ok(ids(at45).includes('overhang'));
  assert.equal(at45.supportThresholdDeg, 45);

  const at55 = R.assessModel({ analysis, supportThresholdDeg: 55 });
  assert.ok(!ids(at55).includes('overhang'), 'a 50° face was reported to a shop that supports past 55°');
});

test('thin is measured against the nozzle, because that part has a physical answer', () => {
  const thin = (mm) => ({
    analysis: { totalAreaMm2: 1000, histogram: new Float64Array(91), windingFlipped: false },
    geometry: { volumeMm3: (mm * 1000) / 2, areaMm2: 1000 },
  });
  // Below one bore, nothing can lay it down at all. Bench: a Hitem3d mesh at 0.18 mm.
  const crit = R.assessModel({ ...thin(0.18), nozzleDiameter: 0.4 });
  assert.equal(crit.risks.find((x) => x.id === 'thin').severity, 'crit');
  assert.equal(crit.worst, 'crit');

  // A 0.8 mm wall-thickness coupon measures 0.71 mm mean — printable, but only if
  // the slicer has been set up for it. `warn` is the right answer, not `crit`.
  const warn = R.assessModel({ ...thin(0.71), nozzleDiameter: 0.4 });
  assert.equal(warn.risks.find((x) => x.id === 'thin').severity, 'warn');

  // Ordinary parts measured 1.5–10 mm and must stay silent.
  assert.equal(R.assessModel({ ...thin(2.35), nozzleDiameter: 0.4 }).risks.length, 0);

  // A bigger nozzle moves the line, because the line IS the nozzle.
  const big = R.assessModel({ ...thin(0.71), nozzleDiameter: 0.8 });
  assert.equal(big.risks.find((x) => x.id === 'thin').severity, 'crit');
});

/* ── does it fit ────────────────────────────────────────────────────────── */

test('a part that only needs turning is not reported as too big', () => {
  const analysis = { totalAreaMm2: 1000, histogram: new Float64Array(91), windingFlipped: false };
  const geometry = { volumeMm3: 100000, areaMm2: 1000, bbox: { x: 300, y: 100, z: 50 } };
  const bed = { x: 200, y: 350, z: 250 };

  const r = R.assessModel({ analysis, geometry, bed });
  assert.ok(!ids(r).includes('bed'), 'a part that fits when turned was called too big');
  assert.ok(ids(r).includes('bed-rotate'));
  assert.equal(r.worst, 'info');
});

test('too tall is too tall, whichever way it is turned', () => {
  const analysis = { totalAreaMm2: 1000, histogram: new Float64Array(91), windingFlipped: false };
  const geometry = { volumeMm3: 100000, areaMm2: 1000, bbox: { x: 100, y: 100, z: 400 } };
  const r = R.assessModel({ analysis, geometry, bed: { x: 250, y: 250, z: 250 } });
  const bedRisk = r.risks.find((x) => x.id === 'bed');
  assert.equal(bedRisk.severity, 'crit');
  assert.equal(bedRisk.tooTall, true);

  // No bed given is not the same as a bed that fits: say nothing.
  assert.ok(!ids(R.assessModel({ analysis, geometry })).includes('bed'));
});

/* ── input hygiene ──────────────────────────────────────────────────────── */

test('a broken or empty mesh returns an answer instead of throwing', () => {
  for (const bad of [null, undefined, [], [null], [[[0, 0, 0]]], [[[0, 0, 0], [0, 0, 0], [0, 0, 0]]]]) {
    const a = R.analyzeTriangles(bad);
    assert.equal(a.totalAreaMm2, 0);
    assert.equal(R.overhangAreaAbove(a, 45), 0);
    const r = R.assessModel({ analysis: a });
    assert.ok(Array.isArray(r.risks));
  }
  // A zero-area sliver has no normal to speak of and must not be counted as one.
  const withSliver = R.analyzeTriangles([...box(0, 0, 0, 10, 10, 10), [[0, 0, 0], [1, 1, 1], [2, 2, 2]]]);
  assert.equal(withSliver.degenerateTriangles, 1);
  assert.equal(withSliver.totalAreaMm2, 600, 'a degenerate triangle changed the surface area');

  assert.deepEqual(R.assessModel(undefined).risks, []);
  assert.equal(R.overhangAreaAbove(null, 45), 0);
});

test('an open mesh falls back to the plate rather than to a meaningless volume', () => {
  // Signed volume is only meaningful for a closed mesh. For a bare sheet it is
  // ~0 and its SIGN is noise — so the orientation is decided by which way round
  // puts more area on the build plate, which is a physical fact either way.
  const sheet = [
    [[0, 0, 0], [10, 0, 0], [10, 10, 0]],
    [[0, 0, 0], [10, 10, 0], [0, 10, 0]],
  ];
  const a = R.analyzeTriangles(sheet);
  assert.equal(a.windingFromVolume, false, 'a flat sheet has no trustworthy signed volume');
  assert.equal(a.bedContactAreaMm2, 100, 'the sheet is lying on the plate');
  assert.equal(R.overhangAreaAbove(a, 45), 0, 'a sheet on the plate is not an overhang');

  // Wound the other way it is the same sheet on the same plate, and must read the same.
  const flipped = R.analyzeTriangles(reverse(sheet));
  assert.equal(flipped.bedContactAreaMm2, 100);
  assert.equal(R.overhangAreaAbove(flipped, 45), 0);
});

/* ============================================================
   WHEN the mesh gets walked
   ============================================================ */

test('a shop that has chosen nothing gets the walk on demand', () => {
  // The walk is seconds on a real file. Defaulting to `import` would add an
  // hour to a four-hundred-model import to answer a question nobody asked
  // about 399 of them.
  assert.equal(R.riskWhen({}), 'demand');
  assert.equal(R.riskWhen(null), 'demand');
  assert.equal(R.riskWhen({ printRisk: {} }), 'demand');
  assert.equal(R.analyseAtImport({}), false);
});

test('a shop can ask for it at import', () => {
  assert.equal(R.riskWhen({ printRisk: { when: 'import' } }), 'import');
  assert.equal(R.analyseAtImport({ printRisk: { when: 'import' } }), true);
});

test('the settings object can be handed over whole or unwrapped', () => {
  // One host holds `settings`, the other holds the root that contains it.
  // Reading it two different ways is how the two of them come to disagree.
  assert.equal(R.riskWhen({ settings: { printRisk: { when: 'import' } } }), 'import');
});

test('an unrecognised value is on demand, not at import', () => {
  // A field synced down from a build that spells it differently, or a typo in
  // a hand-edited store. Failing towards `import` would silently add an hour
  // to the next import; failing towards `demand` costs one click.
  for (const v of ['later', 'always', 'IMPORTS', '', null, 0, true, {}]) {
    assert.equal(R.riskWhen({ printRisk: { when: v } }), 'demand',
      `${JSON.stringify(v)} was not treated as on demand`);
  }
});

test('the value is read the way a person would type it', () => {
  assert.equal(R.riskWhen({ printRisk: { when: '  IMPORT ' } }), 'import');
  assert.equal(R.riskWhen({ printRisk: { when: 'Demand' } }), 'demand');
});

test('every allowed value is one the reader accepts', () => {
  // A list a settings screen renders from, and a reader that rejects one of its
  // own entries, is a chooser with a dead option in it.
  for (const v of R.RISK_WHEN) assert.equal(R.riskWhen({ printRisk: { when: v } }), v);
  assert.ok(R.RISK_WHEN.includes(R.DEFAULT_RISK_WHEN));
});
