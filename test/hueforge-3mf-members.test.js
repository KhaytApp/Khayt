'use strict';
/**
 * The native Mac app cannot load lib/zip-write.js (Node's zlib), so it asks hueforge-3mf for the
 * MEMBERS of a U1 3MF and zips them itself. These hold the split to what it promises: the members
 * are exactly what buildU1_3mf / buildFlatU1_3mf zip — so the desktop's file is unchanged — and the
 * module still finds its template when there is no `require`, the way JavaScriptCore runs it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const HF = require('../lib/hueforge');
const HF3 = require('../lib/hueforge-3mf');
const FLAT = require('../lib/hueforge-flat');
const zipWrite = require('../lib/zip-write');

function gradient(W, H) {
  const data = new Uint8ClampedArray(W * H * 4);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4; data[i] = x * 4; data[i + 1] = y * 6; data[i + 2] = (x * y) % 255; data[i + 3] = 255;
  }
  return { width: W, height: H, data };
}

function reliefInput() {
  const img = gradient(60, 40);
  const fils = HF.suggestFilaments(img, [], 4);
  const p = HF.planPainting(img, fils, { layerH: 0.08, heightMm: 2.4, widthMm: 60, baseLayers: 5 });
  const mesh = HF.heightfieldToMesh(p.solve, { layerH: 0.08, widthMm: 60 });
  return { triangles: mesh.triangles, bands: p.bands, filaments: p.filaments, layerH: 0.08, name: 'T', sizeMm: mesh.sizeMm, bed: { x: 270, y: 270 } };
}

test('u1Members zips to exactly buildU1_3mf, with and without a thumbnail', () => {
  const o = reliefInput();
  assert.ok(Buffer.compare(zipWrite.writeZip(HF3.u1Members(o)), HF3.buildU1_3mf(o)) === 0);
  const t = Object.assign({}, o, { thumbnailPng: Buffer.from([137, 80, 78, 71]) });
  assert.ok(Buffer.compare(zipWrite.writeZip(HF3.u1Members(t)), HF3.buildU1_3mf(t)) === 0);
  const names = HF3.u1Members(t).map((m) => m.name);
  assert.ok(names.includes('Metadata/layer_config_ranges.xml'));
  assert.ok(names.includes('Metadata/plate_1.png'));
});

test('flatU1Members zips to exactly buildFlatU1_3mf', () => {
  const img = gradient(60, 40);
  const fl = FLAT.planFlat(img, { colors: 3, widthMm: 60, heightMm: 2.4 });
  const built = FLAT.buildFlatParts({ labels: Array.from(fl.labels), palette: fl.palette, width: fl.width, height: fl.height }, { widthMm: 60, heightMm: 2.4 });
  const o = { parts: built.parts, filaments: built.filaments, sizeMm: built.sizeMm, baseHead: built.baseHead, layerH: 0.08, name: 'F' };
  assert.ok(Buffer.compare(zipWrite.writeZip(HF3.flatU1Members(o)), HF3.buildFlatU1_3mf(o)) === 0);
});

test('without require, the template comes from KhaytHueForgeU1Template and a thumbnail needs no Buffer', () => {
  const code = fs.readFileSync(path.join(__dirname, '..', 'lib', 'hueforge-3mf.js'), 'utf8');
  const tpl = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'lib', 'hueforge-u1-template.json'), 'utf8'));
  const sandbox = { KhaytHueForgeU1Template: tpl };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(code, sandbox);
  const o = Object.assign(reliefInput(), { thumbnailPng: new Uint8Array(4) });
  const members = sandbox.KhaytHueForge3mf.u1Members(JSON.parse(JSON.stringify(o, (k, v) => (k === 'thumbnailPng' ? undefined : v))));
  assert.ok(Array.isArray(members) && members.length === 8, 'no-thumbnail members');
  const withThumb = sandbox.KhaytHueForge3mf.u1Members(Object.assign({}, o));
  assert.equal(withThumb.length, 10);
  // Same members as Node builds, member for member.
  const node = HF3.u1Members(o);
  assert.equal(JSON.stringify(withThumb.slice(0, 8).map((m) => [m.name, m.data])), JSON.stringify(node.slice(0, 8).map((m) => [m.name, m.data])));
});
