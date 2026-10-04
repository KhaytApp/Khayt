'use strict';
/**
 * One file in, one answer out: how long will this print and how much filament
 * will it use?
 *
 * The calculator used to ask the user to know which button to press — "Parse
 * G-code / 3MF" or "Estimate from STL" — and they answer very different
 * questions. This module makes that one decision, and it always prefers the
 * answer that is *measured* over the answer that is *guessed*:
 *
 *   1. The slicer already computed it.  A .gcode, or a 3MF saved by
 *      PrusaSlicer / OrcaSlicer / Bambu Studio after slicing, carries the real
 *      print time and filament weight. That is not an estimate; it is what the
 *      printer is about to do. `source: 'slicer'`, `exact: true`.
 *
 *   2. Nobody sliced it.  An STL, an OBJ, or a 3MF that is only geometry gives
 *      volume and a bounding box. Weight and time then come from assumptions —
 *      density, infill, wall fraction, flow rate — and are a starting point for
 *      a human, not a quote. `source: 'geometry'`, `exact: false`.
 *
 * The distinction is the whole point of the module. A geometric estimate can be
 * out by a large factor on a sparse or heavily-supported part, and a quote that
 * cannot tell the shop which kind of number it is holding is worse than no
 * number at all. `exact` is therefore never true for a geometric result, and
 * callers are expected to say which one they are showing. Same discipline as
 * the currency work: no number that looks more certain than it is.
 *
 * Pure and fs-free — it takes bytes, so it runs in the main process (from a
 * path read), in the renderer (from a FileReader), and under node --test.
 */

const { parseGcodeText } = require('./gcode-parse.js');
const { parseStl } = require('./stl-parse.js');
const { parseObj, accumulateTriangles } = require('./obj-parse.js');
const mf = require('./mf-convert.js');
const printRisk = require('./print-risk.js');

/**
 * How many facets of a 3MF may be BUILT for the overhang report.
 *
 * Measuring no longer builds anything (mf-convert measureMesh), so this bounds
 * the one caller that still needs the triangles themselves. Building them costs
 * roughly 810 bytes a facet in nested arrays, so four million is about 3 GB and
 * is already generous; a model past it is measured exactly as any other and
 * comes back without the overhang lines.
 */
const MAX_RISK_FACETS = 4000000;

/**
 * Look at the mesh for what might go WRONG, not just what it will cost.
 *
 * Opt-in, because it needs the triangle list and a large model's triangle list
 * is large. Callers that want it pay the memory; the triangles are dropped again
 * the moment the analysis is done, so nothing bulky reaches the caller either
 * way. See lib/print-risk.js.
 */
function riskFrom(tris, opts) {
  if (!tris || !tris.length) return null;
  try {
    const analysis = printRisk.analyzeTriangles(tris, opts);
    const assessment = printRisk.assessModel({ ...(opts || {}), analysis });
    return {
      risks: assessment.risks,
      worst: assessment.worst,
      supportThresholdDeg: assessment.supportThresholdDeg,
      overhangFraction: analysis.totalAreaMm2 > 0
        ? printRisk.overhangAreaAbove(analysis, assessment.supportThresholdDeg) / analysis.totalAreaMm2
        : 0,
      meanThicknessMm: printRisk.meanThicknessMm(analysis.volumeMm3, analysis.totalAreaMm2),
    };
  } catch (e) {
    // A quote must survive a mesh this cannot read. Losing the risk report costs
    // a warning nobody sees; throwing costs the price the shop was asking for.
    return null;
  }
}

/** The geometry a caller gets — never the triangle list, however it was parsed. */
function slimGeometry(g) {
  if (!g) return g;
  if (!g.triangles) return g;
  const out = { ...g };
  delete out.triangles;
  return out;
}

/** Extensions we can say anything useful about. */
const SUPPORTED = ['gcode', 'gco', 'g', '3mf', 'stl', 'obj'];

const extOf = (filename) => {
  const s = String(filename || '');
  const dot = s.lastIndexOf('.');
  return dot === -1 ? '' : s.slice(dot + 1).toLowerCase();
};

