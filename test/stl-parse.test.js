'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const { parseStl, looksBinary } = require('../lib/stl-parse');
const { estimateFromStl } = require('../lib/stl-estimate');

// Build a binary STL of an axis-aligned cube [0,s]^3 (12 triangles).
function cubeBinary(s) {
  const v = [
    [0, 0, 0], [s, 0, 0], [s, s, 0], [0, s, 0], // bottom z=0
    [0, 0, s], [s, 0, s], [s, s, s], [0, s, s], // top z=s
  ];
  // outward-facing triangles (winding doesn't matter — volume is abs'd)
  const f = [
    [0, 1, 2], [0, 2, 3], // bottom
    [4, 6, 5], [4, 7, 6], // top
    [0, 4, 5], [0, 5, 1], // y=0
    [1, 5, 6], [1, 6, 2], // x=s
    [2, 6, 7], [2, 7, 3], // y=s
    [3, 7, 4], [3, 4, 0], // x=0
  ];
  const buf = new ArrayBuffer(84 + f.length * 50);
  const dv = new DataView(buf);
  dv.setUint32(80, f.length, true);
  let off = 84;
  for (const tri of f) {
    off += 12; // normal left as 0
    for (const idx of tri) {
      dv.setFloat32(off, v[idx][0], true);
      dv.setFloat32(off + 4, v[idx][1], true);
      dv.setFloat32(off + 8, v[idx][2], true);
      off += 12;
    }
    off += 2; // attribute byte count
  }
  return buf;
}

function cubeAscii(s) {
  // two triangles per face — reuse the binary winding via a tiny emitter
  const v = [[0,0,0],[s,0,0],[s,s,0],[0,s,0],[0,0,s],[s,0,s],[s,s,s],[0,s,s]];
  const f = [[0,1,2],[0,2,3],[4,6,5],[4,7,6],[0,4,5],[0,5,1],[1,5,6],[1,6,2],[2,6,7],[2,7,3],[3,7,4],[3,4,0]];
  let s2 = 'solid cube\n';
  for (const tri of f) {
    s2 += 'facet normal 0 0 0\nouter loop\n';
    for (const i of tri) s2 += `vertex ${v[i][0]} ${v[i][1]} ${v[i][2]}\n`;
    s2 += 'endloop\nendfacet\n';
  }
  s2 += 'endsolid cube\n';
  return new TextEncoder().encode(s2);
}

test('parseStl: binary cube → exact volume, bbox, triangle count', () => {
  const g = parseStl(cubeBinary(10));
  assert.equal(g.format, 'binary');
  assert.equal(g.triangleCount, 12);
  assert.ok(Math.abs(g.volumeMm3 - 1000) < 1e-3, `volume ${g.volumeMm3}`); // 10^3
  assert.ok(Math.abs(g.bbox.x - 10) < 1e-4 && Math.abs(g.bbox.y - 10) < 1e-4 && Math.abs(g.bbox.z - 10) < 1e-4);
  assert.ok(Math.abs(g.areaMm2 - 600) < 1e-2); // 6 faces × 10×10
});

test('parseStl: ASCII cube matches binary volume', () => {
  const g = parseStl(cubeAscii(20));
  assert.equal(g.format, 'ascii');
  assert.equal(g.triangleCount, 12);
  assert.ok(Math.abs(g.volumeMm3 - 8000) < 1e-2, `volume ${g.volumeMm3}`); // 20^3
});

test('looksBinary: discriminates by declared-count vs byte length', () => {
  assert.equal(looksBinary(new DataView(cubeBinary(5))), true);
  assert.equal(looksBinary(new DataView(cubeAscii(5).buffer)), false);
});

test('estimateFromStl: solid 1cm³ at 100% infill, no shell/waste → density grams', () => {
  const r = estimateFromStl({ volumeMm3: 1000, bbox: { x: 10, y: 10, z: 10 } },
    { densityGPerCm3: 1.24, infillPct: 1, shellFactor: 0, wastePct: 0 });
  assert.equal(r.solidWeightG, 1.2); // round1(1.24)
  assert.equal(r.estWeightG, 1.2);
  assert.ok(r.estPrintTimeH > 0);
  assert.deepEqual(r.dimsMm, { x: 10, y: 10, z: 10 });
});

