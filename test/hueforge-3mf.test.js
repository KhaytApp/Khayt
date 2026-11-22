/**
 * lib/hueforge-3mf.js — the file that actually goes to the printer.
 *
 * Every assertion here is measured against a REAL Snapmaker-Orca export
 * (`KING-Abdulaziz-ART-200mm-U1.3mf`) that the U1 printed, not against a shape
 * imagined here. That distinction found the bug this file now guards: Khayt
 * closed its final colour range at the model's exact height, while a working
 * export runs the last range to max_z="1000".
 *
 * Getting that wrong produces no error anywhere. The top layers simply fall
 * outside every range, take the object's default extruder — which
 * model_settings.config sets to 1, the base colour — and print in the wrong
 * filament. On a relief the top layers are the picture.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const HF = require('../lib/hueforge.js');
const M3 = require('../lib/hueforge-3mf.js');
const { openZip } = require('../lib/zip-read.js');
// The flat-line suite appended below refers to this module as HF3.
const HF3 = M3;

const LAYER_H = 0.08;

function build(bands, { W = 16, H = 16 } = {}) {
  const heights = [];
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) heights.push(4 + Math.round((i / (W - 1)) * 36));
  const mesh = HF.heightfieldToMesh({ width: W, height: H, heights }, { layerH: LAYER_H, widthMm: 80 });
  const buf = M3.buildU1_3mf({ triangles: mesh.triangles, bands, layerH: LAYER_H, name: 'probe', sizeMm: mesh.sizeMm });
  assert.ok(buf && buf.length > 0, 'no 3mf produced');
  // openZip returns a handle ({entries, file, ...}), not a bare array.
  const zip = openZip(buf);
  const byName = {};
  for (const e of zip.entries) byName[e.name] = e;
  return { buf, byName, text: (n) => Buffer.from(zip.file(n)).toString('utf8') };
}

const FOUR = [
  { z0: 0, z1: 0.8, head: 0, hex: '#111111' },
  { z0: 0.8, z1: 1.6, head: 1, hex: '#1b3a6b' },
  { z0: 1.6, z1: 2.4, head: 2, hex: '#c9a227' },
  { z0: 2.4, z1: 3.2, head: 3, hex: '#f2f2f2' },
];

test('the top colour range is open-ended, so no layer falls outside every band', () => {
  // The whole point. A real Orca export ends at 1000; closing at the model's
  // own height leaves the last layers to the default extruder — silently.
  const { text } = build(FOUR);
  const xml = text('Metadata/layer_config_ranges.xml');
  const ranges = [...xml.matchAll(/min_z="([\d.]+)" max_z="([\d.]+)"/g)].map((m) => [m[1], m[2]]);
  assert.equal(ranges.length, 4);
  assert.equal(ranges[3][1], '1000', `top range closed at ${ranges[3][1]} — the top layers will print in the base colour`);
  // Every lower boundary still meets the next band exactly; only the top opens.
  for (let i = 0; i < 3; i++) {
    assert.equal(ranges[i][1], ranges[i + 1][0], `gap between band ${i} and ${i + 1}`);
  }
});

test('heads are written as 1-based extruders, matching a working file', () => {
  // Bands are 0-based everywhere in lib/hueforge.js (`index`, `slot`). The U1
  // has four heads, so 0..3 must become 1..4 — a real export uses exactly that.
  const { text } = build(FOUR);
  const ext = [...text('Metadata/layer_config_ranges.xml').matchAll(/opt_key="extruder">(\d+)</g)].map((m) => m[1]);
  assert.deepEqual(ext, ['1', '2', '3', '4']);
  assert.ok(!ext.includes('5'), 'the U1 has four heads; extruder 5 does not exist');
});

test('the archive carries every part a Snapmaker-Orca project needs', () => {
  // Names taken from the real export, not from the spec — a 3MF missing one of
  // these opens as a bare mesh with the colour plan silently gone.
  const { byName } = build(FOUR);
  for (const n of [
    '[Content_Types].xml', '_rels/.rels', '3D/3dmodel.model', '3D/_rels/3dmodel.model.rels',
    'Metadata/project_settings.config', 'Metadata/model_settings.config', 'Metadata/layer_config_ranges.xml',
  ]) assert.ok(byName[n], `missing ${n}`);
});

test('fewer than four colours still produces a coherent plan', () => {
  const two = [{ z0: 0, z1: 1.2, head: 0 }, { z0: 1.2, z1: 3.2, head: 1 }];
  const { text } = build(two);
  const xml = text('Metadata/layer_config_ranges.xml');
  const ranges = [...xml.matchAll(/min_z="([\d.]+)" max_z="([\d.]+)"/g)].map((m) => [m[1], m[2]]);
  assert.equal(ranges.length, 2);
  assert.equal(ranges[0][0], '0', 'the first band must start at the bed');
  assert.equal(ranges[1][1], '1000', 'the last band is open whatever the count');
  assert.deepEqual([...xml.matchAll(/opt_key="extruder">(\d+)</g)].map((m) => m[1]), ['1', '2']);
});

test('the emitted XML is well formed', () => {
  // A stray character here means Orca opens the model with no colour plan and
  // no complaint, which is indistinguishable from the plan being wrong.
  const { text } = build(FOUR);
  for (const n of ['Metadata/layer_config_ranges.xml', 'Metadata/model_settings.config', '3D/3dmodel.model']) {
    const x = text(n);
    assert.match(x, /^<\?xml /, `${n} lacks a declaration`);
    const opens = (x.match(/<[a-zA-Z]/g) || []).length;
    const closes = (x.match(/<\//g) || []).length + (x.match(/\/>/g) || []).length;
    assert.equal(opens, closes, `${n}: ${opens} opening tags vs ${closes} closings`);
  }
});

/**
 * Base layer height.
 *
 * The reference export runs its opaque base at 0.24 mm and every colour band at
 * 0.12. The base only stops the bed showing through, so its layer height is
 * invisible in the finished piece; the bands above it are where the blending
 * happens. Khayt wrote the per-range key from the start and always gave every
 * range the same number — for the piece that reference was printing, 57 layers
 * instead of 28.
 */
