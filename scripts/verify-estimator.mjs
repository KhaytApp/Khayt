#!/usr/bin/env node
/**
 * Score Khayt's geometry estimate against a real slicer.
 *
 * lib/stl-estimate.js decides how many grams a model will take when nobody has
 * sliced it — the number a customer is quoted through the intake form. Its unit
 * tests check it against physics I derived myself, on cubes. A cube is the
 * friendliest shape there is: the lowest surface-area-to-volume ratio of any
 * solid. Real parts are worse, and the estimator's shell term is driven by
 * exactly that ratio, so cubes cannot tell us whether it holds up.
 *
 * PrusaSlicer can. It is installed on this machine, it has a CLI, and its
 * G-code footer states the grams outright. So this slices each model for real
 * and prints the two numbers side by side.
 *
 * Usage
 *   node scripts/verify-estimator.mjs                  # built-in shape spread
 *   node scripts/verify-estimator.mjs a.stl b.stl      # your own models too
 *
 * WHAT IT CAN AND CANNOT SETTLE
 *
 * The comparison is only fair if both sides assume the same print. The slicer
 * is driven at 20% infill / 3 perimeters / 0.2mm layers, and Khayt is given a
 * wall thickness of 3 x the slicer's actual extrusion width. Anything left
 * over is the model's error, not a difference of opinion about the print.
 *
 * It says nothing about print TIME. That rests on throughputMm3PerS, which is
 * a guess until lib/estimate-calibration.js has real finished jobs to learn
 * from — see scripts/verify-printer-actuals.mjs.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';

const require_ = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const { estimateFromStl } = require_(path.join(ROOT, 'lib/stl-estimate.js'));
// The model this replaced: shell as a flat 35% of volume. Kept here (not
// imported from history) so the improvement is a measurement against the same
// slices rather than a claim.
const OLD_SHELL = 0.35;
const oldEstimate = (geom) => {
  const eff = OLD_SHELL + (1 - OLD_SHELL) * INFILL;
  return (geom.volumeMm3 / 1000) * DENSITY * eff;
};
const { intake } = require_(path.join(ROOT, 'lib/model-intake.js'));

const SLICERS = [
  '/Applications/PrusaSlicer.app/Contents/MacOS/PrusaSlicer',
  '/Applications/Original Prusa Drivers/PrusaSlicer.app/Contents/MacOS/PrusaSlicer',
  '/usr/bin/prusa-slicer',
  '/usr/local/bin/prusa-slicer',
];
const slicer = SLICERS.find((p) => { try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; } });
if (!slicer) {
  console.error('No PrusaSlicer found. Install it, or pass --slicer <path>.');
  console.error('Without a slicer there is no ground truth and this script has nothing to say.');
  process.exit(1);
}

const INFILL = 0.20;
const PERIMETERS = 3;
const LAYER = 0.2;
const NOZZLE = 0.4;
const DENSITY = 1.24;          // PLA, matching Khayt's default
// PrusaSlicer's default external/internal perimeter width for a 0.4 nozzle is
// ~0.45mm, so three of them is ~1.35mm of wall. Khayt's own default is 1.2mm
// (3 x 0.4). Using the slicer's real figure keeps the comparison about the
// MODEL rather than about a disagreement over how wide a line is.
const WALL = PERIMETERS * 0.45;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-est-'));

/** Write an ASCII STL from a triangle list. PrusaSlicer rejects our terse binary. */
function writeStl(file, tris) {
  let s = 'solid m\n';
  for (const t of tris) {
    s += 'facet normal 0 0 0\nouter loop\n';
    for (const v of t) s += `vertex ${v[0]} ${v[1]} ${v[2]}\n`;
    s += 'endloop\nendfacet\n';
  }
  fs.writeFileSync(file, s + 'endsolid m\n');
}

/** Axis-aligned box as 12 triangles, corner at origin. */
function box(x, y, z, ox = 0, oy = 0, oz = 0) {
  const v = [[0,0,0],[x,0,0],[x,y,0],[0,y,0],[0,0,z],[x,0,z],[x,y,z],[0,y,z]]
    .map(([a,b,c]) => [a+ox, b+oy, c+oz]);
  const f = [[0,3,2],[0,2,1],[4,5,6],[4,6,7],[0,1,5],[0,5,4],
             [1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]];
  return f.map((t) => t.map((i) => v[i]));
}

/**
 * Deliberately spread across surface-area-to-volume ratio, because that ratio
 * is the only thing the shell term depends on. A cube is the easy end; a thin
 * plate and a comb of ribs are where a volume-fraction model falls apart.
 */
const SHAPES = {
  'cube 40mm':            () => box(40, 40, 40),
  'block 80x60x30':       () => box(80, 60, 30),
  'plate 100x100x3':      () => box(100, 100, 3),
  'rod 10x10x120':        () => box(10, 10, 120),
  'comb (7 ribs)':        () => {
    let t = box(80, 40, 3);                       // base
    for (let i = 0; i < 7; i++) t = t.concat(box(4, 40, 25, i * 11, 0, 3));
    return t;
  },
  'frame (4 walls)':      () => {
    const L = 70, W = 4, H = 30;
    return box(L, W, H)
      .concat(box(L, W, H, 0, L - W, 0))
      .concat(box(W, L - 2 * W, H, 0, W, 0))
      .concat(box(W, L - 2 * W, H, L - W, W, 0));
  },
};

