'use strict';
/**
 * Measuring a 3MF must not require building it.
 *
 * A shop's real files are posters and kits: 8 to 16 MILLION facets in a 200 MB
 * archive, and none of them sliced, so the mesh is the only place their volume
 * and size can come from. Getting there through extractTriangles materialises
 * twice — resolve() memoises each object's geometry as nested [[x,y,z],…] and
 * emit() builds a second transformed copy — which for a 229 MB / 13.2M-facet
 * poster wants roughly 10 GB. That is why "it can't be read when the file is
 * big" was true no matter what the size ceiling said.
 *
 * measureMesh walks the same graph, in the same order, applying the same
 * transforms in the same sequence, and folds each facet into a running total.
 *
 * THE ONLY THING THAT MAKES IT A SUBSTITUTE IS THAT THE NUMBERS ARE THE SAME —
 * so they are asserted EQUAL to the building path with Object.is, not close.
 * Float64 for the vertices, and the order of the additions preserved, because
 * float addition is not associative and a shop must not get two different
 * volumes for one model depending on which reader saw it.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const mf = require('../lib/mf-convert');
const { accumulateTriangles } = require('../lib/obj-parse');
const { writeZip } = require('../lib/zip-write');

/** A 3MF whose object block is written out longhand, so transforms can be varied. */
function model({ verts, tris, unit, buildItems, objects }) {
  const objXml = (objects || [{ id: '1', verts, tris }]).map((o) => {
    const vs = o.verts.map(([x, y, z]) => `<vertex x="${x}" y="${y}" z="${z}"/>`).join('');
    const ts = (o.tris || []).map(([a, b, c]) => `<triangle v1="${a}" v2="${b}" v3="${c}"/>`).join('');
    const cs = (o.comps || []).map((c) => `<component objectid="${c.ref}"${c.t ? ` transform="${c.t}"` : ''}/>`).join('');
    return `<object id="${o.id}" type="model"><mesh><vertices>${vs}</vertices><triangles>${ts}</triangles></mesh>`
      + (cs ? `<components>${cs}</components>` : '') + '</object>';
  }).join('');
  const items = (buildItems || [{ id: '1' }])
    .map((b) => `<item objectid="${b.id}"${b.t ? ` transform="${b.t}"` : ''}/>`).join('');
  const xml = `<?xml version="1.0"?><model unit="${unit || 'millimeter'}"><resources>${objXml}</resources><build>${items}</build></model>`;
  return writeZip([{ name: '3D/3dmodel.model', data: Buffer.from(xml, 'utf8') }]);
}

const CUBE_V = [[0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0], [0, 0, 10], [10, 0, 10], [10, 10, 10], [0, 10, 10]];
const CUBE_T = [[0, 1, 2], [0, 2, 3], [4, 6, 5], [4, 7, 6], [0, 4, 5], [0, 5, 1],
  [1, 5, 6], [1, 6, 2], [2, 6, 7], [2, 7, 3], [3, 7, 4], [3, 4, 0]];

/** The claim, made against the path it replaces rather than against a constant. */
function assertIdentical(buf, why) {
  const members = mf.readMembers(buf);
  const fast = mf.measureMesh(members);
  const tris = mf.extractTriangles(members);
  const slow = tris && tris.length ? accumulateTriangles(tris) : null;
  assert.ok(fast, `${why}: measureMesh found nothing`);
  assert.ok(slow, `${why}: the building path found nothing, so there is nothing to compare`);
  for (const k of ['triangleCount', 'volumeMm3', 'areaMm2']) {
    assert.ok(Object.is(fast[k], slow[k]),
      `${why}: ${k} differs — ${fast[k]} vs ${slow[k]}`);
  }
  assert.deepEqual(fast.bbox, slow.bbox, `${why}: bbox differs`);
  return fast;
}

