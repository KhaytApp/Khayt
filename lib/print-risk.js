'use strict';
/**
 * What is likely to go wrong with this print, before anyone quotes it.
 *
 * Khayt already turns a model into a weight and a time. Neither of those says
 * whether the thing will actually come off the plate: a part can be priced
 * perfectly and still fail, and a failed print costs the filament, the hours,
 * and the customer's delivery date. That is a different question from "what does
 * it cost", and nothing here was asking it.
 *
 * WHAT IT READS, AND WHY IT IS CHEAP
 *
 * Nothing new has to be computed. `parseStl` and `obj-parse`'s accumulator
 * already walk every triangle and already form `(b-a)×(c-a)` — which IS the
 * facet normal, with the triangle's area as its length. The information needed
 * to find overhangs has been passing through those loops all along and being
 * thrown away. This module takes the same triangle list and keeps it.
 *
 * WHAT IT CANNOT SEE, STATED UP FRONT
 *
 * This is mesh geometry, not a slice. It does not know about supports (a shop
 * that always prints supported does not care about most overhangs), it cannot
 * find the THINNEST wall — only the mean — and it has no idea what the material
 * is. Every risk it reports is therefore a thing to look at, never a refusal,
 * and each one carries the measurement it is based on so the reader can judge it
 * rather than trust it. Same discipline as the estimator, which says outright
 * when a shape is one it cannot price.
 *
 * Pure: takes triangles, returns findings.
 */
