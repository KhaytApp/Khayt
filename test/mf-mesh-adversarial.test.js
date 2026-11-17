'use strict';
/**
 * A crafted 3MF cannot freeze the app through lib/mf-mesh.js.
 *
 * beta.40 security review (Nov 17): `/<object\b[^>]*>([\s\S]*?)<\/object>/g`
 * and its kin (mesh, part, plate, volume, component, item, vertex, triangle,
 * the <model unit>) rescanned to the end from every opener with no ">" or no
 * close: 200 KB took 0.1–2.3 s per pattern, 10 MB about 13 minutes. The
 * PrusaSlicer .ini `grab` was quadratic on whitespace (200 KB: 19 s). All now
 * scan with indexOf (scanTags), and triangles are counted without a match
 * array. Pinned: each shape at 50 KB under 50 ms and linear to 8 MB, through
 * extractMeshFromBuffer and digestModelMember. The answers on the shop's 657
 * local 3MFs were byte-identical before and after (every result field hashed).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/mf-mesh.js');
const { makeZip } = require('./helpers/make-zip');

const repeatTo = (unit, bytes) => unit.repeat(Math.ceil(bytes / unit.length));
const ms = (f) => { const t = process.hrtime.bigint(); f(); return Number(process.hrtime.bigint() - t) / 1e6; };
const SOLID = '<model><resources><object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/>'
  + '<vertex x="0" y="1" z="0"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>'
  + '</resources><build><item objectid="1"/></build></model>';

const MODEL = {
  '<object with no >': (b) => '<model><resources>' + repeatTo('<object id="1" ', b),
  '<object> with no close': (b) => '<model><resources>' + repeatTo('<object id="1">', b),
  '<mesh> with no close': (b) => '<model><resources><object id="1">' + repeatTo('<mesh>', b) + '</object>',
  '<component with no >': (b) => '<model><resources><object id="1">' + repeatTo('<component ', b) + '</object>',
  '<triangle with no >': (b) => '<model><resources><object id="1"><mesh><vertices><vertex x="0" y="0" z="0"/></vertices><triangles>' + repeatTo('<triangle ', b) + '</triangles></mesh></object><build><item objectid="1"/></build>',
  '<vertex with no >': (b) => '<model><resources><object id="1"><mesh><vertices>' + repeatTo('<vertex ', b) + '</vertices></mesh></object><build><item objectid="1"/></build>',
  '<item with no >': (b) => '<model><build>' + repeatTo('<item ', b),
  '<model with no >': (b) => '<build>' + repeatTo('<model ', b),
};
const MEMBER = {
  'model_settings: <object> with no close': ['Metadata/model_settings.config', (b) => '<config>' + repeatTo('<object id="1">', b)],
  'model_settings: <part> with no close': ['Metadata/model_settings.config', (b) => '<config><object id="1">' + repeatTo('<part id="1">', b) + '</object>'],
  'model_settings: <plate> with no close': ['Metadata/model_settings.config', (b) => '<config>' + repeatTo('<plate>', b)],
  'Slic3r_PE_model: <object> with no close': ['Metadata/Slic3r_PE_model.config', (b) => '<config>' + repeatTo('<object id="1">', b)],
  'Slic3r_PE_model: <volume> with no close': ['Metadata/Slic3r_PE_model.config', (b) => '<config><object id="1">' + repeatTo('<volume firstid="0" lastid="1">', b) + '</object>'],
  'Slic3r_PE.config: whitespace': ['Metadata/Slic3r_PE.config', (b) => repeatTo(' \n', b)],
};
const CASES = {};
for (const [k, make] of Object.entries(MODEL)) {
  CASES['extract, ' + k] = (b) => { const zip = makeZip([{ name: '3D/3dmodel.model', data: make(b), method: 8 }]); return () => M.extractMeshFromBuffer(zip, 1); };
  CASES['digest, ' + k] = (b) => { const text = make(b); return () => M.digestModelMember('3D/3dmodel.model', text); };
}
for (const [k, [name, make]] of Object.entries(MEMBER)) {
  CASES['extract, ' + k] = (b) => { const zip = makeZip([{ name, data: make(b), method: 8 }, { name: '3D/3dmodel.model', data: SOLID, method: 8 }]); return () => M.extractMeshFromBuffer(zip, 1); };
}

for (const [name, make] of Object.entries(CASES)) {
  test(`${name}: 50 KB under 50 ms`, () => {
    const t = ms(make(50 * 1024));
    assert.ok(t < 50, `${t.toFixed(1)} ms`);
  });
  test(`${name}: 8 MB stays linear`, () => {
    const one = Math.max(ms(make(1 << 20)), 1);
    const eight = ms(make(8 << 20));
    assert.ok(eight < 2000, `${eight.toFixed(0)} ms`);
    assert.ok(eight < one * 8 * 4 + 50, `1 MB ${one.toFixed(1)} ms, 8 MB ${eight.toFixed(1)} ms`);
  });
}

test('the answers did not change on a well-formed file', () => {
  const r = M.extractMeshFromBuffer(makeZip([{ name: '3D/3dmodel.model', data: SOLID, method: 8 }]), 1);
  assert.equal(r.triangleCount, 1);
  assert.deepEqual([...r.slotsUsed], [1]);
  const d = M.digestModelMember('3D/3dmodel.model', SOLID);
  assert.equal(d.objects[0].tris, 1);
});

test('characters whose lowercase is longer do not shift a case-insensitive tag (re-review, Nov 17)', () => {
  // `<model unit="inch">` after a comment holding 'İ' (two characters
  // lowercased), 'ẞ' or Greek capitals: the unit must still read as inch.
  for (const pre of ['', 'İ', 'İİ', 'İİİİİİ', 'ẞẞ', 'ΣΣΣ', 'İẞΣ'.repeat(40)]) {
    const xml = `<?xml version="1.0"?><!-- ${pre} --><MODEL unit="inch"><resources><object id="1"><mesh><vertices>`
      + '<vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices>'
      + '<triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object></resources><build><item objectid="1"/></build></MODEL>';
    const r = M.extractMeshFromBuffer(makeZip([{ name: '3D/3dmodel.model', data: xml, method: 8 }]), 1);
    assert.equal(r.mmPerUnit, 25.4, JSON.stringify(pre));
  }
});
