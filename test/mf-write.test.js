'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { meshTo3mf, buildModelXml, trianglesToStl } = require('../lib/mf-write');
const { analyze, readMembers, extractTriangles, extractTrianglesWithPaint, extractPlates } = require('../lib/mf-convert');
const { parseStl } = require('../lib/stl-parse');

// A single 10×20×5 triangle (footprint used for the bounds check).
const TRIS = [
  [[0, 0, 0], [10, 0, 0], [0, 20, 5]],
];

test('meshTo3mf produces a 3MF the analyzer can read', () => {
  const buf = meshTo3mf(TRIS);
  assert.ok(Buffer.isBuffer(buf));
  const a = analyze(buf);
  assert.equal(a.ok, true);
  assert.equal(a.hasGeometry, true);
  assert.equal(a.flavour, 'generic');
});

test('meshTo3mf preserves the mesh footprint (bounds)', () => {
  const a = analyze(meshTo3mf(TRIS));
  assert.deepEqual(a.bounds, { x: 10, y: 20, z: 5 });
});

test('meshTo3mf returns null for empty input', () => {
  assert.equal(meshTo3mf([]), null);
  assert.equal(meshTo3mf(null), null);
});

test('round-trip: an ASCII STL becomes a readable 3MF with the same footprint', () => {
  const stl = `solid s
facet normal 0 0 0
 outer loop
  vertex 0 0 0
  vertex 30 0 0
  vertex 0 15 8
 endloop
endfacet
endsolid s`;
  const parsed = parseStl(Buffer.from(stl, 'utf8'), { keepTriangles: true });
  assert.equal(parsed.triangleCount, 1);
  const a = analyze(meshTo3mf(parsed.triangles));
  assert.equal(a.ok, true);
  assert.deepEqual(a.bounds, { x: 30, y: 15, z: 8 });
});

test('extractTriangles recovers the mesh from a 3MF we wrote', () => {
  const tris = extractTriangles(readMembers(meshTo3mf(TRIS)));
  assert.equal(tris.length, 1);
  assert.deepEqual(tris[0], [[0, 0, 0], [10, 0, 0], [0, 20, 5]]);
});

test('extractTriangles recovers a SPLIT 3MF (geometry in a referenced 3D/Objects/*.model)', () => {
  // Mirrors Bambu/Orca: root 3dmodel.model has only a build item → object → component
  // with p:path into a separate object file that holds the actual mesh (a tetrahedron).
  const { writeZip } = require('../lib/zip-write');
  const objModel = `<?xml version="1.0"?><model unit="millimeter"><resources>
    <object id="1" type="model"><mesh>
      <vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices>
      <triangles><triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="2" v3="3"/><triangle v1="1" v2="2" v3="3"/></triangles>
    </mesh></object></resources></model>`;
  const rootModel = `<?xml version="1.0"?><model unit="millimeter" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06"><resources>
    <object id="5" type="model"><components>
      <component objectid="1" p:path="/3D/Objects/o.model" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
    </components></object></resources>
    <build><item objectid="5"/></build></model>`;
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: rootModel },
    { name: '3D/Objects/o.model', data: objModel },
  ]);
  const tris = extractTriangles(readMembers(buf));
  assert.equal(tris.length, 4, 'recovered all 4 tetrahedron faces across files');
  assert.deepEqual(tris[0], [[0, 0, 0], [10, 0, 0], [0, 10, 0]]);
});

test('extractTrianglesWithPaint captures per-facet paint codes aligned to triangles', () => {
  const { writeZip } = require('../lib/zip-write');
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>
    <object id="1" type="model"><mesh>
      <vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices>
      <triangles>
        <triangle v1="0" v2="1" v3="2" paint_color="4"/>
        <triangle v1="0" v2="1" v3="3"/>
        <triangle v1="0" v2="2" v3="3" paint_color="8"/>
        <triangle v1="1" v2="2" v3="3"/>
      </triangles>
    </mesh></object></resources><build><item objectid="1"/></build></model>`;
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: model },
  ]);
  const r = extractTrianglesWithPaint(readMembers(buf));
  assert.equal(r.triangles.length, 4);
  assert.deepEqual(r.paint, ['4', null, '8', null]);
  // extractTriangles (no paint) still returns a plain array of the same 4 faces.
  assert.equal(extractTriangles(readMembers(buf)).length, 4);
});

test('extractTriangles keeps facets whose attributes contain a "/" (regex not truncated)', () => {
  const { writeZip } = require('../lib/zip-write');
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>
    <object id="1" type="model"><mesh>
      <vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices>
      <triangles>
        <triangle v1="0" v2="1" v3="2" custom="a/b"/>
        <triangle v1="0" v2="1" v3="3" paint_color="4/8"/>
        <triangle v1="0" v2="2" v3="3"/>
        <triangle v1="1" v2="2" v3="3"/>
      </triangles>
    </mesh></object></resources><build><item objectid="1"/></build></model>`;
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: model },
  ]);
  assert.equal(extractTriangles(readMembers(buf)).length, 4, 'all 4 facets survive a "/" in attributes');
  assert.deepEqual(extractTrianglesWithPaint(readMembers(buf)).paint, [null, '4/8', null, null]);
});

