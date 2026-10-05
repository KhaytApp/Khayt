'use strict';
/*
 * Vertical colour-band detection — a Node port of the bedready.io web reference (src/lib/color-bands.ts).
 *
 * Detects whether a painted model is VERTICALLY colour-banded — every layer a single colour, the colour
 * only changing as you go up in Z. When it is, all colours can be printed EXACTLY on a swap-capable
 * printer (e.g. the Snapmaker U1) by pausing for a filament swap at each band boundary — no Full Spectrum
 * approximation, no dropped colours.
 *
 * The load-bearing distinction: vertical colour (Z-stratified, one colour per layer) is a manual-swap job;
 * horizontal / in-layer colour (a logo, text inset, gradient sharing a layer) genuinely needs multiple
 * toolheads. So the test is NOT "each colour sits in a contiguous Z range" — it's "is every thin Z slice
 * essentially one colour?". A logo that shares layers with the wall behind it makes those slices
 * two-coloured and correctly disqualifies the model.
 *
 * Input is the extracted mesh (see lib/mf-mesh.js): `positions` = 9 floats per face (3 verts × xyz, already
 * transformed to true coordinates), `faceState` = filament state per face (0 = base → baseState).
 */
(function (global) {
  const HEADS = 4; // U1 physical toolheads

  /**
   * Analyse a painted mesh for clean vertical colour banding. Pure + Worker-safe (no DOM).
   * @param {Float32Array} positions 9 floats per face
   * @param {Uint8Array} faceState filament state per face (0 = base)
   * @param {number} baseState 1-based state that base (unpainted) faces resolve to
   * @param {{ binHeight?:number, purity?:number }} [opts]
   * @returns {{ banded:boolean, bands:{state:number,z0:number,z1:number}[], changeHeights:number[],
   *            colorCount:number, manualSwaps:number, purity:number, reason:string }}
   */
  function detectColorBands(positions, faceState, baseState, opts) {
    opts = opts || {};
    const binHeight = opts.binHeight && opts.binHeight > 0 ? opts.binHeight : 0.2;
    const purityMin = opts.purity != null ? opts.purity : 0.9;
    const faceCount = faceState.length;
    const none = (reason) => ({ banded: false, bands: [], changeHeights: [], colorCount: 0, manualSwaps: 0, purity: 0, reason });

    if (faceCount === 0 || positions.length < faceCount * 9) return none('no geometry to analyse');

    // Global Z extent.
    let zMin = Infinity, zMax = -Infinity;
    for (let f = 0; f < faceCount; f++) {
      const o = f * 9;
      for (const zi of [o + 2, o + 5, o + 8]) {
        const z = positions[zi];
        if (z < zMin) zMin = z;
        if (z > zMax) zMax = z;
      }
    }
    const span = zMax - zMin;
    if (!(span > 0)) return none('model has no height');

    // Slice height into bins; cap the count so a very tall model stays cheap (coarser bins are fine here).
    const nbins = Math.min(4000, Math.max(1, Math.ceil(span / binHeight)));
    const binH = span / nbins;
    const binOf = (z) => Math.min(nbins - 1, Math.max(0, Math.floor((z - zMin) / binH)));

    // Per-bin colour → surface area (area-weighted so a stray sliver can't outvote a wall).
    const bins = [];
    for (let i = 0; i < nbins; i++) bins.push(new Map());
    const binTotal = new Float64Array(nbins);

    for (let f = 0; f < faceCount; f++) {
      const o = f * 9;
      const ax = positions[o], ay = positions[o + 1], az = positions[o + 2];
      const bx = positions[o + 3], by = positions[o + 4], bz = positions[o + 5];
      const cx = positions[o + 6], cy = positions[o + 7], cz = positions[o + 8];
      // 3D triangle area = ½|(B−A)×(C−A)|.
      const ux = bx - ax, uy = by - ay, uz = bz - az;
      const vx = cx - ax, vy = cy - ay, vz = cz - az;
      const cxx = uy * vz - uz * vy, cyy = uz * vx - ux * vz, czz = ux * vy - uy * vx;
      const area = 0.5 * Math.hypot(cxx, cyy, czz);
      if (!(area > 0)) continue;

      const state = faceState[f] === 0 ? baseState : faceState[f];
      const flo = Math.min(az, bz, cz), fhi = Math.max(az, bz, cz);

      if (fhi - flo < 1e-9) {
        // Flat (horizontal) face — lives entirely in one bin.
        const b = binOf(flo);
        bins[b].set(state, (bins[b].get(state) || 0) + area);
        binTotal[b] += area;
        continue;
      }
      // Spread the face's area across every bin its Z-extent overlaps, proportional to the overlap.
      const first = binOf(flo), last = binOf(fhi);
      const inv = 1 / (fhi - flo);
      for (let b = first; b <= last; b++) {
        const bBot = zMin + b * binH, bTop = bBot + binH;
        const ov = Math.min(fhi, bTop) - Math.max(flo, bBot);
        if (ov <= 0) continue;
        const a = area * ov * inv;
        bins[b].set(state, (bins[b].get(state) || 0) + a);
        binTotal[b] += a;
      }
    }

    // Dominant colour per (non-empty) bin + overall purity (area in each bin's dominant colour).
    const dom = new Array(nbins).fill(0); // 0 = empty bin
    let domArea = 0, totArea = 0;
    for (let b = 0; b < nbins; b++) {
      totArea += binTotal[b];
      if (binTotal[b] <= 0) continue;
      let best = 0, bestA = -1;
      for (const [s, a] of bins[b]) if (a > bestA) { bestA = a; best = s; }
      dom[b] = best;
      domArea += bestA;
    }
    const purity = totArea > 0 ? domArea / totArea : 0;
    if (purity < purityMin) {
      return { banded: false, bands: [], changeHeights: [], colorCount: 0, manualSwaps: 0, purity, reason: 'colours share layers (in-layer detail) — needs multiple heads, not a swap' };
    }

    // Compress the dominant-colour sequence of non-empty bins into bands, smoothing lone single-bin flips
    // (a seam bin can momentarily read as the neighbouring colour) so they don't spawn spurious 1-bin bands.
    const seq = [];
    for (let b = 0; b < nbins; b++) if (dom[b] !== 0) seq.push({ state: dom[b], bin: b });
    if (seq.length === 0) return none('no colour data');
    for (let i = 1; i < seq.length - 1; i++) {
      if (seq[i].state !== seq[i - 1].state && seq[i - 1].state === seq[i + 1].state) seq[i].state = seq[i - 1].state;
    }

    const bands = [];
    for (const { state, bin } of seq) {
      const bBot = zMin + bin * binH, bTop = bBot + binH;
      const cur = bands[bands.length - 1];
      if (cur && cur.state === state) cur.z1 = bTop;
      else bands.push({ state, z0: bBot, z1: bTop });
    }

    const changeHeights = bands.slice(1).map((b) => b.z0);
    const colorCount = new Set(bands.map((b) => b.state)).size;
    // Count what the swap PLANNER will actually emit, by mirroring its assignment exactly
    // (lib/swap-pauses.js:170-177): colours take heads in order of first appearance up Z,
    // round-robin once they run out; a swap happens whenever a band's assigned head is
    // currently holding a different colour.
    //
    // `bands.length - HEADS` was wrong in both directions. A colour recurring up Z makes
    // several bands but occupies ONE head — 1,2,1,2,1,2 is 6 bands and 2 colours, which
    // fits 4 heads with zero swaps, yet it reported 2 and the converter printed "…with 2
    // filament swap(s)" directly above a row saying "No manual swap needed". And on a
    // single-extruder machine that same sequence needs FIVE swaps, which neither the old
    // formula nor a simple colours-minus-heads gets right.
    const heads = (opts.heads && opts.heads > 0) ? opts.heads : HEADS;
    const manualSwaps = (() => {
      const order = [];
      for (const b of bands) if (order.indexOf(b.state) < 0) order.push(b.state);
      const headOf = new Map();
      order.forEach((st, i) => headOf.set(st, i % heads));
      const loaded = new Map();      // head -> colour currently on it
      let swaps = 0;
      for (const b of bands) {
        const h = headOf.get(b.state);
        if (loaded.has(h) && loaded.get(h) !== b.state) swaps++;
        loaded.set(h, b.state);
      }
      return swaps;
    })();
    return {
      banded: true,
      bands,
      changeHeights,
      colorCount,
      manualSwaps,
      purity,
      reason: bands.length <= 1
        ? 'single colour — no swaps needed'
        : `${bands.length} colour bands; ${manualSwaps} manual filament swap${manualSwaps === 1 ? '' : 's'} on the U1`,
    };
  }

  // ── PER PLATE ─────────────────────────────────────────────────────────────────────────────
  // detectColorBands answers "is every thin Z slice one colour?", and a multi-plate file breaks
  // the question rather than the answer: the mesh arrives in PLATE-LAYOUT space with every plate
  // standing at z=0, so slicing the whole file slices every plate at once. Ported from bedready.io
  // (src/lib/color-bands.ts detectColorBandsForMesh + src/lib/print-groups.ts, its #13), where both
  // failure modes were reproduced against the real detector:
  //   • two plates each cleanly banded → banded=false, "colours share layers" — false; they share a
  //     Z range, not layers, and the exact-swap path was lost;
  //   • one plate big enough to carry the area-weighted purity vote → banded=TRUE with ITS swap
  //     heights, silently wrong for every other plate. That plan reaches the converter, which writes
  //     those heights into the output file as M600 pauses — a wrong answer here is a wrong file.
  // The second is the one that matters, so this is deliberately conservative: a file qualifies only
  // if EVERY plate is banded and they agree on the colours AND where the swaps are. Plates that disagree have no
  // single valid plan; the honest answer is "not a band-swap candidate".

  /**
   * What prints together: one group per plate, each a list of { positions, faceState } slices.
   * lib/mf-mesh.js describes a part as a face RANGE (start/end) into the flat arrays rather than
   * arrays of its own, so a part is sliced out here (subarray — no copy). A file with no plate
   * structure is one group holding everything: every build item goes down on the same bed.
   */
  function printGroups(mesh) {
    const parts = Array.isArray(mesh.parts) ? mesh.parts : [];
    const plates = Array.isArray(mesh.plates) ? mesh.plates : [];
    const slice = (p) => (p && p.positions ? { positions: p.positions, faceState: p.faceState || new Uint8Array(0) }
      : p && Number.isInteger(p.start) && Number.isInteger(p.end)
        ? { positions: mesh.positions.subarray(p.start * 9, p.end * 9), faceState: mesh.faceState.subarray(p.start, p.end) }
        : null);
    if (plates.length > 1) {
      return plates
        .map((pl) => ({ name: pl.name || '', parts: (pl.partIndices || []).map((i) => slice(parts[i])).filter(Boolean) }))
        .filter((g) => g.parts.length > 0);
    }
    return [{ name: (plates[0] && plates[0].name) || '', parts: [{ positions: mesh.positions, faceState: mesh.faceState }] }];
  }

  /** A group's slices as one contiguous pair of arrays. Zero-copy when there is only one. */
  function flattenGroup(group) {
    const parts = group.parts;
    if (parts.length === 1) return parts[0];
    let posLen = 0, stLen = 0;
    for (const p of parts) { posLen += p.positions.length; stLen += p.faceState.length; }
    const positions = new Float32Array(posLen), faceState = new Uint8Array(stLen);
    let pi = 0, si = 0;
    for (const p of parts) { positions.set(p.positions, pi); pi += p.positions.length; faceState.set(p.faceState, si); si += p.faceState.length; }
    return { positions, faceState };
  }

  /** Two plans agree when their swap heights match to within half a bin — the same physical pauses. */
  function sameSwaps(a, b, tol) {
    return a.length === b.length && a.every((h, i) => Math.abs(h - b[i]) <= tol);
  }

  /**
   * Band analysis over an extracted mesh (lib/mf-mesh.js), asked PER PLATE. Use this instead of
   * handing detectColorBands a whole file's positions — see the note above. Same return shape.
   */
  function detectColorBandsForMesh(mesh, baseState, opts) {
    opts = opts || {};
    const groups = printGroups(mesh);
    const plans = groups.map((g) => {
      const f = flattenGroup(g);
      return { name: g.name, plan: detectColorBands(f.positions, f.faceState, baseState, opts) };
    });
    if (plans.length === 0) return detectColorBands(new Float32Array(0), new Uint8Array(0), baseState, opts);
    if (plans.length === 1) return plans[0].plan;

    const named = (n, i) => n || `plate ${i + 1}`;
    const unbanded = plans.findIndex((p) => !p.plan.banded);
    if (unbanded >= 0) {
      return Object.assign({}, plans[unbanded].plan, { reason: `${named(plans[unbanded].name, unbanded)}: ${plans[unbanded].plan.reason}` });
    }
    const tol = (opts.binHeight && opts.binHeight > 0 ? opts.binHeight : 0.2) / 2;
    const first = plans[0].plan;
    // The SAME COLOURS IN THE SAME ORDER, not only the same heights. A plan is a list of colours
    // per band, and the converter assigns heads from the one it returns: plate A red→blue at 10 mm
    // and plate B green→yellow at 10 mm agreed on heights, so the file came back banded with A's
    // bands alone and B's colours were sent to head 1. (bedready.io's detectColorBandsForMesh,
    // which this was ported from, compares heights only and has the same hole.)
    const seq = (p) => p.bands.map((b) => b.state).join(',');
    const otherColours = plans.findIndex((p) => seq(p.plan) !== seq(first));
    if (otherColours > 0) {
      const names = (p) => p.bands.map((b) => b.state).join('→');
      return {
        banded: false, bands: [], changeHeights: [], colorCount: 0, manualSwaps: 0,
        purity: Math.min.apply(null, plans.map((p) => p.plan.purity)),
        reason: `each plate is banded, but with different colours (${named(plans[0].name, 0)} ${names(first)}, `
          + `${named(plans[otherColours].name, otherColours)} ${names(plans[otherColours].plan)}) — convert one plate at a time to use swaps`,
      };
    }
    const differing = plans.findIndex((p) => !sameSwaps(p.plan.changeHeights, first.changeHeights, tol));
    if (differing > 0) {
      const at = (p) => p.changeHeights.map((h) => h.toFixed(1)).join('/');
      return {
        banded: false, bands: [], changeHeights: [], colorCount: 0, manualSwaps: 0,
        purity: Math.min.apply(null, plans.map((p) => p.plan.purity)),
        reason: `each plate is banded, but they need different swap heights (${named(plans[0].name, 0)} at ${at(first)} mm, `
          + `${named(plans[differing].name, differing)} at ${at(plans[differing].plan)} mm) — convert one plate at a time to use swaps`,
      };
    }
    return first;
  }

  const api = { detectColorBands, detectColorBandsForMesh, printGroups, flattenGroup, HEADS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytColorBands = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