const heightsOf = (xml) => [...xml.matchAll(/layer_height">([\d.]+)</g)].map((m) => m[1]);

test('the base band prints coarser than the colour bands', () => {
  const { text } = build(FOUR);
  const hs = heightsOf(text('Metadata/layer_config_ranges.xml'));
  assert.equal(hs.length, 4);
  assert.equal(Number(hs[0]), Number(hs[1]) * 2, 'base should be twice the colour layer height');
  assert.deepEqual(hs.slice(1), [hs[1], hs[1], hs[1]], 'only the base is coarse — blending needs fine layers');
});

test('at the reference layer height the output matches the real file exactly', () => {
  // 0.24 base / 0.12 colour is what KING-Abdulaziz-ART-200mm-U1.3mf contains.
  // Reproducing it is the strongest check available without Snapmaker Orca.
  const heights = [];
  for (let j = 0; j < 16; j++) for (let i = 0; i < 16; i++) heights.push(4 + Math.round((i / 15) * 36));
  const mesh = HF.heightfieldToMesh({ width: 16, height: 16, heights }, { layerH: 0.12, widthMm: 80 });
  const buf = M3.buildU1_3mf({ triangles: mesh.triangles, bands: FOUR, layerH: 0.12, name: 'p', sizeMm: mesh.sizeMm });
  const zip = openZip(buf);
  assert.deepEqual(heightsOf(Buffer.from(zip.file('Metadata/layer_config_ranges.xml')).toString('utf8')),
    ['0.24', '0.12', '0.12', '0.12']);
});

test('doubling never produces a layer no nozzle can lay down', () => {
  // A shop already printing coarse would otherwise get a base at 0.4mm — the
  // full width of a standard nozzle, which will not extrude cleanly.
  const heights = [];
  for (let j = 0; j < 16; j++) for (let i = 0; i < 16; i++) heights.push(4 + Math.round((i / 15) * 36));
  for (const layerH of [0.06, 0.2, 0.28, 0.5]) {
    const mesh = HF.heightfieldToMesh({ width: 16, height: 16, heights }, { layerH, widthMm: 80 });
    const buf = M3.buildU1_3mf({ triangles: mesh.triangles, bands: FOUR, layerH, name: 'p', sizeMm: mesh.sizeMm });
    const hs = heightsOf(Buffer.from(openZip(buf).file('Metadata/layer_config_ranges.xml')).toString('utf8'));
    const base = Number(hs[0]), colour = Number(hs[1]);
    // Two invariants, and the second is the one that caught a flaw in the fix:
    // capping alone inverted the relationship for a shop already printing
    // coarser than the cap, leaving the base FINER than the bands.
    assert.ok(base <= Math.max(0.3, layerH),
      `base ${base} at layerH ${layerH} was coarsened past what a 0.4 nozzle can print`);
    assert.ok(base >= colour, `base ${base} is finer than the colour bands ${colour}`);
  }
});


// ---------------------------------------------------------------------------
// The flat-multicolor line's own assertions for this module, brought across when
// wip/hueforge-flat was rebased. They cover properties the tests above do not:
// vertex welding, the embedded plate thumbnail, and the null-not-throw contract.
// Its fixtures are prefixed OPT_ because both suites had a `build`.
// ---------------------------------------------------------------------------
// A minimal, valid 1x1 PNG — stands in for the achievable-colour preview.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
  'base64'
);

const OPT_TRIS = [
  [[0, 0, 0.48], [10, 0, 0.48], [10, 10, 4.68]],
  [[0, 0, 0.48], [10, 10, 4.68], [0, 10, 1.2]],
];
const OPT_BANDS = [
  { z0: 0, z1: 1.2, head: 0, hex: '#302225' },
  { z0: 1.2, z1: 2.16, head: 1, hex: '#754845' },
  { z0: 2.16, z1: 3.12, head: 2, hex: '#B47A7D' },
  { z0: 3.12, z1: 4.68, head: 3, hex: '#E3D2C9' },
];
const buildOpts = (extra) => HF3.buildU1_3mf(Object.assign(
  { triangles: OPT_TRIS, bands: OPT_BANDS, layerH: 0.12, name: 'T', sizeMm: { x: 10, y: 10, z: 4.68 } },
  extra || {}
));

test('builds a valid, openable U1 3MF with the core members', () => {
  const z = openZip(buildOpts());
  const names = z.entries.map((e) => e.name);
  for (const n of [
    '[Content_Types].xml', '_rels/.rels', '3D/3dmodel.model',
    '3D/Objects/object_1.model', 'Metadata/project_settings.config',
    'Metadata/model_settings.config', 'Metadata/layer_config_ranges.xml',
  ]) assert.ok(names.includes(n), 'missing ' + n);
});

test('mesh is vertex-indexed (welded) + watertight by index, not a triangle soup', () => {
  // A soup (3 private vertices per triangle) reads as disconnected triangles in Orca →
  // "floating regions" / "empty initial layer" / unprintable. Coincident corners must weld
  // so the mesh is watertight BY INDEX (how the slicer builds connectivity).
  
  const W = 8, H = 8, heights = new Uint16Array(W * H);
  for (let i = 0; i < heights.length; i++) heights[i] = 10 + (i % 5); // varied relief
  const mesh = HF.heightfieldToMesh({ heights, width: W, height: H }, { layerH: 0.12, widthMm: 40 });
  const buf = HF3.buildU1_3mf({ triangles: mesh.triangles, bands: OPT_BANDS, layerH: 0.12, name: 'M', sizeMm: mesh.sizeMm });
  const xml = openZip(buf).file('3D/Objects/object_1.model').toString();
  const nv = (xml.match(/<vertex /g) || []).length;
  const nt = (xml.match(/<triangle /g) || []).length;
  assert.ok(nt > 0);
  assert.ok(nv < nt * 3, `expected welded vertices, got soup: ${nv} verts / ${nt} tris`);
  // every edge shared by exactly two triangles, by INDEX → watertight solid
  const edge = new Map();
  const add = (a, b) => { const k = a < b ? a + '_' + b : b + '_' + a; edge.set(k, (edge.get(k) || 0) + 1); };
  let m; const re = /<triangle v1="(\d+)" v2="(\d+)" v3="(\d+)"\/>/g;
  while ((m = re.exec(xml))) { add(+m[1], +m[2]); add(+m[2], +m[3]); add(+m[3], +m[1]); }
  let boundary = 0, nonmanifold = 0;
  for (const c of edge.values()) { if (c === 1) boundary++; else if (c > 2) nonmanifold++; }
  assert.strictEqual(boundary, 0, 'open (boundary) edges → not watertight');
  assert.strictEqual(nonmanifold, 0, 'non-manifold edges');
});

test('layer_config_ranges keys the geometry object (id=1) with 1-based extruders', () => {
  const xml = openZip(buildOpts()).file('Metadata/layer_config_ranges.xml').toString();
  assert.match(xml, /<object id="1">/);
  // heads 0..3 → extruders 1..4
  for (const ext of [1, 2, 3, 4]) assert.match(xml, new RegExp('<option opt_key="extruder">' + ext + '</option>'));
  assert.doesNotMatch(xml, /<option opt_key="extruder">0</, 'extruders must be 1-based');
});

test('prime tower stays off and is pinned in different_settings_to_system', () => {
  const cfg = JSON.parse(openZip(buildOpts()).file('Metadata/project_settings.config').toString());
  assert.strictEqual(cfg.enable_prime_tower, '0');
  assert.match(cfg.different_settings_to_system[0], /enable_prime_tower/);
  assert.deepStrictEqual(cfg.filament_colour, ['#302225', '#754845', '#B47A7D', '#E3D2C9']);
});

test('a thumbnail is embedded as the plate preview so the model shows a picture', () => {
  const z = openZip(buildOpts({ thumbnailPng: PNG, thumbnailSmallPng: PNG }));
  const names = z.entries.map((e) => e.name);
  assert.ok(names.includes('Metadata/plate_1.png'));
  assert.ok(names.includes('Metadata/plate_1_small.png'));
  // byte-identical (PNGs are STORE'd, not re-compressed)
  assert.strictEqual(Buffer.compare(z.file('Metadata/plate_1.png'), PNG), 0);
  const rels = z.file('_rels/.rels').toString();
  assert.match(rels, /metadata\/thumbnail"[^>]*\/>/);
  assert.match(rels, /cover-thumbnail-middle/);
  assert.match(rels, /Metadata\/plate_1_small\.png/);
  assert.match(openZip(buildOpts({ thumbnailPng: PNG })).file('Metadata/model_settings.config').toString(),
    /thumbnail_file/);
});

test('without a thumbnail the file is still valid and omits the plate PNGs', () => {
  const z = openZip(buildOpts());
  const names = z.entries.map((e) => e.name);
  assert.ok(!names.includes('Metadata/plate_1.png'));
  assert.doesNotMatch(z.file('_rels/.rels').toString(), /plate_1\.png/);
  assert.doesNotMatch(z.file('Metadata/model_settings.config').toString(), /thumbnail_file/);
});

test('bad input returns null, never throws', () => {
  assert.strictEqual(HF3.buildU1_3mf(null), null);
  assert.strictEqual(HF3.buildU1_3mf({ triangles: [], bands: OPT_BANDS }), null);
  assert.strictEqual(HF3.buildU1_3mf({ triangles: OPT_TRIS, bands: [] }), null);
});

test('the geometry part carries the <build/> the 3MF core spec requires', () => {
  // lib3mf refuses a model part without one, and reports it one level up as "Build item not
  // found" on the root. Ported from bedready.io, which found it validating against lib3mf.
  const z = openZip(buildOpts());
  const part = z.file('3D/Objects/object_1.model').toString();
  assert.match(part, /<\/resources><build\/><\/model>$/);
  // …and it is an EMPTY build: the part places nothing; the root still does all the placing.
  assert.doesNotMatch(part, /<item\b/);
  assert.match(z.file('3D/3dmodel.model').toString(), /<build><item objectid="2"/);
});

test('our own readers still find the whole relief through the root', () => {
  const buf = buildOpts();
  const mf = require('../lib/mf-convert');
  const members = mf.readMembers(buf);
  const parsed = (openZip(buf).file('3D/Objects/object_1.model').toString().match(/<triangle /g) || []).length;
  assert.equal(require('../lib/mf-mesh').extractMeshFromMembers(members).triangleCount, parsed);
  assert.ok(mf.computeBounds(members), 'the footprint still resolves through the root build item');
});
