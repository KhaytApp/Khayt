'use strict';
/**
 * Small hostile 3MFs that used to cost seconds to hours of CPU, or all the memory.
 *
 * Modelled on bedready.io's src/lib/hostile-input.test.mts (its #38, the 2026-10-02
 * security review), which found each of these in the web converter this engine was
 * ported from. Every file here is a few hundred bytes to a few hundred kilobytes, and
 * each must now fail or finish fast. The time ceilings are generous on purpose — they
 * are there to catch "quadratic" and "exponential", not to benchmark.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { writeZip } = require('../lib/zip-write');
const mesh = require('../lib/mf-mesh');
const conv = require('../lib/mf-convert');

const members = (xml, extra = []) => [{ name: '3D/3dmodel.model', data: Buffer.from(xml, 'utf8') }, ...extra];
const timed = (fn) => { const t = Date.now(); const r = fn(); return { r, ms: Date.now() - t }; };

// ── the triangle rewrite ─────────────────────────────────────────────────────

test('a Prusa triangle tag that never closes is linear, not quadratic', () => {
  // applyPrusaVolumePaint runs on any file with a Slic3r_PE_model.config carrying volumes.
  const cfg = '<config><object id="1"><metadata type="object" key="extruder" value="1"/>'
    + '<volume firstid="0" lastid="0"><metadata type="volume" key="extruder" value="2"/></volume></object></config>';
  const xml = '<model><resources><object id="1"><mesh><triangles><triangle v1="0"'
    + ' '.repeat(60000) + '</triangles></mesh></object></resources></model>';
  const { ms } = timed(() => mesh.extractMeshFromMembers(members(xml,
    [{ name: 'Metadata/Slic3r_PE_model.config', data: Buffer.from(cfg, 'utf8') }])));
  assert.ok(ms < 1000, `took ${ms} ms`);
});

test('the Prusa volume painter still paints a well-formed triangle', () => {
  // The linear pattern must not lose the ordinary case, with or without a space before "/>".
  const cfg = '<config><object id="1"><metadata type="object" key="extruder" value="1"/>'
    + '<volume firstid="0" lastid="0"><metadata type="volume" key="extruder" value="2"/></volume>'
    + '<volume firstid="1" lastid="1"><metadata type="volume" key="extruder" value="3"/></volume></object></config>';
  const xml = '<model unit="millimeter"><resources><object id="1"><mesh><vertices>'
    + '<vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="1"/></vertices>'
    + '<triangles><triangle v1="0" v2="1" v3="2" /><triangle v1="0" v2="2" v3="1"/></triangles>'
    + '</mesh></object></resources><build><item objectid="1"/></build></model>';
  const r = mesh.extractMeshFromMembers(members(xml,
    [{ name: 'Metadata/Slic3r_PE_model.config', data: Buffer.from(cfg, 'utf8') }]));
  assert.deepEqual(Array.from(r.faceState), [2, 3]);
});

test('no triangle rewriter in lib/ uses the backtracking pattern', () => {
  const bad = '<triangle\\b([^>]*?)\\s*\\/>';
  for (const f of ['mf-mesh.js', 'mf-convert.js']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', f), 'utf8');
    assert.ok(!src.includes(bad), `${f} matches <triangle …/> with a lazy group before \\s*`);
  }
});

// ── the component graph ──────────────────────────────────────────────────────

/**
 * A branch that doubles per level and ends in nothing, beside one real triangle (or, with
 * `leaf`, ending in the triangle). The empty branch is the nasty one for the preview: the
 * instance cap counts leaves, so it saw one instance and let the walk visit 2^levels nodes.
 */
function doubling(levels, leaf) {
  let objs = '<object id="1"><components><component objectid="2"/><component objectid="100"/></components></object>';
  for (let k = 2; k <= levels; k++) {
    const next = leaf && k === levels ? 100 : k + 1;
    objs += `<object id="${k}"><components><component objectid="${next}"/><component objectid="${next}"/></components></object>`;
  }
  objs += '<object id="100"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/>'
    + '<vertex x="0" y="1" z="1"/></vertices><triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object>';
  return `<?xml version="1.0"?><model unit="millimeter"><resources>${objs}</resources><build><item objectid="1"/></build></model>`;
}

test('preview: a component graph that doubles per level stops on the visit budget', () => {
  const { r, ms } = timed(() => mesh.extractMeshFromMembers(members(doubling(40, false))));
  assert.equal(r.skipped, true, 'a graph past the visit budget is reported as too large');
  assert.ok(ms < 10000, `took ${ms} ms`);
});

test('measureMesh: the same graph is abandoned, not walked', () => {
  const { r, ms } = timed(() => conv.measureMesh(members(doubling(40, false))));
  assert.equal(r, null);
  assert.ok(ms < 10000, `took ${ms} ms`);
});

test('extractTriangles: a graph that would build 2^39 triangles is refused before building', () => {
  const { r, ms } = timed(() => conv.extractTriangles(members(doubling(40, true))));
  assert.equal(r, null);
  assert.ok(ms < 2000, `took ${ms} ms`);
});

test('an honest assembly still resolves after all three guards', () => {
  const xml = doubling(4, true); // 2^3 instances of the triangle, plus the sibling
  assert.equal(mesh.extractMeshFromMembers(members(xml)).triangleCount, 9);
  assert.equal(conv.extractTriangles(members(xml)).length, 9);
  assert.equal(conv.measureMesh(members(xml)).triangleCount, 9);
});

// ── the member budget ────────────────────────────────────────────────────────

/** A zip whose members' headers claim an uncompressed size of 0, whatever they hold. */
function undeclaredZip(entries) {
  const z = writeZip(entries);
  for (let i = 0; i + 4 <= z.length; i++) {
    const sig = z.readUInt32LE(i);
    if (sig === 0x04034b50) z.writeUInt32LE(0, i + 22); // local header: uncompressed size
    if (sig === 0x02014b50) z.writeUInt32LE(0, i + 24); // central directory: the same
  }
  return z;
}

test('readMembers charges a mesh that declares size 0 what it really inflates to', () => {
  // 1 MB of real mesh behind a header claiming nothing. It used to be budgeted at its
  // compressed size (about a kilobyte) while zip-read let it inflate to 400 MB.
  const big = Buffer.from('<model>' + ' '.repeat(1024 * 1024) + '</model>', 'utf8');
  const out = conv.readMembers(undeclaredZip([
    { name: '3D/3dmodel.model', data: big },
    { name: 'Metadata/project_settings.config', data: '{}' },
  ]));
  const m = out.find((x) => x.name === '3D/3dmodel.model');
  assert.ok(m, 'the member is still read');
  assert.equal(m.size, big.length, 'charged and reported at its real size, not the declared 0');
  assert.equal(m.data.length, big.length);
  assert.equal(out.truncated, null);
});

test('readMembers still reads an honest archive the same way', () => {
  const out = conv.readMembers(writeZip([
    { name: '3D/3dmodel.model', data: '<model/>' },
    { name: 'Metadata/project_settings.config', data: '{}' },
  ]));
  assert.deepEqual(out.map((m) => m.name).sort(), ['3D/3dmodel.model', 'Metadata/project_settings.config']);
  assert.equal(out.find((m) => m.name === '3D/3dmodel.model').data.toString(), '<model/>');
});
