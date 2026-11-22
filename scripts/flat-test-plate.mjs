#!/usr/bin/env node
/**
 * Generate a FLAT-mode test plate and check everything that can be checked without a printer.
 *
 *   node scripts/flat-test-plate.mjs <image.png> [outDir] [widthMm]
 *
 * Flat mode has passed every test that can be written about it and has never been printed.
 * This exists to close that gap from the near side: produce the real file, then verify — from
 * the file itself, not from the code that wrote it — that every colour region is a part, every
 * part names a head, the heads are the ones the palette says, and the plate fits the bed.
 *
 * What it cannot do is tell you the print is right. That needs Orca and the U1, and the
 * checklist it prints at the end is the part a person has to do.
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { PNG } = require('pngjs');
const FLAT = require(path.join(ROOT, 'lib/hueforge-flat.js'));
const M3 = require(path.join(ROOT, 'lib/hueforge-3mf.js'));
const { openZip } = require(path.join(ROOT, 'lib/zip-read.js'));

const src = process.argv[2];
const outDir = process.argv[3] || path.join(process.env.HOME || '.', 'Desktop');
const widthMm = +(process.argv[4] || 60);
if (!src || !fs.existsSync(src)) { console.error('usage: flat-test-plate.mjs <image.png> [outDir] [widthMm]'); process.exit(1); }

const fail = [];
const ok = (cond, msg) => { console.log((cond ? '  ok   ' : '  FAIL ') + msg); if (!cond) fail.push(msg); };

// ── the image, as the studio would see it ───────────────────────────────────
const png = PNG.sync.read(fs.readFileSync(src));
const img = { data: new Uint8ClampedArray(png.data), width: png.width, height: png.height };
console.log(`image   ${path.basename(src)}  ${png.width}x${png.height}`);

// ── the plan, through the shipped library ───────────────────────────────────
const plan = FLAT.planFlat(img, { colors: 4, widthMm, heightMm: 2.4 });
console.log(`plate   ${plan.sizeMm.x.toFixed(1)} x ${plan.sizeMm.y.toFixed(1)} x ${plan.sizeMm.z.toFixed(2)} mm`
  + `   ${plan.palette.length} colours, ${plan.parts.length} parts`);
console.log('palette ' + plan.palette.map((p, i) => 'T' + i + ' ' + p.hex).join('   '));
console.log('        base slab prints on T' + plan.baseHead);

const buf = M3.buildFlatU1_3mf({
  parts: plan.parts, filaments: plan.filaments, sizeMm: plan.sizeMm,
  baseHead: plan.baseHead, layerH: 0.12, name: path.basename(src).replace(/\.[^.]+$/, ''),
});
if (!buf) { console.error('FAILED to build the 3MF'); process.exit(1); }

const outPath = path.join(outDir, path.basename(src).replace(/\.[^.]+$/, '') + '-flat-U1.3mf');
fs.writeFileSync(outPath, buf);
console.log(`\nwrote   ${outPath}  (${(buf.length / 1024).toFixed(0)} KB)\n`);

// ── verify the FILE, not the code that wrote it ─────────────────────────────
console.log('checks read back out of the written file:');
const zip = openZip(fs.readFileSync(outPath));
const names = zip.entries.map((e) => e.name);
const text = (n) => Buffer.from(zip.file(n)).toString('utf8');

ok(names.includes('3D/3dmodel.model') && names.includes('3D/Objects/object_1.model'), 'geometry members present');
ok(!names.includes('Metadata/layer_config_ranges.xml'), 'no Z-band table (flat colour is a region, not a height)');

const root = text('3D/3dmodel.model');
const settings = text('Metadata/model_settings.config');
const parts = text('3D/Objects/object_1.model');
const compIds = [...root.matchAll(/<component[^>]*objectid="(\d+)"/g)].map((m) => m[1]);
const partIds = [...settings.matchAll(/<part id="(\d+)"/g)].map((m) => m[1]);
const objIds = [...parts.matchAll(/<object id="(\d+)"/g)].map((m) => m[1]);
ok(compIds.length === plan.parts.length, `every part is a component (${compIds.length}/${plan.parts.length})`);
ok(JSON.stringify(partIds) === JSON.stringify(compIds), 'model_settings describes exactly those components');
ok(JSON.stringify(objIds) === JSON.stringify(compIds), 'every referenced id is a real mesh object');

const extruders = [...settings.matchAll(/<part id="\d+"[\s\S]*?key="extruder" value="(\d+)"/g)].map((m) => +m[1]);
ok(extruders.length === plan.parts.length, 'every part names a head');
ok(extruders.every((e) => e >= 1 && e <= 4), 'every head is one of the U1\'s four: ' + extruders.join(','));
ok(JSON.stringify(extruders) === JSON.stringify(plan.parts.map((p) => p.head + 1)), 'each part got the head its region belongs to');

const cfg = JSON.parse(text('Metadata/project_settings.config'));
ok(cfg.filament_colour.length === 4, 'four filament slots');
ok(plan.parts.every((p) => cfg.filament_colour[p.head] === String(p.hex).toUpperCase()),
  'slot colours are indexed by head — load T0..T3 in the order printed above');
ok(cfg.enable_prime_tower === '0', 'prime tower off (SnapSwap needs no purge)');

// geometry sanity: welded, non-empty, and inside the bed
let tri = 0, vert = 0;
for (const o of parts.split('<object id=').slice(1)) {
  tri += (o.match(/<triangle /g) || []).length;
  vert += (o.match(/<vertex /g) || []).length;
}
ok(tri > 0, `mesh has faces (${tri} triangles, ${vert} vertices)`);
ok(vert < tri * 3, 'mesh is welded by index, not a triangle soup');
ok(plan.sizeMm.x <= 270 && plan.sizeMm.y <= 270, `fits the 270x270 bed (${plan.sizeMm.x.toFixed(0)}x${plan.sizeMm.y.toFixed(0)})`);

const m = root.match(/<item objectid="2" transform="([^"]+)"/);
const t = m ? m[1].trim().split(/\s+/).map(Number) : [];
ok(t.length === 12 && Math.abs(t[9] - (270 - plan.sizeMm.x) / 2) < 0.01, 'plate is centred on the bed');

console.log(fail.length ? `\n${fail.length} CHECK(S) FAILED` : '\nall offline checks passed');

console.log(`
what a machine cannot answer — do this next:

  1. open ${path.basename(outPath)} in Snapmaker Orca
  2. it should appear as ONE object with ${plan.parts.length} parts, not ${plan.parts.length} loose objects
  3. click each part: the extruder shown must match
${plan.parts.map((p, i) => `       part ${i + 1}  ->  T${p.head}  ${p.hex}${i === 0 ? '   (base slab, hidden under the caps)' : ''}`).join('\n')}
  4. slice it. the preview should show flat colour REGIONS, not stripes by height,
     and the tool-change count should be small — a few per layer at most
  5. load T0..T3 with the colours above and print it

  the failure this is looking for is a region printing in the wrong filament,
  which no test here can see because every test here reads the same numbers the
  writer wrote.
`);
process.exit(fail.length ? 1 : 0);
