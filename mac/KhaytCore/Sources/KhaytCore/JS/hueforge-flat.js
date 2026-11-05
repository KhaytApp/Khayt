'use strict';
/**
 * HueForge · U1 — FLAT multicolor mode (KhaytHueForgeFlat).
 *
 * The U1 is a 4-toolhead TOOLCHANGER with no purge waste on a tool change, so it can print
 * flat, solid, in-layer multicolor for free — a smooth poster/plaque where each XY region
 * is one opaque filament. That sidesteps the whole height-relief problem class (surface
 * texture, transmission physics, TD calibration, top-surface speckle): there is no relief
 * and no light mixing, just quantize the image to ≤4 colors and assign each color region to
 * a toolhead.
 *
 * Pipeline: k-means quantize → label field → despeckle (drop sub-nozzle islands) → greedy
 * rectangle meshing per color → a flat plate whose base is one solid slab and whose top
 * ~capMm is split into one mesh PART per color (each part → an extruder). The 3MF assembler
 * — `buildFlatU1_3mf` in lib/hueforge-3mf.js — welds each part and tags it with its head.
 *
 * `planFlat` output feeds that function directly: `{ parts, filaments, sizeMm, baseHead }`.
 * What is still missing is a caller: nothing in the app loads this module or offers the
 * mode, so the pipeline runs end to end only from its tests.
 *
 * Pure geometry + colour maths; no DOM. Uses lib/color-mix (KhaytColor) for hex/lab.
 */
