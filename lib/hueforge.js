'use strict';
/**
 * HueForge-style filament-painting engine — pure, DOM-free, Node-testable.
 * Bed Ready's own take on "colour by material", tuned for the Snapmaker U1.
 *
 * The idea (same as HueForge): print a flat relief whose surface HEIGHT varies per
 * pixel. An ordered stack of filaments is swapped at fixed global Z-heights, so at any
 * point the visible colour is the light-transmission composite of every layer beneath
 * the surface. Because the swaps are global (by layer, not by XY paint), the set of
 * achievable colours is a single 1-D gradient `colour(k)` parameterised by the number of
 * printed layers k — every pixel just picks the height whose colour is closest to its
 * target. That maps perfectly onto the U1's 4 always-loaded SnapSwap heads: ≤4 filaments
 * print fully automatically; more need mid-print reloads.
 *
 * Transmission model: each layer of filament f adds opacity a = 1 − exp(−layerH / TD),
 * where TD (Transmission Distance, mm) is how far light penetrates f before it is blocked
 * — low TD = opaque (darks), high TD = translucent (whites/naturals that let lower colours
 * bleed through). Layers are composited bottom→top in linear light.
 *
 * Colour maths (hex/rgb/Lab, CIEDE2000, nearest) come from lib/color-mix.js.
 */