test('a plain mesh measures identically to the mesh that was built', () => {
  const g = assertIdentical(model({ verts: CUBE_V, tris: CUBE_T }), 'plain cube');
  assert.equal(g.triangleCount, 12);
  assert.equal(g.volumeMm3, 1000, 'a 10 mm cube is 1000 mm3');
  assert.deepEqual([g.bbox.x, g.bbox.y, g.bbox.z], [10, 10, 10]);
});

test('a build item\'s transform is applied, and in the same order', () => {
  // Scale x2 on X, translated. Composing matrices instead of applying them in
  // sequence would round differently, so this is where that would show.
  assertIdentical(model({
    verts: CUBE_V, tris: CUBE_T,
    buildItems: [{ id: '1', t: '2 0 0 0 1 0 0 0 1 3.5 -2.25 0.125' }],
  }), 'transformed item');
});

test('a component assembly resolves, transform-nested, exactly as the builder does', () => {
  // Object 2 has no mesh of its own: it is object 1 placed twice, and the
  // component's matrix applies BEFORE the build item's. Getting that order
  // wrong is invisible on an identity transform and wrong on every real one.
  const buf = model({
    objects: [
      { id: '1', verts: CUBE_V, tris: CUBE_T },
      { id: '2', verts: [], tris: [], comps: [
        { ref: '1', t: '1 0 0 0 1 0 0 0 1 0 0 0' },
        { ref: '1', t: '1 0 0 0 1 0 0 0 1 20 0 0' },
      ] },
    ],
    buildItems: [{ id: '2', t: '0 1 0 -1 0 0 0 0 1 5 5 0' }],
  });
  const g = assertIdentical(buf, 'component assembly');
  assert.equal(g.triangleCount, 24, 'the same object used twice is measured twice');
});

test('the declared unit scales the measurement, both readers alike', () => {
  const g = assertIdentical(model({ verts: CUBE_V, tris: CUBE_T, unit: 'inch' }), 'inch model');
  assert.equal(Math.round(g.bbox.x), 254, '10 inches is 254 mm');
});

test('a facet naming a vertex that would not parse is dropped, not snapped to the origin', () => {
  // The builder pushes null for an unparseable vertex so the guard drops the
  // facet; the typed-array reader has to reach the same verdict from a mask.
  // A vertex snapped to [0,0,0] instead would spike the bbox and the volume.
  const verts = CUBE_V.map((v, i) => (i === 6 ? ['nope', 'nope', 'nope'] : v));
  assertIdentical(model({ verts, tris: CUBE_T }), 'unparseable vertex');
});

test('a triangle indexing past the end of the vertex list is skipped', () => {
  const buf = model({ verts: CUBE_V, tris: CUBE_T.concat([[0, 1, 99]]) });
  const g = assertIdentical(buf, 'out-of-range index');
  assert.equal(g.triangleCount, 12, 'the impossible facet is not counted');
});

test('a component cycle terminates instead of running out of stack', () => {
  // No memo here — a component used twice is walked twice, which is the trade
  // that keeps the memory flat — so the cycle guard is the only thing standing
  // between a self-referencing file and a stack overflow.
  const buf = model({
    objects: [
      { id: '1', verts: CUBE_V, tris: CUBE_T, comps: [{ ref: '2' }] },
      { id: '2', verts: [], tris: [], comps: [{ ref: '1' }] },
    ],
    buildItems: [{ id: '1' }],
  });
  const g = mf.measureMesh(mf.readMembers(buf));
  assert.ok(g, 'a cyclic file must still measure');
  assert.ok(g.triangleCount >= 12);
});

test('a file with no mesh returns null, so the caller keeps its no-geometry branch', () => {
  assert.equal(mf.measureMesh([]), null);
  assert.equal(mf.measureMesh(null), null);
  const empty = writeZip([{ name: '3D/3dmodel.model', data: Buffer.from('<model><build/></model>') }]);
  assert.equal(mf.measureMesh(mf.readMembers(empty)), null);
});

