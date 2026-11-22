const { test } = require('node:test');
const assert = require('node:assert/strict');
const mesh = require('../lib/mf-mesh.js');

/**
 * A 3MF component graph can contain a reference cycle — malformed, but trivially produced
 * by a buggy exporter, and the file is otherwise parseable.
 *
 * The COUNTER (subtree) breaks cycles with a memoised sentinel, so it returned a small
 * triangle count and the typed arrays were sized from it. The EMITTER (walk) had only a
 * depth cap, so it kept descending — writing far more faces than the buffers held (silently
 * discarded by the typed arrays) and publishing `parts` ranges many times larger than the
 * data. Anything slicing by part.start/end would read past the end.
 */
const cyclicModel = () => `<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter"><resources>
  <object id="3" type="model"><mesh>
    <vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices>
    <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
  </mesh></object>
  <object id="1" type="model"><components>
    <component objectid="3"/><component objectid="2"/>
  </components></object>
  <object id="2" type="model"><components>
    <component objectid="1"/><component objectid="3"/>
  </components></object>
</resources>
<build><item objectid="1"/></build></model>`;

const members = (xml) => [{ name: '3D/3dmodel.model', data: Buffer.from(xml, 'utf8') }];

test('a cyclic component graph does not overrun the mesh buffers', () => {
  const r = mesh.extractMeshFromMembers(members(cyclicModel()));
  assert.ok(r, 'should still return a mesh rather than throwing');

  const faces = r.faceState ? r.faceState.length : 0;
  const verts = r.positions ? r.positions.length / 9 : 0;

  assert.equal(r.triangleCount, faces,
    `triangleCount (${r.triangleCount}) must match the faces actually stored (${faces})`);

  for (const p of r.parts || []) {
    assert.ok(p.start >= 0 && p.end <= faces,
      `part range ${p.start}..${p.end} exceeds the ${faces} faces in the buffers`);
    assert.ok(p.triangleCount <= faces,
      `part advertises ${p.triangleCount} triangles but only ${faces} exist`);
  }
  assert.ok(verts >= faces, 'positions must cover every stored face');
});

test('a legitimately repeated component is still emitted twice', () => {
  // The guard tracks the DESCENT PATH, not every node seen — two siblings referencing the
  // same child is valid 3MF and must still produce two instances.
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter"><resources>
  <object id="3" type="model"><mesh>
    <vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices>
    <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
  </mesh></object>
  <object id="1" type="model"><components>
    <component objectid="3"/><component objectid="3"/>
  </components></object>
</resources>
<build><item objectid="1"/></build></model>`;
  const r = mesh.extractMeshFromMembers(members(xml));
  assert.equal(r.triangleCount, 2, 'the same child referenced twice must emit twice');
});
