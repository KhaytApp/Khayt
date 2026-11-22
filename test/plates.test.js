'use strict';
/**
 * One plate of a multi-plate 3MF, as a 3MF of its own (lib/plates.js).
 *
 * Ported from bedready.io's plates.ts and its tests, and asserting the rule its
 * history had to learn three times — an extracted package references nothing
 * it does not contain — over the WHOLE package (checkPackage), not one file at
 * a time. The fixture (test/helpers/multi-plate-3mf.js) is a Bambu-shaped
 * project: three plates, a two-part object, a painted object, an object with two
 * copies, per-plate thumbnails, slice info, custom G-code per plate, and the two
 * position-keyed files that must be renumbered rather than copied.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const plates = require('../lib/plates');
const mf = require('../lib/mf-convert');
const mfMesh = require('../lib/mf-mesh');
const jobs = require('../lib/mf-jobs');
const { openZip } = require('../lib/zip-read');
const { writeZip } = require('../lib/zip-write');
const { buildMultiPlate3mf, COLOURS, BED, STRIDE } = require('./helpers/multi-plate-3mf');

const SRC = buildMultiPlate3mf();
const text = (zip, n) => { const b = zip.file(n); return b ? b.toString('utf8') : null; };
const names = (buf) => openZip(buf).entries.map((e) => e.name).sort();
const rawOf = (buf, n) => { const z = openZip(buf); return z.raw(n); };
const extract = (i, src = SRC) => {
  const r = plates.extractPlate(src, i);
  assert.ok(r.ok, `plate ${i} should extract: ${r.error}`);
  return r;
};
const itemsOf = (rootXml) => [...rootXml.matchAll(/<item\b[^>]*objectid="(\d+)"[^>]*transform="([^"]+)"/g)]
  .map((m) => ({ id: m[1], t: m[2].split(/\s+/).map(Number) }));

// ── listing ───────────────────────────────────────────────────────────────

test('peekPlates lists every plate with its name, counts, thumbnail and colours', () => {
  const r = plates.peekPlates(SRC);
  assert.ok(r.ok);
  assert.deepEqual(r.plates.map((p) => [p.index, p.name]), [[1, 'Base'], [2, 'Dragon'], [3, 'Sign']]);
  assert.deepEqual(r.plates.map((p) => p.objectCount), [2, 2, 1]);
  assert.deepEqual(r.plates.map((p) => p.instanceCount), [2, 3, 1], 'plate 2 holds two copies of one object');
  assert.deepEqual(r.plates.map((p) => p.partCount), [3, 2, 1], 'the two-part object counts both parts');
  assert.ok(r.plates.every((p) => p.splittable && !p.problem));
  assert.ok(r.plates.every((p) => /^data:image\/png;base64,/.test(p.thumbnail)), 'each plate shows its own thumbnail');
  assert.notEqual(r.plates[0].thumbnail, r.plates[1].thumbnail);
  // Plate 1: filaments 1 and 2 (the lid). Plate 2: the base filament, its paint (3, 4) and
  // the copies' filament 2 — read from the mesh. Plate 3 is sliced, so slice_info answers.
  assert.deepEqual(r.plates.map((p) => p.colorIndices), [[0, 1], [0, 1, 2, 3], [3]]);
  assert.deepEqual(r.plates[2].colors, [COLOURS[3]]);
  assert.ok(r.plates.every((p) => !p.colorsApprox));
});

test('peekPlates reports each plate\'s own geometry size, not the archive\'s', () => {
  const r = plates.peekPlates(SRC);
  const z = openZip(SRC);
  const size = (n) => z.entries.find((e) => e.name === n).size;
  assert.equal(r.plates[2].bytes, size('3D/Objects/object_5.model'));
  assert.equal(r.plates[0].bytes, size('3D/Objects/object_1.model') + size('3D/Objects/object_2.model'));
});

/** The same members, but every geometry part claims to be huge and refuses to inflate. */
function hostileGeometry(buf) {
  const members = plates.readMembers(buf);
  for (const m of members) {
    if (!/^3D\/Objects\//.test(m.name)) continue;
    m.size = 900 * 1024 * 1024;
    Object.defineProperty(m, 'data', { get() { throw new Error(`inflated ${m.name}`); } });
  }
  return members;
}

test('listing a project too big to read whole never inflates its geometry', () => {
  const r = plates.peekPlatesMembers(hostileGeometry(SRC));
  assert.ok(r.ok, r.error);
  assert.equal(r.plates.length, 3);
  // Without the mesh, colours come from object and part filaments — and say so.
  assert.deepEqual(r.plates[0].colorIndices, [0, 1]);
  assert.ok(r.plates[0].colorsApprox && r.plates[1].colorsApprox);
  assert.deepEqual(r.plates[2].colorIndices, [3], 'a sliced plate is still exact');
});

test('splitting a plate out of a project too big to read whole copies its geometry still compressed', () => {
  const r = plates.extractPlateMembers(hostileGeometry(SRC), 2);
  assert.ok(r.ok, r.error);
  const parts = r.members.filter((m) => /^3D\/Objects\//.test(m.name));
  assert.deepEqual(parts.map((m) => m.name).sort(), ['3D/Objects/object_3.model', '3D/Objects/object_4.model']);
  assert.ok(parts.every((m) => m.raw && m.raw.comp), 'passed through as stored, never inflated');
  assert.ok(writeZip(r.members), 'and still writes a package');
});

// ── splitting ─────────────────────────────────────────────────────────────

test('each extracted plate holds exactly that plate\'s objects and parts', () => {
  const want = {
    1: { ids: ['2', '5'], parts: ['object_1', 'object_2'] },
    2: { ids: ['7', '9'], parts: ['object_3', 'object_4'] },
    3: { ids: ['11'], parts: ['object_5'] },
  };
  for (const [i, w] of Object.entries(want)) {
    const r = extract(Number(i));
    const z = openZip(r.buffer);
    const root = text(z, '3D/3dmodel.model');
    const defined = [...root.matchAll(/<object\b[^>]*\bid="(\d+)"/g)].map((m) => m[1]);
    assert.deepEqual(defined, w.ids, `plate ${i} root objects`);
    assert.deepEqual([...new Set(itemsOf(root).map((x) => x.id))], w.ids, `plate ${i} build items`);
    const parts = z.entries.map((e) => e.name).filter((n) => /^3D\/Objects\//.test(n)).map((n) => n.replace(/^3D\/Objects\/|\.model$/g, '')).sort();
    assert.deepEqual(parts, w.parts, `plate ${i} geometry parts`);
    const ms = text(z, 'Metadata/model_settings.config');
    assert.deepEqual([...ms.matchAll(/<object id="(\d+)"/g)].map((m) => m[1]), w.ids, `plate ${i} model_settings objects`);
    assert.equal((ms.match(/<plate>/g) || []).length, 1, 'one plate left');
    assert.match(ms, /key="plater_id" value="1"/, 'renumbered to plate 1');
    assert.deepEqual(plates.checkPackage(plates.readMembers(r.buffer)), [], `plate ${i} references only what it contains`);
  }
});

test('copies come along with their object, and a two-part object keeps both parts', () => {
  const z2 = openZip(extract(2).buffer);
  assert.equal(itemsOf(text(z2, '3D/3dmodel.model')).filter((x) => x.id === '9').length, 2, 'both copies of the peg');
  assert.equal((text(z2, 'Metadata/model_settings.config').match(/<model_instance>/g) || []).length, 3);
  const z1 = openZip(extract(1).buffer);
  const ms = text(z1, 'Metadata/model_settings.config');
  assert.match(ms, /<part id="3"[\s\S]*<part id="4"/, 'body and lid');
  assert.equal((text(z1, '3D/3dmodel.model').match(/<component\b/g) || []).length, 3);
});

test('the plate lands on one bed, exactly where its author put it on that plate', () => {
  // Plate 2 sits one stride to the right, plate 3 one stride down — Bambu's grid.
  const t2 = itemsOf(text(openZip(extract(2).buffer), '3D/3dmodel.model'));
  assert.deepEqual(t2.map((x) => [x.t[9], x.t[10]]), [[128, 100], [100, 160], [150, 160]]);
  const t3 = itemsOf(text(openZip(extract(3).buffer), '3D/3dmodel.model'));
  assert.deepEqual(t3.map((x) => [x.t[9], x.t[10]]), [[128, 128]]);
  assert.equal(extract(2).report.seat, 'grid');
  // Plate 1 is already at the origin: its build items are left exactly as written.
  const src = text(openZip(SRC), '3D/3dmodel.model');
  const r1 = extract(1);
  assert.equal(r1.report.seat, 'unchanged');
  for (const it of text(openZip(r1.buffer), '3D/3dmodel.model').match(/<item\b[^>]*\/>/g)) assert.ok(src.includes(it), 'item untouched');
  // And the geometry agrees: every extracted plate measures inside the bed.
  for (const i of [1, 2, 3]) {
    const g = mf.measureMesh(mf.readMembers(extract(i).buffer));
    assert.ok(g.bbox.min[0] >= 0 && g.bbox.min[1] >= 0 && g.bbox.max[0] <= BED && g.bbox.max[1] <= BED, `plate ${i} on the bed: ${JSON.stringify(g.bbox)}`);
  }
});

test('a plate whose items the grid does not explain is centred instead, and says so', () => {
  // Move plate 2's items a whole bed further right than the grid puts them.
  const z = openZip(SRC);
  const members = z.entries.map((e) => ({ name: e.name, data: z.entryData(e) }));
  const root = members.find((m) => m.name === '3D/3dmodel.model');
  root.data = Buffer.from(root.data.toString('utf8').replace(/ (\d+(?:\.\d+)?) (\d+(?:\.\d+)?) 0" printable/g, (m, x, y) => {
    const nx = Number(x);
    return nx > BED ? ` ${nx + STRIDE} ${y} 0" printable` : m;
  }));
  const r = plates.extractPlate(writeZip(members), 2);
  assert.ok(r.ok, r.error);
  assert.equal(r.report.seat, 'centred');
  const xs = itemsOf(text(openZip(r.buffer), '3D/3dmodel.model')).map((x) => x.t[9]);
  const mid = xs.reduce((s, x) => s + x, 0) / xs.length;
  assert.ok(Math.abs(mid - BED / 2) < 0.01, `centred on the bed (got ${mid})`);
});

test('thumbnails are the plate\'s own, renumbered to plate 1 and byte-identical', () => {
  const out = extract(3).buffer;
  const n = names(out);
  for (const f of ['plate_1.png', 'plate_1_small.png', 'plate_no_light_1.png', 'top_1.png', 'pick_1.png', 'plate_1.json']) assert.ok(n.includes('Metadata/' + f), f);
  assert.ok(!n.some((x) => /_(2|3)(_small)?\.(png|json)$/.test(x)), 'no other plate\'s files');
  assert.ok(openZip(out).file('Metadata/plate_1.png').equals(openZip(SRC).file('Metadata/plate_3.png')), 'plate 3\'s picture, under plate 1\'s name');
  const ms = text(openZip(out), 'Metadata/model_settings.config');
  assert.match(ms, /thumbnail_file" value="Metadata\/plate_1\.png"/);
  assert.match(ms, /pattern_bbox_file" value="Metadata\/plate_1\.json"/);
});

test('members a split does not touch are copied byte for byte', () => {
  const out = extract(2).buffer;
  for (const n of ['Metadata/project_settings.config', '3D/Objects/object_3.model', '3D/Objects/object_4.model', '[Content_Types].xml', 'Auxiliaries/.thumbnails/thumbnail_3mf.png']) {
    const a = rawOf(SRC, n), b = rawOf(out, n);
    assert.ok(a && b && a.comp.equals(b.comp) && a.crc === b.crc, `${n} unchanged`);
  }
  // Filament arrays untouched, so every paint code still names the colour it did.
  assert.deepEqual(JSON.parse(text(openZip(out), 'Metadata/project_settings.config')).filament_colour, COLOURS);
  assert.ok(rawOf(out, 'Metadata/plate_1.png').comp.equals(rawOf(SRC, 'Metadata/plate_2.png').comp), 'renamed, not re-encoded');
});

test('slice info, custom G-code and the filament sequence keep only this plate, renumbered', () => {
  const z3 = openZip(extract(3).buffer);
  const si3 = text(z3, 'Metadata/slice_info.config');
  assert.equal((si3.match(/<plate>/g) || []).length, 1);
  assert.match(si3, /key="index" value="1"/);
  assert.match(si3, /<header>/, 'header kept');
  assert.equal(text(z3, 'Metadata/custom_gcode_per_layer.xml'), null, 'plate 3 had no custom G-code');
  assert.deepEqual(JSON.parse(text(z3, 'Metadata/filament_sequence.json')), { plate_1: { sequence: [] } });

  const z2 = openZip(extract(2).buffer);
  assert.ok(!/<plate>/.test(text(z2, 'Metadata/slice_info.config')), 'plate 2 was not sliced');
  const cg = text(z2, 'Metadata/custom_gcode_per_layer.xml');
  assert.match(cg, /<plate_info id="1"\/>/);
  assert.match(cg, /M400 U1/, 'its pause survives');
  assert.deepEqual(JSON.parse(text(z2, 'Metadata/filament_sequence.json')), { plate_1: { sequence: [3, 1] } });
});

test('settings stored by object POSITION are renumbered to the objects that remain', () => {
  // Source positions: 2→1, 5→2, 7→3, 9→4, 11→5. Layer heights for positions 2 and 5,
  // a cut for position 3.
  const z1 = openZip(extract(1).buffer);
  assert.equal(text(z1, 'Metadata/layer_heights_profile.txt').trim(), 'object_id=2|0;0.2;4;0.2;4;0.12;10;0.12');
  assert.equal(text(z1, 'Metadata/cut_information.xml'), null, 'no cut object on plate 1');
  const z2 = openZip(extract(2).buffer);
  assert.match(text(z2, 'Metadata/cut_information.xml'), /<object id="1">/, 'object 7 is now first');
  assert.equal(text(z2, 'Metadata/layer_heights_profile.txt'), null);
  const z3 = openZip(extract(3).buffer);
  assert.equal(text(z3, 'Metadata/layer_heights_profile.txt').trim(), 'object_id=1|0;0.2;10;0.28');
});

test('the <assemble> list and relationships name only what is left', () => {
  const z = openZip(extract(2).buffer);
  const ms = text(z, 'Metadata/model_settings.config');
  assert.deepEqual([...ms.matchAll(/assemble_item object_id="(\d+)"/g)].map((m) => m[1]), ['7', '9', '9']);
  const rels = text(z, '3D/_rels/3dmodel.model.rels');
  assert.ok(rels.includes('object_3.model') && rels.includes('object_4.model') && !rels.includes('object_1.model'));
  assert.match(text(z, '_rels/.rels'), /plate_1\.png/, 'the cover now shows this plate');
});

// ── the converter's own re-check, and converting the plate ──────────────────

test('an extracted plate passes the converter\'s own reading, and converts', () => {
  for (const i of [1, 2, 3]) {
    const buf = extract(i).buffer;
    const a = mf.analyze(buf);
    assert.ok(a.ok && a.hasGeometry && !a.truncated, `plate ${i} analyses`);
    assert.equal(a.flavour, 'bambu');
    assert.deepEqual(a.filaments.map((f) => f.color), COLOURS, 'every filament still declared');
    assert.ok(!(a.meta && a.meta.plates), 'one plate now');
    const mesh = mfMesh.extractMeshFromBuffer(buf);
    const faces = { 1: 36, 2: 36, 3: 12 }[i];
    assert.equal(mesh.faceState.length, faces, `plate ${i} has exactly its own facets`);
    const c = mf.convert(buf, { targetId: 'bambu-p1s' });
    assert.ok(c.ok, `plate ${i} converts: ${c.error}`);
    assert.ok(mf.readMembers(c.buffer).some((m) => m.name === '3D/Objects/' + (i === 3 ? 'object_5' : i === 2 ? 'object_3' : 'object_1') + '.model'));
  }
  // The painted plate keeps its paint through extraction and conversion.
  const painted = mfMesh.extractMeshFromBuffer(mf.convert(extract(2).buffer, { targetId: 'bambu-p1s' }).buffer);
  assert.ok(painted.statesPresent.includes(3) && painted.statesPresent.includes(4));
});

test('the whole file still converts as it did', () => {
  const c = mf.convert(SRC, { targetId: 'bambu-p1s' });
  assert.ok(c.ok, c.error);
});

// ── refusals: never guess ───────────────────────────────────────────────────

test('an object with copies on two plates refuses those plates and only those', () => {
  const src = buildMultiPlate3mf({ sharedObject: true });
  const p = plates.peekPlates(src).plates;
  assert.deepEqual(p.map((x) => x.splittable), [true, false, false]);
  assert.equal(p[1].problem.code, 'shared-object');
  const r = plates.extractPlate(src, 3);
  assert.equal(r.ok, false);
  assert.equal(r.code, 'shared-object');
  assert.ok(plates.extractPlate(src, 1).ok);
});

test('a project without plates, a missing plate, and a non-3MF are refused clearly', () => {
  const plain = writeZip([
    { name: '3D/3dmodel.model', data: '<model><resources><object id="1"><mesh><vertices/><triangles/></mesh></object></resources><build><item objectid="1"/></build></model>' },
  ]);
  assert.equal(plates.peekPlates(plain).code, 'no-plates');
  assert.equal(plates.extractPlate(plain, 1).code, 'no-plates');
  assert.equal(plates.extractPlate(SRC, 9).code, 'no-such-plate');
  assert.equal(plates.extractPlate(Buffer.from('not a zip'), 1).code, 'not-3mf');
});

/** Rewrite one member of the fixture. */
function edit(name, fn) {
  const z = openZip(SRC);
  return writeZip(z.entries.map((e) => ({ name: e.name, data: e.name === name ? fn(z.entryData(e).toString('utf8')) : z.entryData(e) })));
}

test('copies that do not match what the plate lists are refused, not guessed at', () => {
  const src = edit('3D/3dmodel.model', (s) => s.replace(/\s*<item objectid="9" p:UUID="00090001[^>]*\/>/, ''));
  const r = plates.extractPlate(src, 2);
  assert.equal(r.code, 'instances-mismatch');
  assert.ok(plates.extractPlate(src, 1).ok, 'other plates are unaffected');
});

test('a plate whose geometry part is missing from the file is refused', () => {
  const z = openZip(SRC);
  const src = writeZip(z.entries.filter((e) => e.name !== '3D/Objects/object_5.model').map((e) => ({ name: e.name, data: z.entryData(e) })));
  assert.equal(plates.extractPlate(src, 3).code, 'missing-part');
});

test('position-keyed settings with an ambiguous object order are refused', () => {
  // model_settings lists objects in a different order from the build: which object is "position 2"?
  const src = edit('Metadata/model_settings.config', (s) => {
    const a = s.match(/  <object id="2">[\s\S]*?<\/object>\n/)[0];
    return s.replace(a, '').replace('  <plate>', a + '  <plate>');
  });
  assert.equal(plates.extractPlate(src, 1).code, 'positional-order');
});

test('an empty plate cannot be split out', () => {
  const src = edit('Metadata/model_settings.config', (s) => s.replace(/(<metadata key="plater_name" value="Sign"\/>[\s\S]*?)<model_instance>[\s\S]*?<\/model_instance>\n/, '$1'));
  const p = plates.peekPlates(src).plates[2];
  assert.equal(p.splittable, false);
  assert.equal(p.problem.code, 'empty-plate');
});

test('checkPackage catches a package that names a part it does not contain', () => {
  const bad = plates.checkPackage([
    { name: '_rels/.rels', data: Buffer.from('<Relationships><Relationship Target="/Metadata/plate_6.png" Id="r" Type="t"/></Relationships>') },
    { name: '3D/3dmodel.model', data: Buffer.from('<model><metadata name="Thumbnail_Middle">/Metadata/plate_6.png</metadata><resources><object id="2"><components><component p:path="/3D/Objects/gone.model" objectid="1"/></components></object></resources><build><item objectid="2"/></build></model>') },
    { name: 'Metadata/model_settings.config', data: Buffer.from('<config><plate><metadata key="thumbnail_file" value="Metadata/plate_6.png"/><model_instance><metadata key="object_id" value="40"/></model_instance></plate><assemble><assemble_item object_id="60"/></assemble></config>') },
  ]);
  assert.ok(bad.some((b) => b.includes('_rels/.rels')));
  assert.ok(bad.some((b) => b.includes('gone.model')));
  assert.ok(bad.some((b) => b.includes('object 40')) && bad.some((b) => b.includes('object 60')));
  assert.ok(bad.filter((b) => b.includes('plate_6.png')).length >= 3);
});

test('plateFileName names the split after its source', () => {
  assert.equal(plates.plateFileName('/tmp/Spider Poster.3mf', 6), 'Spider Poster-plate6.3mf');
  assert.equal(plates.plateFileName('C:\\x\\a.3MF', 2), 'a-plate2.3mf');
});

// ── the converter's "too large" refusal points at the picker ────────────────

test('a too-large convert carries a code and points at the plate list', () => {
  const members = mf.readMembers(SRC);
  Object.defineProperty(members, 'truncated', { value: { members: 2, bytes: 300 * 1024 * 1024 } });
  const r = mf.convertMembers(members, { targetId: 'bambu-p1s' });
  assert.equal(r.ok, false);
  assert.equal(r.code, 'too_large');
  assert.match(r.error, /too large to convert in one piece/);
  assert.match(r.error, /plate list/);
  assert.doesNotMatch(r.error, /one plate at a time/);
});

// ── the worker's jobs ───────────────────────────────────────────────────────

test('the worker lists plates and writes a split plate to the path it is given', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-plates-'));
  try {
    const src = path.join(dir, 'project.3mf');
    fs.writeFileSync(src, SRC);
    const l = await jobs.run('plates', { src, maxBytes: 50e6 });
    assert.ok(l.ok && l.plates.length === 3);
    const out = path.join(dir, 'out.3mf');
    const r = await jobs.run('extractPlate', { src, maxBytes: 50e6, plate: 2, tmpOut: out });
    assert.ok(r.ok && r.tmpPath === out, r.error);
    assert.equal(r.plate.name, 'Dragon');
    assert.ok(mf.analyze(fs.readFileSync(out)).ok);
    const bad = await jobs.run('extractPlate', { src, maxBytes: 50e6, plate: 7, tmpOut: out + '2' });
    assert.equal(bad.ok, false);
    assert.equal(bad.code, 'no-such-plate');
    assert.ok(!fs.existsSync(out + '2'), 'nothing written for a refusal');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
