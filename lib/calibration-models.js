'use strict';
/**
 * The Calibration Assistant's tests and test models, with no DOM.
 *
 * renderer/calibration.js (Bed Ready's assistant) holds the same tables and the same procedural
 * STL generator inline. The native Mac app runs this module instead, and
 * test/calibration-models.test.js holds the two to the same answers — every test, every material,
 * byte for byte — so the Mac cannot hand a maker a different tower than the desktop does.
 *
 * Pure: no require, no Buffer, no process. Loaded by Node and by JavaScriptCore.
 */
(function (global) {
  // Per-material recommended temperature range [start, end, step] (°C) and a typical
  // first-layer / print speed hint. Approximate starting points — adjust to your setup.
  const MATERIALS = {
    'PLA':  { temp: [190, 220, 5], bed: 60,  speed: 60 },
    'PLA+': { temp: [195, 225, 5], bed: 60,  speed: 60 },
    'PETG': { temp: [220, 250, 5], bed: 80,  speed: 45 },
    'ABS':  { temp: [230, 260, 5], bed: 100, speed: 45 },
    'ASA':  { temp: [235, 265, 5], bed: 100, speed: 45 },
    'TPU':  { temp: [210, 235, 5], bed: 40,  speed: 25 },
    'Nylon':{ temp: [240, 270, 5], bed: 80,  speed: 40 },
  };

  const TESTS = {
    temp: {
      name: 'Temperature tower',
      blurb: 'Find the temperature with the best layer bonding, surface and bridging.',
      model: 'tower',
      steps: (m) => {
        const [a, b, s] = MATERIALS[m].temp;
        const n = Math.floor((b - a) / s) + 1;
        return [
          `Slice the tower and add a temperature change every band (${Math.round(80 / n)} mm ÷ ${n} bands).`,
          `Sweep ${a} °C → ${b} °C in ${s} °C steps (top = coolest or hottest, your call).`,
          'Print, then pick the band with the cleanest surface and strongest overhang.',
          'Record the winning temperature below.',
        ];
      },
      sweep: (m) => { const [a, b, s] = MATERIALS[m].temp; return `${a}–${b} °C · ${s} °C steps`; },
    },
    flow: {
      name: 'Flow / extrusion multiplier',
      blurb: 'Correct over/under-extrusion so walls are exactly the right thickness.',
      model: 'cube',
      steps: () => [
        'Print the hollow calibration cube in vase / single-wall mode.',
        'Measure the wall thickness with calipers (aim = your nozzle line width, e.g. 0.42 mm).',
        'New flow = current flow × (target ÷ measured). Re-slice and verify.',
      ],
      sweep: () => 'measure wall → adjust flow %',
    },
    retraction: {
      name: 'Retraction',
      blurb: 'Kill stringing between separated features.',
      model: 'towers2',
      steps: () => [
        'Print the two-pillar test; watch for strings across the gap.',
        'Sweep retraction distance 0.5–2 mm (direct) or 3–7 mm (Bowden) in 0.5 mm steps.',
        'Pick the shortest distance with no strings; too much causes clogs.',
      ],
      sweep: () => 'direct 0.5–2 mm · Bowden 3–7 mm · 0.5 mm steps',
    },
    firstlayer: {
      name: 'First layer',
      blurb: 'Dial in Z-offset and squish for a perfect, well-adhered base.',
      model: 'patch',
      steps: () => [
        'Print the flat patch; live-tune Z-offset while the first layer lays down.',
        'Lines should touch with no gaps and no ridging.',
        'Save the Z-offset once the surface is smooth and even.',
      ],
      sweep: () => 'live-tune Z-offset (~±0.05 mm)',
    },
    xyz: {
      name: 'XYZ dimensional cube',
      blurb: 'Check X/Y/Z accuracy and steps-per-mm.',
      model: 'cube',
      steps: () => [
        'Print the 20 mm cube at your tuned temperature.',
        'Measure each axis with calipers; each should read 20.00 mm.',
        'If an axis is off, adjust that axis’ steps/mm by (20 ÷ measured).',
      ],
      sweep: () => 'target 20.00 mm per axis',
    },
  };

  // ---- procedural ASCII STL ----------------------------------------------------
  function boxTris(x0, y0, z0, x1, y1, z1) {
    const v = (x, y, z) => [x, y, z];
    const q = (n, a, b, c, d) => [{ n, v: [a, b, c] }, { n, v: [a, c, d] }];
    let t = [];
    t = t.concat(q([0, 0, -1], v(x0, y0, z0), v(x1, y0, z0), v(x1, y1, z0), v(x0, y1, z0)));   // bottom
    t = t.concat(q([0, 0, 1],  v(x0, y0, z1), v(x0, y1, z1), v(x1, y1, z1), v(x1, y0, z1)));   // top
    t = t.concat(q([0, -1, 0], v(x0, y0, z0), v(x0, y0, z1), v(x1, y0, z1), v(x1, y0, z0)));   // front
    t = t.concat(q([0, 1, 0],  v(x0, y1, z0), v(x1, y1, z0), v(x1, y1, z1), v(x0, y1, z1)));   // back
    t = t.concat(q([-1, 0, 0], v(x0, y0, z0), v(x0, y1, z0), v(x0, y1, z1), v(x0, y0, z1)));   // left
    t = t.concat(q([1, 0, 0],  v(x1, y0, z0), v(x1, y0, z1), v(x1, y1, z1), v(x1, y1, z0)));   // right
    return t;
  }
  function stlFromTris(tris, name) {
    const f = (x) => (Math.round(x * 1000) / 1000).toString();
    let s = `solid ${name}\n`;
    for (const tr of tris) {
      s += `facet normal ${f(tr.n[0])} ${f(tr.n[1])} ${f(tr.n[2])}\nouter loop\n`;
      for (const p of tr.v) s += `vertex ${f(p[0])} ${f(p[1])} ${f(p[2])}\n`;
      s += `endloop\nendfacet\n`;
    }
    return s + `endsolid ${name}\n`;
  }
  function buildModel(kind, material) {
    if (kind === 'cube') return stlFromTris(boxTris(0, 0, 0, 20, 20, 20), 'xyz_cube');
    if (kind === 'patch') return stlFromTris(boxTris(0, 0, 0, 60, 60, 0.3), 'first_layer_patch');
    if (kind === 'towers2') {
      let t = boxTris(0, 0, 0, 8, 8, 40).concat(boxTris(18, 0, 0, 26, 8, 40));   // two pillars
      t = t.concat(boxTris(0, 3, 38, 26, 5, 40));                                 // top bridge
      return stlFromTris(t, 'retraction_test');
    }
    // temperature tower — a stepped staircase so each band steps back (overhang test)
    const [a, b, s] = (MATERIALS[material] || MATERIALS.PLA).temp;
    const bands = Math.max(2, Math.floor((b - a) / s) + 1);
    const bandH = 8;
    let t = [];
    for (let i = 0; i < bands; i++) {
      const depth = 20 - i * (12 / bands);   // front steps back each band
      t = t.concat(boxTris(0, 0, i * bandH, 40, depth, (i + 1) * bandH));
      // a small overhang tab off the front of each band
      t = t.concat(boxTris(5, depth, i * bandH + bandH - 2, 35, depth + 6, i * bandH + bandH));
    }
    return stlFromTris(t, 'temp_tower');
  }

  /** What one test says, for one material: the screen's text and the model's file name. */
  function describe(test, material) {
    const T = TESTS[test] || TESTS.temp;
    const key = TESTS[test] ? test : 'temp';
    const m = MATERIALS[material] ? material : 'PLA';
    const steps = T.steps(m);
    return {
      test: key, material: m, name: T.name, blurb: T.blurb, model: T.model,
      sweep: T.sweep(m), steps,
      plan: `${T.name} — ${m}\nSweep: ${T.sweep(m)}\n` + steps.map((s, i) => `${i + 1}. ${s}`).join('\n'),
      fileName: `${key}-${m.replace(/[^a-z0-9]+/gi, '')}.stl`.toLowerCase(),
    };
  }

  /** The test model's STL text for a test and a material. */
  function modelFor(test, material) {
    const d = describe(test, material);
    return buildModel(d.model, d.material);
  }

  /**
   * The row the result log keeps, newest first in settings.calibrationLog — the shape
   * renderer/calibration.js writes. `now` is an ISO timestamp; the id is the desktop's 'CAL' + ms.
   */
  function logEntry(test, material, result, nowIso, nowMs) {
    const d = describe(test, material);
    return { id: 'CAL' + nowMs, test: d.name, material: d.material, result: String(result || '').trim(), date: nowIso };
  }

  const api = {
    MATERIALS, TESTS, materials: Object.keys(MATERIALS), tests: Object.keys(TESTS),
    boxTris, stlFromTris, buildModel, describe, modelFor, logEntry,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytCalibrationModels = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
