'use strict';
/**
 * The slots a print uses, worked out one `.model` member at a time
 * (`digestModelMember` + `slotsUsedFromDigests`), are the slots the whole-file
 * extractor names (`extractMeshFromMembers(...).slotsUsed`), for every file.
 *
 * The Mac binds model XML as strings and has a memory budget; a painted project
 * with more XML than the budget could not be read at all (7 of one shop's 662
 * local 3MFs, Nov 2026). Reading a member at a time needs only the largest
 * member in memory. It is only worth having if it never disagrees with the
 * extractor, so every case here is run through both.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const M = require('../lib/mf-mesh.js');
const Z = require('../lib/zip-read.js');

const VERTS = '<vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices>';
const tri = (paint) => `<triangle v1="0" v2="1" v3="2"${paint != null ? ` paint_color="${paint}"` : ''}/>`;
const meshObj = (id, paints) => `<object id="${id}" type="model"><mesh>${VERTS}<triangles>${paints.map(tri).join('')}</triangles></mesh></object>`;
const compObj = (id, comps) => `<object id="${id}" type="model"><components>${comps.map((c) =>
  `<component${c.path ? ` p:path="${c.path}"` : ''} objectid="${c.id}"/>`).join('')}</components></object>`;
const model = (objects, items) => `<?xml version="1.0"?><model unit="millimeter"><resources>${objects.join('')}</resources>` +
  (items ? `<build>${items.map((i) => `<item objectid="${i}"/>`).join('')}</build>` : '') + '</model>';
const settings = (objects) => '<config>' + objects.map((o) =>
  `<object id="${o.id}">${o.extruder != null ? `<metadata key="extruder" value="${o.extruder}"/>` : ''}` +
  (o.faceCount ? `<metadata face_count="${o.faceCount}"/>` : '') +
  (o.parts || []).map((p) => `<part id="${p.id}" subtype="normal_part">${p.extruder != null ? `<metadata key="extruder" value="${p.extruder}"/>` : ''}</part>`).join('') +
  '</object>').join('') + '</config>';

const solid = (n) => M.encodeSolidPaint(n);
const SPLIT_0_2 = M.bitsToHex([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);

/** Both readers over the same members; they must agree. */
function both(members, hardCap) {
  const whole = M.extractMeshFromMembers(members.map((m) => ({ name: m.name, data: Buffer.from(m.data) })), 1, hardCap);
  const digests = members.filter((m) => /\.model$/i.test(m.name)).map((m) => M.digestModelMember(m.name, m.data));
  const ms = members.find((m) => m.name.toLowerCase().split('/').pop() === 'model_settings.config');
  const part = M.slotsUsedFromDigests(digests, ms ? ms.data : '', hardCap);
  return { whole: whole.skipped ? null : whole.slotsUsed, part };
}
function agree(name, members, want, hardCap) {
  test(name, () => {
    const r = both(members, hardCap);
    assert.deepEqual(r.part, r.whole, 'member by member must be what the extractor says');
    if (want !== undefined) assert.deepEqual(r.part, want);
  });
}

const ROOT = '3D/3dmodel.model';

agree('one unpainted object prints with slot 1', [{ name: ROOT, data: model([meshObj(1, [null, null])], [1]) }], [1]);

agree('paint adds its slots; an unpainted face keeps the base', [
  { name: ROOT, data: model([meshObj(1, [solid(2), solid(5), null])], [1]) }], [1, 2, 5]);

agree('a fully painted object does not use its base', [
  { name: ROOT, data: model([meshObj(1, [solid(2), solid(3)])], [1]) }], [2, 3]);

agree('a split face uses its base and the painted slot', [
  { name: ROOT, data: model([meshObj(1, [SPLIT_0_2])], [1]) }], [1, 2]);

agree('the base is the part\'s extruder, then the object\'s by face count, then the first named', [
  { name: ROOT, data: model([meshObj(1, [null]), meshObj(2, [null, null]), meshObj(3, [null, null, null]),
    compObj(10, [{ id: 1 }]), compObj(11, [{ id: 2 }]), compObj(12, [{ id: 3 }])], [10, 11, 12]) },
  { name: 'Metadata/model_settings.config', data: settings([
    { id: 10, extruder: 4, parts: [{ id: 1, extruder: 6 }] },
    { id: 11, extruder: 7, faceCount: 2, parts: [] },
    { id: 12, parts: [] }]) }], [4, 6, 7]);

agree('a split face in a part with its own extruder falls back to THAT extruder', [
  { name: ROOT, data: model([meshObj(1, [SPLIT_0_2]), compObj(10, [{ id: 1 }])], [10]) },
  { name: 'Metadata/model_settings.config', data: settings([{ id: 10, extruder: 1, parts: [{ id: 1, extruder: 3 }] }]) }], [2, 3]);

agree('components in other members (the Orca layout), meshes in their own files', [
  { name: ROOT, data: model([compObj(1, [{ path: '/3D/Objects/a.model', id: 5 }, { path: '/3D/Objects/b.model', id: 6 }])], [1]) },
  { name: '3D/Objects/a.model', data: model([meshObj(5, [solid(4), null])]) },
  { name: '3D/Objects/b.model', data: model([meshObj(6, [solid(8)])]) },
  { name: 'Metadata/model_settings.config', data: settings([{ id: 1, extruder: 2, parts: [{ id: 5 }, { id: 6, extruder: 3 }] }]) }], [2, 4, 8]);