(function (global) {
  const KC = (typeof module !== 'undefined' && module.exports)
    ? require('./color-mix')
    : (global.KhaytColor || {});

  const DEFAULT_LAYER_H = 0.08;    // mm — HueForge de-facto standard for PLA
  const DEFAULT_BASE_LAYERS = 4;   // opaque floor so the bed never bleeds through
  const DEFAULT_BAND_LAYERS = 12;  // layers per filament band when not specified
  const U1_HEADS = 4;              // Snapmaker U1 SnapSwap toolheads

  const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);
  const srgbToLinear = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const linearToSrgb = (c) => { const v = c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; return clamp(v * 255, 0, 255); };

  /** Perceived luminance 0..1 of a hex colour. */
  function luminance(hex) {
    const rgb = KC.hexToRgb(hex);
    if (!rgb) return 0.5;
    return (0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b) / 255;
  }

  /**
   * A sensible starting TD (mm) for a colour we have no measured value for: opaque darks
   * low (~1.2), translucent lights high (~11). Only a seed — the maker can override, and
   * real TD should ultimately come from a stepped-swatch calibration.
   */
  /**
   * A layer height that is actually a layer height.
   *
   * `+x > 0` was the guard, and it admits Infinity — `+"1e999"` is Infinity, so
   * a numeric field is enough to produce one. It then reached the palette as
   * `height: Infinity` on every entry: not a crash, just a stack describing a
   * part nobody can print, which is the shape of fault this module is worst at
   * showing you.
   */
  function posFinite(v, fallback) {
    const n = +v;
    return Number.isFinite(n) && n > 0 ? n : fallback;
  }

  function defaultTd(hex) {
    const lum = luminance(hex);
    return Math.round((0.8 + lum * lum * 5) * 10) / 10;
  }

  /**
   * Per-layer opacity of filament with transmission distance `td` at layer height `h`.
   * TD is treated as the thickness at which the filament reads ~90% opaque (light is
   * blocked to 10%): a band of thickness T reaches 1 − 0.1^(T/TD). Low TD = opaque, high
   * TD = translucent (lets lower colours bleed through — where the blending happens).
   */
  function layerAlpha(h, td) {
    const t = Math.max(0.05, +td || 4);
    // NOT Math.max(0, h): that catches a negative thickness and passes NaN
    // straight through, which then composites into a silently wrong colour.
    const thickness = Number.isFinite(+h) ? Math.max(0, +h) : 0;
    return 1 - Math.pow(0.1, thickness / t);
  }

  /** A sensible band thickness (layers) for a filament: translucent (high TD) needs more
   *  layers to read; opaque needs few. Clamped to a printable range. */
  function suggestLayers(td, layerH) {
    const h = +layerH > 0 ? +layerH : DEFAULT_LAYER_H;
    return clamp(Math.round((+td || 2) / h * 0.25), 8, 40);
  }

  /**
   * Order a filament set for printing: opaque (low TD) at the bottom, translucent (high
   * TD) on top so upper layers let the colours beneath show through — the HueForge rule.
   * Returns a new array; does not mutate.
   */
  function orderByOpacity(filaments) {
    return (filaments || []).slice().sort((a, b) => (a.td || defaultTd(a.hex)) - (b.td || defaultTd(b.hex)));
  }

  /**
   * Build the print stack + achievable-colour gradient from an ordered filament list.
   * @param {Array<{hex,td?,layers?}>} filaments  bottom→top
   * @param {{layerH?:number, baseLayers?:number}} [opts]
   * @returns {{layerH, baseLayers, totalLayers, bands:[], palette:[], filaments:[]}}
   *   bands   = [{index,hex,td,layers,startLayer,endLayer}]  (1-based layer ranges)
   *   palette = [{k,height,hex,lab}] for k in [baseLayers..totalLayers]  (the colour path)
   */
  function buildStack(filaments, opts) {
    opts = opts || {};
    const layerH = posFinite(opts.layerH, DEFAULT_LAYER_H);
    const baseLayers = Math.max(1, Math.round(opts.baseLayers != null ? opts.baseLayers : DEFAULT_BASE_LAYERS));
    const fils = (filaments || []).map((f) => ({
      hex: f.hex,
      td: +f.td > 0 ? +f.td : defaultTd(f.hex),
      layers: Math.max(1, Math.round(+f.layers > 0 ? +f.layers : DEFAULT_BAND_LAYERS)),
    })).filter((f) => KC.hexToRgb(f.hex));

    const bands = [];
    let layer = 0;
    fils.forEach((f, i) => {
      const start = layer + 1;
      layer += (i === 0 ? Math.max(f.layers, baseLayers) : f.layers);
      bands.push({ index: i, hex: f.hex, td: f.td, layers: layer - start + 1, startLayer: start, endLayer: layer });
    });
    const totalLayers = layer;

    // filament active at global layer k (1-based)
    const filAt = (k) => {
      for (let i = 0; i < bands.length; i++) if (k >= bands[i].startLayer && k <= bands[i].endLayer) return fils[i];
      return fils[fils.length - 1];
    };

    // Composite the reflective colour after k printed layers (bottom→top, linear light).
    const palette = [];
    if (fils.length) {
      const first = KC.hexToRgb(fils[0].hex);
      let R = srgbToLinear(first.r), G = srgbToLinear(first.g), B = srgbToLinear(first.b);
      for (let k = 1; k <= totalLayers; k++) {
        if (k > 1) {
          const f = filAt(k);
          const rgb = KC.hexToRgb(f.hex);
          const a = layerAlpha(layerH, f.td);
          R = R * (1 - a) + srgbToLinear(rgb.r) * a;
          G = G * (1 - a) + srgbToLinear(rgb.g) * a;
          B = B * (1 - a) + srgbToLinear(rgb.b) * a;
        }
        if (k >= baseLayers) {
          const hex = KC.rgbToHex(linearToSrgb(R), linearToSrgb(G), linearToSrgb(B));
          palette.push({ k, height: +(k * layerH).toFixed(3), hex, lab: KC.rgbToLab(KC.hexToRgb(hex)) });
        }
      }
    }

    return { layerH, baseLayers, totalLayers, bands, palette, filaments: fils };
  }

  /**
   * Despeckle + gently smooth a per-pixel height map so it prints. The raw nearest-colour
   * solve is spatially incoherent — neighbouring pixels routinely jump many layers, which
   * on a fine image (e.g. a patterned fabric) becomes a field of 1-pixel spikes. Those
   * spikes are watertight but unprintable: tiny isolated top areas, steep towers, and the
   * slicer's "floating regions" warning. A median pass kills the isolated spikes (edge-
   * preserving), then optional box passes ease the ramps into a printable relief. Values
   * stay within the palette's [minK..maxK] band, so the base floor and colour swaps are
   * untouched. `amount` = number of median+box rounds (0 = off).
   */
  function smoothHeights(heights, W, H, amount) {
    const rounds = Math.max(0, Math.round(amount || 0));
    if (!rounds || W < 3 || H < 3) return heights;
    let kMin = Infinity, kMax = -Infinity;
    for (let i = 0; i < heights.length; i++) { const v = heights[i]; if (v < kMin) kMin = v; if (v > kMax) kMax = v; }
    const clamp = (v) => (v < kMin ? kMin : v > kMax ? kMax : v);
    let cur = heights;
    const at = (g, x, y) => g[y * W + x];
    for (let r = 0; r < rounds; r++) {
      // 3x3 median — removes salt-and-pepper spikes without blurring genuine edges.
      const med = new Uint16Array(cur.length);
      const win = new Array(9);
      for (let j = 0; j < H; j++) {
        for (let i = 0; i < W; i++) {
          let c = 0;
          for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
            const x = i + di, y = j + dj;
            if (x < 0 || x >= W || y < 0 || y >= H) continue;
            win[c++] = at(cur, x, y);
          }
          for (let a = 1; a < c; a++) { const v = win[a]; let b = a - 1; while (b >= 0 && win[b] > v) { win[b + 1] = win[b]; b--; } win[b + 1] = v; }
          med[j * W + i] = win[c >> 1];
        }
      }
      // 3x3 box — eases the surviving ramps so slopes stay printable.
      const box = new Uint16Array(cur.length);
      for (let j = 0; j < H; j++) {
        for (let i = 0; i < W; i++) {
          let s = 0, c = 0;
          for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
            const x = i + di, y = j + dj;
            if (x < 0 || x >= W || y < 0 || y >= H) continue;
            s += at(med, x, y); c++;
          }
          box[j * W + i] = clamp(Math.round(s / c));
        }
      }
      cur = box;
    }
    return cur;
  }

  /**
   * Solve a heightfield: for each pixel, choose the palette height whose colour is the
   * closest CIEDE2000 match to the target pixel. Returns per-pixel layer counts + an RGBA
   * preview of the achievable result. The result is the raw per-pixel solve unless a caller
   * asks otherwise (opts.smooth = despeckle rounds, default 0) — smoothing moves pixels off
   * their nearest match, which is the caller's decision to make, not this function's.
   * @param {{data:Uint8ClampedArray, width:number, height:number}} img
   * @param {ReturnType<buildStack>} stack
   * @param {{smooth?:number}} [opts]
   * @returns {{heights:Uint16Array, preview:Uint8ClampedArray, width, height, minK, maxK}}
   */
  function solveHeightfield(img, stack, opts) {
    const { data, width, height } = img;
    const pal = stack.palette;
    const n = width * height;
    const heights = new Uint16Array(n);
    const preview = new Uint8ClampedArray(n * 4);
    if (!pal.length) return { heights, preview, width, height, minK: 0, maxK: 0 };

    // pre-split palette rgb for the preview blit
    const palRgb = pal.map((p) => KC.hexToRgb(p.hex));
    let lossSum = 0, lossN = 0;

    for (let i = 0; i < n; i++) {
      const o = i * 4;
      const a = data[o + 3];
      // transparent pixels → floor (base) so they print as the base colour
      const lab = KC.rgbToLab({ r: data[o], g: data[o + 1], b: data[o + 2] });
      let best = 0, bestD = Infinity;
      for (let j = 0; j < pal.length; j++) {
        const d = KC.ciede2000(lab, pal[j].lab);
        if (d < bestD) { bestD = d; best = j; }
      }
      if (a < 8) best = 0; else { lossSum += bestD; lossN++; }
      heights[i] = pal[best].k;
    }

    // Despeckle + smooth for printability, OFF unless asked for. Palette k-values are
    // contiguous from pal[0].k, so a smoothed height maps straight back to a palette index
    // for the preview.
    //
    // This defaulted to on, and that quietly broke what this function promises: every pixel
    // takes the nearest colour the stack can print. Smoothing moves pixels off their nearest
    // match on purpose — which is a fine thing for a caller to ask for and a bad thing to do
    // to one that didn't. Every caller in this file already passes `smooth` explicitly, and
    // the studio's own default is 0, so nothing loses behaviour by asking.
    const smooth = opts && opts.smooth != null ? opts.smooth : 0;
    const k0 = pal[0].k;
    const finalH = smoothHeights(heights, width, height, smooth);

    let minK = Infinity, maxK = -Infinity;
    for (let i = 0; i < n; i++) {
      const k = finalH[i];
      if (k < minK) minK = k;
      if (k > maxK) maxK = k;
      const idx = Math.max(0, Math.min(pal.length - 1, k - k0));
      const rgb = palRgb[idx];
      const o = i * 4;
      preview[o] = rgb.r; preview[o + 1] = rgb.g; preview[o + 2] = rgb.b; preview[o + 3] = 255;
    }
    return {
      heights: finalH, preview, width, height,
      minK: isFinite(minK) ? minK : 0, maxK: isFinite(maxK) ? maxK : 0,
      meanDeltaE: lossN ? lossSum / lossN : 0,
    };
  }

  /** Mean CIEDE2000 between an image and the colours a stack can achieve — the "match
   *  quality" of a plan (lower = closer). Runs on a downsample for speed. */
  function scorePlan(img, filaments, opts) {
    const small = downsample(img, 64);
    const stack = buildStack(filaments, opts);
    return solveHeightfield(small, stack, { smooth: 0 }).meanDeltaE;
  }

  /** Pick every `stride`-th pixel down to a target longest side — cheap loss evaluation. */
  function downsample(img, maxSide) {
    const { data, width, height } = img;
    const stride = Math.max(1, Math.ceil(Math.max(width, height) / maxSide));
    if (stride === 1) return img;
    const w = Math.ceil(width / stride), h = Math.ceil(height / stride);
    const out = new Uint8ClampedArray(w * h * 4);
    let oi = 0;
    for (let y = 0; y < height; y += stride) {
      for (let x = 0; x < width; x += stride) {
        const o = (y * width + x) * 4;
        out[oi] = data[o]; out[oi + 1] = data[o + 1]; out[oi + 2] = data[o + 2]; out[oi + 3] = data[o + 3];
        oi += 4;
      }
    }
    return { data: out, width: w, height: h };
  }

  /** Area-averaging downsample to a target longest side. Unlike the point-sampling
   *  `downsample`, this anti-aliases: each output cell is the mean of its source block, so
   *  flat regions (a noisy sky) become uniform instead of aliasing into per-cell speckle —
   *  which is what makes the solved heightmap sprout isolated towers. Used for the mesh. */
  function downsampleAvg(img, maxSide) {
    const { data, width, height } = img;
    const stride = Math.max(1, Math.round(Math.max(width, height) / maxSide));
    if (stride === 1) return img;
    const w = Math.max(1, Math.round(width / stride)), h = Math.max(1, Math.round(height / stride));
    const out = new Uint8ClampedArray(w * h * 4);
    for (let j = 0; j < h; j++) {
      for (let i = 0; i < w; i++) {
        let r = 0, g = 0, b = 0, a = 0, cnt = 0, acnt = 0;
        const y0 = j * stride, x0 = i * stride;
        for (let dy = 0; dy < stride; dy++) {
          const yy = y0 + dy; if (yy >= height) break;
          for (let dx = 0; dx < stride; dx++) {
            const xx = x0 + dx; if (xx >= width) break;
            const o = (yy * width + xx) * 4, al = data[o + 3];
            a += al; cnt++;
            if (al >= 8) { r += data[o]; g += data[o + 1]; b += data[o + 2]; acnt++; }
          }
        }
        const oo = (j * w + i) * 4;
        out[oo] = acnt ? r / acnt : 0; out[oo + 1] = acnt ? g / acnt : 0; out[oo + 2] = acnt ? b / acnt : 0;
        out[oo + 3] = cnt ? a / cnt : 0;
      }
    }
    return { data: out, width: w, height: h };
  }

  /**
   * Auto-tune band thicknesses (and base) to minimise the image match ΔE — a clean,
   * greedy coordinate-descent reimplementation of the "optimise" idea (inspired by
   * AutoForge, hvoss-techfak/AutoForge, CC-BY-NC-SA; concept only, no code/data borrowed).
   * Filament colours + order are kept; only how many layers each gets is tuned.
   * @returns {{filaments:Array, baseLayers:number, meanDeltaE:number}}
   */
  function autoTune(img, filaments, opts) {
    opts = opts || {};
    const layerH = posFinite(opts.layerH, DEFAULT_LAYER_H);
    const small = downsample(img, 72);
    let fils = filaments.map((f) => Object.assign({}, f, { layers: Math.max(4, Math.round(f.layers || suggestLayers(f.td, layerH))) }));
    let base = Math.max(1, Math.round(opts.baseLayers != null ? opts.baseLayers : DEFAULT_BASE_LAYERS));
    const CANDS = [4, 6, 8, 10, 12, 16, 20, 26, 32, 40];

    const score = (fl, b) => solveHeightfield(small, buildStack(fl, { layerH, baseLayers: b }), { smooth: 0 }).meanDeltaE;
    let bestScore = score(fils, base);

    for (let pass = 0; pass < 3; pass++) {
      let improved = false;
      for (let i = 0; i < fils.length; i++) {
        let localBest = fils[i].layers, localScore = bestScore;
        for (const c of CANDS) {
          if (c === fils[i].layers) continue;
          const trial = fils.map((f, j) => (j === i ? Object.assign({}, f, { layers: c }) : f));
          const s = score(trial, base);
          if (s < localScore - 1e-4) { localScore = s; localBest = c; }
        }
        if (localBest !== fils[i].layers) { fils[i] = Object.assign({}, fils[i], { layers: localBest }); bestScore = localScore; improved = true; }
      }
      // tune base a little
      for (const b of [2, 3, 4, 5, 6, 8]) {
        const s = score(fils, b);
        if (s < bestScore - 1e-4) { bestScore = s; base = b; }
      }
      if (!improved) break;
    }
    return { filaments: fils, baseLayers: base, meanDeltaE: bestScore };
  }

  /**
   * Suggest a starting filament palette from an image: k-means the dominant colours, then
   * (if the maker owns colour filaments) snap each to the nearest one they actually have.
   * Ordered opaque→translucent. Every entry is editable afterwards.
   * @param {{data:Uint8ClampedArray,width:number,height:number}} img
   * @param {Array} owned   inventory items with a `.color` hex (may be empty)
   * @param {number} maxColors
   */
  /**
   * Make an auto-extracted palette print well: k-means centroids come out desaturated
   * (they average pixels), which yields muddy filament suggestions. Boost saturation and
   * anchor the darkest toward black + lightest toward white so the stack has a proper
   * opaque base and a bright top — the contrast a filament painting needs.
   */
  function enhancePalette(hexes, satBoost) {
    const s = satBoost != null ? satBoost : 1.4;
    const rgbs = hexes.map((h) => KC.hexToRgb(h)).filter(Boolean);
    if (rgbs.length < 2) return hexes;
    const lum = (c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    const out = rgbs.map((c) => { const y = lum(c); return { r: clamp(y + (c.r - y) * s, 0, 255), g: clamp(y + (c.g - y) * s, 0, 255), b: clamp(y + (c.b - y) * s, 0, 255) }; });
    const idx = out.map((_, i) => i).sort((a, b) => lum(out[a]) - lum(out[b]));
    const dk = idx[0], lt = idx[idx.length - 1];
    out[dk] = { r: out[dk].r * 0.55, g: out[dk].g * 0.55, b: out[dk].b * 0.55 };            // deepen base
    out[lt] = { r: out[lt].r + (255 - out[lt].r) * 0.5, g: out[lt].g + (255 - out[lt].g) * 0.5, b: out[lt].b + (255 - out[lt].b) * 0.5 }; // lift highlight
    return out.map((c) => KC.rgbToHex(c.r, c.g, c.b));
  }

  function suggestFilaments(img, owned, maxColors) {
    const K = Math.max(2, Math.min(8, Math.round(maxColors || U1_HEADS)));
    const centroids = enhancePalette(kmeans(img, K));
    const ownedList = (owned || []).filter((it) => it && KC.hexToRgb(it.color));

    const out = centroids.map((hex) => {
      let resolvedHex = hex, name = null, deltaE = null;
      if (ownedList.length) {
        const near = KC.nearest(hex, ownedList, { limit: 1 })[0];
        if (near) {
          resolvedHex = near.color;
          name = [near.material, near.colourVariant].filter(Boolean).join(' — ') || near.brand || null;
          deltaE = near.deltaE;
        }
      }
      const td = defaultTd(resolvedHex);
      return { hex: resolvedHex, td, layers: suggestLayers(td, DEFAULT_LAYER_H), sourceHex: hex, name, deltaE };
    });

    // de-dupe filaments that snapped to the same owned spool
    const seen = new Set();
    const deduped = out.filter((f) => { const key = f.hex.toUpperCase(); if (seen.has(key)) return false; seen.add(key); return true; });
    return orderByOpacity(deduped);
  }

  /** Tiny k-means over a downsampled pixel set → K centroid hexes (sorted by luminance). */
  function kmeans(img, K) {
    const { data, width, height } = img;
    const step = Math.max(1, Math.floor(Math.sqrt((width * height) / 4096))); // ~≤4k samples
    const pts = [];
    for (let y = 0; y < height; y += step) {
      for (let x = 0; x < width; x += step) {
        const o = (y * width + x) * 4;
        if (data[o + 3] < 8) continue;
        pts.push([data[o], data[o + 1], data[o + 2]]);
      }
    }
    if (!pts.length) return ['#202020', '#808080', '#E0E0E0'].slice(0, K);
    // seed: spread across luminance
    pts.sort((a, b) => (0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]) - (0.2126 * b[0] + 0.7152 * b[1] + 0.0722 * b[2]));
    let cent = [];
    for (let i = 0; i < K; i++) cent.push(pts[Math.floor((i + 0.5) / K * (pts.length - 1))].slice());

    for (let iter = 0; iter < 8; iter++) {
      const sums = cent.map(() => [0, 0, 0, 0]);
      for (let p = 0; p < pts.length; p++) {
        const pt = pts[p];
        let bi = 0, bd = Infinity;
        for (let c = 0; c < cent.length; c++) {
          const dx = pt[0] - cent[c][0], dy = pt[1] - cent[c][1], dz = pt[2] - cent[c][2];
          const d = dx * dx + dy * dy + dz * dz;
          if (d < bd) { bd = d; bi = c; }
        }
        sums[bi][0] += pt[0]; sums[bi][1] += pt[1]; sums[bi][2] += pt[2]; sums[bi][3]++;
      }
      for (let c = 0; c < cent.length; c++) {
        if (sums[c][3]) { cent[c] = [sums[c][0] / sums[c][3], sums[c][1] / sums[c][3], sums[c][2] / sums[c][3]]; }
      }
    }
    return cent
      .sort((a, b) => (0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2]) - (0.2126 * b[0] + 0.7152 * b[1] + 0.0722 * b[2]))
      .map((c) => KC.rgbToHex(c[0], c[1], c[2]));
  }

  /**
   * Map the stack's filaments onto the U1's toolheads. ≤maxHeads → each colour is an
   * always-loaded head, fully automatic. More → the overflow colours reuse a finished
   * head via a mid-print reload pause at that colour's first layer.
   * @param {ReturnType<buildStack>} stack
   * @param {number} [maxHeads=4]
   */
  function u1Plan(stack, maxHeads) {
    const heads = Math.max(1, Math.round(maxHeads || U1_HEADS));
    const bands = stack.bands || [];
    const slots = [];   // [{slot, band}]  slot is 0-based head index
    const reloads = []; // [{atLayer, band, slot}]
    bands.forEach((b, i) => {
      const slot = i % heads;
      slots.push({ slot, band: b });
      if (i >= heads) reloads.push({ atLayer: b.startLayer, band: b, slot });
    });
    return {
      heads,
      colorCount: bands.length,
      automatic: bands.length <= heads,
      slots,
      reloads,
    };
  }

  /**
   * Where a hanger goes: a round hole through the top of the picture, or a loop on a tab
   * above it — what turns a relief into a keychain or something to hang on a nail.
   *
   * Everything is in GRID units (one unit = one cell, `sx` mm), measured from the top-left
   * of the grid the mesher will walk: for a loop that grid is `extra` rows taller than the
   * picture, and the picture starts at row `extra`. The hole is centred across the width.
   *
   * The loop's tab is printed `tabLayers` thick — never thinner than the base, and 1.6 mm
   * where the relief is that tall, because a loop as thin as the base snaps off a keyring.
   *
   * @param {number} W grid points across the picture
   * @param {number} H grid points down the picture
   * @param {number} sx mm per cell
   * @param {{hang?:'hole'|'loop', holeMm?:number, wallMm?:number}} opts
   * @returns {null|{kind:string, extra:number, cx:number, cy:number, r:number, R:number,
   *   inHole:(x:number,y:number)=>boolean, inTab:(x:number,y:number)=>boolean}}
   */
  function hangLayout(W, H, sx, opts) {
    opts = opts || {};
    const kind = opts.hang === 'hole' || opts.hang === 'loop' ? opts.hang : '';
    if (!kind || !(sx > 0) || W < 2 || H < 2) return null;
    const holeMm = clamp(posFinite(opts.holeMm, 4), 2, 12);
    const wallMm = clamp(posFinite(opts.wallMm, 2.5), 1.2, 8);
    const r = holeMm / 2 / sx, R = (holeMm / 2 + wallMm) / sx;
    const cx = (W - 1) / 2;
    // A hole that leaves less than a wall of picture each side would cut the part in two.
    if (kind === 'hole' && (2 * R > W - 1 || 2 * R > H - 1)) return null;
    const extra = kind === 'loop' ? Math.ceil(2 * R) : 0;
    const cy = R;   // a wall's width in from the top: of the tab, or of the picture
    const d2 = (x, y) => (x - cx) * (x - cx) + (y - cy) * (y - cy);
    return {
      kind, extra, cx, cy, r, R,
      inHole: (x, y) => d2(x, y) < r * r,
      // Above the picture only: the round head, and the straight sides below it that
      // run down into the picture so the tab joins it along a full edge.
      inTab: (x, y) => y < extra && (d2(x, y) <= R * R || (y >= cy && Math.abs(x - cx) <= R)),
    };
  }

  /** How thick a loop's tab prints, in layers (see hangLayout). */
  function hangTabLayers(layerH, baseLayers, maxLayers) {
    const want = Math.ceil(1.6 / layerH - 1e-9);
    return Math.max(clamp(baseLayers | 0, 0, 64), Math.min(want, maxLayers | 0));   // a base off the IPC is bounded
  }

  /**
   * Build a watertight, 2-manifold solid from a solved heightfield, sized to the bed: a
   * continuous top surface over the pixel grid, a matching flat bottom at z=0, and a skirt
   * of side walls joining them. Every edge is shared by exactly two faces (grid vertices
   * are bit-identical across the top, bottom and walls), so it slices cleanly with no
   * repair / empty layers. The colour swaps are by Z (layer_config_ranges), not by the
   * mesh, so a smooth surface reproduces the image just as well as stepped terraces.
   * @param {ReturnType<solveHeightfield>} solve
   * @param {{layerH:number, widthMm?:number, hang?:'hole'|'loop', holeMm?:number, baseLayers?:number}} opts
   *   `hang` adds a hanger (see hangLayout); `baseLayers` sets how thin a loop may print.
   * @returns {{triangles:Array, sizeMm:{x,y,z}, triangleCount:number}}
   */
  function heightfieldToMesh(solve, opts) {
    opts = opts || {};
    const layerH = posFinite(opts.layerH, DEFAULT_LAYER_H);
    const W = solve.width, H = solve.height, hts = solve.heights;
    if (W < 2 || H < 2) return { triangles: [], sizeMm: { x: 0, y: 0, z: 0 }, triangleCount: 0 };
    const widthMm = +opts.widthMm > 0 ? +opts.widthMm : 120;
    const sx = widthMm / (W - 1), sy = sx;        // square pixels; footprint = widthMm × …

    let maxLayers = 0;
    for (let k = 0; k < hts.length; k++) if (hts[k] > maxLayers) maxLayers = hts[k];
    // A hanger (hangLayout): a loop adds `extra` rows of tab above the picture, and both
    // kinds drop the cells inside the hole.
    const hang = hangLayout(W, H, sx, opts);
    const extra = hang ? hang.extra : 0;
    const tabH = hang && hang.kind === 'loop'
      ? hangTabLayers(layerH, opts.baseLayers != null ? opts.baseLayers : DEFAULT_BASE_LAYERS, maxLayers) : 0;
    const GH = H + extra;                          // grid rows walked, tab included
    const CW = W - 1, CH = GH - 1;                 // cells
    const keep = new Uint8Array(CW * CH).fill(1);
    if (hang) {
      for (let j = 0; j < CH; j++) {
        for (let i = 0; i < CW; i++) {
          const x = i + 0.5, y = j + 0.5;
          if (hang.inHole(x, y) || (y < extra && !hang.inTab(x, y))) keep[j * CW + i] = 0;
        }
      }
      // Two cells touching only at a corner share a vertex and no edge — a pinch no slicer
      // reads as one solid. Filling the gap costs a sliver of hole, not a broken part.
      for (let j = 0; j < CH - 1; j++) {
        for (let i = 0; i < CW - 1; i++) {
          const a = keep[j * CW + i], b = keep[j * CW + i + 1], c = keep[(j + 1) * CW + i], d = keep[(j + 1) * CW + i + 1];
          if (a === d && b === c && a !== b) keep[j * CW + i] = keep[j * CW + i + 1] = keep[(j + 1) * CW + i] = keep[(j + 1) * CW + i + 1] = 1;
        }
      }
    }
    const kept = (i, j) => i >= 0 && j >= 0 && i < CW && j < CH && keep[j * CW + i] === 1;
    const vh = (i, j) => (j < extra ? tabH : hts[(j - extra) * W + i]) * layerH;  // surface height at grid point
    const X = (i) => i * sx;
    const Y = (j) => (GH - 1 - j) * sy;            // +Y = image up
    const tris = [];
    const quad = (a, b, c, d) => { tris.push([a, b, c]); tris.push([a, c, d]); };
    // A wall down from top edge a→b (in the top face's winding) to z=0. Running the edge
    // the other way round from the top face is what keeps the shell consistently wound.
    const wall = (a, b) => quad([b[0], b[1], 0], b, a, [a[0], a[1], 0]);

    // Winding is chosen so every face normal points OUTWARD (top +Z, bottom −Z, walls away
    // from the solid) — an inside-out mesh makes the slicer produce empty/degenerate layers.
    // Every kept cell gets a top and a bottom, and a wall on each side that has no kept
    // neighbour: the outer border, the rim of a hole, the sides of a tab.
    for (let j = 0; j < CH; j++) {
      for (let i = 0; i < CW; i++) {
        if (!kept(i, j)) continue;
        const x0 = X(i), x1 = X(i + 1), y0 = Y(j), y1 = Y(j + 1); // y0 > y1
        const p00 = [x0, y0, vh(i, j)], p10 = [x1, y0, vh(i + 1, j)], p11 = [x1, y1, vh(i + 1, j + 1)], p01 = [x0, y1, vh(i, j + 1)];
        quad(p00, p01, p11, p10);                              // top → +Z
        quad([x0, y0, 0], [x1, y0, 0], [x1, y1, 0], [x0, y1, 0]); // bottom → −Z
        if (!kept(i - 1, j)) wall(p00, p01);                   // −X
        if (!kept(i, j + 1)) wall(p01, p11);                   // −Y
        if (!kept(i + 1, j)) wall(p11, p10);                   // +X
        if (!kept(i, j - 1)) wall(p10, p00);                   // +Y
      }
    }
    const maxZ = Math.max(maxLayers, tabH) * layerH;
    return { triangles: tris, sizeMm: { x: (W - 1) * sx, y: (GH - 1) * sy, z: maxZ }, triangleCount: tris.length };
  }

  /** Binary STL as a Uint8Array (renderer-friendly; no Node Buffer). Same layout as
   *  lib/mf-write trianglesToStl. Triangles = [[x,y,z],[x,y,z],[x,y,z]]. */
  function meshToStlBinary(triangles) {
    const n = triangles.length;
    const buf = new ArrayBuffer(84 + n * 50);
    const dv = new DataView(buf);
    const header = 'Bed Ready HueForge U1';
    for (let i = 0; i < header.length && i < 80; i++) dv.setUint8(i, header.charCodeAt(i));
    dv.setUint32(80, n, true);
    let off = 84;
    for (let t = 0; t < n; t++) {
      const tri = triangles[t];
      const a = tri[0], b = tri[1], c = tri[2];
      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
      const vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      const len = Math.hypot(nx, ny, nz) || 1; nx /= len; ny /= len; nz /= len;
      dv.setFloat32(off, nx, true); dv.setFloat32(off + 4, ny, true); dv.setFloat32(off + 8, nz, true); off += 12;
      for (const p of [a, b, c]) { dv.setFloat32(off, p[0], true); dv.setFloat32(off + 4, p[1], true); dv.setFloat32(off + 8, p[2], true); off += 12; }
      dv.setUint16(off, 0, true); off += 2;
    }
    return new Uint8Array(buf);
  }

  // ===========================================================================
  // Phase 1 — optimised per-layer filament painting (the AutoForge-class engine)
  //
  // The 4-band engine above gives each filament one contiguous Z-band. This engine
  // instead learns a per-LAYER filament SEQUENCE (seq[k] = which of the ≤4 loaded
  // filaments prints at layer k, bottom→top) in which a filament may recur at many
  // heights. On the Snapmaker U1 — a tool-changer — swapping among the 4 loaded heads
  // is automatic and near-free, so that reuse is exactly what turns 4 filaments into a
  // rich, photographic tonal range. Clean-room: physics (Beer-Lambert transmission) +
  // a coordinate-descent search over the sequence minimising image ΔE. No third-party
  // code, constants, or filament data.
  // ===========================================================================

  /**
   * Composite the reflective colour visible after each printed layer for an explicit
   * per-layer filament sequence (bottom→top, linear light). Returns palette entries
   * { k, hex, rgb, lab } for k = 1..seq.length. The first layer is the opaque base
   * seed (blocks the bed); higher layers alpha-over via layerAlpha(layerH, TD).
   */
  function compositeSequence(filaments, seq, layerH, tdScale) {
    // Front-lit correction: a reflective (non-backlit) print only shows light that
    // penetrates a little way and bounces back, so each layer reads FAR more opaque than
    // its backlit TD implies. Scaling TD down (default ~0.2, à la Kromacut's front-lit
    // factor) makes the top filaments dominate → saturated, non-muddy colour, and similar
    // tones collapse onto the same height → less slice speckle. tdScale=1 = raw backlit.
    const s = +tdScale > 0 ? +tdScale : 0.2;
    const fils = filaments.map((f) => ({
      rgb: KC.hexToRgb(f.hex),
      td: (+f.td > 0 ? +f.td : defaultTd(f.hex)) * s,
    }));
    const palette = [];
    if (!fils.length || !seq.length) return palette;
    let R = 0, G = 0, B = 0, started = false;
    for (let k = 0; k < seq.length; k++) {
      const f = fils[seq[k]] || fils[0];
      if (!f.rgb) continue;
      const lr = srgbToLinear(f.rgb.r), lg = srgbToLinear(f.rgb.g), lb = srgbToLinear(f.rgb.b);
      if (!started) { R = lr; G = lg; B = lb; started = true; }
      else {
        const a = layerAlpha(layerH, f.td);
        R = R * (1 - a) + lr * a; G = G * (1 - a) + lg * a; B = B * (1 - a) + lb * a;
      }
      const rgb = { r: linearToSrgb(R), g: linearToSrgb(G), b: linearToSrgb(B) };
      palette.push({ k: k + 1, hex: KC.rgbToHex(rgb.r, rgb.g, rgb.b), rgb, lab: KC.rgbToLab(rgb) });
    }
    return palette;
  }

  /** Reduce an image to weighted representative Lab colours (5-bit/channel buckets) so the
   *  optimiser's loss is a small weighted sum instead of a per-pixel scan. */
  function quantizeTargets(img, maxSide) {
    const s = downsample(img, maxSide || 96);
    const { data, width, height } = s;
    const map = new Map();
    for (let i = 0; i < width * height; i++) {
      const o = i * 4;
      if (data[o + 3] < 8) continue;
      const key = ((data[o] >> 3) << 10) | ((data[o + 1] >> 3) << 5) | (data[o + 2] >> 3);
      let e = map.get(key);
      if (!e) { e = [0, 0, 0, 0]; map.set(key, e); }
      e[0] += data[o]; e[1] += data[o + 1]; e[2] += data[o + 2]; e[3]++;
    }
    const reps = [];
    for (const e of map.values()) {
      reps.push({ lab: KC.rgbToLab({ r: e[0] / e[3], g: e[1] / e[3], b: e[2] / e[3] }), w: e[3] });
    }
    return reps;
  }

  // squared Euclidean Lab distance — cheap inner-loop metric for the search (ΔE00 is used
  // for the final preview/reporting where accuracy, not speed, matters).
  function labDist2(a, b) { const dl = a.L - b.L, da = a.a - b.a, db = a.b - b.b; return dl * dl + da * da + db * db; }

  /** Weighted mean nearest-palette distance of the reps (only heights k ≥ baseLayers are
   *  printable). Uses squared-Lab by default; ΔE00 when exact:true. */
  function sequenceLoss(reps, palette, baseLayers, exact) {
    let sum = 0, wsum = 0;
    for (let r = 0; r < reps.length; r++) {
      const rep = reps[r]; let best = Infinity;
      for (let j = 0; j < palette.length; j++) {
        if (palette[j].k < baseLayers) continue;
        const d = exact ? KC.ciede2000(rep.lab, palette[j].lab) : labDist2(rep.lab, palette[j].lab);
        if (d < best) best = d;
      }
      if (best !== Infinity) { sum += (exact ? best : Math.sqrt(best)) * rep.w; wsum += rep.w; }
    }
    return wsum ? sum / wsum : 0;
  }

  /** Seed sequence: dark/opaque filaments low, light/translucent high, spread across the
   *  height by luminance — a good starting point the search then refines. */
  function initSequence(filaments, totalLayers, baseLayers, baseIdx) {
    const order = filaments.map((f, i) => i).sort((i, j) => luminance(filaments[i].hex) - luminance(filaments[j].hex));
    const seq = new Array(totalLayers);
    for (let k = 0; k < totalLayers; k++) {
      if (k < baseLayers) { seq[k] = baseIdx; continue; }
      const t = (k - baseLayers) / Math.max(1, totalLayers - baseLayers - 1);
      seq[k] = order[Math.min(order.length - 1, Math.round(t * (order.length - 1)))];
    }
    return seq;
  }

  /**
   * Learn the per-layer filament sequence that best reproduces the image. Coordinate
   * descent: repeatedly try every filament at every printable layer, keep improvements.
   * A small switch penalty discourages gratuitous tool-changes (each still costs a prime
   * on the U1) without forcing contiguous bands.
   * @returns {{seq:number[], loss:number, baseIdx:number}}
   */
  function optimizeSequence(reps, filaments, opts) {
    opts = opts || {};
    const nFil = filaments.length;
    const totalLayers = Math.max(2, opts.totalLayers | 0);
    const baseLayers = Math.max(1, Math.min(totalLayers - 1, opts.baseLayers | 0));
    const layerH = +opts.layerH > 0 ? +opts.layerH : 0.08;
    // Light penalty: on the U1 tool-changes are near-free, so barely discourage churn —
    // just enough to prefer a clean plan when two are equal in colour fidelity.
    const switchPenalty = opts.switchPenalty != null ? +opts.switchPenalty : 0.04;
    const tdScale = +opts.tdScale > 0 ? +opts.tdScale : 0.2;
    const tds = filaments.map((f) => (+f.td > 0 ? +f.td : defaultTd(f.hex)));
    let baseIdx = 0; for (let i = 1; i < nFil; i++) if (tds[i] < tds[baseIdx]) baseIdx = i;
    if (nFil <= 1) { return { seq: new Array(totalLayers).fill(0), loss: 0, baseIdx: 0 }; }

    // Optional monotonic mode (OFF by default). Filament REUSE across non-contiguous heights
    // is the source of HueForge's per-layer colour blending — a few filaments make many
    // colours — so we keep it ON (via the annealing search below). Speckle from reuse is
    // handled the right way in solveFromSequence: a smoothness-regularised height solve, not
    // by forbidding reuse. Monotonic remains available for flat-graphic edge cases.
    if (opts.monotonic === true) {
      const order = filaments.map((f, i) => i).sort((a, b) => luminance(filaments[a].hex) - luminance(filaments[b].hex));
      const nSeg = order.length;
      const mcost = (s) => sequenceLoss(reps, compositeSequence(filaments, s, layerH, tdScale), baseLayers, false);
      const build = (bp) => {
        const s = new Array(totalLayers);
        for (let k = 0; k < baseLayers; k++) s[k] = order[0];
        for (let j = 0; j < nSeg; j++) for (let k = bp[j]; k < bp[j + 1]; k++) s[k] = order[j];
        return s;
      };
      const bp = [baseLayers];
      for (let j = 1; j < nSeg; j++) bp.push(baseLayers + Math.round((totalLayers - baseLayers) * j / nSeg));
      bp.push(totalLayers);
      let bestS = build(bp), bestC = mcost(bestS);
      for (let pass = 0; pass < 16; pass++) {
        let improved = false;
        for (let j = 1; j < nSeg; j++) {
          const lo = bp[j - 1], hi = bp[j + 1]; let bj = bp[j];
          for (let v = lo; v <= hi; v++) {
            if (v === bp[j]) continue;
            const t = bp.slice(); t[j] = v; const c = mcost(build(t));
            if (c < bestC - 1e-6) { bestC = c; bj = v; }
          }
          if (bj !== bp[j]) { bp[j] = bj; improved = true; }
        }
        if (!improved) break;
      }
      bestS = build(bp);
      return { seq: bestS, loss: sequenceLoss(reps, compositeSequence(filaments, bestS, layerH, tdScale), baseLayers, true), baseIdx: order[0] };
    }

    const switches = (s) => { let c = 0; for (let k = 1; k < s.length; k++) if (s[k] !== s[k - 1]) c++; return c; };
    const cost = (s) => sequenceLoss(reps, compositeSequence(filaments, s, layerH, tdScale), baseLayers, false) + switchPenalty * switches(s);

    const seq = initSequence(filaments, totalLayers, baseLayers, baseIdx);
    let best = cost(seq);
    // (1) coordinate descent to a local optimum
    const passes = opts.passes || 8;
    for (let pass = 0; pass < passes; pass++) {
      let improved = false;
      for (let k = baseLayers; k < totalLayers; k++) {
        const cur = seq[k]; let bk = cur, bl = best;
        for (let f = 0; f < nFil; f++) {
          if (f === cur) continue;
          seq[k] = f; const l = cost(seq);
          if (l < bl - 1e-6) { bl = l; bk = f; }
        }
        seq[k] = bk;
        if (bk !== cur) { best = bl; improved = true; }
      }
      if (!improved) break;
    }
    // (2) simulated-annealing polish — escapes the "contiguous bands" local optimum and
    // discovers filament reuse. Seeded LCG so the same inputs always give the same plan
    // (a re-solve on every preview render must not flicker).
    let rng = (opts.seed || 0x9e3779b1) >>> 0;
    const rand = () => { rng = (Math.imul(rng, 1664525) + 1013904223) >>> 0; return rng / 4294967296; };
    const iters = opts.anneal != null ? opts.anneal | 0 : 1600;
    let curSeq = seq.slice(), curCost = best;
    let bestSeq = seq.slice(), bestCost = best;
    const T0 = Math.max(0.5, best * 0.5), T1 = 0.02;
    for (let it = 0; it < iters; it++) {
      const T = T0 * Math.pow(T1 / T0, it / Math.max(1, iters - 1));
      const k = baseLayers + ((rand() * (totalLayers - baseLayers)) | 0);
      const span = rand() < 0.3 ? 1 + ((rand() * 3) | 0) : 1; // sometimes a small block
      const f = (rand() * nFil) | 0;
      const prev = [];
      for (let d = 0; d < span && k + d < totalLayers; d++) { prev.push(curSeq[k + d]); curSeq[k + d] = f; }
      const c = cost(curSeq);
      if (c < curCost || rand() < Math.exp((curCost - c) / T)) {
        curCost = c;
        if (c < bestCost) { bestCost = c; bestSeq = curSeq.slice(); }
      } else {
        for (let d = 0; d < prev.length; d++) curSeq[k + d] = prev[d]; // revert
      }
    }
    return { seq: bestSeq, loss: sequenceLoss(reps, compositeSequence(filaments, bestSeq, layerH, tdScale), baseLayers, true), baseIdx };
  }

  /**
   * Solve per-pixel heights against a sequence palette, with Floyd-Steinberg error
   * diffusion so intermediate tones the palette can't hit directly are reproduced by a
   * fine mix of the two nearest heights. Dither cells are whole pixels — keep the mesh
   * grid at ~nozzle width so they stay printable (see planPainting). Returns the same
   * shape as solveHeightfield.
   */
  function solveFromSequence(img, filaments, seq, opts) {
    opts = opts || {};
    const layerH = +opts.layerH > 0 ? +opts.layerH : 0.08;
    const baseLayers = Math.max(1, opts.baseLayers | 0);
    const dither = opts.dither !== false;
    const tdScale = +opts.tdScale > 0 ? +opts.tdScale : 0.2;
    const palette = compositeSequence(filaments, seq, layerH, tdScale).filter((p) => p.k >= baseLayers);
    const { data, width, height } = img;
    const n = width * height;
    const heights = new Uint16Array(n);
    const preview = new Uint8ClampedArray(n * 4);
    if (!palette.length) return { heights, preview, width, height, minK: 0, maxK: 0, meanDeltaE: 0 };
    const palRgb = palette.map((p) => p.rgb), palLab = palette.map((p) => p.lab);
    const errR = dither ? new Float32Array(n) : null;
    const errG = dither ? new Float32Array(n) : null;
    const errB = dither ? new Float32Array(n) : null;
    let minK = Infinity, maxK = -Infinity, lossSum = 0, lossN = 0;
    const clamp255 = (v) => (v < 0 ? 0 : v > 255 ? 255 : v);
    // For the smoothness-regularised solve below: each cell's chosen palette index and its
    // TRUE (undithered) target Lab. `opaque` marks printable (non-transparent) cells.
    const idxArr = new Int16Array(n);
    const tLab = new Float32Array(n * 3);
    const opaque = new Uint8Array(n);

    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const i = y * width + x, o = i * 4;
        if (data[o + 3] < 8) { // transparent → base colour, no dither spill
          heights[i] = palette[0].k; idxArr[i] = 0;
          preview[o] = palRgb[0].r; preview[o + 1] = palRgb[0].g; preview[o + 2] = palRgb[0].b; preview[o + 3] = 255;
          if (palette[0].k < minK) minK = palette[0].k; if (palette[0].k > maxK) maxK = palette[0].k;
          continue;
        }
        opaque[i] = 1;
        const tr = dither ? clamp255(data[o] + errR[i]) : data[o];
        const tg = dither ? clamp255(data[o + 1] + errG[i]) : data[o + 1];
        const tb = dither ? clamp255(data[o + 2] + errB[i]) : data[o + 2];
        const lab = KC.rgbToLab({ r: tr, g: tg, b: tb });
        let best = 0, bestD = Infinity;
        for (let j = 0; j < palLab.length; j++) { const d = labDist2(lab, palLab[j]); if (d < bestD) { bestD = d; best = j; } }
        const k = palette[best].k;
        heights[i] = k; idxArr[i] = best; if (k < minK) minK = k; if (k > maxK) maxK = k;
        const rgb = palRgb[best];
        preview[o] = rgb.r; preview[o + 1] = rgb.g; preview[o + 2] = rgb.b; preview[o + 3] = 255;
        const oLab = KC.rgbToLab({ r: data[o], g: data[o + 1], b: data[o + 2] });
        tLab[i * 3] = oLab.L; tLab[i * 3 + 1] = oLab.a; tLab[i * 3 + 2] = oLab.b;
        lossSum += KC.ciede2000(oLab, palLab[best]); lossN++;
        if (dither) {
          const er = tr - rgb.r, eg = tg - rgb.g, eb = tb - rgb.b;
          const spread = (xx, yy, wgt) => {
            if (xx < 0 || xx >= width || yy < 0 || yy >= height) return;
            const ii = yy * width + xx; errR[ii] += er * wgt; errG[ii] += eg * wgt; errB[ii] += eb * wgt;
          };
          spread(x + 1, y, 7 / 16); spread(x - 1, y + 1, 3 / 16); spread(x, y + 1, 5 / 16); spread(x + 1, y + 1, 1 / 16);
        }
      }
    }

    // Smoothness-regularised height solve — the real dot-killer (AutoForge's total-variation
    // trick, done properly during the solve instead of as crude cleanup after). The per-pixel
    // nearest-palette pass above is noisy: subtle tonal wobble in a near-uniform area flips
    // neighbouring cells to different heights → different top colours → the scattered "dots".
    // Here we re-solve each cell's palette index to minimise
    //     colour cost  +  λ · Σ_neighbours min(|Δindex|, cap)
    // i.e. stay near the target colour BUT stay near neighbours' heights, so a smooth tone
    // sits on one band (no speckle). The penalty is TRUNCATED (robust/TV): a big jump costs a
    // flat cap·λ, so genuine edges aren't smeared — only sub-nozzle noise gets flattened.
    // Solved by iterated conditional modes (ICM). Skipped when dithering (its variation is
    // intentional). This keeps filament reuse — colour still comes from the layer stack.
    if (!dither && palette.length) {
      const P = palette.length;
      // `heights` is the raw per-pixel nearest-palette solve — noisy: subtle tonal wobble
      // makes lone cells jump to a tall band → isolated spikes → "floating regions" + dots.
      // Despeckle with a SELECTIVE median: for each cell take the 3×3 median, but only ADOPT it
      // when the cell deviates from that median by more than `speck` layers. A lone spike is a
      // large deviation → pulled to the majority; a genuine edge or smooth gradient deviates
      // little from its own local median → left EXACTLY as solved. This is the crucial fix for
      // the lost sharpness: an unconditional median rounds off every real feature, whereas the
      // selective form only corrects true salt-and-pepper and never blurs detail. `speck` scales
      // to ~0.16 mm (a band-width speck); `smooth` (0..3) loosens it slightly for busy photos.
      const speck = Math.max(2, Math.round((0.16 + 0.04 * (opts.smooth > 0 ? opts.smooth : 0)) / layerH));
      const mpasses = 2;
      const win = new Uint16Array(9);
      for (let pass = 0; pass < mpasses; pass++) {
        const src = heights.slice();
        for (let y = 0; y < height; y++) {
          for (let x = 0; x < width; x++) {
            const i = y * width + x; if (!opaque[i]) continue;
            let m = 0;
            for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
              const xx = x + di, yy = y + dj; if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
              win[m++] = src[yy * width + xx];
            }
            for (let a = 1; a < m; a++) { const v = win[a]; let b = a - 1; while (b >= 0 && win[b] > v) { win[b + 1] = win[b]; b--; } win[b + 1] = v; }
            const med = win[m >> 1];
            const cur = src[i];
            if ((cur > med ? cur - med : med - cur) > speck) heights[i] = med; // outlier only
          }
        }
      }

      // Printability peak-clip: no cell may tower > ~0.5 mm over its whole neighbourhood, so an
      // isolated speck can't become a sub-nozzle needle. Real edges survive (their tall side
      // borders other tall cells). Two passes handle 2-cell slivers.
      const maxJump = Math.max(3, Math.round(0.5 / layerH));
      for (let pass = 0; pass < 2; pass++) {
        const src2 = heights.slice();
        for (let y = 0; y < height; y++) {
          for (let x = 0; x < width; x++) {
            const i = y * width + x; if (!opaque[i]) continue;
            let nmax = 0, count = 0;
            for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
              if (!di && !dj) continue; const xx = x + di, yy = y + dj;
              if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
              const v = src2[yy * width + xx]; if (v > nmax) nmax = v; count++;
            }
            if (count && heights[i] > nmax + maxJump) heights[i] = nmax + maxJump;
          }
        }
      }
      // Kill isolated local-max spikes — the decisive fix for "floating regions". After
      // smoothing, any cell still standing strictly TALLER than all 8 neighbours is a lone
      // needle (a leftover speck): an unsupported overhang the slicer flags as floating, and a
      // scattered dot in the preview. Pull it down to its tallest neighbour. A real bright
      // feature is ≥2 cells wide so it has an equal-height neighbour and survives. Two passes.
      for (let pass = 0; pass < 8; pass++) {
        const src4 = heights.slice(); let changed = 0;
        for (let y = 0; y < height; y++) {
          for (let x = 0; x < width; x++) {
            const i = y * width + x; if (!opaque[i]) continue;
            let nmax = -1;
            for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
              if (!di && !dj) continue; const xx = x + di, yy = y + dj;
              if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
              const v = src4[yy * width + xx]; if (v > nmax) nmax = v;
            }
            if (nmax >= 0 && src4[i] > nmax) { heights[i] = nmax; changed++; }
          }
        }
        if (!changed) break; // converged → no strict local-max spikes remain
      }

      // Lone-colour despeckle — removes the last scattered "dots" WITHOUT any blur, run BEFORE a
      // final spike sweep so it can never leave a floating region. A dot is a cell whose visible
      // colour (palette index) differs from a super-majority of its 8 neighbours that agree among
      // themselves: e.g. a single cell that slipped into a different band inside a smooth sky. We
      // snap ONLY these, because an EDGE never has a ≥6/8 agreeing majority (its neighbours split
      // between the two sides) — so real detail is untouched. The lone cell drops to its majority
      // neighbours' MEDIAN height (never above them), so it joins their band without new spikes.
      {
        const k0i = palette[0].k;
        const pidxOf = (k) => (k < k0i ? 0 : k - k0i >= P ? P - 1 : k - k0i);
        const counts = new Uint16Array(P);
        for (let pass = 0; pass < 2; pass++) {
          const srcH = heights.slice();
          for (let y = 0; y < height; y++) {
            for (let x = 0; x < width; x++) {
              const i = y * width + x; if (!opaque[i]) continue;
              let tot = 0, best = -1, bestN = 0;
              for (let p = 0; p < P; p++) counts[p] = 0;
              for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
                if (!di && !dj) continue; const xx = x + di, yy = y + dj;
                if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
                const j = yy * width + xx; if (!opaque[j]) continue;
                const pj = pidxOf(srcH[j]); const c = ++counts[pj]; tot++;
                if (c > bestN) { bestN = c; best = pj; }
              }
              if (best < 0) continue;
              const cp = pidxOf(srcH[i]);
              if (cp !== best && bestN >= 6 && bestN >= tot - 1) {
                const hv = [];
                for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
                  if (!di && !dj) continue; const xx = x + di, yy = y + dj;
                  if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
                  const j = yy * width + xx; if (!opaque[j]) continue;
                  if (pidxOf(srcH[j]) === best) hv.push(srcH[j]);
                }
                if (hv.length) { hv.sort((a, b) => a - b); heights[i] = hv[hv.length >> 1]; }
              }
            }
          }
        }
        // final spike sweep — guarantees the colour snap above left no floating region
        for (let pass = 0; pass < 4; pass++) {
          const s = heights.slice(); let ch = 0;
          for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
            const i = y * width + x; if (!opaque[i]) continue;
            let nmax = -1;
            for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
              if (!di && !dj) continue; const xx = x + di, yy = y + dj;
              if (xx < 0 || xx >= width || yy < 0 || yy >= height) continue;
              const v = s[yy * width + xx]; if (v > nmax) nmax = v;
            }
            if (nmax >= 0 && s[i] > nmax) { heights[i] = nmax; ch++; }
          }
          if (!ch) break;
        }
      }

      // recompute preview + min/max from the final smoothed heights
      const k0 = palette[0].k;
      const idxOf = (k) => (k < k0 ? 0 : k - k0 >= P ? P - 1 : k - k0);
      minK = Infinity; maxK = -Infinity;
      for (let i = 0; i < n; i++) {
        const k = heights[i]; if (k < minK) minK = k; if (k > maxK) maxK = k;
        const rgb = palRgb[idxOf(k)], o = i * 4;
        preview[o] = rgb.r; preview[o + 1] = rgb.g; preview[o + 2] = rgb.b; preview[o + 3] = 255;
      }
    }
    return {
      heights, preview, width, height,
      minK: isFinite(minK) ? minK : 0, maxK: isFinite(maxK) ? maxK : 0,
      meanDeltaE: lossN ? lossSum / lossN : 0,
    };
  }

  /** Contiguous same-filament runs of a sequence → export bands [{z0,z1,head,hex}].
   *  A reused filament yields several bands sharing one head (one U1 tool). */
  function sequenceToBands(seq, filaments, layerH) {
    const bands = [];
    if (!seq.length) return bands;
    let start = 0;
    for (let k = 1; k <= seq.length; k++) {
      if (k === seq.length || seq[k] !== seq[start]) {
        const head = seq[start];
        bands.push({
          z0: +(start * layerH).toFixed(4), z1: +(k * layerH).toFixed(4),
          head, hex: (filaments[head] && filaments[head].hex) || '#FFFFFF',
        });
        start = k;
      }
    }
    return bands;
  }

  /**
   * Edge-preserving denoise (3×3 per-channel median), `passes` times. Kills the stray
   * bright/dark single pixels — JPEG noise, a glint on skin, a lone star — that otherwise
   * map to isolated TALL spikes in the relief → the slicer's "floating regions" warning and
   * the scattered dots. A median removes those specks while keeping EDGES crisp (unlike a
   * blur), so the filigree / checker / real detail stays sharp. This is what a HueForge user
   * does by hand when they "clean up" a photo before importing; we do it automatically.
   */
  function medianRGB(img, passes) {
    passes = passes | 0; if (passes <= 0) return img;
    const W = img.width, H = img.height; let src = img.data;
    for (let p = 0; p < passes; p++) {
      const out = new Uint8ClampedArray(src.length); const win = new Uint8Array(9);
      for (let y = 0; y < H; y++) {
        for (let x = 0; x < W; x++) {
          const o = (y * W + x) * 4;
          for (let ch = 0; ch < 3; ch++) {
            let n = 0;
            for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
              const xx = x + di, yy = y + dj; if (xx < 0 || xx >= W || yy < 0 || yy >= H) continue;
              win[n++] = src[(yy * W + xx) * 4 + ch];
            }
            for (let i = 1; i < n; i++) { const v = win[i]; let j = i - 1; while (j >= 0 && win[j] > v) { win[j + 1] = win[j]; j--; } win[j + 1] = v; }
            out[o + ch] = win[n >> 1];
          }
          out[o + 3] = src[o + 3];
        }
      }
      src = out;
    }
    return { data: src, width: W, height: H };
  }

  /**
   * Full optimised-painting plan for the U1: pick layer count from the target height,
   * learn the sequence, solve the dithered heightfield, and return everything the
   * preview + exporter need. `filaments` = the ≤4 loaded spools ({hex, td?}).
   */
  function planPainting(img, filaments, opts) {
    opts = opts || {};
    const layerH = +opts.layerH > 0 ? +opts.layerH : 0.08;
    const heightMm = +opts.heightMm > 0 ? +opts.heightMm : 2.4;
    const totalLayers = Math.max(4, Math.round(heightMm / layerH));
    const baseLayers = Math.max(1, opts.baseLayers != null ? opts.baseLayers | 0 : Math.max(2, Math.round(0.4 / layerH)));
    const fils = (filaments || []).filter((f) => f && KC.hexToRgb(f.hex)).slice(0, U1_HEADS);
    if (!fils.length) return null;
    // Solve at PRINT resolution: one grid cell ≈ one dither cell ≈ ~nozzle width, so the
    // error-diffused heights stay printable (no sub-nozzle spikes) and the mesh stays a
    // sane size. widthMm/cellMm sets the grid; default cell 0.45 mm (> a 0.4 nozzle).
    const widthMm = +opts.widthMm > 0 ? +opts.widthMm : 120;
    const cellMm = +opts.cellMm > 0 ? +opts.cellMm : 0.4; // ≈ one nozzle width
    const targetW = Math.max(48, Math.min(img.width, Math.round(widthMm / cellMm)));
    const solveImg0 = img.width > targetW ? downsampleAvg(img, Math.round(targetW * Math.max(img.width, img.height) / img.width)) : img;
    // Clean source noise BEFORE solving so it never becomes a spike (see medianRGB).
    const solveImg = medianRGB(solveImg0, opts.denoise != null ? opts.denoise : 2);
    const tdScale = +opts.tdScale > 0 ? +opts.tdScale : 0.2;
    const reps = quantizeTargets(img, opts.reps || 96);
    const { seq, loss, baseIdx } = optimizeSequence(reps, fils, {
      totalLayers, baseLayers, layerH, passes: opts.passes || 8,
      // These are FRONT-LIT prints: the viewer sees the top filament, not the translucent
      // stack. Reusing a filament at scattered heights (cheap on the U1) minimises the
      // composite error but makes the TOP colour jump around as height rises → visible
      // speckle/dots on the real print. A high switch penalty forces a near-monotonic
      // sequence (each colour in one height band, ordered by lightness) so a smooth tone
      // maps to a smooth top colour. This is the single biggest print-cleanliness win.
      switchPenalty: opts.switchPenalty != null ? opts.switchPenalty : 1.0,
      anneal: opts.anneal, seed: opts.seed, tdScale,
    });
    const solve = solveFromSequence(solveImg, fils, seq, { layerH, baseLayers, dither: opts.dither === true, tdScale, smooth: opts.smooth });
    const bands = sequenceToBands(seq, fils, layerH);
    return {
      seq, bands, solve, filaments: fils, layerH, baseLayers, totalLayers, baseIdx,
      swaps: bands.length - 1, meanDeltaE: solve.meanDeltaE, optLoss: loss,
      palette: compositeSequence(fils, seq, layerH, tdScale),
    };
  }

  const api = {
    DEFAULT_LAYER_H, DEFAULT_BASE_LAYERS, DEFAULT_BAND_LAYERS, U1_HEADS,
    heightfieldToMesh, hangLayout, hangTabLayers, meshToStlBinary, smoothHeights,
    luminance, defaultTd, layerAlpha, suggestLayers, orderByOpacity,
    buildStack, solveHeightfield, suggestFilaments, enhancePalette, u1Plan,
    scorePlan, autoTune, downsample, downsampleAvg,
    compositeSequence, quantizeTargets, sequenceLoss, optimizeSequence,
    solveFromSequence, sequenceToBands, planPainting,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytHueForge = Object.assign(global.KhaytHueForge || {}, api);
})(typeof globalThis !== 'undefined' ? globalThis : this);
