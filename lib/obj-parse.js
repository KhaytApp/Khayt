'use strict';
/**
 * Pure OBJ geometry reader. No DOM, no Three.js — just maths, so it runs in the
 * renderer (ArrayBuffer from a FileReader) and under node --test.
 *
 * Returns the SAME shape as lib/stl-parse.js parseStl(): triangle count, solid
 * volume, bounding box, surface area. That is deliberate — lib/stl-estimate.js
 * takes `{ volumeMm3, bbox }` and does not care where the geometry came from, so
 * an OBJ prices through exactly the same path as an STL with no second estimator.
 * Like parseStl it NEVER estimates weight/time/price.
 *
 * OBJ is a text format. The parts that matter here:
 *
 *   v  x y z          a vertex, 1-indexed in declaration order
 *   f  1 2 3          a face, by vertex index
 *   f  1/1 2/2 3/3    with texture coords    — only the first field is geometry
 *   f  1//1 2//2      with normals           — likewise
 *   f  -1 -2 -3       NEGATIVE index, counted back from the most recent vertex
 *
 * Faces with more than three vertices are fanned into triangles (v0,vi,vi+1),
 * which is correct for the convex, planar faces OBJ exporters emit.
 *
 * Everything else — vt, vn, o, g, s, usemtl, mtllib, comments — is geometry-
 * irrelevant and skipped. A file that declares no usable face yields zero
 * triangles rather than throwing, so the caller can say "no geometry" instead of
 * showing a crash.
 */
(function (global) {
  function toText(buf) {
    if (typeof buf === 'string') return buf;
    if (typeof TextDecoder !== 'undefined') {
      if (buf instanceof ArrayBuffer) return new TextDecoder('utf-8').decode(new Uint8Array(buf));
      if (ArrayBuffer.isView(buf)) return new TextDecoder('utf-8').decode(buf);
    }
    if (typeof Buffer !== 'undefined') {
      if (buf instanceof ArrayBuffer) return Buffer.from(buf).toString('utf8');
      if (ArrayBuffer.isView(buf)) return Buffer.from(buf.buffer, buf.byteOffset, buf.byteLength).toString('utf8');
    }
    throw new Error('parseObj: expected string/ArrayBuffer/TypedArray');
  }

  /**
   * Resolve one face vertex reference to a 0-based index into `verts`.
   * Returns -1 for anything unusable, so a malformed face is dropped rather than
   * poisoning the volume with an undefined vertex.
   */
  function refToIndex(token, vertCount) {
    // "12/7/3" → 12. Only the position component is geometry. parseInt would
    // stop at the slash on its own; the split is here so that is obvious to a
    // reader rather than resting on parseInt's leniency.
    const slash = token.indexOf('/');
    const raw = slash === -1 ? token : token.slice(0, slash);
    const n = parseInt(raw, 10);
    if (!Number.isFinite(n) || n === 0) return -1;
    // A negative index counts back from the most recently declared vertex, so it
    // depends on how many vertices exist AT THIS POINT in the file, not in total.
    const idx = n < 0 ? vertCount + n : n - 1;
    return idx >= 0 && idx < vertCount ? idx : -1;
  }

  function accumulate(tris) {
    let vol6 = 0, area2 = 0;
    let minX = Infinity, minY = Infinity, minZ = Infinity;
    let maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity;
    for (const [a, b, c] of tris) {
      // Signed volume of the tetrahedron (origin, a, b, c) × 6 — the same
      // divergence-theorem sum parseStl uses, exact for a closed mesh.
      vol6 += a[0] * (b[1] * c[2] - b[2] * c[1])
            - a[1] * (b[0] * c[2] - b[2] * c[0])
            + a[2] * (b[0] * c[1] - b[1] * c[0]);
      const ux = b[0] - a[0], uy = b[1] - a[1], uz = b[2] - a[2];
      const vx = c[0] - a[0], vy = c[1] - a[1], vz = c[2] - a[2];
      const cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
      area2 += Math.sqrt(cx * cx + cy * cy + cz * cz);
      for (const p of [a, b, c]) {
        if (p[0] < minX) minX = p[0]; if (p[0] > maxX) maxX = p[0];
        if (p[1] < minY) minY = p[1]; if (p[1] > maxY) maxY = p[1];
        if (p[2] < minZ) minZ = p[2]; if (p[2] > maxZ) maxZ = p[2];
      }
    }
    const n = tris.length;
    return {
      triangleCount: n,
      volumeMm3: Math.abs(vol6) / 6,
      areaMm2: area2 / 2,
      bbox: n ? {
        x: maxX - minX, y: maxY - minY, z: maxZ - minZ,
        min: [minX, minY, minZ], max: [maxX, maxY, maxZ],
      } : { x: 0, y: 0, z: 0, min: [0, 0, 0], max: [0, 0, 0] },
    };
  }

  /**
   * @param {string|ArrayBuffer|TypedArray} buf
   * @param {{keepTriangles?: boolean}} [opts]
   * @returns {{triangleCount, volumeMm3, areaMm2, bbox, triangles?}}
   */
  function parseObj(buf, opts) {
    const text = toText(buf);
    const verts = [];
    const tris = [];

    for (const rawLine of text.split('\n')) {
      // Strip comments and normalise CR from Windows-authored files.
      const hash = rawLine.indexOf('#');
      const line = (hash === -1 ? rawLine : rawLine.slice(0, hash)).trim();
      if (!line) continue;

      // Split on the FIRST run of whitespace only; OBJ pads columns freely.
      const sp = line.search(/\s/);
      if (sp === -1) continue;
      const kind = line.slice(0, sp);
      if (kind !== 'v' && kind !== 'f') continue;      // vt/vn/o/g/s/usemtl…
      const parts = line.slice(sp).trim().split(/\s+/);

      if (kind === 'v') {
        const x = parseFloat(parts[0]), y = parseFloat(parts[1]), z = parseFloat(parts[2]);
        // A vertex line missing a coordinate is not a vertex. Pushing NaN would
        // make every volume downstream NaN, which reads as "0 g" in the form.
        if (Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z)) verts.push([x, y, z]);
        continue;
      }

      // kind === 'f'
      if (parts.length < 3) continue;
      const idx = [];
      for (const tok of parts) {
        const i = refToIndex(tok, verts.length);
        if (i === -1) { idx.length = 0; break; }       // drop the whole face
        idx.push(i);
      }
      if (idx.length < 3) continue;
      // Fan a polygon into triangles around its first vertex.
      for (let i = 1; i + 1 < idx.length; i++) {
        tris.push([verts[idx[0]], verts[idx[i]], verts[idx[i + 1]]]);
      }
    }

    const out = accumulate(tris);
    if (opts && opts.keepTriangles) out.triangles = tris;
    return out;
  }

  /** Cheap sniff for routing, not validation — parseObj tolerates junk anyway. */
  function looksObj(buf) {
    let head;
    try { head = toText(buf).slice(0, 4096); } catch (e) { return false; }
    return /^\s*(v|vn|vt|f|o|g|usemtl|mtllib)\s/m.test(head);
  }

  // accumulate() is exported because lib/model-intake.js needs the same
  // signed-volume sum for triangles it gets from a 3MF, and two copies of a
  // volume formula is two chances to be wrong about what a part weighs.
  const api = { parseObj, looksObj, accumulateTriangles: accumulate };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytObj = Object.assign(global.KhaytObj || {}, api);
})(typeof globalThis !== 'undefined' ? globalThis : this);