function sliceGrams(stlPath) {
  const out = path.join(tmp, path.basename(stlPath).replace(/\.stl$/i, '') + '.gcode');
  execFileSync(slicer, [
    '--export-gcode',
    '--fill-density', `${Math.round(INFILL * 100)}%`,
    '--perimeters', String(PERIMETERS),
    '--layer-height', String(LAYER),
    '--nozzle-diameter', String(NOZZLE),
    '--filament-diameter', '1.75',
    '--filament-density', String(DENSITY),
    // Skirt, brim and supports are real filament, but they are not the MODEL —
    // a 10x10x120 rod first scored 15.2 g against a solid weight of 14.9 g,
    // which is impossible until you notice the slicer was adding a skirt. The
    // estimator does not claim to predict them, so comparing against them
    // would be scoring it on a question it never answers.
    // NOTE the `=` form: `--skirts 0` makes PrusaSlicer treat the 0 as another
    // input file and fail with "No such file: 0".
    '--skirts=0',
    '--brim-width=0',
    '--support-material=0',
    '-o', out, stlPath,
  ], { stdio: ['ignore', 'ignore', 'pipe'], timeout: 300_000 });
  const g = fs.readFileSync(out, 'latin1');
  const m = /;\s*filament used \[g\]\s*=\s*([\d.]+)/i.exec(g);
  if (!m) throw new Error('no "filament used [g]" in the g-code');
  return parseFloat(m[1]);
}

function khaytGrams(stlPath) {
  const res = intake({ filename: path.basename(stlPath), bytes: fs.readFileSync(stlPath) });
  if (!res.geometry || !(res.geometry.volumeMm3 > 0)) throw new Error('no geometry parsed');
  const est = estimateFromStl(res.geometry, {
    infillPct: INFILL, wallThicknessMm: WALL, densityGPerCm3: DENSITY, wastePct: 0,
  });
  return { grams: est.estWeightG, geom: res.geometry, shell: est.shellFraction,
           oldGrams: oldEstimate(res.geometry) };
}

const extra = process.argv.slice(2).filter((a) => !a.startsWith('-'));
const jobs = [];
for (const [name, make] of Object.entries(SHAPES)) {
  const p = path.join(tmp, name.replace(/[^a-z0-9]+/gi, '_') + '.stl');
  writeStl(p, make());
  jobs.push([name, p]);
}
for (const p of extra) jobs.push([path.basename(p), p]);

console.log(`slicer: ${slicer}`);
console.log(`settings: ${Math.round(INFILL * 100)}% infill, ${PERIMETERS} perimeters, `
  + `${LAYER}mm layers, wall=${WALL}mm, PLA ${DENSITY} g/cm³, no waste margin\n`);
console.log('model                      area/vol   sliced g    old g  old err     new g  new err');
console.log('-'.repeat(78));

const errors = [];
for (const [name, p] of jobs) {
  let k, sliced;
  try { k = khaytGrams(p); } catch (e) { console.log(`${name.padEnd(26)} parse failed: ${e.message}`); continue; }
  try { sliced = sliceGrams(p); } catch (e) { console.log(`${name.padEnd(26)} slice failed: ${e.message}`); continue; }
  const ratio = k.geom.areaMm2 / k.geom.volumeMm3;
  const err = (k.grams - sliced) / sliced * 100;
  const errOld = (k.oldGrams - sliced) / sliced * 100;
  errors.push({ name, err, errOld, ratio });
  const pct = (v) => ((v > 0 ? '+' : '') + v.toFixed(0) + '%').padStart(8);
  console.log(`${name.padEnd(26)}${ratio.toFixed(3).padStart(8)}${sliced.toFixed(1).padStart(11)}`
    + `${k.oldGrams.toFixed(1).padStart(9)}${pct(errOld)}${k.grams.toFixed(1).padStart(10)}${pct(err)}`);
}

if (errors.length) {
  const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
  const meanNew = mean(errors.map((e) => Math.abs(e.err)));
  const meanOld = mean(errors.map((e) => Math.abs(e.errOld)));
  const worst = errors.reduce((a, b) => (Math.abs(b.err) > Math.abs(a.err) ? b : a));
  console.log('-'.repeat(78));
  console.log(`mean |error|   old ${meanOld.toFixed(0)}%   ->   new ${meanNew.toFixed(0)}%`);
  console.log(`worst remaining: ${worst.name} at ${worst.err > 0 ? '+' : ''}${worst.err.toFixed(0)}%`);
  console.log('\nA positive error means Khayt quotes MORE filament than the print uses —');
  console.log('the customer is overcharged. Negative means the shop absorbs the difference.');
}
fs.rmSync(tmp, { recursive: true, force: true });
