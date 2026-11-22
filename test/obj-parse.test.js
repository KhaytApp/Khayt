/**
 * Reading geometry out of an OBJ.
 *
 * The numbers here are checkable by hand — a 20mm cube is 8000 mm³ and 2400 mm²,
 * a tetrahedron is base×height/6 — because the whole point of this module is to
 * feed a weight that a shop will charge money for. "It returned a number" is not
 * a passing result.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseObj, looksObj, accumulateTriangles } = require('../lib/obj-parse.js');
const { parseStl } = require('../lib/stl-parse.js');

/** A closed 20mm cube at the origin, triangulated. */
const CUBE = `# 20mm cube
v 0 0 0
v 20 0 0
v 20 20 0
v 0 20 0
v 0 0 20
v 20 0 20
v 20 20 20
v 0 20 20
f 1 4 3
f 1 3 2
f 5 6 7
f 5 7 8
f 1 2 6
f 1 6 5
f 2 3 7
f 2 7 6
f 3 4 8
f 3 8 7
f 4 1 5
f 4 5 8
`;

test('a 20mm cube measures exactly 8000 mm3 and 2400 mm2', () => {
  const g = parseObj(CUBE);
  assert.equal(g.triangleCount, 12);
  assert.equal(g.volumeMm3, 8000);
  assert.equal(g.areaMm2, 2400);
  assert.deepEqual({ x: g.bbox.x, y: g.bbox.y, z: g.bbox.z }, { x: 20, y: 20, z: 20 });
  assert.deepEqual(g.bbox.min, [0, 0, 0]);
  assert.deepEqual(g.bbox.max, [20, 20, 20]);
});

test('the same cube read as an STL gives the same volume', () => {
  // parseObj and parseStl feed the identical estimator, so a part must not be
  // priced differently depending on which format the customer sent.
  const tris = parseObj(CUBE, { keepTriangles: true }).triangles;
  const buf = Buffer.alloc(84 + tris.length * 50);
  buf.writeUInt32LE(tris.length, 80);
  let o = 84;
  for (const t of tris) {
    o += 12;                                     // normal, unused
    for (const v of t) for (const c of v) { buf.writeFloatLE(c, o); o += 4; }
    o += 2;                                      // attribute byte count
  }
  const s = parseStl(buf);
  assert.equal(s.volumeMm3, parseObj(CUBE).volumeMm3);
  assert.equal(s.areaMm2, parseObj(CUBE).areaMm2);
});

test('quad faces are fanned into triangles', () => {
  const quads = `
v 0 0 0
v 20 0 0
v 20 20 0
v 0 20 0
v 0 0 20
v 20 0 20
v 20 20 20
v 0 20 20
f 1 4 3 2
f 5 6 7 8
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
`;
  const g = parseObj(quads);
  assert.equal(g.triangleCount, 12, '6 quads → 12 triangles');
  assert.equal(g.volumeMm3, 8000, 'and the same solid');
});

test('face references carrying texture and normal indices still resolve', () => {
  // "f 1/1/1" and "f 1//1" are both extremely common; only the first field is
  // geometry. Reading the wrong field silently gives the wrong shape.
  const withRefs = CUBE.replace(/^f (\d+) (\d+) (\d+)$/gm, 'f $1/4/7 $2//9 $3/2');
  assert.notEqual(withRefs, CUBE, 'the rewrite actually applied');
  assert.equal(parseObj(withRefs).volumeMm3, 8000);
});

test('negative indices count back from the vertices declared so far', () => {
  // -1 is the most recent vertex, NOT the first, and not the last vertex in the
  // file. Four decoy vertices come FIRST so a wrong rule selects a different
  // four points and builds a different solid — with only the four real vertices
  // present, every plausible mapping yields the same tetrahedron and the test
  // cannot tell the rules apart.
  const tetra = `
v 999 999 999
v 999 0 0
v 0 999 0
v 0 0 999
v 0 0 0
v 20 0 0
v 0 20 0
v 0 0 20
f -4 -2 -3
f -4 -3 -1
f -4 -1 -2
f -3 -2 -1
`;
  const g = parseObj(tetra);
  assert.equal(g.triangleCount, 4);
  // Tetrahedron on the axes: 20·20·20/6. Resolving against the decoys instead
  // gives a vastly larger solid, so this number is the discriminator.
  assert.ok(Math.abs(g.volumeMm3 - 8000 / 6) < 1e-6, `got ${g.volumeMm3}`);
  assert.deepEqual(g.bbox.max, [20, 20, 20], 'the decoy vertices were not used');
});

