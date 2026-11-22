'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const HF = require('../lib/hueforge');
const HF3 = require('../lib/hueforge-3mf');
const { openZip } = require('../lib/zip-read');

const FILS = [
  { hex: '#111318', td: 0.9 },  // opaque base
  { hex: '#0A3D7A', td: 2.0 },  // blue
  { hex: '#C99B27', td: 5.3 },  // gold
  { hex: '#F5F1E6', td: 10 },   // white
];

// synthetic image: horizontal bands of the four filament colours (so a good plan exists)
function bandedImage(W, H) {
  const data = new Uint8ClampedArray(W * H * 4);
  const cols = [[17, 19, 24], [10, 61, 122], [201, 155, 39], [245, 241, 230]];
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const c = cols[Math.min(3, (y / H * 4) | 0)]; const o = (y * W + x) * 4;
    data[o] = c[0]; data[o + 1] = c[1]; data[o + 2] = c[2]; data[o + 3] = 255;
  }
  return { data, width: W, height: H };
}

test('compositeSequence builds a palette one entry per layer, composited bottom→top', () => {
  const seq = [0, 0, 1, 2, 3];
  const pal = HF.compositeSequence(FILS, seq, 0.08);
  assert.strictEqual(pal.length, seq.length);
  for (let i = 0; i < pal.length; i++) { assert.strictEqual(pal[i].k, i + 1); assert.ok(pal[i].lab && pal[i].rgb); }
});

test('sequenceToBands makes contiguous runs; reused filament → multiple bands, one head', () => {
  const seq = [0, 0, 1, 1, 2, 0, 0]; // filament 0 reused at bottom and top
  const bands = HF.sequenceToBands(seq, FILS, 0.1);
  assert.deepStrictEqual(bands.map((b) => b.head), [0, 1, 2, 0]);
  assert.strictEqual(bands[0].z0, 0);
  assert.strictEqual(bands[bands.length - 1].z1, +(seq.length * 0.1).toFixed(4));
  // bands tile the height with no gaps
  for (let i = 1; i < bands.length; i++) assert.strictEqual(bands[i].z0, bands[i - 1].z1);
});

test('optimizeSequence pins the base to the most-opaque filament and is deterministic', () => {
  const reps = HF.quantizeTargets(bandedImage(48, 48), 48);
  const a = HF.optimizeSequence(reps, FILS, { totalLayers: 24, baseLayers: 4, layerH: 0.08, seed: 7 });
  const b = HF.optimizeSequence(reps, FILS, { totalLayers: 24, baseLayers: 4, layerH: 0.08, seed: 7 });
  assert.deepStrictEqual(a.seq, b.seq, 'same seed → same plan (no preview flicker)');
  assert.strictEqual(a.baseIdx, 0); // #111318 is most opaque (lowest TD)
  for (let k = 0; k < 4; k++) assert.strictEqual(a.seq[k], a.baseIdx, 'base layers use the opaque base');
  assert.strictEqual(a.seq.length, 24);
});

test('planPainting returns a full, height-tiling plan capped to 4 filaments', () => {
  const plan = HF.planPainting(bandedImage(64, 64), FILS, { layerH: 0.08, heightMm: 2.0, widthMm: 100 });
  assert.ok(plan && plan.bands.length >= 1);
  assert.ok(plan.filaments.length <= 4);
  assert.strictEqual(plan.seq.length, plan.totalLayers);
  assert.ok(plan.solve && plan.solve.heights.length === plan.solve.width * plan.solve.height);
  // heights never below the base floor
  let minK = Infinity; for (const h of plan.solve.heights) if (h < minK) minK = h;
  assert.ok(minK >= plan.baseLayers, `min height ${minK} < base ${plan.baseLayers}`);
});

test('print grid is capped near nozzle width (not full image resolution)', () => {
  const plan = HF.planPainting(bandedImage(600, 600), FILS, { layerH: 0.08, heightMm: 2.0, widthMm: 100, cellMm: 0.45 });
  // 100mm / 0.45mm ≈ 222 cells, not 600
  assert.ok(plan.solve.width <= 240, 'grid should be downsampled to ~nozzle resolution, got ' + plan.solve.width);
});

test('optimised plan exports a watertight indexed U1 3MF with 4-slot filament_colour', () => {
  const plan = HF.planPainting(bandedImage(80, 80), FILS, { layerH: 0.08, heightMm: 2.0, widthMm: 100 });
  const mesh = HF.heightfieldToMesh(plan.solve, { layerH: plan.layerH, widthMm: 100 });
  const buf = HF3.buildU1_3mf({
    triangles: mesh.triangles, bands: plan.bands, filaments: plan.filaments.map((f) => f.hex),
    layerH: plan.layerH, name: 'paint', sizeMm: mesh.sizeMm,
  });
  assert.ok(buf, 'export produced a buffer');
  const z = openZip(buf);
  const cfg = JSON.parse(z.file('Metadata/project_settings.config').toString());
  // filament_colour is the 4 distinct filaments (indexed by head), NOT one-per-band
  assert.strictEqual(cfg.filament_colour.length, 4);
  assert.strictEqual(cfg.filament_colour[0], '#111318');
  assert.strictEqual(cfg.filament_colour[2], '#C99B27');
  assert.strictEqual(cfg.layer_height, String(plan.layerH));
  // ranges reference extruders in 1..4 (head+1)
  const ranges = z.file('Metadata/layer_config_ranges.xml').toString();
  assert.match(ranges, /opt_key="extruder">[1-4]</);
  assert.doesNotMatch(ranges, /opt_key="extruder">[05-9]</);
  // mesh watertight by index
  const xml = z.file('3D/Objects/object_1.model').toString();
  const nv = (xml.match(/<vertex /g) || []).length, nt = (xml.match(/<triangle /g) || []).length;
  assert.ok(nv < nt * 3, 'welded, not a triangle soup');
  const edge = new Map();
  const add = (a, b) => { const k = a < b ? a + '_' + b : b + '_' + a; edge.set(k, (edge.get(k) || 0) + 1); };
  let m; const re = /<triangle v1="(\d+)" v2="(\d+)" v3="(\d+)"\/>/g;
  while ((m = re.exec(xml))) { add(+m[1], +m[2]); add(+m[2], +m[3]); add(+m[3], +m[1]); }
  let boundary = 0; for (const c of edge.values()) if (c === 1) boundary++;
  assert.strictEqual(boundary, 0, 'watertight (no open edges)');
});
