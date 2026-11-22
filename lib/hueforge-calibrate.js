/**
 * HueForge · U1 — CALIBRATION from a printed card (KhaytHueForgeCalibrate).
 *
 * The painting engine (lib/hueforge.js) composites thin layers with one number per
 * filament, its transmission distance (TD), and one colour, the hex the maker typed. Both
 * are guesses: `defaultTd` derives TD from lightness, and the hex is whatever the spool
 * label said. Two "reds" layer completely differently, so a guess is where the muddy
 * prints come from. This module measures both from a photograph of a small printed card.
 *
 * ── THE CARD ─────────────────────────────────────────────────────────────────────────
 * One row per loaded filament F. A row is two runs of cells, each run printed over a
 * different BACKING filament (A and B): a bare backing cell, then cells with 1, 2, 3 … layers
 * of F on top of that backing. A frame in the darkest filament surrounds the card, with a
 * small square of the lightest filament in its top-left corner so the photo's orientation
 * is never in doubt. Everything is axis-aligned boxes, the same shape the flat mode
 * already exports (`buildFlatU1_3mf`), so the card prints from the same zero-slicer file.
 *
 * ── THE MATHS ────────────────────────────────────────────────────────────────────────
 * The engine's model, front-lit: k layers of F over a backing X read as
 *     R = (1 − t)·C + t·X,     t = 0.1^(k·h / TD)
 * where C is F's own colour and t the share of the backing still showing. Over two backings
 * at the same k, C cancels:  R_A − R_B = t·(A − B), so t is measured directly, per channel,
 * with A and B taken from the bare cells in the SAME photo — the backing's real colour, not
 * its label. Then C = (R − t·X)/(1 − t), and TD falls out of a least-squares line through
 * the origin of log10(t) against thickness. Exposure and white balance scale every patch
 * alike, so t is immune to them; C is not, which is why the lightest filament's stated hex
 * is used to set a per-channel gain (`whiteRef`).
 *
 * The TD measured this way is FRONT-LIT, which is what a hung picture shows. The engine
 * keeps TDs in backlit terms and scales them by `tdScale` (default 0.2, the "vividness"
 * control at 9), so the stored value is the front-lit TD divided by that default: at the
 * default vividness the engine then reproduces exactly what the card measured.
 *
 * Clean-room: the approach (two-backing step wedge, Beer–Lambert fit) is textbook optics;
 * no code, constants or data were taken from Lumina Layers, HueForge or AutoForge.
 *
 * Pure geometry + colour maths; no DOM. Uses lib/color-mix (KhaytColor) for Lab/ΔE.
 */