test('comments, blank lines and irrelevant records are skipped', () => {
  const noisy = `
# a comment
mtllib thing.mtl
o cube
g default
s off
usemtl red
vt 0.5 0.5
vn 0 0 1
${CUBE}
# trailing comment
`;
  assert.equal(parseObj(noisy).volumeMm3, 8000);
});

test('an inline comment does not break the line before it', () => {
  const g = parseObj('v 0 0 0 # origin\nv 20 0 0\nv 0 20 0\nv 0 0 20\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n');
  assert.equal(g.triangleCount, 4);
});

test('Windows line endings parse identically', () => {
  assert.equal(parseObj(CUBE.replace(/\n/g, '\r\n')).volumeMm3, 8000);
});

test('accepts a Buffer, an ArrayBuffer and a TypedArray, not just a string', () => {
  // The renderer hands over an ArrayBuffer from FileReader; the main process a
  // Buffer. Both have to work or one of the two callers silently breaks.
  const b = Buffer.from(CUBE, 'utf8');
  assert.equal(parseObj(b).volumeMm3, 8000);
  assert.equal(parseObj(new Uint8Array(b)).volumeMm3, 8000);
  const ab = b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
  assert.equal(parseObj(ab).volumeMm3, 8000);
});

test('a file with no faces yields zero geometry rather than throwing', () => {
  // These come from users. An empty or header-only OBJ must produce "no
  // geometry", which the caller can report, not a crash.
  for (const junk of ['', '# nothing here', 'v 1 2 3', 'mtllib a.mtl\no thing']) {
    const g = parseObj(junk);
    assert.equal(g.triangleCount, 0, JSON.stringify(junk));
    assert.equal(g.volumeMm3, 0);
    assert.deepEqual(g.bbox, { x: 0, y: 0, z: 0, min: [0, 0, 0], max: [0, 0, 0] });
  }
});

test('a malformed face is dropped, not guessed at', () => {
  // Out-of-range and non-numeric references would otherwise index `undefined`
  // and make every downstream number NaN — which renders as "0 g" in the form.
  const bad = `
v 0 0 0
v 20 0 0
v 0 20 0
v 0 0 20
f 1 2 99
f 1 2 abc
f 1 0 3
f 1 3 2
f 1 2 4
f 1 4 3
f 2 3 4
`;
  const g = parseObj(bad);
  assert.equal(g.triangleCount, 4, 'the three bad faces are gone, the tetra remains');
  assert.ok(Number.isFinite(g.volumeMm3));
  assert.ok(Math.abs(g.volumeMm3 - 8000 / 6) < 1e-6);
});

test('a vertex missing a coordinate is not treated as a vertex', () => {
  // Pushing NaN here poisons the bbox and the volume for the whole file.
  const g = parseObj('v 0 0 0\nv 20 0\nv 20 0 0\nv 0 20 0\nv 0 0 20\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4\n');
  assert.ok(Number.isFinite(g.volumeMm3), 'volume is a number');
  assert.ok(Number.isFinite(g.bbox.x), 'bbox is a number');
});

test('volume is orientation-independent', () => {
  // Reversing winding flips the sign of the tetrahedron sum; a parser that
  // forgets the abs() reports a negative weight.
  const flipped = CUBE.replace(/^f (\d+) (\d+) (\d+)$/gm, 'f $1 $3 $2');
  assert.equal(parseObj(flipped).volumeMm3, 8000);
});

test('looksObj recognises an OBJ without validating it', () => {
  assert.equal(looksObj(CUBE), true);
  assert.equal(looksObj('mtllib x.mtl\n'), true);
  assert.equal(looksObj('solid ascii stl\nfacet normal 0 0 1\n'), false);
  assert.equal(looksObj(''), false);
});

test('accumulateTriangles is the shared volume sum, exported for 3MF triangles', () => {
  // lib/model-intake.js reuses this for a 3MF's mesh. If it drifted from what
  // parseObj uses, the same part would weigh differently as .obj and as .3mf.
  const tris = parseObj(CUBE, { keepTriangles: true }).triangles;
  const acc = accumulateTriangles(tris);
  assert.equal(acc.volumeMm3, 8000);
  assert.equal(acc.triangleCount, 12);
  assert.deepEqual(acc.bbox.max, [20, 20, 20]);
});