test('extractTriangles falls back to raw meshes when the build graph resolves to nothing', () => {
  // Build item points at a missing object id (99) and the real mesh (id 1) is not referenced.
  const { writeZip } = require('../lib/zip-write');
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>
    <object id="1" type="model"><mesh>
      <vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/></vertices>
      <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
    </mesh></object></resources><build><item objectid="99"/></build></model>`;
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: model },
  ]);
  const tris = extractTriangles(readMembers(buf));
  assert.equal(tris.length, 1, 'raw mesh rendered even though the build item was unresolvable');
  assert.deepEqual(tris[0], [[0, 0, 0], [10, 0, 0], [0, 10, 0]]);
});

test('extractTrianglesWithPaint thins huge meshes for preview but keeps full mesh otherwise', () => {
  const { writeZip } = require('../lib/zip-write');
  const N = 900; // facets — small but enough to exercise the stride
  let s = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh><vertices>';
  for (let i = 0; i < N + 2; i++) s += `<vertex x="${i}" y="0" z="0"/>`;
  s += '</vertices><triangles>';
  for (let i = 0; i < N; i++) s += `<triangle v1="${i}" v2="${i + 1}" v3="${i + 2}"/>`;
  s += '</triangles></mesh></object></resources><build><item objectid="1"/></build></model>';
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: s },
  ]);
  const members = readMembers(buf);
  const full = extractTrianglesWithPaint(members);
  assert.equal(full.triangles.length, N, 'no cap → full mesh');
  assert.equal(full.thinned, false);
  const capped = extractTrianglesWithPaint(members, { maxTris: 100 });
  assert.equal(capped.thinned, true);
  assert.ok(capped.triangles.length <= 100 && capped.triangles.length >= 90, `~100 facets kept, got ${capped.triangles.length}`);
  assert.equal(capped.paint.length, capped.triangles.length, 'paint stays aligned after thinning');
});

test('extractTriangles parses scientific-notation and single-quoted vertices', () => {
  const { writeZip } = require('../lib/zip-write');
  // Negative exponents (1.5e-3) and single quotes — a CAD exporter dialect that used to make
  // every vertex fail to parse, collapsing the whole mesh to the "no geometry" fallback.
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>
    <object id="1" type="model"><mesh>
      <vertices>
        <vertex x='0' y='0' z='0'/>
        <vertex x="1.0e1" y="0" z="0"/>
        <vertex x="0" y="2.5e-1" z="-3.0E-2"/>
      </vertices>
      <triangles><triangle v1='0' v2='1' v3='2'/></triangles>
    </mesh></object></resources><build><item objectid="1"/></build></model>`;
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: model },
  ]);
  const tris = extractTriangles(readMembers(buf));
  assert.equal(tris.length, 1, 'the facet survives — its vertices all parsed');
  assert.deepEqual(tris[0], [[0, 0, 0], [10, 0, 0], [0, 0.25, -0.03]]);
});

test('extractPlates + per-triangle object ids power a multi-plate preview', () => {
  const { writeZip } = require('../lib/zip-write');
  // Two objects, both built; a Bambu-style model_settings.config assigns each to its own plate.
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>
    <object id="1" type="model"><mesh>
      <vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices>
      <triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>
    <object id="2" type="model"><mesh>
      <vertices><vertex x="5" y="5" z="0"/><vertex x="6" y="5" z="0"/><vertex x="5" y="6" z="0"/></vertices>
      <triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>
  </resources><build><item objectid="1"/><item objectid="2"/></build></model>`;
  const settings = `<?xml version="1.0"?><config>
    <object id="1"><metadata key="name" value="A"/></object>
    <object id="2"><metadata key="name" value="B"/></object>
    <plate><metadata key="plater_id" value="1"/><metadata key="plater_name" value="Left"/>
      <model_instance><metadata key="object_id" value="1"/></model_instance></plate>
    <plate><metadata key="plater_id" value="2"/><metadata key="plater_name" value="Right"/>
      <model_instance><metadata key="object_id" value="2"/></model_instance></plate>
  </config>`;
  const buf = writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/model_settings.config', data: settings },
  ]);
  const members = readMembers(buf);
  const plates = extractPlates(members);
  assert.equal(plates.length, 2);
  assert.deepEqual(plates[0], { name: 'Left', objectIds: ['1'] });
  assert.deepEqual(plates[1], { name: 'Right', objectIds: ['2'] });
  const wp = extractTrianglesWithPaint(members);
  assert.equal(wp.triangles.length, 2);
  assert.deepEqual(wp.objIds, ['1', '2'], 'each facet is tagged with its build-item object id');
});

test('trianglesToStl writes a binary STL that parses back to the same mesh', () => {
  const stl = trianglesToStl(TRIS);
  assert.ok(Buffer.isBuffer(stl));
  const parsed = parseStl(stl, { keepTriangles: true });
  assert.equal(parsed.format, 'binary');
  assert.equal(parsed.triangleCount, 1);
  assert.deepEqual(parsed.bbox, { x: 10, y: 20, z: 5, min: [0, 0, 0], max: [10, 20, 5] });
});

test('round-trip STL → 3MF → STL preserves the mesh', () => {
  const orig = trianglesToStl([
    [[0, 0, 0], [30, 0, 0], [0, 15, 8]],
    [[0, 0, 0], [0, 15, 8], [-5, 2, 1]],
  ]);
  const p1 = parseStl(orig, { keepTriangles: true });
  const back = extractTriangles(readMembers(meshTo3mf(p1.triangles)));
  const p2 = parseStl(trianglesToStl(back), { keepTriangles: true });
  assert.equal(p2.triangleCount, 2);
  assert.deepEqual(p2.bbox.max, p1.bbox.max);
  assert.deepEqual(p2.bbox.min, p1.bbox.min);
});

test('trianglesToStl returns null for empty input', () => {
  assert.equal(trianglesToStl([]), null);
});

test('buildModelXml indexes vertices per triangle', () => {
  const xml = buildModelXml([[[0, 0, 0], [1, 0, 0], [0, 1, 0]], [[0, 0, 0], [1, 0, 0], [0, 0, 1]]]);
  assert.match(xml, /<triangle v1="0" v2="1" v3="2"\/>/);
  assert.match(xml, /<triangle v1="3" v2="4" v3="5"\/>/);
});
