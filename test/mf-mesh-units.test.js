'use strict';
// A 3MF is not always in millimetres, and this reader used to assume it was.
//
// `<model unit="…">` may be micron, millimeter, centimeter, inch, foot or meter — the core spec's
// full list — and CAD exporters use them. mf-mesh.js did not look, so every vertex was taken as
// millimetres and everything derived from the geometry inherited the error, both ways:
//
//   a 12x12x6 INCH box is 305x305x152 mm, does not fit the U1's bed, and the preview said it did
//   a 200 mm part written in microns measured 200000 and looked enormous
//
// WHAT MAKES THIS MORE THAN AN OMISSION: mf-convert.js:261 has read the unit all along, with the
// same table. So two readers of the same file disagreed about its scale — the exact failure the
// comment at mf-mesh.js's vertex loop already records about tag forms ("The two readers disagreeing
// meant a legal 3MF converted wrongly with no warning"). Same two readers, same file, second time.
//
// Found by the bedready.io website's engine-parity check, which compares this module against
// src/lib/paint.ts and had never been pointed at the extractor before.
const test = require('node:test');
const assert = require('node:assert/strict');
const { extractMeshFromBuffer, unitScale } = require('../lib/mf-mesh');
const { writeZip } = require('../lib/zip-write');

function box(sx, sy, sz) {
  const v = [[0, 0, 0], [sx, 0, 0], [sx, sy, 0], [0, sy, 0], [0, 0, sz], [sx, 0, sz], [sx, sy, sz], [0, sy, sz]];
  const f = [[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6], [0, 4, 5], [0, 5, 1], [1, 5, 6], [1, 6, 2], [2, 6, 7], [2, 7, 3], [3, 7, 4], [3, 4, 0]];
  return '<mesh><vertices>' + v.map(([x, y, z]) => `<vertex x="${x}" y="${y}" z="${z}"/>`).join('') + '</vertices>'
    + '<triangles>' + f.map(([a, b, c]) => `<triangle v1="${a}" v2="${b}" v3="${c}"/>`).join('') + '</triangles></mesh>';
}

function project(unitAttr, dims) {
  return writeZip([
    { name: '[Content_Types].xml', data: Buffer.from('<?xml version="1.0"?><Types/>') },
    { name: '_rels/.rels', data: Buffer.from('<?xml version="1.0"?><Relationships/>') },
    {
      name: '3D/3dmodel.model',
      data: Buffer.from(`<?xml version="1.0"?><model ${unitAttr}><resources>`
        + `<object id="1" type="model">${box(dims[0], dims[1], dims[2])}</object>`
        + '</resources><build><item objectid="1"/></build></model>'),
    },
  ]);
}

function sizeOf(positions) {
  const mn = [Infinity, Infinity, Infinity], mx = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < positions.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      if (positions[i + k] < mn[k]) mn[k] = positions[i + k];
      if (positions[i + k] > mx[k]) mx[k] = positions[i + k];
    }
  }
  return mx.map((v, k) => Math.round(v - mn[k]));
}

test('the unit table matches the 3MF core spec, and anything else is millimetres', () => {
  assert.equal(unitScale('micron'), 0.001);
  assert.equal(unitScale('millimeter'), 1);
  assert.equal(unitScale('centimeter'), 10);
  assert.equal(unitScale('inch'), 25.4);
  assert.equal(unitScale('foot'), 304.8);
  assert.equal(unitScale('meter'), 1000);
  assert.equal(unitScale(undefined), 1, 'absent means millimetre, per the spec');
  assert.equal(unitScale('furlong'), 1, 'an unknown unit must not scale geometry to nonsense');
  assert.equal(unitScale(' INCH '), 25.4, 'the attribute is not always tidily cased');
  assert.equal(unitScale('micrometer'), 0.001, 'not in the spec; mf-convert has always taken it');
});

test('geometry is normalised to millimetres whatever the document declares', () => {
  const cases = [
    ['unit="millimeter"', [200, 200, 100], [200, 200, 100]],
    ['', [200, 200, 100], [200, 200, 100]],            // absent → millimetre
    ['unit="inch"', [12, 12, 6], [305, 305, 152]],
    ['unit="centimeter"', [30, 30, 20], [300, 300, 200]],
    ['unit="meter"', [0.3, 0.3, 0.2], [300, 300, 200]],
    ['unit="micron"', [200000, 200000, 100000], [200, 200, 100]],
    ['unit="foot"', [1, 1, 0.5], [305, 305, 152]],
  ];
  for (const [attr, dims, expected] of cases) {
    const m = extractMeshFromBuffer(project(attr, dims));
    assert.deepEqual(sizeOf(m.positions), expected, `${attr || '(no unit)'} should measure ${expected}`);
  }
});