test('estimateFromStl: lower infill → lighter than solid; time tracks weight', () => {
  const geom = { volumeMm3: 50000, bbox: { x: 50, y: 40, z: 25 } };
  const solid = estimateFromStl(geom, { infillPct: 1, shellFactor: 0, wastePct: 0 });
  const sparse = estimateFromStl(geom, { infillPct: 0.2, shellFactor: 0.35, wastePct: 0 });
  assert.ok(sparse.estWeightG < solid.estWeightG);
  assert.ok(sparse.estPrintTimeH < solid.estPrintTimeH);
  assert.ok(sparse.estWeightG > 0);
});

test('estimateFromStl: handles empty/zero geometry without NaN', () => {
  const r = estimateFromStl({ volumeMm3: 0, bbox: { x: 0, y: 0, z: 0 } }, {});
  assert.equal(r.estWeightG, 0);
  assert.equal(r.estPrintTimeH, 0);
});

/* THE COST OF READING A MESH, pinned — because it is what made a big model
 * unaddable and nothing here was measuring it.
 *
 * `parseBinary` allocated `new Array(count)` of nested `[[x,y,z],…]` whether or
 * not the caller wanted the triangles, so measuring a mesh cost roughly six
 * times the file's own size in heap: a 250 MB binary STL parsed to 1,488 MB and
 * 1,459 ms with keepTriangles OFF. Forty million small objects, summed and
 * dropped. The same file now costs the buffer, 4 MB of heap and 164 ms.
 *
 * A regression here does not throw and does not change a number — it just makes
 * a large file unreadable again, which is exactly how this shipped.
 */
test('measuring a mesh does not allocate the triangles it is summing', () => {
  // 200k triangles: ~10 MB, big enough that a per-triangle allocation shows up
  // well clear of the noise, small enough to stay a unit test.
  const N = 200000;
  const buf = new ArrayBuffer(84 + N * 50);
  const dv = new DataView(buf);
  dv.setUint32(80, N, true);
  let off = 84;
  for (let i = 0; i < N; i++) {
    off += 12;
    const x = (i % 100) * 0.5, y = ((i / 100) | 0) % 100 * 0.5, z = (i % 7) * 0.3;
    const pts = [[x, y, z], [x + 1, y, z], [x, y + 1, z]];
    for (const p of pts) {
      dv.setFloat32(off, p[0], true); dv.setFloat32(off + 4, p[1], true); dv.setFloat32(off + 8, p[2], true);
      off += 12;
    }
    off += 2;
  }

  const before = process.memoryUsage().heapUsed;
  const lean = parseStl(buf);
  const leanCost = process.memoryUsage().heapUsed - before;
  assert.strictEqual(lean.triangles, undefined, 'no triangle list was asked for');
  assert.strictEqual(lean.triangleCount, N);

  // The list, when it IS asked for, is the expensive shape — which is the whole
  // reason the two are separated. Asserting it costs MORE keeps the comparison
  // honest: a lean read that quietly started keeping them would pass a bare
  // "under N bytes" threshold on a fast machine.
  const mid = process.memoryUsage().heapUsed;
  const full = parseStl(buf, { keepTriangles: true });
  const fullCost = process.memoryUsage().heapUsed - mid;
  assert.strictEqual(full.triangles.length, N);
  assert.ok(fullCost > leanCost * 4,
    `keeping ${N} triangles cost ${fullCost} vs ${leanCost} for measuring them — the lean path is allocating a list again`);

  // And the numbers are the same either way. They must be: the same call feeds
  // the quote screen (which wants triangles) and the library import (which does
  // not), and a shop cannot get two volumes for one model.
  for (const k of ['triangleCount', 'volumeMm3', 'areaMm2']) {
    assert.ok(Object.is(lean[k], full[k]), `${k} differs between the lean and full reads`);
  }
  assert.deepStrictEqual(lean.bbox, full.bbox);
});

test('an ASCII STL is summed as it is scanned, not collected twice', () => {
  // The old path built an array of every vertex and then a second array of
  // triangles from it — worst case in the file format that is already the
  // largest on disk.
  const s = 10;
  const asciiBuf = cubeAscii(s);
  const lean = parseStl(asciiBuf);
  const full = parseStl(asciiBuf, { keepTriangles: true });
  assert.strictEqual(lean.format, 'ascii');
  assert.strictEqual(lean.triangles, undefined);
  assert.strictEqual(full.triangles.length, lean.triangleCount);
  assert.ok(Object.is(lean.volumeMm3, full.volumeMm3));
  assert.deepStrictEqual(lean.bbox, full.bbox);
});
