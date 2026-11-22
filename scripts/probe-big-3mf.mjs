/**
 * What the convert pipeline actually does with a very large 3MF — stage by stage, with
 * the clock and the resident set beside each one.
 *
 *   node scripts/probe-big-3mf.mjs <file.3mf> [targetId]
 *
 * Written against a 229 MB Bambu poster (19 meshes, 1168 MB inflated) that the converter
 * refused outright, and kept for the next one. The numbers it printed are the argument for
 * member passthrough: readMembers 1479 ms -> 130 ms, convert 106 s -> 7.7 s.
 *
 * Pass a targetId to run a full convert as well. NOTE that this holds the whole file and
 * its inflated members in memory on purpose — that is the thing being measured — so it is
 * a deliberate memory hog. Run it on its own.
 */
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const MF = require('../lib/mf-convert.js');

const F = process.argv[2];
const mb = (n) => (n / 1024 / 1024).toFixed(1) + ' MB';
const rss = () => mb(process.memoryUsage().rss);
const t0 = Date.now();
const lap = (label) => console.log(`  ${label.padEnd(28)} ${String(Date.now() - t0).padStart(7)} ms   rss ${rss()}`);

console.log('file:', F);
const buf = fs.readFileSync(F);
console.log('bytes:', mb(buf.length));
lap('read');

const members = MF.readMembers(buf);
lap('readMembers');
console.log('  members read:', members.length);
const meshes = members.filter((m) => /\.model$/i.test(m.name));
console.log('  mesh members:', meshes.length, 'totalling', mb(meshes.reduce((s, m) => s + m.data.length, 0)));
console.log('  configs seen:', members.filter((m) => /\.config$/i.test(m.name)).map((m) => m.name).join(', ') || '(none)');

console.log('  flavour:', MF.detectFlavour(members));
lap('detectFlavour');
const fil = MF.extractFilaments(members);
console.log('  filaments:', fil.length, fil.slice(0, 6).map((f) => f.color).join(' '));
lap('extractFilaments');

try {
  const a = MF.analyze(buf);
  console.log('  analyze ok:', !!a, a && { flavour: a.flavour, filaments: (a.filaments || []).length, plates: (a.plates || []).length });
} catch (e) { console.log('  analyze THREW:', e.message); }
lap('analyze');

// full convert to a temp file — the real question is whether it completes
const target = process.argv[3];
if (target) {
  const peak = () => mb(process.memoryUsage().rss);
  try {
    const out = MF.convert(buf, { targetId: target, mode: 'normalize' });
    console.log('  convert ok:', !!out, out && out.buffer ? mb(out.buffer.length) : '(no buffer)');
  } catch (e) { console.log('  convert THREW:', e.message); }
  lap('convert');
  console.log('  peak rss:', peak());
}