agree('an object that is in a file but not built is not counted', [
  { name: ROOT, data: model([meshObj(1, [solid(2)]), meshObj(2, [solid(9)])], [1]) }], [2]);

agree('no <build>: every mesh object is a root', [
  { name: ROOT, data: model([meshObj(1, [solid(2)]), meshObj(2, [solid(9), null])]) }], [1, 2, 9]);

agree('an object built twice is counted once', [
  { name: ROOT, data: model([meshObj(1, [solid(3), null])], [1, 1]) }], [1, 3]);

agree('a component cycle stops and still names the mesh it reaches', [
  { name: ROOT, data: model([meshObj(3, [solid(2)]), compObj(1, [{ id: 3 }, { id: 2 }]), compObj(2, [{ id: 1 }, { id: 3 }])], [1]) }], [2]);

agree('a component naming a missing object or file adds nothing', [
  { name: ROOT, data: model([meshObj(1, [null]), compObj(2, [{ id: 1 }, { id: 99 }, { path: '/3D/none.model', id: 1 }])], [2]) }], [1]);

agree('no triangles at all: no slots, not "skipped"', [
  { name: ROOT, data: model([compObj(1, [])], [1]) }], []);

agree('over the triangle cap both say they could not tell', [
  { name: ROOT, data: model([meshObj(1, [solid(2), solid(3), null])], [1]) }], null, 2);

agree('mmu_segmentation is paint too, and a state past 3 decodes', [
  { name: ROOT, data: model([`<object id="1" type="model"><mesh>${VERTS}<triangles><triangle v1="0" v2="1" v3="2" mmu_segmentation="${solid(12)}"/></triangles></mesh></object>`], [1]) }], [12]);

// Generated: many small files with random structure, both readers on each.
test('500 generated projects: the two readers never disagree', () => {
  let seed = 20261116;
  const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
  const paints = [null, solid(1), solid(2), solid(3), solid(5), solid(9), SPLIT_0_2];
  for (let k = 0; k < 500; k++) {
    const files = 1 + rnd(3);
    const members = [], meshIds = [], compIds = [];
    let nextId = 1;
    const rootObjs = [];
    for (let f = 0; f < files; f++) {
      const objs = [];
      const count = 1 + rnd(3);
      const name = f === 0 ? ROOT : `3D/Objects/o${f}.model`;
      for (let i = 0; i < count; i++) {
        const id = nextId++;
        const ps = []; for (let t = 0, n = rnd(5); t < n; t++) ps.push(paints[rnd(paints.length)]);
        objs.push(meshObj(id, ps));
        meshIds.push({ id, path: '/' + name });
      }
      if (f === 0) rootObjs.push(...objs); else members.push({ name, data: model(objs) });
    }
    for (let i = 0, n = rnd(3); i < n; i++) {
      const id = nextId++;
      const comps = []; for (let c = 0, m = 1 + rnd(3); c < m; c++) {
        const pick = rnd(4) === 0 && compIds.length ? { id: compIds[rnd(compIds.length)] } : meshIds[rnd(meshIds.length)];
        comps.push(pick.path === '/' + ROOT ? { id: pick.id } : pick);
      }
      rootObjs.push(compObj(id, comps)); compIds.push(id);
    }
    const all = [...meshIds.filter((m) => m.path === '/' + ROOT).map((m) => m.id), ...compIds];
    const items = rnd(6) === 0 ? null : Array.from({ length: 1 + rnd(3) }, () => all[rnd(all.length)]);
    members.unshift({ name: ROOT, data: model(rootObjs, items) });
    if (rnd(3) > 0) {
      members.push({ name: 'Metadata/model_settings.config', data: settings(compIds.concat(meshIds.map((m) => m.id)).filter(() => rnd(2)).map((id) => ({
        id, extruder: rnd(3) ? 1 + rnd(8) : null, faceCount: rnd(3) ? rnd(6) : 0,
        parts: meshIds.filter(() => rnd(3) === 0).map((m) => ({ id: m.id, extruder: rnd(2) ? 1 + rnd(8) : null })) }))) });
    }
    const r = both(members);
    assert.deepEqual(r.part, r.whole, `case ${k}: ${JSON.stringify(members.map((m) => m.data))}`);
  }
});

// The sample 3MFs both apps read.
const dir = path.join(__dirname, 'fixtures', 'library-colours');
for (const name of fs.readdirSync(dir).filter((n) => n.endsWith('.3mf'))) {
  test(`fixture ${name}`, () => {
    const buf = fs.readFileSync(path.join(dir, name));
    const zip = Z.openZip(buf);
    const members = zip.entries.map((e) => ({ name: e.name, data: zip.file(e.name).toString('utf8') }));
    const r = both(members);
    assert.deepEqual(r.part, r.whole);
    const want = JSON.parse(fs.readFileSync(path.join(dir, 'expected.json'), 'utf8'))[name];
    assert.deepEqual(r.part, want.paintSlots);
  });
}

test('a digest is small: it keeps counts and states, never the mesh', () => {
  const big = model([meshObj(1, Array.from({ length: 20000 }, (_, i) => (i % 3 ? solid(1 + (i % 7)) : null)))], [1]);
  const d = M.digestModelMember(ROOT, big);
  assert.ok(big.length > 800000);
  assert.ok(JSON.stringify(d).length < 300, JSON.stringify(d).length + ' bytes');
  assert.deepEqual(d.objects[0], { id: 1, tris: 20000, states: [1, 2, 3, 4, 5, 6, 7], usesBase: true });
});