test('the parts that used to be waved onto the bed are now caught', () => {
  // Each of these is genuinely too big for a 270 mm bed and each measured small before the fix.
  for (const [attr, dims] of [['unit="inch"', [12, 12, 6]], ['unit="centimeter"', [30, 30, 20]], ['unit="meter"', [0.3, 0.3, 0.2]]]) {
    const s = sizeOf(extractMeshFromBuffer(project(attr, dims)).positions);
    assert.ok(Math.max(s[0], s[1]) > 270, `${attr} is 300 mm+ and must measure as such, got ${s}`);
  }
  // And the mirror image: microns made a part that fits look enormous.
  const s = sizeOf(extractMeshFromBuffer(project('unit="micron"', [200000, 200000, 100000])).positions);
  assert.ok(Math.max(s[0], s[1], s[2]) <= 270, `a 200 mm part written in microns fits, got ${s}`);
});

test('mmPerUnit is carried out, so a value can be converted BACK to the document space', () => {
  assert.equal(extractMeshFromBuffer(project('unit="inch"', [12, 12, 6])).mmPerUnit, 25.4);
  assert.equal(extractMeshFromBuffer(project('unit="millimeter"', [10, 10, 10])).mmPerUnit, 1);
  assert.equal(extractMeshFromBuffer(project('', [10, 10, 10])).mmPerUnit, 1);
});

test('mf-mesh and mf-convert agree about scale, which is the point', () => {
  // The two readers of the same file. mf-convert.js has always had this table; this test exists so
  // that removing it from either side fails rather than going quiet.
  const mesh = require('../lib/mf-mesh');
  const convertSrc = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'lib', 'mf-convert.js'), 'utf8');
  const table = /const UNIT_MM = \{([^}]*)\}/.exec(convertSrc);
  assert.ok(table, 'mf-convert.js no longer declares UNIT_MM — the two readers can now disagree again');
  for (const pair of table[1].split(',')) {
    const [k, v] = pair.split(':').map((s) => s.trim());
    if (!k) continue;
    assert.equal(mesh.unitScale(k), Number(v), `mf-convert maps ${k}→${v}; mf-mesh must agree`);
  }
});

test('mmPerUnit is on every return shape, not only the one with geometry', () => {
  // #784 put mmPerUnit on the full return and not on emptyMesh(), so a 3MF that
  // is empty or over the triangle budget came back with `mmPerUnit: undefined`.
  //
  // Nothing was numerically wrong on that path — there is no geometry to scale —
  // which is exactly why it survived: the defect is that a consumer reading
  // `mesh.mmPerUnit` gets a number on one path and undefined on the other, and
  // `undefined * anything` is NaN. That is the Salla `Number(undefined)` shape
  // one step earlier, and the printer audits' question in a new place: which
  // return is the field on.
  //
  // Found by makerrun's engine-parity suite, which compares this extractor
  // against the web reference it was ported from:
  //   mmPerUnit differs (unit="millimeter" ×1): 1 !== undefined
  //
  // The hard cap forces the early return. It is 1 rather than 0 because
  // extractMeshFromMembers defaults with `hardCap = hardCap || HARD_CAP`, so a
  // zero is read as "not given" and replaced by the real cap — the fixture would
  // then take the ordinary path and the test would pass while proving nothing.
  const over = extractMeshFromBuffer(project('unit="inch"', [12, 12, 6]), 1000, 1);
  assert.equal(over.skipped, true, 'the fixture should exercise the over-budget return');
  assert.equal(over.positions.length, 0);
  assert.equal(over.mmPerUnit, 25.4, 'the unit was read but not reported on this path');

  // And the same file within budget, for contrast: same number, other return.
  const ok = extractMeshFromBuffer(project('unit="inch"', [12, 12, 6]), 1000, 1000);
  assert.equal(ok.skipped, false);
  assert.equal(ok.mmPerUnit, 25.4);
});