function toBuffer(bytes) {
  if (Buffer.isBuffer(bytes)) return bytes;
  if (bytes instanceof ArrayBuffer) return Buffer.from(bytes);
  if (ArrayBuffer.isView(bytes)) return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (typeof bytes === 'string') return Buffer.from(bytes, 'utf8');
  return null;
}

/** A slicer answer is only usable if it carries BOTH numbers. */
const usable = (m) => !!(m && m.printTimeMins > 0 && m.filamentGrams > 0);

function blank(kind) {
  return {
    kind,
    exact: false,
    source: null,
    printTimeMins: null,
    filamentGrams: null,
    filamentType: null,
    filamentCost: null,
    slicer: null,
    geometry: null,
    risk: null,
    warnings: [],
  };
}

/**
 * A 3MF is a ZIP. The slicer's summary lives in a compressed member, so reading
 * the raw file as text finds nothing at all for any normally-written project —
 * the metadata is DEFLATE'd and simply is not in those bytes. It has to be
 * unzipped.
 *
 * Three shapes exist in the wild and all three are checked:
 *   - PrusaSlicer / SuperSlicer: Metadata/Slic3r_PE.config, gcode-comment syntax
 *   - Bambu Studio / Orca:       Metadata/slice_info.config, XML-ish attributes
 *   - "sliced 3MF":              an actual .gcode member inside the archive
 */