/* THE CLAIM, MADE THE WAY THE SHOP MEETS IT: a machine that cannot build the
 * mesh can still measure it.
 *
 * Asserted by running both readers in a child process under a heap cap, because
 * an in-process comparison of `heapUsed` before and after cannot say this. GC
 * runs during the call, so the delta comes back NEGATIVE — measured here at
 * -17 MB and -187 MB for two mesh sizes, which is not a smaller number, it is a
 * meaningless one. An earlier version of this test asserted on exactly that and
 * would have passed or failed on GC timing.
 *
 * 400,000 facets over a shared vertex set under a 220 MB cap: measuring
 * finishes, building dies with an allocation failure. That is the whole change
 * in one line, and it cannot pass by accident.
 */
test('a heap that cannot build the mesh can still measure it', () => {
  const { execFileSync } = require('node:child_process');
  const script = `
    const mf = require(${JSON.stringify(require.resolve('../lib/mf-convert'))});
    const { writeZip } = require(${JSON.stringify(require.resolve('../lib/zip-write'))});
    const N = 400000, V = 200;
    const v = []; for (let i = 0; i < V; i++) v.push('<vertex x="' + (i % 20) + '" y="' + ((i / 20) | 0) + '" z="' + (i % 7) + '"/>');
    const t = []; for (let i = 0; i < N; i++) t.push('<triangle v1="' + (i % V) + '" v2="' + ((i * 7 + 1) % V) + '" v3="' + ((i * 13 + 2) % V) + '"/>');
    const xml = '<model unit="millimeter"><resources><object id="1" type="model"><mesh><vertices>'
      + v.join('') + '</vertices><triangles>' + t.join('') + '</triangles></mesh></object></resources>'
      + '<build><item objectid="1"/></build></model>';
    const m = mf.readMembers(writeZip([{ name: '3D/3dmodel.model', data: Buffer.from(xml) }]));
    const r = process.argv[1] === 'measure' ? mf.measureMesh(m) : mf.extractTriangles(m);
    console.log('OK ' + (process.argv[1] === 'measure' ? r.triangleCount : r.length));
  `;
  const run = (mode) => {
    try {
      return { ok: true, out: String(execFileSync(process.execPath,
        ['--max-old-space-size=220', '-e', script, mode], { stdio: ['ignore', 'pipe', 'pipe'] })).trim() };
    } catch (e) {
      return { ok: false, err: String((e && e.stderr) || e) };
    }
  };

  const measured = run('measure');
  assert.ok(measured.ok, `measuring 400k facets under a 220 MB heap failed: ${measured.err}`);
  assert.equal(measured.out, 'OK 400000');

  const builtIt = run('build');
  assert.equal(builtIt.ok, false,
    'building 400k facets fitted in a 220 MB heap — either the builder got much cheaper, in which case '
    + 'measureMesh may no longer be needed, or this fixture stopped being big enough to prove anything');
  assert.match(builtIt.err, /Allocation failed|heap out of memory|JavaScript heap/,
    'the builder failed for some reason other than running out of memory, so this proves nothing');
});

/* ── A BOX PER PLATE ──────────────────────────────────────────────────────
 *
 * Reported from the Mac app, and true of this reader too: a slicer lays plates
 * out side by side in one coordinate space, and a box drawn round everything in
 * <build> is the layout, not the model. On the shop's own two-plate file that
 * was 295 x 170 x 26 for a model whose widest plate is 80 mm — handed to
 * print-fit, a part that goes on a 256 mm bed reported as too big for it.
 *
 * The bbox is the largest plate's; count, volume and area stay totals.
 * The Mac app applies the same rule (Mesh.swift measure3MF) and the keys the
 * two write for one file are compared by its Mesh3MFTests. */

