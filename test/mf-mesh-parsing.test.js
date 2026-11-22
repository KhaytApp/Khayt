const { test } = require('node:test');
const assert = require('node:assert/strict');
const mesh = require('../lib/mf-mesh.js');

/**
 * lib/mf-mesh.js and lib/mf-convert.js both read the geometry out of the SAME 3MF, for the
 * preview and for the conversion respectively. They must agree.
 *
 * They did not. mf-mesh accepted only `<vertex x="1" …/>` — self-closing, double-quoted,
 * attributes on one line — while mf-convert used tolerant patterns. All of these are legal
 * 3MF, so a file written by a different slicer previewed as an empty mesh, or converted
 * with the wrong paint states and no warning. `attr()` also matched `id` inside `pid`,
 * which loses an entire object when the attribute order happens to put pid first.
 */
const tri = ({ q = '"', selfClose = true, attrOrder = 'id-first' } = {}) => {
  const v = [[0, 0, 0], [10, 0, 0], [0, 10, 0]];
  const vtx = v.map(([x, y, z]) => (selfClose
    ? `<vertex x=${q}${x}${q} y=${q}${y}${q} z=${q}${z}${q}/>`
    : `<vertex x=${q}${x}${q} y=${q}${y}${q} z=${q}${z}${q}></vertex>`)).join('');
  const t = selfClose
    ? `<triangle v1=${q}0${q} v2=${q}1${q} v3=${q}2${q}/>`
    : `<triangle v1=${q}0${q} v2=${q}1${q} v3=${q}2${q}></triangle>`;
  const objAttrs = attrOrder === 'id-first'
    ? `id="7" pid="1" pindex="0"`
    : `pid="1" pindex="0" id="7"`;
  return `<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter"><resources>
<object ${objAttrs} type="model"><mesh>
<vertices>${vtx}</vertices><triangles>${t}</triangles>
</mesh></object></resources>
<build><item objectid="7"/></build></model>`;
};

const members = (xml) => [{ name: '3D/3dmodel.model', data: Buffer.from(xml, 'utf8') }];

function meshTriangleCount(xml) {
  const r = mesh.extractMeshFromMembers(members(xml));
  return r && r.triangleCount ? r.triangleCount : 0;
}

test('the preview parser accepts every legal spelling the converter does', () => {
  const variants = [
    ['double quotes, self-closing', {}],
    ['single quotes', { q: "'" }],
    ['paired tags', { selfClose: false }],
    ['single quotes + paired tags', { q: "'", selfClose: false }],
  ];
  for (const [label, opts] of variants) {
    const count = meshTriangleCount(tri(opts));
    assert.equal(count, 1, `preview parser read 0 triangles for: ${label}`);
  }
});

test('attribute order does not lose the object (id must not match inside pid)', () => {
  // 3MF attribute order is arbitrary; `<object pid="1" pindex="0" id="7">` used to return
  // id="1", so the object never matched the build item and the whole mesh vanished.
  assert.equal(meshTriangleCount(tri({ attrOrder: 'pid-first' })), 1,
    'mesh lost when pid precedes id');
});

test('every legal spelling yields the same geometry, not just a non-zero count', () => {
  // Guards against a pattern that matches but reads the wrong numbers.
  const ref = mesh.extractMeshFromMembers(members(tri({})));
  for (const opts of [{ q: "'" }, { selfClose: false }, { attrOrder: 'pid-first' }]) {
    const got = mesh.extractMeshFromMembers(members(tri(opts)));
    assert.equal(got.triangleCount, ref.triangleCount, `triangle count differs for ${JSON.stringify(opts)}`);
    assert.deepEqual(Array.from(got.positions), Array.from(ref.positions),
      `vertex positions differ for ${JSON.stringify(opts)}`);
  }
});