function from3mf(buf, out, riskOpts, opts) {
  let members;
  try { members = mf.readMembers(buf); } catch (e) { members = []; }
  if (!members || !members.length) {
    out.warnings.push('not-a-zip');
    return out;
  }

  // --- 0. A project of several plates ---------------------------------------
  /* EVERY PLATE, NOT THE FIRST (reported by a tester, Oct 2026: "I uploaded a
   * multi plate 3mf and it only shows the filament data and time for one").
   *
   * A Bambu/Orca "export all sliced plates" file carries one G-code PER PLATE
   * — Metadata/plate_1.gcode, plate_2.gcode, … — and step 1 below took the
   * first one it met and returned. So a two-plate project was quoted at plate
   * 1's hours and grams, while slice_info.config, which lists every plate, was
   * never asked. The Mac reads slice_info first (KhaytEngine.slicerFigures);
   * this is the same order, so both apps answer the same for the same file. */
  let meta = null;
  try { meta = mf.extractMeta(members); } catch (e) { meta = null; }
  if (meta && Array.isArray(meta.plates) && meta.plates.length >= 2
      && meta.totalGrams > 0 && meta.printMinutes > 0) {
    out.exact = true;
    out.source = 'slicer';
    out.printTimeMins = meta.printMinutes;
    out.filamentGrams = meta.totalGrams;
    out.filamentType = (meta.plates.find((p) => p.filamentType) || {}).filamentType || null;
    out.slicer = 'Bambu/Orca';
    out.plates = meta.plates;
    if (Array.isArray(meta.filaments)) out.filaments = meta.filaments;
    return out;
  }

  // --- 1. gcode-comment metadata, wherever it lives -------------------------
  // Ordered: a real embedded .gcode first, then Prusa/Slic3r's config. Both
  // speak the same comment syntax, so one parser covers them.
  const textual = members.filter((m) => /\.(gcode|gco|config|txt)$/i.test(m.name) && m.data);
  textual.sort((a, b) => (/\.gcode$/i.test(b.name) ? 1 : 0) - (/\.gcode$/i.test(a.name) ? 1 : 0));
  // Several embedded G-codes with no slice_info to list them are still
  // several plates: their figures are added, not the first one taken.
  const gcodes = [];
  for (const m of textual) {
    if (!/\.gcode$/i.test(m.name)) continue;
    let parsed;
    try { parsed = parseGcodeText(m.data.toString('utf8')); } catch (e) { continue; }
    if (usable(parsed)) gcodes.push(parsed);
  }
  if (gcodes.length > 1) {
    const sum = (k) => Math.round(gcodes.reduce((a, g) => a + (Number(g[k]) || 0), 0) * 100) / 100;
    out.exact = true;
    out.source = 'slicer';
    out.printTimeMins = sum('printTimeMins');
    out.filamentGrams = sum('filamentGrams');
    out.filamentType = (gcodes.find((g) => g.filamentType) || {}).filamentType || null;
    out.filamentCost = gcodes.every((g) => g.filamentCost != null) ? sum('filamentCost') : null;
    out.slicer = gcodes[0].slicer;
    return out;
  }
  for (const m of textual) {
    let parsed;
    try { parsed = parseGcodeText(m.data.toString('utf8')); } catch (e) { continue; }
    if (usable(parsed)) {
      out.exact = true;
      out.source = 'slicer';
      out.printTimeMins = parsed.printTimeMins;
      out.filamentGrams = parsed.filamentGrams;
      out.filamentType = parsed.filamentType;
      out.filamentCost = parsed.filamentCost;
      out.slicer = parsed.slicer;
      return out;
    }
  }

  // --- 2. Bambu / Orca slice_info + project settings ------------------------
  if (meta && meta.totalGrams > 0 && meta.printMinutes > 0) {
    out.exact = true;
    out.source = 'slicer';
    out.printTimeMins = meta.printMinutes;
    out.filamentGrams = meta.totalGrams;
    out.slicer = out.slicer || 'Bambu/Orca';
    return out;
  }

  // --- 3. Geometry only -----------------------------------------------------
  // Nothing sliced this. Fall back to the mesh, and say so.
  /* ASK THE PRICE BEFORE PAYING IT.
   *
   * Reading a 3MF's mesh is the most expensive thing in this file and its cost
   * is per FACET, not per byte — a 3MF is a compressed archive of XML, so bytes
   * are a poor proxy: measured on real files, a geometry-only 3MF costs about
   * 68x its own size in heap once the nested arrays exist (27.8 MB in, 1,886 MB
   * out, 8.2 s). _extractCore holds the resolved objects AND a second
   * transformed copy of every triangle, which is where that goes.
   *
   * countTriangles is a byte scan and answers in milliseconds — 2.33M facets
   * counted in 366 ms and 5 MB, against 8.2 s and 1,886 MB to build them. So
   * the decision is now made before the memory is spent rather than after.
   *
   * Over the budget the file is NOT refused: it keeps everything steps 1 and 2
   * found — print time, weight, material, slicer — which is what a sliced
   * project carries and is the answer that actually prices a job. What it loses
   * is the geometric fallback, and it says so.
   *
   * The number is above every real file to hand rather than a tightening: the
   * largest here is 2.33M facets and it works today. This exists to stop the
   * pathological case taking the app with it, not to refuse the ordinary one. */
  /* MEASURING NO LONGER NEEDS THE MESH.
   *
   * mf.measureMesh walks the same graph in the same order and folds each facet
   * into a running total, holding vertices in a Float64Array and indices in a
   * Uint32Array instead of building the triangles. Its numbers are asserted
   * EQUAL to accumulateTriangles(extractTriangles(…)), not close.
   *
   * That is the difference between a real file working and not: the posters and
   * kits a shop actually downloads run 8-16 MILLION facets, which the building
   * path wants 6-12 GB for. This holds a few hundred megabytes.
   *
   * Time is the part this cannot fix — thirteen million facets is about nine
   * seconds of arithmetic wherever it happens. `deferMesh` lets the caller take
   * that somewhere other than the thread drawing the app; main hands it to the
   * 3MF worker (lib/mf-jobs.js `measure`) and merges the answer back. */
  if (opts && opts.deferMesh) {
    out.source = 'geometry';
    out.warnings.push('mesh-deferred');
    return out;
  }
  if (typeof mf.measureMesh === 'function') {
    let g = null;
    try { g = mf.measureMesh(members); } catch (e) { g = null; }
    if (g) {
      out.source = 'geometry';
      out.geometry = g;
      // The overhang report is the one thing that still needs every triangle,
      // and it is only ever asked for by the quote screen. Bounded, because
      // building them is what this function just stopped doing by default.
      if (riskOpts) {
        const facets = (typeof mf.countTriangles === 'function') ? mf.countTriangles(members) : 0;
        if (facets > 0 && facets <= MAX_RISK_FACETS) {
          let tris = null;
          try { tris = mf.extractTriangles(members); } catch (e) { tris = null; }
          if (tris && tris.length) out.risk = riskFrom(tris, riskOpts);
          else out.warnings.push('risk-unavailable');
        } else {
          out.warnings.push('risk-unavailable');
        }
      }
      return out;
    }
    out.warnings.push('no-geometry');
    return out;
  }

  let tris = null;
  try { tris = mf.extractTriangles(members); } catch (e) { tris = null; }
  if (tris && tris.length) {
    out.source = 'geometry';
    out.geometry = accumulateTriangles(tris);
    if (riskOpts) out.risk = riskFrom(tris, riskOpts);
  } else {
    out.warnings.push('no-geometry');
  }
  return out;
}

