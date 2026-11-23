'use strict';

(function (global) {
/**
 * What shape a g-code file prints, in a form that survives re-slicing.
 *
 * A print-file record is recognised by two keys, and for g-code both of them
 * change every time the model is sliced again:
 *
 *   contentHash  hashes the bytes. Re-slicing rewrites them — and so does merely
 *                exporting to a different filename, because slicers stamp the
 *                output path and a timestamp into the header. Two exports of one
 *                model at identical settings already hash differently.
 *   geometryKey  came from the mesh (triangle count, volume, bbox) and was only
 *                ever computed for STL. A shop that slices elsewhere and keeps
 *                only g-code has no mesh to take it from.
 *
 * So the same model came back a stranger every time, per-file calibration never
 * reached MIN_JOBS, and quotes fell back to the machine-wide median — which
 * misprices anything unlike the shop's recent average by 20%+ in either
 * direction, because grams-per-hour tracks a part's geometry far more than it
 * tracks the machine.
 *
 * What IS stable across a re-slice is the object's envelope. This walks the
 * extruding moves and records, for each of N height bands, how wide and deep the
 * printed material reaches — normalised by the overall bounding box, so the
 * bands describe a SHAPE rather than a size, and by height, so changing the layer
 * height moves nothing between bands.
 *
 * Measured on real slices (PrusaSlicer, one clip and one figure, each sliced at
 * 0.2 and 0.3 mm and at two infills):
 *
 *   same model, different settings   distance 0.000 – 0.002
 *   different models                 distance 0.304 – 0.306
 *
 * Two limits worth stating rather than discovering:
 *
 *   - This is an ENVELOPE. Two plaques of the same outer size whose faces carry
 *     different reliefs have the same silhouette, and will land on the same key.
 *     That is why the key feeds `similar` matching and never `exact` — see
 *     lib/model-identity.js, where exact means the bytes matched.
 *   - Arcs (G2/G3) are not traced, only their endpoints. No slicer in use here
 *     emits them by default, and an arc's endpoints still bound it, so the
 *     envelope is right even where the path between them is not.
 *
 * Streaming, because the caller reads only a file's head and tail for slicer
 * metadata and must not have to hold a 60 MB toolpath in memory to get this.
 * State is one entry per distinct Z, so memory tracks layer count, not file size.
 */

const DEFAULT_BANDS = 8;
/** One decimal. Two splits a model across keys: the same figure sliced at 0.2
 *  and 0.3 mm agreed to 0.01 on some bands and differed on others. */
const BAND_PRECISION = 1;

const isNum = (n) => typeof n === 'number' && Number.isFinite(n);
const round = (n, dp) => (isNum(n) ? Math.round(n * 10 ** dp) / 10 ** dp : null);

/**
 * Accumulates g-code lines and reports the printed envelope.
 * @param {{bands?: number}} [opts]
 */
function createSilhouette(opts = {}) {
  const bandCount = Math.max(2, Math.min(32, Number(opts.bands) || DEFAULT_BANDS));
  let x = 0; let y = 0; let z = 0;
  let relXYZ = false;   // G91
  let relE = false;     // M83 — PrusaSlicer and Orca both default to it
  let lastE = 0;
  let sawExtrusion = false;
  // z → extent of extruded material on that layer. One entry per layer, so this
  // stays small however large the file is.
  const layers = new Map();

  function push(rawLine) {
    // A comment can hold anything, including something that parses as a move.
    const line = String(rawLine == null ? '' : rawLine);
    const code = (line.indexOf(';') >= 0 ? line.slice(0, line.indexOf(';')) : line).trim();
    if (!code) return;
    const parts = code.split(/\s+/);
    const op = parts[0].toUpperCase();

    if (op === 'G90') { relXYZ = false; return; }
    if (op === 'G91') { relXYZ = true; return; }
    if (op === 'M82') { relE = false; return; }
    if (op === 'M83') { relE = true; return; }
    if (op === 'G92') {
      // Resets the origin of an axis; for E it is how absolute-E slicers zero
      // the extruder between objects. Missing it turns the next move into a
      // huge phantom extrusion.
      for (let i = 1; i < parts.length; i++) {
        const k = parts[i][0].toUpperCase();
        const v = Number(parts[i].slice(1));
        if (!Number.isFinite(v)) continue;
        if (k === 'E') lastE = v;
        else if (k === 'X') x = v;
        else if (k === 'Y') y = v;
        else if (k === 'Z') z = v;
      }
      return;
    }
    if (op !== 'G0' && op !== 'G1') return;

    let nx = x; let ny = y; let nz = z; let e = null;
    for (let i = 1; i < parts.length; i++) {
      const k = parts[i][0].toUpperCase();
      const v = Number(parts[i].slice(1));
      if (!Number.isFinite(v)) continue;
      if (k === 'X') nx = relXYZ ? x + v : v;
      else if (k === 'Y') ny = relXYZ ? y + v : v;
      else if (k === 'Z') nz = relXYZ ? z + v : v;
      else if (k === 'E') e = v;
    }

    const de = e === null ? 0 : (relE ? e : e - lastE);
    if (e !== null && !relE) lastE = e;

    // Only material laid down describes the object. Travel moves cross empty
    // space and would inflate the envelope to the whole build plate.
    if (de > 0 && (nx !== x || ny !== y)) {
      sawExtrusion = true;
      const key = Math.round(nz * 1000) / 1000;
      let L = layers.get(key);
      if (!L) { L = { minX: Infinity, maxX: -Infinity, minY: Infinity, maxY: -Infinity }; layers.set(key, L); }
      // Both ends: the move starts where the last one finished, and a layer's
      // first extrusion would otherwise contribute only its far end.
      for (const [px, py] of [[x, y], [nx, ny]]) {
        if (px < L.minX) L.minX = px;
        if (px > L.maxX) L.maxX = px;
        if (py < L.minY) L.minY = py;
        if (py > L.maxY) L.maxY = py;
      }
    }
    x = nx; y = ny; z = nz;
  }

  /** @returns {{bbox: {x:number,y:number,z:number}, bands: [number,number][], layers: number}|null} */
  function result() {
    if (!sawExtrusion || !layers.size) return null;
    let minX = Infinity; let maxX = -Infinity; let minY = Infinity; let maxY = -Infinity; let maxZ = 0;
    for (const [zz, L] of layers) {
      if (L.minX < minX) minX = L.minX;
      if (L.maxX > maxX) maxX = L.maxX;
      if (L.minY < minY) minY = L.minY;
      if (L.maxY > maxY) maxY = L.maxY;
      if (zz > maxZ) maxZ = zz;
    }
    const w = maxX - minX;
    const d = maxY - minY;
    if (!(w > 0) || !(d > 0) || !(maxZ > 0)) return null;

    const bands = [];
    for (let b = 0; b < bandCount; b++) {
      const lo = (maxZ * b) / bandCount;
      const hi = (maxZ * (b + 1)) / bandCount;
      let bx0 = Infinity; let bx1 = -Infinity; let by0 = Infinity; let by1 = -Infinity;
      let any = false;
      for (const [zz, L] of layers) {
        if (zz < lo || zz > hi) continue;
        any = true;
        if (L.minX < bx0) bx0 = L.minX;
        if (L.maxX > bx1) bx1 = L.maxX;
        if (L.minY < by0) by0 = L.minY;
        if (L.maxY > by1) by1 = L.maxY;
      }
      bands.push(any
        ? [round((bx1 - bx0) / w, BAND_PRECISION), round((by1 - by0) / d, BAND_PRECISION)]
        : [0, 0]);
    }
    return {
      bbox: { x: round(w, 1), y: round(d, 1), z: round(maxZ, 1) },
      bands,
      layers: layers.size,
    };
  }

  return { push, result };
}

/** Convenience for callers that already hold the whole text (tests, small files). */
function silhouetteFromText(text, opts) {
  const s = createSilhouette(opts);
  for (const line of String(text || '').split('\n')) s.push(line);
  return s.result();
}

const api = { createSilhouette, silhouetteFromText, DEFAULT_BANDS, BAND_PRECISION };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytGcodeGeometry = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