(function (global) {
  const DEG = 180 / Math.PI;

  /** Slicer defaults sit between 45° (Cura) and 55° (PrusaSlicer). The lower one
   *  is the more cautious question to ask, and it is what callers may override. */
  const DEFAULT_SUPPORT_DEG = 45;
  /** Above this the underside is effectively a ceiling: a bridge, not a slope. */
  const BRIDGE_DEG = 80;

  /**
   * Overhang, in the sense a slicer means it.
   *
   * For a triangle with unit outward normal `n`, `-n.z` is the sine of the angle
   * the SURFACE makes with vertical:
   *
   *   vertical wall      n.z =  0    →   0°   (prints fine)
   *   45° underside      n.z = -0.71 →  45°   (the usual threshold)
   *   flat ceiling       n.z = -1    →  90°   (a bridge)
   *
   * Faces with n.z >= 0 point up or sideways and are not overhangs at all.
   */
  function overhangDegFor(nzUnit) {
    if (!(nzUnit < 0)) return null;
    return Math.asin(Math.min(1, -nzUnit)) * DEG;
  }

  /**
   * A face this close to vertical belongs to neither side.
   *
   * It is not a downward face in EITHER winding, and lumping it with one of them
   * makes the reading depend on which way the mesh happens to be wound: a box's
   * four walls have n.z of exactly 0, so putting them on the positive side means
   * a reversed box reports all four as downward-facing. Caught by the test that
   * asserts winding cannot change the answer, which is the whole reason that test
   * exists rather than being assumed.
   */
  const VERTICAL_EPS = 1e-9;

  /** A fresh set of the sums one orientation produces. */
  function blankSide() {
    return { area: 0, bedArea: 0, hist: new Float64Array(91) };
  }

  /**
   * Walk the mesh once and record where its downward-facing area is.
   *
   * @param {Array<[number[],number[],number[]]>} tris
   * @param {object} [opts]
   * @param {number} [opts.layerHeight=0.2]  used only to decide what counts as
   *        "resting on the plate" — see the bed exclusion below.
   */
  function analyzeTriangles(tris, opts) {
    const list = Array.isArray(tris) ? tris : [];
    const o = opts || {};
    const layerHeight = Number(o.layerHeight) > 0 ? Number(o.layerHeight) : 0.2;

    // Pass 1 is unavoidable: the bed is the model's lowest point, and a triangle
    // cannot be judged against it until every triangle has been seen.
    let minZ = Infinity;
    for (const t of list) {
      if (!t || t.length < 3) continue;
      for (const p of t) { if (p && p[2] < minZ) minZ = p[2]; }
    }
    if (!Number.isFinite(minZ)) minZ = 0;
    // A first layer's worth. Anything within it is sitting on the plate, which is
    // the one downward-facing surface that is never a problem — and it is usually
    // the largest, so counting it would drown every real overhang.
    const bedEps = Math.max(layerHeight, 0.05);

    // Both orientations are accumulated because the correct one is not known
    // until the winding is, and the winding is not known until the signed volume
    // is — which is also a whole-mesh quantity. Two small sums is cheaper than a
    // second pass over a million triangles.
    const neg = blankSide();   // area whose computed normal points down
    const pos = blankSide();   // …and up, in case the winding is inverted
    let vol6 = 0;
    let totalArea = 0;
    let degenerate = 0;

    for (const t of list) {
      if (!t || t.length < 3) { degenerate++; continue; }
      const a = t[0]; const b = t[1]; const c = t[2];
      if (!a || !b || !c) { degenerate++; continue; }

      vol6 += a[0] * (b[1] * c[2] - b[2] * c[1])
            - a[1] * (b[0] * c[2] - b[2] * c[0])
            + a[2] * (b[0] * c[1] - b[1] * c[0]);

      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
      const vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
      const len = Math.sqrt(cx * cx + cy * cy + cz * cz);
      if (!(len > 0)) { degenerate++; continue; }   // zero-area sliver: no normal to speak of
      const area = len / 2;
      totalArea += area;

      const nz = cz / len;
      // On the plate if the whole triangle is inside the first layer. Checked on
      // the highest vertex so a triangle standing UP from the bed is not excused.
      const topZ = Math.max(a[2], b[2], c[2]);
      const onBed = topZ <= minZ + bedEps;

      // Vertical faces are downward in neither reading — see VERTICAL_EPS.
      if (nz > -VERTICAL_EPS && nz < VERTICAL_EPS) continue;
      const side = nz < 0 ? neg : pos;
      side.area += area;
      if (onBed) { side.bedArea += area; continue; }
      const deg = overhangDegFor(nz < 0 ? nz : -nz);
      if (deg !== null) side.hist[Math.min(90, Math.round(deg))] += area;
    }

    // Which set is really facing down?
    //
    // A closed mesh wound outward has a positive signed volume, so the sign
    // settles it. When it does not — an open or broken mesh, where the sum means
    // nothing — fall back to a physical fact instead: the model is resting on the
    // plate, so the orientation that puts MORE area flat on the bed is the one
    // whose normals point down. That is a better answer than trusting a number
    // that is known to be meaningless.
    const volumeMm3 = Math.abs(vol6) / 6;
    const volumeTrustworthy = volumeMm3 > 1e-6;
    const flipped = volumeTrustworthy ? vol6 < 0 : pos.bedArea > neg.bedArea;
    const down = flipped ? pos : neg;

    return {
      triangleCount: list.length,
      degenerateTriangles: degenerate,
      totalAreaMm2: totalArea,
      downwardAreaMm2: down.area,
      bedContactAreaMm2: down.bedArea,
      histogram: down.hist,
      bedZ: minZ,
      windingFlipped: flipped,
      windingFromVolume: volumeTrustworthy,
      volumeMm3,
    };
  }

  /** Downward-facing area steeper than `deg`, excluding anything on the plate. */
  function overhangAreaAbove(analysis, deg) {
    const h = analysis && analysis.histogram;
    if (!h) return 0;
    let sum = 0;
    for (let i = Math.max(0, Math.ceil(Number(deg) || 0)); i < h.length; i++) sum += h[i];
    return sum;
  }

  /**
   * Mean wall thickness, from volume and surface area alone.
   *
   * For anything plate-like or shell-like, `2V/A` IS the thickness — a 100×100×1
   * plate has V = 10,000 and A ≈ 20,400, giving 0.98 mm. For a solid lump it
   * degrades into a size scale instead (a sphere gives 2r/3), which is harmless:
   * a lump is not what this is looking for.
   *
   * It is a MEAN, and the honest limit of that is worth stating rather than
   * burying — a chunky part with one thin fin will not trip it, because the fin
   * is a rounding error in both totals. It catches the part that is thin all
   * over, which is the part a shop quotes and then cannot print.
   */
  function meanThicknessMm(volumeMm3, areaMm2) {
    const v = Number(volumeMm3) || 0;
    const a = Number(areaMm2) || 0;
    if (!(v > 0) || !(a > 0)) return null;
    return (2 * v) / a;
  }

  /**
   * Where the lines are, and how they were chosen.
   *
   * Measured across 60-odd real models on the bench — functional parts, printer
   * spares, figurines, vases, wall-thickness test coupons — rather than picked
   * because they sound reasonable. The distribution came out clean enough to cut:
   *
   *   overhang beyond 45°, as a fraction of total surface area
   *     0–2%    print-ready functional parts (clips, brackets, panels, trays)
   *     10–15%  mixed geometry (a dino body, a skateboarder, a hinge)
   *     18–24%  organic figurines and vehicles — supports are not optional
   *
   *   near-horizontal underside (beyond 80°) — the kind that SAGS rather than
   *   merely looks rough
   *     ~0–1%   functional parts
   *     15–23%  an airship, a battery box, a dispenser
   *
   * `thin` is anchored on the nozzle rather than on the corpus, because that one
   * has a physical answer: a wall thinner than the nozzle bore cannot be laid
   * down at all, and one under two bore widths is a single perimeter with nothing
   * either side of it. A 0.8 mm wall-thickness test coupon measures 0.71 mm mean
   * and lands in `warn`, which is the correct answer for a part that prints only
   * if the slicer has been set up for it.
   */
  const THRESHOLD = {
    /** Fraction of surface area overhanging past the support angle. */
    overhangNotable: 0.05,
    overhangHeavy: 0.15,
    /** Fraction that is near-horizontal underside. */
    bridgeHeavy: 0.08,
    /** Mean wall thickness, in multiples of the nozzle bore. */
    thinCritical: 1.0,
    thinWarning: 2.0,
  };

  const SEVERITY_RANK = { info: 1, warn: 2, crit: 3 };

  /**
   * Everything worth a second look before this model is quoted.
   *
   * Every finding carries the measurement behind it, so the reader can disagree
   * with it. A shop that supports everything by default will scroll past the
   * overhang line; a shop quoting a figurine as if it were a bracket will not.
   *
   * @param {object}  input
   * @param {object}  input.analysis              analyzeTriangles() output
   * @param {object}  [input.geometry]            {volumeMm3, areaMm2, bbox} — falls back to analysis
   * @param {number}  [input.nozzleDiameter=0.4]
   * @param {number}  [input.supportThresholdDeg=45]  the shop's own slicer setting
   * @param {{x:number,y:number,z:number}} [input.bed]  build volume, when known
   * @returns {{risks: object[], worst: string|null, supportThresholdDeg: number}}
   */
  function assessModel(input) {
    const inp = input || {};
    const analysis = inp.analysis || null;
    const geom = inp.geometry || analysis || {};
    const nozzle = Number(inp.nozzleDiameter) > 0 ? Number(inp.nozzleDiameter) : 0.4;
    const supportDeg = Number(inp.supportThresholdDeg) > 0
      ? Number(inp.supportThresholdDeg) : DEFAULT_SUPPORT_DEG;
    const risks = [];

    const totalArea = Number(analysis && analysis.totalAreaMm2) || Number(geom.areaMm2) || 0;

    if (analysis && totalArea > 0) {
      const overhangArea = overhangAreaAbove(analysis, supportDeg);
      const bridgeArea = overhangAreaAbove(analysis, BRIDGE_DEG);
      const overhangFraction = overhangArea / totalArea;
      const bridgeFraction = bridgeArea / totalArea;

      if (overhangFraction >= THRESHOLD.overhangNotable) {
        risks.push({
          id: 'overhang',
          severity: overhangFraction >= THRESHOLD.overhangHeavy ? 'warn' : 'info',
          fraction: overhangFraction,
          areaMm2: overhangArea,
          thresholdDeg: supportDeg,
        });
      }
      // Reported separately from `overhang`, not folded into it. A 50° slope
      // prints rough; a flat ceiling with nothing under it droops into the cavity
      // below. They fail differently and they are fixed differently.
      if (bridgeFraction >= THRESHOLD.bridgeHeavy) {
        risks.push({
          id: 'bridge',
          severity: 'warn',
          fraction: bridgeFraction,
          areaMm2: bridgeArea,
          thresholdDeg: BRIDGE_DEG,
        });
      }
    }

    const thickness = meanThicknessMm(
      Number(geom.volumeMm3) || (analysis && analysis.volumeMm3) || 0, totalArea,
    );
    if (thickness !== null) {
      const bores = thickness / nozzle;
      if (bores < THRESHOLD.thinWarning) {
        risks.push({
          id: 'thin',
          severity: bores < THRESHOLD.thinCritical ? 'crit' : 'warn',
          meanThicknessMm: thickness,
          nozzleDiameter: nozzle,
          bores,
        });
      }
    }

    // Does it fit? The only check here with no threshold to argue about — either
    // the box is inside the build volume or it is not. Checked with the part
    // turned a quarter-turn as well, because "rotate it 90°" is a real answer and
    // reporting a part as too big when it merely needs turning is a false alarm
    // the operator has to disprove by hand.
    const bed = inp.bed;
    const bbox = geom.bbox || (analysis && analysis.bbox);
    if (bed && bbox && Number(bed.x) > 0 && Number(bed.y) > 0) {
      const fits = (w, d) => w <= Number(bed.x) && d <= Number(bed.y);
      const tallEnough = !(Number(bed.z) > 0) || (Number(bbox.z) || 0) <= Number(bed.z);
      const flat = fits(Number(bbox.x) || 0, Number(bbox.y) || 0);
      const turned = fits(Number(bbox.y) || 0, Number(bbox.x) || 0);
      if (!tallEnough || (!flat && !turned)) {
        risks.push({
          id: 'bed', severity: 'crit',
          bbox: { x: Number(bbox.x) || 0, y: Number(bbox.y) || 0, z: Number(bbox.z) || 0 },
          bed: { x: Number(bed.x), y: Number(bed.y), z: Number(bed.z) || 0 },
          tooTall: !tallEnough,
        });
      } else if (!flat && turned) {
        risks.push({ id: 'bed-rotate', severity: 'info' });
      }
    }

    // A mesh whose winding had to be corrected is worth mentioning once. It is
    // not a print risk on its own — this module handled it — but it is a sign the
    // file has been through something, and the next tool in the chain may not be
    // as forgiving.
    if (analysis && analysis.windingFlipped) {
      risks.push({ id: 'inverted-winding', severity: 'info' });
    }

    let worst = null;
    for (const r of risks) {
      if (!worst || SEVERITY_RANK[r.severity] > SEVERITY_RANK[worst]) worst = r.severity;
    }
    return { risks, worst, supportThresholdDeg: supportDeg };
  }

  /**
   * WHEN the mesh gets walked: when the shop asks, or as each file arrives.
   *
   * This is a setting because the two answers are right for different shops,
   * and neither is right for both.
   *
   * `demand` — the default. The walk costs seconds on a real file: this shop's
   * models run eight to sixteen million facets, and forming `(b-a)x(c-a)` and
   * its length for each one is about nine seconds of arithmetic however fast
   * the disk is. A shop importing a folder of four hundred models would spend
   * an hour of that before seeing its library, to answer a question it has not
   * asked about 399 of them.
   *
   * `import` — for a shop that quotes from its library rather than from a file
   * a customer just sent. Pay it once, while the import is already reading the
   * bytes and the shop is already waiting, and every model afterwards answers
   * instantly.
   *
   * Defaulting to `demand` is the conservative choice in the sense that
   * matters: it cannot make an existing workflow slower. Turning it on is a
   * decision a shop makes about its own library.
   *
   * Anything unrecognised — a future value, a typo, a field synced down from a
   * build that spells it differently — reads as `demand`, so an unknown setting
   * cannot silently add an hour to an import.
   */
  const RISK_WHEN = ['demand', 'import'];
  const DEFAULT_RISK_WHEN = 'demand';

  function riskWhen(settings) {
    const s = settings || {};
    const pr = s.printRisk || (s.settings && s.settings.printRisk) || {};
    const v = String(pr.when == null ? '' : pr.when).trim().toLowerCase();
    return RISK_WHEN.indexOf(v) === -1 ? DEFAULT_RISK_WHEN : v;
  }

  /** True when an import should walk the mesh as the file lands. */
  function analyseAtImport(settings) {
    return riskWhen(settings) === 'import';
  }

  const api = {
    analyzeTriangles, overhangAreaAbove, meanThicknessMm, overhangDegFor, assessModel,
    DEFAULT_SUPPORT_DEG, BRIDGE_DEG, THRESHOLD,
    riskWhen, analyseAtImport, RISK_WHEN, DEFAULT_RISK_WHEN,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintRisk = Object.assign(global.KhaytPrintRisk || {}, api);
})(typeof globalThis !== 'undefined' ? globalThis : this);
