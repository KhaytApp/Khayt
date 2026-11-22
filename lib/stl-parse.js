'use strict';
/**
 * Pure STL geometry reader (binary + ASCII). No DOM, no Three.js — just maths,
 * so it runs in the renderer (ArrayBuffer from a FileReader) and under node --test.
 *
 * Returns physical facts only: triangle count, solid volume, bounding box, and
 * surface area. It NEVER estimates weight/time/price — see lib/stl-estimate.js.
 * Volume uses the signed-tetrahedron sum (Σ a·(b×c)/6), which is exact for a
 * closed mesh and robust enough for typical (near-closed) print models.
 */
(function (global) {
  function toDataView(buf) {
    if (buf instanceof DataView) return buf;
    if (buf instanceof ArrayBuffer) return new DataView(buf);
    if (ArrayBuffer.isView(buf)) return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    throw new Error('parseStl: expected ArrayBuffer/TypedArray/DataView');
  }

  // Binary STL: 80-byte header + uint32 count + 50 bytes/triangle. We confirm by
  // matching the declared count to the byte length (ASCII can falsely start
  // "solid", so the size check is the reliable discriminator).
  function looksBinary(dv) {
    if (dv.byteLength < 84) return false;
    const count = dv.getUint32(80, true);
    return dv.byteLength === 84 + count * 50;
  }

  /**
   * The running totals, fed one triangle at a time.
   *
   * Lifted out of a loop over a MATERIALISED triangle list, because building
   * that list cost roughly six times the file's own size in heap and the common
   * caller never wanted it. Measured before it was changed: a 250 MB binary STL
   * (5M triangles) parsed to 1,488 MB of heap in 1,459 ms with `keepTriangles`
   * OFF — `new Array(count)` of nested `[[x,y,z],…]` is forty million small
   * objects, allocated only to be summed and dropped. The same file now costs
   * 4 MB of heap and 164 ms.
   *
   * The arithmetic is unchanged, deliberately down to the ORDER of the adds.
   * Floating-point addition is not associative, so reordering these would move
   * the last digits of every volume this app has ever quoted; the numbers are
   * asserted equal to the old parser's, not merely close.
   */
  function accumulator() {
    let vol6 = 0, area2 = 0, n = 0;
    let minX = Infinity, minY = Infinity, minZ = Infinity;
    let maxX = -Infinity, maxY = -Infinity, maxZ = -Infinity;
    return {
      push(ax, ay, az, bx, by, bz, cx0, cy0, cz0) {
        n++;
        // signed volume of tetra (origin,a,b,c) ×6
        vol6 += ax * (by * cz0 - bz * cy0)
              - ay * (bx * cz0 - bz * cx0)
              + az * (bx * cy0 - by * cx0);
        // triangle area ×2 = |(b-a)×(c-a)|
        const ux = bx - ax, uy = by - ay, uz = bz - az;
        const vx = cx0 - ax, vy = cy0 - ay, vz = cz0 - az;
        const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
        area2 += Math.sqrt(nx * nx + ny * ny + nz * nz);
        if (ax < minX) minX = ax; if (ax > maxX) maxX = ax;
        if (ay < minY) minY = ay; if (ay > maxY) maxY = ay;
        if (az < minZ) minZ = az; if (az > maxZ) maxZ = az;
        if (bx < minX) minX = bx; if (bx > maxX) maxX = bx;
        if (by < minY) minY = by; if (by > maxY) maxY = by;
        if (bz < minZ) minZ = bz; if (bz > maxZ) maxZ = bz;
        if (cx0 < minX) minX = cx0; if (cx0 > maxX) maxX = cx0;
        if (cy0 < minY) minY = cy0; if (cy0 > maxY) maxY = cy0;
        if (cz0 < minZ) minZ = cz0; if (cz0 > maxZ) maxZ = cz0;
      },
      result() {
        return {
          triangleCount: n,
          volumeMm3: Math.abs(vol6) / 6,
          areaMm2: area2 / 2,
          bbox: n ? {
            x: maxX - minX, y: maxY - minY, z: maxZ - minZ,
            min: [minX, minY, minZ], max: [maxX, maxY, maxZ],
          } : { x: 0, y: 0, z: 0, min: [0, 0, 0], max: [0, 0, 0] },
        };
      },
    };
  }

  // When keepTriangles is requested, thread the raw triangle list out to the caller
  // (for thumbnail rendering). Off by default so the common path keeps its small
  // memory profile and unchanged return shape.
  function withTris(result, tris, opts) {
    if (opts && opts.keepTriangles) result.triangles = tris || [];
    return result;
  }

  function parseBinary(dv, opts) {
    const count = dv.getUint32(80, true);
    const keep = !!(opts && opts.keepTriangles);
    // Allocated only when the caller asked for it. This was `new Array(count)`
    // unconditionally, so every read paid for a list most reads discarded.
    const tris = keep ? new Array(count) : null;
    const acc = accumulator();
    let off = 84;
    for (let i = 0; i < count; i++) {
      off += 12; // skip the normal
      const f = (k) => dv.getFloat32(off + k, true);
      const ax = f(0), ay = f(4), az = f(8);
      const bx = f(12), by = f(16), bz = f(20);
      const cx = f(24), cy = f(28), cz = f(32);
      acc.push(ax, ay, az, bx, by, bz, cx, cy, cz);
      if (keep) tris[i] = [[ax, ay, az], [bx, by, bz], [cx, cy, cz]];
      off += 36 + 2; // 3 verts + 2-byte attribute
    }
    return withTris(Object.assign({ format: 'binary' }, acc.result()), tris, opts);
  }

  function parseAscii(text, opts) {
    const keep = !!(opts && opts.keepTriangles);
    const re = /vertex\s+(-?[\d.eE+]+)\s+(-?[\d.eE+]+)\s+(-?[\d.eE+]+)/g;
    const acc = accumulator();
    const tris = keep ? [] : null;
    // Three vertices at a time rather than all of them: this built a `nums`
    // array of every vertex in the file and then a SECOND array of triangles
    // from it, so an ASCII STL — already several times the size of the same mesh
    // in binary — cost the most of anything here.
    const v = [];
    let m;
    while ((m = re.exec(text)) !== null) {
      v.push(parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]));
      if (v.length < 9) continue;
      acc.push(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8]);
      if (keep) tris.push([[v[0], v[1], v[2]], [v[3], v[4], v[5]], [v[6], v[7], v[8]]]);
      v.length = 0;
    }
    return withTris(Object.assign({ format: 'ascii' }, acc.result()), tris, opts);
  }

  /**
   * Parse an STL → { format, triangleCount, volumeMm3, areaMm2, bbox{x,y,z,min,max} }.
   * Pass { keepTriangles:true } to also get `triangles` (array of [a,b,c] vertex triples)
   * for rendering — omit it (default) to keep the lean shape.
   */
  function parseStl(buf, opts) {
    const dv = toDataView(buf);
    if (looksBinary(dv)) return parseBinary(dv, opts);
    // ASCII fallback — decode bytes to text.
    let text;
    if (typeof TextDecoder !== 'undefined') text = new TextDecoder('utf-8').decode(dv);
    else text = Buffer.from(dv.buffer, dv.byteOffset, dv.byteLength).toString('utf8');
    if (!/facet|vertex/i.test(text)) {
      // Not ASCII either — best-effort binary read so a slightly-off size still works.
      if (dv.byteLength >= 84) return parseBinary(dv, opts);
      throw new Error('parseStl: unrecognized STL');
    }
    return parseAscii(text, opts);
  }

  const api = { parseStl, looksBinary };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStl = Object.assign(global.KhaytStl || {}, api);
})(typeof globalThis !== 'undefined' ? globalThis : this);