(function (global) {
  'use strict';

  const KC = (typeof module !== 'undefined' && module.exports)
    ? require('./color-mix.js')
    : (global && global.KhaytColor);
  const FLAT = (typeof module !== 'undefined' && module.exports)
    ? require('./hueforge-flat.js')
    : (global && global.KhaytHueForgeFlat);

  const DEFAULT_TD_SCALE = 0.2;           // lib/hueforge.js compositeSequence's default
  const DEFAULTS = {
    layerH: 0.08,
    steps: [1, 2, 3, 4, 6, 9, 13],         // layers of F per cell — 0.08 … 1.04 mm at 0.08
    cellMm: 8,
    gapMm: 4,                              // between the A run and the B run
    frameMm: 5,
    backingMm: 0.8,
    rowGapMm: 2,
  };
  const TD_MIN = 0.3, TD_MAX = 20;         // the panel's own clamp (renderer/hueforge.js)

  // ---- colour space ----------------------------------------------------------------

  const toLin = (v) => { const c = v / 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const toSrgb = (l) => {
    const c = l <= 0.0031308 ? 12.92 * l : 1.055 * Math.pow(Math.max(0, l), 1 / 2.4) - 0.055;
    return Math.max(0, Math.min(255, Math.round(c * 255)));
  };
  function hexToLin(hex) {
    const rgb = KC && KC.hexToRgb(hex);
    return rgb ? [toLin(rgb.r), toLin(rgb.g), toLin(rgb.b)] : null;
  }
  function linToHex(l) {
    return '#' + l.map((v) => toSrgb(v).toString(16).padStart(2, '0')).join('').toUpperCase();
  }
  const lum = (l) => 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2];

  // ---- the card --------------------------------------------------------------------

  /**
   * Choose two backings for filament i: the pair of OTHER filaments furthest apart in
   * luminance, because t is read from their difference and a small difference is noise.
   * With only one other filament there is one backing; `fitFilament` handles that.
   */
  function pickBackings(lins, i) {
    const others = lins.map((l, j) => j).filter((j) => j !== i && lins[j]);
    if (!others.length) return [];
    if (others.length === 1) return [others[0]];
    let best = null;
    for (let a = 0; a < others.length; a++) {
      for (let b = a + 1; b < others.length; b++) {
        const d = Math.abs(lum(lins[others[a]]) - lum(lins[others[b]]));
        if (!best || d > best.d) best = { d, pair: [others[a], others[b]] };
      }
    }
    // Lighter backing first, so every row reads the same way round.
    return best.pair.sort((p, q) => lum(lins[q]) - lum(lins[p]));
  }

  /**
   * Lay the card out. `filaments` is the loaded set, indexed by head (≤4 on the U1), each a
   * hex string or `{ hex }`. Coordinates are mm with the origin at the card's TOP-LEFT and y
   * growing DOWN — the way the photo is read; `buildCardParts` flips y for the printer.
   */
  function planCard(filaments, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const hexes = (filaments || []).map((f) => String((f && f.hex) || f || '').toUpperCase());
    const lins = hexes.map(hexToLin);
    if (lins.filter(Boolean).length < 2) return null;
    const steps = o.steps.filter((k) => Number.isInteger(k) && k > 0);
    const runCells = steps.length + 1;                      // the bare backing + each step
    const runW = runCells * o.cellMm;
    const width = 2 * o.frameMm + 2 * runW + o.gapMm;

    let dark = 0, light = 0;
    lins.forEach((l, j) => { if (!l) return; if (lum(l) < lum(lins[dark] || [1, 1, 1])) dark = j; if (lum(l) > lum(lins[light] || [0, 0, 0])) light = j; });

    const rows = [];
    const cells = [];
    let y = o.frameMm;
    hexes.forEach((hex, i) => {
      if (!lins[i]) return;
      const backs = pickBackings(lins, i);
      if (!backs.length) return;
      rows.push({ head: i, hex, backings: backs.slice() });
      backs.forEach((bh, run) => {
        const x0 = o.frameMm + run * (runW + o.gapMm);
        [0].concat(steps).forEach((k, c) => {
          cells.push({ row: rows.length - 1, head: i, backing: bh, run, layers: k,
            x0: x0 + c * o.cellMm, y0: y, x1: x0 + (c + 1) * o.cellMm, y1: y + o.cellMm });
        });
      });
      y += o.cellMm + o.rowGapMm;
    });
    if (!rows.length) return null;
    const height = y - o.rowGapMm + o.frameMm;
    return {
      sizeMm: { x: width, y: height }, layerH: o.layerH, steps, backingMm: o.backingMm,
      frameMm: o.frameMm, filaments: hexes, frameHead: dark, markHead: light,
      rows, cells,
    };
  }

  /**
   * The card as printable parts `{ head, hex, triangles }` for `buildFlatU1_3mf`. The frame
   * (and every gap between cells) is one slab in the darkest filament at backing height;
   * each cell is its backing pad plus, above it, k layers of the row's filament.
   */
  function buildCardParts(plan) {
    if (!plan || !FLAT) return null;
    const H = plan.sizeMm.y;
    const box = FLAT.boxTris;
    const byHead = new Map();
    const add = (head, x0, y0, z0, x1, y1, z1) => {
      if (!(z1 > z0)) return;
      if (!byHead.has(head)) byHead.set(head, []);
      // Photo coordinates have y down; the bed has y up.
      for (const t of box(x0, H - y1, z0, x1, H - y0, z1)) byHead.get(head).push(t);
    };
    const b = plan.backingMm;
    // The frame: four strips around the cells, plus the strips between rows and runs. It is
    // simplest — and exactly as printable — as the complement of the cell rectangles, built
    // here as a coarse grid of the gaps.
    const xs = new Set([0, plan.sizeMm.x]), ys = new Set([0, H]);
    for (const c of plan.cells) { xs.add(c.x0); xs.add(c.x1); ys.add(c.y0); ys.add(c.y1); }
    const X = [...xs].sort((p, q) => p - q), Y = [...ys].sort((p, q) => p - q);
    const covered = (x, y) => plan.cells.some((c) => x > c.x0 && x < c.x1 && y > c.y0 && y < c.y1);
    const f = plan.frameMm;
    for (let i = 0; i + 1 < X.length; i++) {
      for (let j = 0; j + 1 < Y.length; j++) {
        const cx = (X[i] + X[i + 1]) / 2, cy = (Y[j] + Y[j + 1]) / 2;
        if (covered(cx, cy)) continue;
        // The orientation mark: the top-left frame corner in the lightest filament.
        const mark = cx < f && cy < f && plan.markHead !== plan.frameHead;
        add(mark ? plan.markHead : plan.frameHead, X[i], Y[j], 0, X[i + 1], Y[j + 1], b);
      }
    }
    for (const c of plan.cells) {
      add(c.backing, c.x0, c.y0, 0, c.x1, c.y1, b);
      add(c.head, c.x0, c.y0, b, c.x1, c.y1, b + c.layers * plan.layerH);
    }
    const parts = [...byHead.entries()].map(([head, triangles]) => ({ head, hex: plan.filaments[head], triangles }));
    const zMax = plan.backingMm + Math.max(...plan.steps) * plan.layerH;
    return { parts, filaments: plan.filaments, sizeMm: { x: plan.sizeMm.x, y: H, z: zMax }, baseHead: plan.frameHead };
  }

  // ---- reading the photo -----------------------------------------------------------

  /** Solve an n×n linear system by Gaussian elimination with partial pivoting. */
  function solve(A, bv) {
    const n = bv.length;
    const M = A.map((row, i) => row.concat([bv[i]]));
    for (let c = 0; c < n; c++) {
      let p = c;
      for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
      if (Math.abs(M[p][c]) < 1e-12) return null;
      [M[c], M[p]] = [M[p], M[c]];
      for (let r = 0; r < n; r++) {
        if (r === c) continue;
        const k = M[r][c] / M[c][c];
        for (let q = c; q <= n; q++) M[r][q] -= k * M[c][q];
      }
    }
    return M.map((row, i) => row[n] / row[i]);
  }

  /**
   * The projective map taking four points `src` to four points `dst` (each `[x, y]`).
   * Returns a function (x, y) → [x', y'], or null when the corners are degenerate.
   */
  function homography(src, dst) {
    if (!Array.isArray(src) || !Array.isArray(dst) || src.length !== 4 || dst.length !== 4) return null;
    const A = [], bv = [];
    for (let i = 0; i < 4; i++) {
      const [x, y] = src[i], [u, v] = dst[i];
      A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); bv.push(u);
      A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); bv.push(v);
    }
    const h = solve(A, bv);
    if (!h || h.some((v) => !Number.isFinite(v))) return null;
    return (x, y) => {
      const w = h[6] * x + h[7] * y + 1;
      return [(h[0] * x + h[1] * y + h[2]) / w, (h[3] * x + h[4] * y + h[5]) / w];
    };
  }

  /**
   * Sample every cell of `plan` from a photo. `img` is `{ data, width, height }` (RGBA, as
   * from a canvas); `corners` are the card's four outer corners in photo pixels, in the order
   * top-left, top-right, bottom-right, bottom-left (top-left is the light mark). Each cell is
   * read as the per-channel MEDIAN of its inner half — the median shrugs off a glint or a
   * stray hair, and the inner half keeps clear of the step edges. Returns linear RGB.
   */
  function sampleCells(img, corners, plan) {
    if (!img || !img.data || !plan) return null;
    const { x: W, y: H } = plan.sizeMm;
    const map = homography([[0, 0], [W, 0], [W, H], [0, H]], corners);
    if (!map) return null;
    const LUT = new Float64Array(256);
    for (let v = 0; v < 256; v++) LUT[v] = toLin(v);
    return plan.cells.map((c) => {
      const r = [], g = [], bl = [];
      const mx = (c.x1 - c.x0) / 4, my = (c.y1 - c.y0) / 4;
      const N = 9;
      for (let i = 0; i < N; i++) {
        for (let j = 0; j < N; j++) {
          const x = c.x0 + mx + (2 * mx) * (i / (N - 1));
          const y = c.y0 + my + (2 * my) * (j / (N - 1));
          const [px, py] = map(x, y);
          const ix = Math.round(px), iy = Math.round(py);
          if (ix < 0 || iy < 0 || ix >= img.width || iy >= img.height) continue;
          const o = (iy * img.width + ix) * 4;
          r.push(LUT[img.data[o]]); g.push(LUT[img.data[o + 1]]); bl.push(LUT[img.data[o + 2]]);
        }
      }
      const med = (a) => { if (!a.length) return NaN; a.sort((p, q) => p - q); return a[a.length >> 1]; };
      return Object.assign({}, c, { lin: [med(r), med(g), med(bl)] });
    });
  }

  // ---- the fit ---------------------------------------------------------------------

  /**
   * Per-channel gain that makes the bare cells of the lightest filament read as its stated
   * hex. Corrects exposure and white balance for C; t never needed it.
   */
  function whiteRef(samples, plan) {
    const ref = hexToLin(plan.filaments[plan.markHead]);
    const bare = samples.filter((s) => s.layers === 0 && s.backing === plan.markHead && s.lin.every(Number.isFinite));
    if (!ref || !bare.length) return [1, 1, 1];
    return [0, 1, 2].map((ch) => {
      const m = bare.reduce((a, s) => a + s.lin[ch], 0) / bare.length;
      return m > 1e-4 ? ref[ch] / m : 1;
    });
  }

  /**
   * Fit one filament from its row's samples. Returns
   *   { head, hex, tdFront, td, residual, steps, warnings[] }
   * `hex` is the measured colour, `td` is in the engine's backlit units (see the header),
   * `residual` the mean ΔE2000 between the card and the model's prediction of it.
   */
  function fitFilament(rowSamples, layerH, gain) {
    const g = gain || [1, 1, 1];
    const fix = (l) => l.map((v, ch) => v * g[ch]);
    const runs = new Map();
    for (const s of rowSamples) {
      if (!s.lin.every(Number.isFinite)) continue;
      if (!runs.has(s.run)) runs.set(s.run, { bare: null, steps: new Map() });
      const run = runs.get(s.run);
      if (s.layers === 0) run.bare = fix(s.lin); else run.steps.set(s.layers, fix(s.lin));
    }
    const R = [...runs.values()].filter((r) => r.bare);
    const warnings = [];
    if (!R.length) return null;
    const ks = [...new Set(R.flatMap((r) => [...r.steps.keys()]))].sort((a, b) => a - b);

    // t per step.
    const ts = new Map();
    if (R.length >= 2) {
      const [A, B] = R;
      const diff = [0, 1, 2].map((ch) => A.bare[ch] - B.bare[ch]);
      const wsum = diff.reduce((a, d) => a + d * d, 0);
      if (wsum < 0.01) warnings.push('low-contrast-backings');
      for (const k of ks) {
        const ra = A.steps.get(k), rb = B.steps.get(k);
        if (!ra || !rb || wsum < 1e-6) continue;
        // Weighted least squares over channels: t = Σ d·(ra−rb) / Σ d².
        let num = 0;
        for (let ch = 0; ch < 3; ch++) num += diff[ch] * (ra[ch] - rb[ch]);
        ts.set(k, Math.max(0, Math.min(1, num / wsum)));
      }
    } else {
      // One backing: assume the thickest step is opaque enough to BE the colour, and read t
      // from how far each thinner step still leans toward the backing.
      warnings.push('one-backing');
      const A = R[0], Cthick = A.steps.get(ks[ks.length - 1]);
      const diff = [0, 1, 2].map((ch) => A.bare[ch] - Cthick[ch]);
      const wsum = diff.reduce((a, d) => a + d * d, 0);
      for (const k of ks) {
        const r = A.steps.get(k);
        if (!r || wsum < 1e-6) continue;
        let num = 0;
        for (let ch = 0; ch < 3; ch++) num += diff[ch] * (r[ch] - Cthick[ch]);
        ts.set(k, Math.max(0, Math.min(1, num / wsum)));
      }
    }

    // TD: log10(t) = −(k·h)/TD, a line through the origin. Steps where t is pinned at 0 or 1
    // carry no slope, only noise.
    let sxx = 0, sxy = 0, used = 0;
    for (const [k, t] of ts) {
      if (t <= 0.02 || t >= 0.97) continue;
      const x = k * layerH, yv = Math.log10(t);
      sxx += x * x; sxy += x * yv; used++;
    }
    let tdFront;
    if (used && sxy < 0) tdFront = -sxx / sxy;
    else {
      const tVals = [...ts.values()];
      const hMin = ks[0] * layerH, hMax = ks[ks.length - 1] * layerH;
      if (tVals.length && tVals.every((t) => t <= 0.02)) { warnings.push('too-opaque'); tdFront = hMin; }
      else if (tVals.length && tVals.every((t) => t >= 0.97)) { warnings.push('too-translucent'); tdFront = hMax * 4; }
      else return null;
    }
    if (used < 2 && !warnings.includes('too-opaque') && !warnings.includes('too-translucent')) warnings.push('few-steps');

    // C: average of (R − t·X)/(1 − t) over every step and run, weighted by (1 − t) — the
    // thicker the layer, the less the backing contributes and the better C is seen.
    const acc = [0, 0, 0];
    let wC = 0;
    for (const run of R) {
      for (const [k, r] of run.steps) {
        const t = 0.1 ** (k * layerH / tdFront);
        if (t > 0.7) continue;
        const w = 1 - t;
        for (let ch = 0; ch < 3; ch++) acc[ch] += w * ((r[ch] - t * run.bare[ch]) / (1 - t));
        wC += w;
      }
    }
    if (!wC) {
      const thick = R[0].steps.get(ks[ks.length - 1]);
      for (let ch = 0; ch < 3; ch++) acc[ch] = thick[ch];
      wC = 1;
    }
    const C = acc.map((v) => Math.max(0, Math.min(1, v / wC)));
    const hex = linToHex(C);

    // How well does the fitted model reproduce the card?
    let de = 0, n = 0;
    for (const run of R) {
      for (const [k, r] of run.steps) {
        const t = 0.1 ** (k * layerH / tdFront);
        const pred = C.map((c, ch) => (1 - t) * c + t * run.bare[ch]);
        de += KC.deltaE(linToHex(pred), linToHex(r)); n++;
      }
    }
    const residual = n ? Math.round((de / n) * 10) / 10 : null;
    if (residual != null && residual > 6) warnings.push('poor-fit');

    const td = Math.round(Math.max(TD_MIN, Math.min(TD_MAX, tdFront / DEFAULT_TD_SCALE)) * 10) / 10;
    return { hex, tdFront: Math.round(tdFront * 1000) / 1000, td, residual, steps: used, warnings };
  }

  /**
   * The whole read: photo + corners + plan → one result per row, indexed like the loaded
   * filaments. `{ results: [{ head, statedHex, hex, td, … }], gain }` or null.
   */
  function measureCard(img, corners, plan) {
    const samples = sampleCells(img, corners, plan);
    if (!samples) return null;
    const gain = whiteRef(samples, plan);
    const results = plan.rows.map((row, ri) => {
      const fit = fitFilament(samples.filter((s) => s.row === ri), plan.layerH, gain);
      return fit ? Object.assign({ head: row.head, statedHex: row.hex }, fit) : { head: row.head, statedHex: row.hex, error: 'unreadable' };
    });
    return { results, gain };
  }

  const api = {
    DEFAULTS, DEFAULT_TD_SCALE, planCard, buildCardParts, pickBackings,
    homography, sampleCells, whiteRef, fitFilament, measureCard, hexToLin, linToHex,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else if (global) global.KhaytHueForgeCalibrate = api;
})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this));
