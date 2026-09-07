/**
 * Full Spectrum (colour mixing) planner for the 3MF converter.
 *
 * When a painted file uses MORE colours than the target printer has physical slots (e.g. a 5-colour
 * model → Snapmaker U1's 4 heads), a naive convert collapses the extras onto whatever slot they map
 * to — losing that colour. Snapmaker Orca's "Full Spectrum" instead keeps 4 filaments physical and
 * reproduces the rest as *dithered mixes* of those 4 (alternating thin layers the eye blends). This
 * module decides WHICH 4 to keep physical, computes the best mix recipe for each extra colour, and
 * emits the Snapmaker Orca `mixed_filament_definitions` + dithering keys that make the U1 print them.
 *
 * Ported from the bedready.io web app (src/lib/convert.ts colour maths + src/lib/mixed-filament.ts),
 * which is verified byte-for-byte against real Orca-saved Full-Spectrum projects. The pigment model
 * lives in ./filament-mixer. Paint-code bit twiddling is reused from ./mf-mesh.
 */
(function (global) {
  'use strict';

  var mixer = (typeof require === 'function') ? require('./filament-mixer') : global.filamentMixer;
  var mfMesh = (typeof require === 'function') ? require('./mf-mesh')
    // `KhaytMfMesh` is what `mf-mesh.js` actually publishes. The old name
    // here was `mfMesh`, which nothing has ever defined: never wrong in
    // practice because both readers are main-process and take the
    // `require` branch, and wrong the moment the Mac app loaded this
    // into JavaScriptCore. The old name is NOT kept as a second chance —
    // a fallback that can only ever be undefined reads like an option.
    : global.KhaytMfMesh;
  var mixRgb = mixer.mixRgb;
  var hexToBits = mfMesh.hexToBits;
  var bitsToHex = mfMesh.bitsToHex;

  function normalizeHex(h) {
    var s = String(h || '').replace('#', '');
    return s.length >= 6 ? '#' + s.slice(0, 6).toUpperCase() : '#FFFFFF';
  }
  function hexToRgb(h) {
    var s = normalizeHex(h).slice(1);
    return [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)];
  }
  function rgbHex(rgb) {
    return '#' + rgb.map(function (v) { return Math.round(v).toString(16).toUpperCase().padStart(2, '0'); }).join('');
  }
  function srgbToLinear(c) {
    var x = c / 255;
    return x <= 0.04045 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
  }
  function rgbToLab(rgb) {
    var R = srgbToLinear(rgb[0]), G = srgbToLinear(rgb[1]), B = srgbToLinear(rgb[2]);
    var X = (R * 0.4124 + G * 0.3576 + B * 0.1805) / 0.95047;
    var Y = R * 0.2126 + G * 0.7152 + B * 0.0722;
    var Z = (R * 0.0193 + G * 0.1192 + B * 0.9505) / 1.08883;
    var f = function (t) { return t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116; };
    var fx = f(X), fy = f(Y), fz = f(Z);
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
  }
  // CIEDE2000 perceptual distance (ΔE00) between two CIELAB colours. kL=kC=kH=1.
  function deltaE(a, b) {
    var L1 = a[0], a1 = a[1], b1 = a[2], L2 = b[0], a2 = b[1], b2 = b[2];
    var rad = Math.PI / 180;
    var C1 = Math.hypot(a1, b1), C2 = Math.hypot(a2, b2);
    var Cbar = (C1 + C2) / 2, Cbar7 = Math.pow(Cbar, 7);
    var G = 0.5 * (1 - Math.sqrt(Cbar7 / (Cbar7 + Math.pow(25, 7))));
    var a1p = (1 + G) * a1, a2p = (1 + G) * a2;
    var C1p = Math.hypot(a1p, b1), C2p = Math.hypot(a2p, b2);
    var hp = function (y, x) { var h = Math.atan2(y, x) / rad; if (h < 0) h += 360; return h; };
    var h1p = C1p === 0 ? 0 : hp(b1, a1p);
    var h2p = C2p === 0 ? 0 : hp(b2, a2p);
    var dLp = L2 - L1, dCp = C2p - C1p, dhp = 0;
    if (C1p * C2p !== 0) { dhp = h2p - h1p; if (dhp > 180) dhp -= 360; else if (dhp < -180) dhp += 360; }
    var dHp = 2 * Math.sqrt(C1p * C2p) * Math.sin((dhp / 2) * rad);
    var Lbarp = (L1 + L2) / 2, Cbarp = (C1p + C2p) / 2, hbarp = h1p + h2p;
    if (C1p * C2p !== 0) {
      if (Math.abs(h1p - h2p) <= 180) hbarp = (h1p + h2p) / 2;
      else if (h1p + h2p < 360) hbarp = (h1p + h2p + 360) / 2;
      else hbarp = (h1p + h2p - 360) / 2;
    }
    var T = 1 - 0.17 * Math.cos((hbarp - 30) * rad) + 0.24 * Math.cos(2 * hbarp * rad) +
      0.32 * Math.cos((3 * hbarp + 6) * rad) - 0.2 * Math.cos((4 * hbarp - 63) * rad);
    var dTheta = 30 * Math.exp(-Math.pow((hbarp - 275) / 25, 2));
    var Cbarp7 = Math.pow(Cbarp, 7);
    var Rc = 2 * Math.sqrt(Cbarp7 / (Cbarp7 + Math.pow(25, 7)));
    var SL = 1 + (0.015 * Math.pow(Lbarp - 50, 2)) / Math.sqrt(20 + Math.pow(Lbarp - 50, 2));
    var SC = 1 + 0.045 * Cbarp, SH = 1 + 0.015 * Cbarp * T;
    var RT = -Math.sin(2 * dTheta * rad) * Rc;
    var lTerm = dLp / SL, cTerm = dCp / SC, hTerm = dHp / SH;
    return Math.sqrt(lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + RT * cTerm * hTerm);
  }

  // Orca's "Min Mix Ratio" default — a mixed region's minor component must be ≥ this %, or the
  // alternating dither layers get too thin to print cleanly.
  var MIN_MIX_RATIO = 15;

  /** Closest reproduction of targetHex as a pure/2-way mix of the base filaments (1-based a/b). */
  function bestMix(targetHex, baseHexes) {
    var tLab = rgbToLab(hexToRgb(targetHex));
    var bases = baseHexes.map(hexToRgb);
    var best = null;
    var consider = function (a, b, pct, rgb) {
      var dE = deltaE(tLab, rgbToLab(rgb));
      if (!best || dE < best.deltaE) best = { a: a + 1, b: b + 1, mixBPercent: pct, hex: rgbHex(rgb), deltaE: dE };
    };
    for (var i = 0; i < bases.length; i++) {
      consider(i, i, 0, bases[i]);
      for (var j = i + 1; j < bases.length; j++)
        for (var pct = MIN_MIX_RATIO; pct <= 100 - MIN_MIX_RATIO; pct += 5) consider(i, j, pct, mixRgb(bases[i], bases[j], pct / 100));
    }
    return best;
  }

  function mix3(rgb, w) {
    var wab = w[0] + w[1];
    var t1 = mixRgb(rgb[0], rgb[1], wab > 0 ? w[1] / wab : 0.5);
    return mixRgb(t1, rgb[2], (w[2] || 0) / 100);
  }

  /** Best pure / 2-way / 3-way (gradient) mix of the base filaments. ids are 1-based. */
  function bestMixMulti(targetHex, baseHexes) {
    var tLab = rgbToLab(hexToRgb(targetHex));
    var bases = baseHexes.map(hexToRgb);
    var n = bases.length, best = null;
    var consider = function (ids, weights, rgb, bias) {
      bias = bias || 0;
      var dE = deltaE(tLab, rgbToLab(rgb));
      if (!best || dE + bias < best.deltaE) best = { ids: ids.map(function (x) { return x + 1; }), weights: weights, hex: rgbHex(rgb), deltaE: dE };
    };
    var MIN = MIN_MIX_RATIO;
    for (var i = 0; i < n; i++) {
      consider([i], [100], bases[i]);
      for (var j = i + 1; j < n; j++)
        for (var p = MIN; p <= 100 - MIN; p += 5) consider([i, j], [100 - p, p], mixRgb(bases[i], bases[j], p / 100));
    }
    for (var a = 0; a < n; a++)
      for (var b = a + 1; b < n; b++)
        for (var k = b + 1; k < n; k++)
          for (var wa = MIN; wa <= 100 - 2 * MIN; wa += 5)
            for (var wb = MIN; wa + wb <= 100 - MIN; wb += 5) {
              var wc = 100 - wa - wb;
              if (wc < MIN) continue;
              consider([a, b, k], [wa, wb, wc], mix3([bases[a], bases[b], bases[k]], [wa, wb, wc]), 1.5);
            }
    return best;
  }

  /**
   * Pick which colours load as the (up to 4) physical heads: keep the colours a mix can LEAST
   * reproduce, virtualise the ones it can fake well. Greedily drop the colour the survivors mix most
   * faithfully (lowest best-mix ΔE); usage only breaks perceptual ties. Returns src indices, most-used
   * first. `pinned` colours are never dropped (e.g. the unpainted base).
   */
  function bestPhysicalSet(hexes, usage, pinned, cap) {
    usage = usage || []; pinned = pinned || [];
    cap = (cap >= 1) ? Math.floor(cap) : 4;
    var all = hexes.map(function (_, i) { return i; });
    if (all.length <= cap) return all.sort(function (a, b) { return (usage[b] || 0) - (usage[a] || 0); });
    var pin = new Set(pinned.filter(function (i) { return i >= 0 && i < hexes.length; }));
    var keep = new Set(all);
    while (keep.size > cap) {
      var idxs = Array.from(keep).filter(function (c) { return !pin.has(c); });
      if (!idxs.length) break;
      var dE = new Map();
      idxs.forEach(function (c) {
        var others = Array.from(keep).filter(function (x) { return x !== c; }).map(function (x) { return normalizeHex(hexes[x]); });
        dE.set(c, bestMix(normalizeHex(hexes[c]), others).deltaE);
      });
      var minDE = Math.min.apply(null, idxs.map(function (c) { return dE.get(c); }));
      var dropI = idxs.filter(function (c) { return dE.get(c) <= minDE + 1.5; })
        .sort(function (a, b) { return (usage[a] || 0) - (usage[b] || 0); })[0];
      keep.delete(dropI);
    }
    return Array.from(keep).sort(function (a, b) { return (usage[b] || 0) - (usage[a] || 0); });
  }

  // ---------- Snapmaker Orca mixed_filament_definitions serializer ----------
  // Per definition, comma-separated tokens; definitions joined with ';'. Verified against a real
  // Orca-saved Full-Spectrum project. See bedready.io src/lib/mixed-filament.ts.
  function fmtOffset(v) {
    var s = (v || 0).toFixed(4).replace(/0+$/, '').replace(/\.$/, '');
    if (s === '-0' || s === '') s = '0';
    return s;
  }
  function serializeMixedDef(d) {
    var tokens = [
      d.componentA,
      d.componentB,
      d.enabled === false ? 0 : 1,
      d.custom === false ? 0 : 1,
      Math.max(0, Math.min(100, Math.round(d.mixBPercent))),
      d.pointillismAll ? 1 : 0,
      'g' + (d.gradientIds || ''),
      'w' + (d.gradientWeights || ''),
      'm' + (d.distributionMode == null ? 2 : d.distributionMode),
      'z' + Math.max(0, d.localZ || 0),
      'xa' + fmtOffset(d.surfaceOffsetA || 0),
      'xb' + fmtOffset(d.surfaceOffsetB || 0),
      'd' + (d.deleted ? 1 : 0),
      'o' + (d.originAuto ? 1 : 0),
      'u' + d.stableId
    ].join(',');
    var ui = d.uiMode == null ? 0 : d.uiMode;
    return ui >= 0 ? tokens + ',cm' + ui : tokens;
  }
  function serializeMixedDefs(defs) { return defs.map(serializeMixedDef).join(';'); }

  // Global dithering keys that accompany the definitions (from a real Orca Full-Spectrum save).
  var MIXED_DITHERING_DEFAULTS = {
    mixed_color_layer_height_a: '0',
    mixed_color_layer_height_b: '0',
    mixed_filament_advanced_dithering: '1',
    mixed_filament_component_bias_enabled: '0',
    mixed_filament_gradient_mode: '0',
    mixed_filament_height_lower_bound: '0.04',
    mixed_filament_height_upper_bound: '0.16',
    mixed_filament_pointillism_line_gap: '0',
    mixed_filament_pointillism_pixel_size: '0',
    mixed_filament_region_collapse: '1',
    mixed_filament_surface_indentation: '0',
    dithering_local_z_mode: '1',
    dithering_local_z_infill: '1',
    dithering_z_step_size: '0',
    dithering_step_painted_zones_only: '1'
  };

  // ---------- paint-code remap ----------
  /** Remap a paint_color code's leaf states through stateMap(oldState)→newState. */
  function remapPaintCode(hex, stateMap) {
    var bits = hexToBits(hex);
    var p = 0;
    var rd = function (k) { var n = 0; for (var i = 0; i < k; i++) n |= (bits[p++] || 0) << i; return n; };
    var out = [];
    (function tri(depth) {
      var ss = rd(2);
      if (ss !== 0 && depth < 64) { // depth cap: guard against a crafted deep paint code (stack overflow)
        var side = rd(2);
        out.push(ss & 1, (ss >> 1) & 1, side & 1, (side >> 1) & 1);
        for (var c = 0; c < ss + 1; c++) tri(depth + 1);
        return;
      }
      var lo = rd(2);
      var s = lo === 3 ? rd(4) + 3 : lo;
      var ns = stateMap(s);
      out.push(0, 0);
      if (ns > MAX_ENCODABLE_SLOT) {
        throw new RangeError('full-spectrum: slot ' + ns + ' exceeds the 3MF paint encoding limit of ' + MAX_ENCODABLE_SLOT);
      }
      if (ns >= 3) { out.push(1, 1); for (var i = 0; i < 4; i++) out.push((ns - 3) >> i & 1); }
      else out.push(ns & 1, (ns >> 1) & 1);
    })(0);
    while (out.length % 4 !== 0) out.push(0);
    return bitsToHex(out);
  }

  /**
   * Plan a Full Spectrum conversion.
   *
   * @param {string[]} colors  source filament palette (hex), length = source colour count
   * @param {number[]} usage   per-colour usage weight (paint-state tally); [] if unknown
   * @param {object}   [opts]
   *   opts.physical   {number[]} 0-based src indices to force as the 4 physical heads (UI override)
   *   opts.physicalHex{string[]} hex actually loaded on each head, aligned to opts.physical
   *   opts.pinned     {number[]} src indices never virtualised (e.g. the unpainted base colour)
   * @returns {{
   *   physical:number[], physicalHex:string[], mixDefs:object[],
   *   newOf:object, stateMap:function, map:number[],
   *   extras:{src:number, srcHex:string, resultHex:string, deltaE:number, recipe:object}[]
   * }}  newOf: src index → 1-based output filament slot. map: src index → 0-based slot (extruder refs).
   */
  // The physical-set search is superlinear in the palette size: bestMixMulti scans all
  // pair/triple mixes (O(n^3)) and bestPhysicalSet calls it O(n^2) times while dropping
  // colours down to the head count — so planning is ~O(n^5). A real multicolour file has at
  // most ~16 filaments (a full 4-unit AMS); this cap sits at 2x that headroom. A crafted
  // project_settings.config could otherwise declare thousands of colours and wedge the main
  // process. Above the cap, decline to plan (caller falls back to a normal reduce).
  var MAX_FS_COLORS = 32;
  // Highest slot the 3MF paint encoding can represent: the extension field is 4 bits
  // holding (state - 3), so state <= 3 + 15 = 18.
  var MAX_ENCODABLE_SLOT = 18;
  function planFullSpectrum(colors, usage, opts) {
    opts = opts || {};
    usage = usage || [];
    if (!Array.isArray(colors) || colors.length < 1 || colors.length > MAX_FS_COLORS) return null;
    // Every source colour becomes a physical head or a mix slot, so the slot count tracks
    // the palette size. Anything above the paint encoding's ceiling can never be written
    // correctly — reject BEFORE the O(n^3) reduction rather than after doing the work.
    if (colors.length > MAX_ENCODABLE_SLOT) return null;
    var maxPhysical = (opts.maxPhysical >= 1) ? Math.floor(opts.maxPhysical) : 4; // physical heads on the target
    var n = colors.length;
    var order = colors.map(function (_, i) { return i; }).sort(function (a, b) { return (usage[b] || 0) - (usage[a] || 0); });
    var physOld = (opts.physical && opts.physical.length === maxPhysical)
      ? opts.physical.slice(0, maxPhysical)
      : bestPhysicalSet(colors.slice(0, n), usage, opts.pinned || [], maxPhysical);
    var physHex = physOld.map(function (i, k) { return normalizeHex((opts.physicalHex && opts.physicalHex[k]) || colors[i]); });

    // Virtual mix slots follow the physical heads: 1..physOld.length are physical, mixes start after.
    var virtualBase = physOld.length + 1;
    var newOf = {};
    physOld.forEach(function (oldI, k) { newOf[oldI] = k + 1; });
    var mixDefs = [];
    var extras = [];
    var mixIdx = 0;
    order.forEach(function (oldI) {
      if (newOf[oldI] != null) return; // physical
      var mm = bestMixMulti(normalizeHex(colors[oldI]), physHex);
      var recipe;
      if (mm.ids.length === 1) { newOf[oldI] = mm.ids[0]; recipe = { kind: 'pure', ids: mm.ids, weights: [100] }; }
      else if (mm.ids.length === 2) {
        var a = mm.ids[0], b = mm.ids[1], pctB = mm.weights[1];
        if (pctB >= 92) { newOf[oldI] = b; recipe = { kind: 'pure', ids: [b], weights: [100] }; }
        else if (pctB <= 8) { newOf[oldI] = a; recipe = { kind: 'pure', ids: [a], weights: [100] }; }
        else {
          newOf[oldI] = virtualBase + mixIdx;
          mixDefs.push({ componentA: a, componentB: b, mixBPercent: pctB, stableId: ++mixIdx });
          recipe = { kind: 'mix2', ids: [a, b], weights: [100 - pctB, pctB] };
        }
      } else {
        newOf[oldI] = virtualBase + mixIdx;
        mixDefs.push({ componentA: mm.ids[0], componentB: mm.ids[1], mixBPercent: 50,
          gradientIds: mm.ids.join(''), gradientWeights: mm.weights.join('/'), distributionMode: 0, stableId: ++mixIdx });
        recipe = { kind: 'mix3', ids: mm.ids, weights: mm.weights };
      }
      if (recipe.kind !== 'pure') extras.push({ src: oldI, srcHex: normalizeHex(colors[oldI]), resultHex: mm.hex, deltaE: mm.deltaE, recipe: recipe });
    });

    var stateMap = function (s) { return s === 0 ? 0 : (newOf[s - 1] != null ? newOf[s - 1] : 1); };
    var map = colors.map(function (_, i) { return (newOf[i] != null ? newOf[i] : 1) - 1; });
    // The 3MF paint field encodes a state as a 2-bit low field plus a 4-BIT extension
    // holding (state - 3), so the highest representable slot is 18. MAX_FS_COLORS is 32
    // and mix slots run to physical + mixes, so a large palette could produce slot 19+,
    // which wrapped SILENTLY to a different valid filament (19 decoded as 3, 24 as 8) —
    // no throw, no warning, just the wrong colour printed. Refuse instead; the caller
    // already handles a null plan by falling back.
    if (physOld.length + mixDefs.length > MAX_ENCODABLE_SLOT) return null;
    return { physical: physOld, physicalHex: physHex, mixDefs: mixDefs, newOf: newOf, stateMap: stateMap, map: map, extras: extras };
  }

  var api = {
    planFullSpectrum: planFullSpectrum,
    bestMix: bestMix, bestMixMulti: bestMixMulti, bestPhysicalSet: bestPhysicalSet,
    deltaE: deltaE, rgbToLab: rgbToLab, hexToRgb: hexToRgb, normalizeHex: normalizeHex,
    remapPaintCode: remapPaintCode,
    serializeMixedDefs: serializeMixedDefs, serializeMixedDef: serializeMixedDef,
    MIXED_DITHERING_DEFAULTS: MIXED_DITHERING_DEFAULTS, MIN_MIX_RATIO: MIN_MIX_RATIO
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.fullSpectrum = api;
})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this));