/** Two cubes on two plates, 300 mm apart — one 10 mm, one 20 mm. */
function twoPlates({ config = true, order = ['2', '4'] } = {}) {
  const big = CUBE_V.map(([x, y, z]) => [x * 2, y * 2, z * 2]);
  const objXml = (id, verts) => `<object id="${id}" type="model"><mesh><vertices>`
    + verts.map(([x, y, z]) => `<vertex x="${x}" y="${y}" z="${z}"/>`).join('')
    + '</vertices><triangles>' + CUBE_T.map(([a, b, c]) => `<triangle v1="${a}" v2="${b}" v3="${c}"/>`).join('')
    + '</triangles></mesh></object>';
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources>${objXml('2', CUBE_V)}${objXml('4', big)}</resources><build>`
    + `<item objectid="2" transform="1 0 0 0 1 0 0 0 1 100 100 0"/>`
    + `<item objectid="4" transform="1 0 0 0 1 0 0 0 1 400 100 0"/>`
    + '</build></model>';
  const msc = `<?xml version="1.0"?><config>`
    + order.map((id, i) => `<plate><metadata key="plater_id" value="${i + 1}"/><model_instance><metadata key="object_id" value="${id}"/></model_instance></plate>`).join('')
    + '</config>';
  const members = [{ name: '3D/3dmodel.model', data: Buffer.from(model, 'utf8') }];
  if (config) members.push({ name: 'Metadata/model_settings.config', data: Buffer.from(msc, 'utf8') });
  return writeZip(members);
}

/** The building path, grouped by plate the same way — the claim is still "identical". */
function accumulateByPlate(members) {
  const rich = mf.extractTrianglesWithPaint(members);
  const onPlate = mf.plateOf(members);
  const groups = new Map();
  rich.triangles.forEach((tri, i) => {
    const k = onPlate.get(String(rich.objIds[i])) || 1;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(tri);
  });
  return new Map([...groups].map(([k, tris]) => [k, accumulateTriangles(tris)]));
}

test('a two-plate project measures its largest plate, not the gap between them', () => {
  const members = mf.readMembers(twoPlates());
  const g = mf.measureMesh(members);
  assert.ok(g, 'measureMesh found nothing');
  assert.equal(g.plates, 2, 'the plates were not told apart');
  assert.deepEqual([g.bbox.x, g.bbox.y, g.bbox.z], [20, 20, 20],
    `the box is ${g.bbox.x} x ${g.bbox.y} x ${g.bbox.z}: the layout, not the model`);
  // Totals stay totals — both plates get printed.
  assert.equal(g.triangleCount, 24);
  assert.equal(g.volumeMm3, 1000 + 8000);

  // And it is still identical to the building path, plate for plate.
  const slow = accumulateByPlate(members);
  const bigPlate = slow.get(2);
  assert.deepEqual(g.bbox, bigPlate.bbox, 'the largest plate differs from the built one');
  const totalVol = [...slow.values()].reduce((a, s) => a + s.volumeMm3, 0);
  assert.ok(Math.abs(totalVol - g.volumeMm3) < 1e-9);
});

test('the largest plate is chosen by footprint, and a tie goes to the lowest plate', () => {
  // Plate order swapped in the config: the 20 mm cube is now plate 1. Same
  // answer — the plate NUMBER never matters, which objects share one does.
  const g = mf.measureMesh(mf.readMembers(twoPlates({ order: ['4', '2'] })));
  assert.deepEqual([g.bbox.x, g.bbox.y, g.bbox.z], [20, 20, 20]);
  assert.equal(g.plates, 2);
});

test('a file with no plate structure is one plate, measured as it always was', () => {
  const g = mf.measureMesh(mf.readMembers(twoPlates({ config: false })));
  assert.equal(g.plates, 1);
  // 100..410 across both cubes: with nothing saying otherwise, everything is
  // on plate one and the old answer stands.
  assert.equal(g.bbox.x, 320);
});

test('computeBounds — the converter\'s fit warnings — reads the largest plate too', () => {
  const a = mf.analyze(twoPlates());
  assert.deepEqual(a.bounds, { x: 20, y: 20, z: 20 },
    `fitWarnings would say a ${a.bounds && a.bounds.x} mm footprint does not fit a 256 mm bed`);
  const plain = mf.analyze(twoPlates({ config: false }));
  assert.equal(plain.bounds.x, 320, 'a file with no plates keeps the whole-layout footprint');
});