/**
 * @param {{filename?: string, bytes: Buffer|ArrayBuffer|TypedArray|string}} input
 * @returns {{
 *   kind: string, exact: boolean, source: 'slicer'|'geometry'|null,
 *   printTimeMins: number|null, filamentGrams: number|null,
 *   filamentType: string|null, filamentCost: number|null, slicer: string|null,
 *   plates?: Array<{index, name, printTimeMins, filamentGrams, filamentType, filaments}>,
 *     present only for a project sliced as two or more plates; the totals
 *     above are their SUM,
 *   filaments?: Array<{id, type, color, grams, meters}>, per filament slot,
 *     summed over every plate (alongside `plates`),
 *   geometry: {volumeMm3, areaMm2, bbox, triangleCount}|null,
 *   risk: {risks, worst, overhangFraction, meanThicknessMm}|null,
 *   warnings: string[]
 * }}
 */
function intake(input, opts) {
  const filename = (input && input.filename) || '';
  const kind = extOf(filename);
  const out = blank(kind);
  // `risk: true` turns on the mesh analysis; anything else in `opts` (nozzle
  // diameter, the shop's support angle, the machine's bed) is passed straight
  // through to it, so the report answers THIS shop's question rather than a
  // generic one.
  const riskOpts = (opts && opts.risk) ? opts : null;

  const buf = toBuffer(input && input.bytes);
  if (!buf || !buf.length) {
    out.warnings.push('empty');
    return out;
  }
  if (!SUPPORTED.includes(kind)) {
    out.warnings.push('unsupported');
    return out;
  }

  try {
    if (kind === 'gcode' || kind === 'gco' || kind === 'g') {
      // Prusa/Orca write their summary in the FOOTER, Cura near the head. The
      // caller may hand us head+tail rather than a whole 200 MB file; either
      // way this only ever reads text.
      const parsed = parseGcodeText(buf.toString('utf8'));
      out.printTimeMins = parsed.printTimeMins;
      out.filamentGrams = parsed.filamentGrams;
      out.filamentType = parsed.filamentType;
      out.filamentCost = parsed.filamentCost;
      out.slicer = parsed.slicer;
      if (usable(parsed)) { out.exact = true; out.source = 'slicer'; }
      else out.warnings.push('no-slicer-summary');
      return out;
    }

    if (kind === '3mf') return from3mf(buf, out, riskOpts, opts);

    if (kind === 'stl') {
      out.source = 'geometry';
      const g = parseStl(buf, riskOpts ? { keepTriangles: true } : undefined);
      out.geometry = slimGeometry(g);
      if (riskOpts) out.risk = riskFrom(g.triangles, riskOpts);
      return out;
    }

    if (kind === 'obj') {
      out.source = 'geometry';
      const g = parseObj(buf, riskOpts ? { keepTriangles: true } : undefined);
      out.geometry = slimGeometry(g);
      if (riskOpts) out.risk = riskFrom(g.triangles, riskOpts);
      return out;
    }
  } catch (e) {
    out.warnings.push('parse-failed');
    out.source = null;
    out.geometry = null;
    out.risk = null;
    return out;
  }
  return out;
}

module.exports = { intake, SUPPORTED, extOf };