(function (global) {
  const KC = () => (typeof require === 'function' ? require('./color-mix') : global.KhaytColor);

  function hex2(v) { const s = Math.max(0, Math.min(255, Math.round(v))).toString(16); return s.length < 2 ? '0' + s : s; }
  function rgbHex(r, g, b) { return ('#' + hex2(r) + hex2(g) + hex2(b)).toUpperCase(); }
  function lum(r, g, b) { return 0.2126 * r + 0.7152 * g + 0.0722 * b; }

  /** Area-averaging downsample of an RGBA image to ≤ maxW wide (keeps aspect). */
  function downsample(img, maxW) {
    const { data, width: W, height: H } = img;
    if (W <= maxW) return { data: data.slice(), width: W, height: H };
    const w = maxW, h = Math.max(1, Math.round(H * maxW / W));
    const out = new Uint8ClampedArray(w * h * 4);
    for (let y = 0; y < h; y++) {
      const sy0 = Math.floor(y * H / h), sy1 = Math.max(sy0 + 1, Math.floor((y + 1) * H / h));
      for (let x = 0; x < w; x++) {
        const sx0 = Math.floor(x * W / w), sx1 = Math.max(sx0 + 1, Math.floor((x + 1) * W / w));
        let r = 0, g = 0, b = 0, a = 0, n = 0;
        for (let sy = sy0; sy < sy1; sy++) for (let sx = sx0; sx < sx1; sx++) {
          const o = (sy * W + sx) * 4; r += data[o]; g += data[o + 1]; b += data[o + 2]; a += data[o + 3]; n++;
        }
        const o = (y * w + x) * 4; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n; out[o + 3] = a / n;
      }
    }
    return { data: out, width: w, height: h };
  }

  /**
   * K-means quantise to K colours in RGB. Deterministic (seeded, evenly-sampled init) so a
   * re-solve on every preview render never flickers. Returns { palette:[{r,g,b,hex}],
   * labels:Int32Array, width, height }. `fixed` = optional array of {r,g,b} the user pinned
   * (their loaded spools) — those centroids are kept, only the rest move.
   */
  function quantize(img, K, fixed) {
    const { data, width: W, height: H } = img;
    const N = W * H;
    K = Math.max(1, Math.min(8, K | 0));
    const cs = [];
    const pinned = Math.min(K, (fixed && fixed.length) || 0);
    for (let i = 0; i < pinned; i++) cs.push([fixed[i].r, fixed[i].g, fixed[i].b]);
    for (let i = pinned; i < K; i++) { const j = Math.floor((i + 0.5) / K * N); cs.push([data[j * 4], data[j * 4 + 1], data[j * 4 + 2]]); }
    const labels = new Int32Array(N);
    for (let it = 0; it < 16; it++) {
      let moved = false;
      for (let i = 0; i < N; i++) {
        const r = data[i * 4], g = data[i * 4 + 1], b = data[i * 4 + 2];
        let bd = Infinity, bj = 0;
        for (let j = 0; j < K; j++) { const dr = r - cs[j][0], dg = g - cs[j][1], db = b - cs[j][2]; const d = dr * dr + dg * dg + db * db; if (d < bd) { bd = d; bj = j; } }
        if (labels[i] !== bj) { labels[i] = bj; moved = true; }
      }
      const sum = []; for (let j = 0; j < K; j++) sum.push([0, 0, 0, 0]);
      for (let i = 0; i < N; i++) { const j = labels[i], o = i * 4; sum[j][0] += data[o]; sum[j][1] += data[o + 1]; sum[j][2] += data[o + 2]; sum[j][3]++; }
      for (let j = pinned; j < K; j++) if (sum[j][3]) { cs[j] = [sum[j][0] / sum[j][3], sum[j][1] / sum[j][3], sum[j][2] / sum[j][3]]; }
      if (!moved && it > 0) break;
    }
    const palette = cs.map((c) => ({ r: Math.round(c[0]), g: Math.round(c[1]), b: Math.round(c[2]), hex: rgbHex(c[0], c[1], c[2]) }));
    return { palette, labels, width: W, height: H };
  }

  /**
   * Mode (majority) filter on the label field: any cell whose label is a minority in its
   * (2R+1)² neighbourhood snaps to the local majority. Removes sub-nozzle colour specks and
   * ragged single-pixel edges that would print as noise (and, on a toolchanger, waste swap
   * time). Two passes. Returns a new Int32Array.
   */
  function despeckle(labels, W, H, K, passes, R) {
    R = R || 1; passes = passes == null ? 2 : passes;
    let cur = labels;
    for (let p = 0; p < passes; p++) {
      const src = cur, out = src.slice();
      const cnt = new Int32Array(K);
      for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
        const i = y * W + x; cnt.fill(0); let maj = src[i], mc = -1, tot = 0;
        for (let dj = -R; dj <= R; dj++) for (let di = -R; di <= R; di++) {
          if (!di && !dj) continue; const xx = x + di, yy = y + dj; if (xx < 0 || xx >= W || yy < 0 || yy >= H) continue;
          const v = src[yy * W + xx]; cnt[v]++; tot++; if (cnt[v] > mc) { mc = cnt[v]; maj = v; }
        }
        if (tot && src[i] !== maj && cnt[src[i]] <= tot * 0.25 && mc >= tot * 0.5) out[i] = maj;
      }
      cur = out;
    }
    return cur;
  }

  /** Greedy rectangle meshing of the boolean mask (label === k) → [{x0,y0,x1,y1}] in cells. */
  function greedyRects(labels, W, H, k) {
    const used = new Uint8Array(W * H);
    const rects = [];
    for (let y = 0; y < H; y++) {
      for (let x = 0; x < W; x++) {
        const i = y * W + x;
        if (used[i] || labels[i] !== k) continue;
        // extend right
        let x1 = x + 1; while (x1 < W && labels[y * W + x1] === k && !used[y * W + x1]) x1++;
        // extend down while the whole row [x,x1) matches
        let y1 = y + 1;
        for (; y1 < H; y1++) {
          let ok = true;
          for (let xx = x; xx < x1; xx++) { const j = y1 * W + xx; if (labels[j] !== k || used[j]) { ok = false; break; } }
          if (!ok) break;
        }
        for (let yy = y; yy < y1; yy++) for (let xx = x; xx < x1; xx++) used[yy * W + xx] = 1;
        rects.push({ x0: x, y0: y, x1, y1 });
      }
    }
    return rects;
  }

  /** Closed axis-aligned box [x0,x1]×[y0,y1]×[z0,z1] → 12 triangles (arrays of 3 [x,y,z]). */
  function boxTris(x0, y0, z0, x1, y1, z1) {
    const v = [
      [x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], // bottom 0..3
      [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1], // top 4..7
    ];
    const q = (a, b, c, d) => [[v[a], v[b], v[c]], [v[a], v[c], v[d]]];
    return [].concat(
      q(0, 3, 2, 1), // bottom (−z)
      q(4, 5, 6, 7), // top (+z)
      q(0, 1, 5, 4), // −y
      q(1, 2, 6, 5), // +x
      q(2, 3, 7, 6), // +y
      q(3, 0, 4, 7)  // −x
    );
  }

  /**
   * Build the flat multicolor plate. Returns { parts:[{head, hex, triangles}], sizeMm,
   * filaments:[hex], baseHead }. `head` is 0-based (→ extruder head+1). Geometry: one full
   * base slab (z 0..baseMm) in the most-common colour, then one cap part per colour
   * (z baseMm..totalMm) over that colour's cells, greedy-meshed. y is flipped so image row 0
   * maps to the far (+y) edge — matches how the relief export orients the picture.
   */
  function buildFlatParts(q, opts) {
    opts = opts || {};
    const { labels, palette, width: W, height: H } = q;
    const K = palette.length;
    const widthMm = +opts.widthMm > 0 ? +opts.widthMm : 120;
    const cell = widthMm / W;
    const heightMm = H * cell;
    const totalMm = +opts.heightMm > 0 ? +opts.heightMm : 2.4;
    const capMm = Math.min(totalMm - 0.4, +opts.capMm > 0 ? +opts.capMm : 1.0);
    const baseMm = Math.max(0.4, totalMm - capMm);

    // most-common colour → the (hidden) base slab
    const counts = new Int32Array(K); for (let i = 0; i < W * H; i++) counts[labels[i]]++;
    let baseHead = 0; for (let k = 1; k < K; k++) if (counts[k] > counts[baseHead]) baseHead = k;

    const X = (cx) => +(cx * cell).toFixed(4);
    const Y = (cy) => +((H - cy) * cell).toFixed(4); // flip

    const parts = [];
    // base slab (full plate)
    parts.push({ head: baseHead, hex: palette[baseHead].hex, triangles: boxTris(0, 0, 0, widthMm, heightMm, baseMm) });
    // one cap part per colour
    for (let k = 0; k < K; k++) {
      if (!counts[k]) continue;
      const rects = greedyRects(labels, W, H, k);
      if (!rects.length) continue;
      const tris = [];
      for (const r of rects) {
        // note the y-flip swaps which edge is min/max; boxTris wants y0<y1
        const ya = Y(r.y1), yb = Y(r.y0);
        for (const t of boxTris(X(r.x0), ya, baseMm, X(r.x1), yb, totalMm)) tris.push(t);
      }
      parts.push({ head: k, hex: palette[k].hex, triangles: tris });
    }
    return {
      parts, sizeMm: { x: widthMm, y: heightMm, z: totalMm },
      filaments: palette.map((p) => p.hex), baseHead,
    };
  }

  /**
   * Full flat plan from an image + optional pinned spools. Returns everything the preview and
   * exporter need: quantised palette, label field, mesh parts, and a flat preview (the
   * quantised image itself — WYSIWYG, since a flat print shows exactly these solid colours).
   */
  function planFlat(img, opts) {
    opts = opts || {};
    const K = Math.max(2, Math.min(4, opts.colors || 4));
    const widthMm = +opts.widthMm > 0 ? +opts.widthMm : 120;
    const cellMm = +opts.cellMm > 0 ? +opts.cellMm : 0.4;
    const targetW = Math.max(64, Math.min(img.width, Math.round(widthMm / cellMm)));
    const work = downsample(img, targetW);
    const fixed = opts.filaments && opts.filaments.length
      ? opts.filaments.map((f) => { const c = KC() && KC().hexToRgb(f.hex || f); return c ? { r: c.r, g: c.g, b: c.b } : null; }).filter(Boolean)
      : null;
    const q = quantize(work, K, fixed);
    q.labels = despeckle(q.labels, q.width, q.height, K, opts.despeckle == null ? 2 : opts.despeckle);
    const built = buildFlatParts(q, opts);
    // flat preview = the label field painted with the palette (exactly what prints)
    const preview = new Uint8ClampedArray(q.width * q.height * 4);
    for (let i = 0; i < q.width * q.height; i++) { const p = q.palette[q.labels[i]]; preview[i * 4] = p.r; preview[i * 4 + 1] = p.g; preview[i * 4 + 2] = p.b; preview[i * 4 + 3] = 255; }
    return {
      mode: 'flat', palette: q.palette, labels: q.labels, width: q.width, height: q.height,
      parts: built.parts, sizeMm: built.sizeMm, filaments: built.filaments, baseHead: built.baseHead,
      preview, widthMm, heightMm: built.sizeMm.y, totalMm: built.sizeMm.z,
    };
  }

  const api = { downsample, quantize, despeckle, greedyRects, boxTris, buildFlatParts, planFlat, rgbHex, lum };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytHueForgeFlat = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
